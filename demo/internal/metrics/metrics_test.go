package metrics_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"go.opentelemetry.io/otel/trace/noop"

	"k8s-observability-blueprint/demo/internal/app"
	"k8s-observability-blueprint/demo/internal/metrics"
)

func newApp(m *metrics.Metrics) http.Handler {
	exits := make(chan int, 1)
	return app.New(
		noop.NewTracerProvider().Tracer("test"),
		m,
		func(time.Duration) {},
		func(code int) { exits <- code },
	).Handler()
}

func get(h http.Handler, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

// exposition returns the /metrics output, which is what Prometheus scrapes.
func exposition(t *testing.T, h http.Handler) string {
	t.Helper()
	rec := get(h, "/metrics")
	if rec.Code != http.StatusOK {
		t.Fatalf("/metrics status = %d, want 200", rec.Code)
	}
	return rec.Body.String()
}

func requireLine(t *testing.T, body, line string) {
	t.Helper()
	for _, l := range strings.Split(body, "\n") {
		if l == line {
			return
		}
	}
	t.Fatalf("metrics output lacks line %q:\n%s", line, body)
}

func TestWorkIsCountedWithRouteAndStatus(t *testing.T) {
	h := newApp(metrics.New())
	get(h, "/work")
	requireLine(t, exposition(t, h), `demo_http_requests_total{route="/work",status="200"} 1`)
}

func TestErrorIsCountedWithRouteAndStatus(t *testing.T) {
	h := newApp(metrics.New())
	get(h, "/error")
	requireLine(t, exposition(t, h), `demo_http_requests_total{route="/error",status="500"} 1`)
}

func TestSlowDurationIsObserved(t *testing.T) {
	h := newApp(metrics.New())
	get(h, "/slow")
	requireLine(t, exposition(t, h), `demo_http_request_duration_seconds_count{route="/slow"} 1`)
}

func TestOperationalEndpointsAreExcluded(t *testing.T) {
	m := metrics.New()
	h := newApp(m)
	for _, path := range []string{"/healthz", "/readyz", "/metrics"} {
		get(h, path)
	}
	if n := testutil.CollectAndCount(m.Registry(), "demo_http_requests_total", "demo_http_request_duration_seconds"); n != 0 {
		t.Fatalf("operational endpoints produced %d application series, want 0", n)
	}
}

func TestLabelsAreBounded(t *testing.T) {
	h := newApp(metrics.New())
	get(h, "/work?user=alice&traceId=abc")
	body := exposition(t, h)
	requireLine(t, body, `demo_http_requests_total{route="/work",status="200"} 1`)
	for _, forbidden := range []string{"alice", "traceId=", "user=", `path="`, `url="`} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("request input leaked into metrics: %q", forbidden)
		}
	}
}

func TestHistogramBuckets(t *testing.T) {
	want := []float64{0.05, 0.10, 0.25, 0.50, 1.00, 2.00, 5.00}
	got := metrics.DurationBuckets()
	if len(got) != len(want) {
		t.Fatalf("buckets = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("buckets = %v, want %v", got, want)
		}
	}
	got[0] = 42
	if metrics.DurationBuckets()[0] != 0.05 {
		t.Fatal("DurationBuckets must return a fresh slice")
	}
}

func TestIndependentInstancesDoNotConflict(t *testing.T) {
	a, b := metrics.New(), metrics.New()
	get(newApp(a), "/work")
	if n := testutil.CollectAndCount(b.Registry(), "demo_http_requests_total"); n != 0 {
		t.Fatalf("second instance saw %d series from the first", n)
	}
}
