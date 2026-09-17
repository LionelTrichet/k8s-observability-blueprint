package app_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"sync"
	"testing"
	"time"

	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"k8s-observability-blueprint/demo/internal/app"
	"k8s-observability-blueprint/demo/internal/metrics"
	"k8s-observability-blueprint/demo/internal/tracing"
)

var traceIDPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

type fakes struct {
	mu     sync.Mutex
	sleeps []time.Duration
	exits  chan int
}

func (f *fakes) sleep(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sleeps = append(f.sleeps, d)
}

func (f *fakes) recordedSleeps() []time.Duration {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]time.Duration(nil), f.sleeps...)
}

func (f *fakes) exit(code int) {
	f.exits <- code
}

func newTestApp(t *testing.T) (http.Handler, *fakes) {
	t.Helper()
	provider := sdktrace.NewTracerProvider(
		sdktrace.WithSyncer(tracetest.NewInMemoryExporter()),
		sdktrace.WithResource(tracing.Resource()),
	)
	t.Cleanup(func() { _ = provider.Shutdown(t.Context()) })

	f := &fakes{exits: make(chan int, 1)}
	a := app.New(provider.Tracer(tracing.TracerName), metrics.New(), f.sleep, f.exit)
	return a.Handler(), f
}

func do(t *testing.T, h http.Handler, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
	return rec
}

func decode(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", got)
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("response is not valid JSON: %v: %s", err, rec.Body.String())
	}
	return body
}

func TestHealthz(t *testing.T) {
	h, _ := newTestApp(t)
	rec := do(t, h, http.MethodGet, "/healthz")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if body := decode(t, rec); body["status"] != "ok" {
		t.Fatalf(`status field = %v, want "ok"`, body["status"])
	}
}

func TestReadyz(t *testing.T) {
	h, _ := newTestApp(t)
	rec := do(t, h, http.MethodGet, "/readyz")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if body := decode(t, rec); body["status"] != "ready" {
		t.Fatalf(`status field = %v, want "ready"`, body["status"])
	}
}

func TestWork(t *testing.T) {
	h, _ := newTestApp(t)
	rec := do(t, h, http.MethodGet, "/work")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := decode(t, rec)
	if body["ok"] != true || body["route"] != "/work" {
		t.Fatalf("unexpected body: %v", body)
	}
	if id, _ := body["traceId"].(string); !traceIDPattern.MatchString(id) {
		t.Fatalf("traceId %q does not match %s", id, traceIDPattern)
	}
}

func TestError(t *testing.T) {
	h, _ := newTestApp(t)
	rec := do(t, h, http.MethodGet, "/error")
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	body := decode(t, rec)
	if body["ok"] != false || body["route"] != "/error" || body["error"] != "injected failure" {
		t.Fatalf("unexpected body: %v", body)
	}
	if id, _ := body["traceId"].(string); !traceIDPattern.MatchString(id) {
		t.Fatalf("traceId %q does not match %s", id, traceIDPattern)
	}
}

func TestSlowUsesInjectedFixedDelay(t *testing.T) {
	h, f := newTestApp(t)
	start := time.Now()
	rec := do(t, h, http.MethodGet, "/slow")
	if elapsed := time.Since(start); elapsed >= app.SlowDelay {
		t.Fatalf("unit test waited %v; the delay must go through the injected sleeper", elapsed)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := f.recordedSleeps(); len(got) != 1 || got[0] != 750*time.Millisecond {
		t.Fatalf("sleeps = %v, want exactly [750ms]", got)
	}
}

func TestSlowIgnoresQueryParameters(t *testing.T) {
	h, f := newTestApp(t)
	do(t, h, http.MethodGet, "/slow?delay=10s&duration=1ms")
	if got := f.recordedSleeps(); len(got) != 1 || got[0] != app.SlowDelay {
		t.Fatalf("sleeps = %v, want the fixed delay only", got)
	}
}

func TestCrashAnswersThenExits(t *testing.T) {
	h, f := newTestApp(t)
	rec := do(t, h, http.MethodGet, "/crash")
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202", rec.Code)
	}
	body := decode(t, rec)
	if body["action"] != "container will exit" || body["route"] != "/crash" {
		t.Fatalf("unexpected body: %v", body)
	}

	select {
	case code := <-f.exits:
		if code != 1 {
			t.Fatalf("exit code = %d, want 1", code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("exiter was not called")
	}
	if got := f.recordedSleeps(); len(got) != 1 || got[0] != 500*time.Millisecond {
		t.Fatalf("sleeps = %v, want exactly [500ms] before exit", got)
	}
}

func TestUnknownRoute(t *testing.T) {
	h, _ := newTestApp(t)
	for _, path := range []string{"/", "/unknown", "/work/extra", "/healthz/"} {
		if rec := do(t, h, http.MethodGet, path); rec.Code != http.StatusNotFound {
			t.Errorf("GET %s status = %d, want 404", path, rec.Code)
		}
	}
}
