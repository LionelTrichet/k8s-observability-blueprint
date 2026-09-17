package tracing_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"k8s-observability-blueprint/demo/internal/app"
	"k8s-observability-blueprint/demo/internal/metrics"
	"k8s-observability-blueprint/demo/internal/tracing"
)

func newApp(t *testing.T) (http.Handler, *tracetest.InMemoryExporter) {
	t.Helper()
	exporter := tracetest.NewInMemoryExporter()
	provider := sdktrace.NewTracerProvider(
		sdktrace.WithSyncer(exporter),
		sdktrace.WithResource(tracing.Resource()),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	t.Cleanup(func() { _ = provider.Shutdown(t.Context()) })

	exits := make(chan int, 1)
	h := app.New(provider.Tracer(tracing.TracerName), metrics.New(),
		func(time.Duration) {}, func(code int) { exits <- code }).Handler()
	return h, exporter
}

func attrs(span tracetest.SpanStub) map[attribute.Key]attribute.Value {
	out := make(map[attribute.Key]attribute.Value, len(span.Attributes))
	for _, kv := range span.Attributes {
		out[kv.Key] = kv.Value
	}
	return out
}

func TestScenarioSpans(t *testing.T) {
	cases := []struct {
		path     string
		span     string
		scenario string
		status   int64
	}{
		{"/work", "demo.work", "baseline", 200},
		{"/error", "demo.error", "error", 500},
		{"/slow", "demo.slow", "latency", 200},
		{"/crash", "demo.crash", "crash", 202},
	}

	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			h, exporter := newApp(t)
			h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, tc.path, nil))

			spans := exporter.GetSpans()
			if len(spans) != 1 {
				t.Fatalf("exported %d spans, want 1", len(spans))
			}
			span := spans[0]
			if span.Name != tc.span {
				t.Fatalf("span name = %q, want %q", span.Name, tc.span)
			}

			a := attrs(span)
			if got := a["scenario"].AsString(); got != tc.scenario {
				t.Errorf("scenario = %q, want %q", got, tc.scenario)
			}
			if got := a["http.route"].AsString(); got != tc.path {
				t.Errorf("http.route = %q, want %q", got, tc.path)
			}
			if got := a["http.request.method"].AsString(); got != http.MethodGet {
				t.Errorf("http.request.method = %q, want GET", got)
			}
			if got := a["http.response.status_code"].AsInt64(); got != tc.status {
				t.Errorf("http.response.status_code = %d, want %d", got, tc.status)
			}
		})
	}
}

func TestErrorSpanStatus(t *testing.T) {
	h, exporter := newApp(t)
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/error", nil))
	span := exporter.GetSpans()[0]
	if span.Status.Code != codes.Error {
		t.Fatalf("span status = %v, want Error", span.Status.Code)
	}
}

func TestSuccessfulSpanStatusIsNotError(t *testing.T) {
	h, exporter := newApp(t)
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/work", nil))
	if code := exporter.GetSpans()[0].Status.Code; code == codes.Error {
		t.Fatal("successful request produced an Error span status")
	}
}

func TestOperationalEndpointsAreNotTraced(t *testing.T) {
	h, exporter := newApp(t)
	for _, path := range []string{"/healthz", "/readyz", "/metrics"} {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil))
	}
	if n := len(exporter.GetSpans()); n != 0 {
		t.Fatalf("operational endpoints produced %d spans, want 0", n)
	}
}

func TestResourceAttributes(t *testing.T) {
	want := map[string]string{
		"service.name":                "demo-service",
		"service.version":             "0.1.0",
		"deployment.environment.name": "local",
	}
	set := tracing.Resource().Set()
	for key, value := range want {
		got, ok := set.Value(attribute.Key(key))
		if !ok || got.AsString() != value {
			t.Errorf("resource %s = %q, want %q", key, got.AsString(), value)
		}
	}
}

func TestNewProviderRejectsEmptyEndpoint(t *testing.T) {
	if _, err := tracing.NewProvider(t.Context(), ""); err == nil {
		t.Fatal("NewProvider accepted an empty endpoint")
	}
}
