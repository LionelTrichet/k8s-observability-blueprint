// Package app implements the demo workload's HTTP handlers.
//
// The workload exists only as a predictable telemetry source and a
// deterministic failure source. It has no business logic.
package app

import (
	"encoding/json"
	"net/http"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"

	"k8s-observability-blueprint/demo/internal/metrics"
)

const (
	// SlowDelay is the fixed delay of the latency scenario. It is not
	// configurable per request.
	SlowDelay = 750 * time.Millisecond
	// CrashDelay is how long the process waits after answering /crash before
	// exiting, so the response reaches the client.
	CrashDelay = 500 * time.Millisecond
	// CrashExitCode is the process exit code of the crash scenario.
	CrashExitCode = 1
)

// Exiter terminates the process. Production uses os.Exit; tests inject a fake.
type Exiter func(code int)

// Sleeper blocks for a duration. Production uses time.Sleep; tests inject a
// fake so unit tests do not wait for real delays.
type Sleeper func(d time.Duration)

// App holds the handler dependencies.
type App struct {
	tracer  trace.Tracer
	metrics *metrics.Metrics
	sleep   Sleeper
	exit    Exiter
}

// New wires the handler dependencies explicitly.
func New(tracer trace.Tracer, m *metrics.Metrics, sleep Sleeper, exit Exiter) *App {
	return &App{tracer: tracer, metrics: m, sleep: sleep, exit: exit}
}

// Handler returns the HTTP routes. Anything not listed answers 404.
func (a *App) Handler() http.Handler {
	mux := http.NewServeMux()

	// Operational endpoints: not scenario traffic, not counted in
	// application metrics, not traced.
	mux.HandleFunc("GET /healthz", a.healthz)
	mux.HandleFunc("GET /readyz", a.readyz)
	mux.Handle("GET /metrics", a.metrics.Handler())

	mux.HandleFunc("GET /work", a.scenario("/work", "demo.work", "baseline", a.work))
	mux.HandleFunc("GET /error", a.scenario("/error", "demo.error", "error", a.fail))
	mux.HandleFunc("GET /slow", a.scenario("/slow", "demo.slow", "latency", a.slow))
	mux.HandleFunc("GET /crash", a.scenario("/crash", "demo.crash", "crash", a.crash))

	return mux
}

type statusResponse struct {
	Status string `json:"status"`
}

type scenarioResponse struct {
	OK      bool   `json:"ok"`
	Route   string `json:"route"`
	TraceID string `json:"traceId"`
	Error   string `json:"error,omitempty"`
	Action  string `json:"action,omitempty"`
}

// scenarioFunc writes the response and returns the HTTP status it wrote.
type scenarioFunc func(w http.ResponseWriter, route string, span trace.Span) int

// scenario wraps a handler with its span and application metrics. Route and
// scenario are fixed per endpoint and never derived from the request, which
// keeps label and attribute cardinality bounded.
func (a *App) scenario(route, spanName, scenario string, fn scenarioFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		_, span := a.tracer.Start(r.Context(), spanName,
			trace.WithSpanKind(trace.SpanKindServer),
			trace.WithAttributes(
				attribute.String("http.request.method", r.Method),
				attribute.String("http.route", route),
				attribute.String("scenario", scenario),
			),
		)
		defer span.End()

		status := fn(w, route, span)

		span.SetAttributes(attribute.Int("http.response.status_code", status))
		a.metrics.Observe(route, status, time.Since(start))
	}
}

func (a *App) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, statusResponse{Status: "ok"})
}

func (a *App) readyz(w http.ResponseWriter, _ *http.Request) {
	// The server starts listening only after tracing is initialized, so a
	// reachable handler means the workload is fully instrumented.
	writeJSON(w, http.StatusOK, statusResponse{Status: "ready"})
}

func (a *App) work(w http.ResponseWriter, route string, span trace.Span) int {
	writeJSON(w, http.StatusOK, scenarioResponse{
		OK: true, Route: route, TraceID: traceID(span),
	})
	return http.StatusOK
}

func (a *App) fail(w http.ResponseWriter, route string, span trace.Span) int {
	const message = "injected failure"
	span.SetStatus(codes.Error, message)
	writeJSON(w, http.StatusInternalServerError, scenarioResponse{
		OK: false, Route: route, TraceID: traceID(span), Error: message,
	})
	return http.StatusInternalServerError
}

func (a *App) slow(w http.ResponseWriter, route string, span trace.Span) int {
	a.sleep(SlowDelay)
	writeJSON(w, http.StatusOK, scenarioResponse{
		OK: true, Route: route, TraceID: traceID(span),
	})
	return http.StatusOK
}

func (a *App) crash(w http.ResponseWriter, route string, span trace.Span) int {
	writeJSON(w, http.StatusAccepted, scenarioResponse{
		OK: true, Route: route, TraceID: traceID(span), Action: "container will exit",
	})
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}

	// Exit asynchronously after the response is written. The span may not be
	// exported before exit; the crash scenario validates restart telemetry,
	// not trace durability.
	go func() {
		a.sleep(CrashDelay)
		a.exit(CrashExitCode)
	}()

	return http.StatusAccepted
}

func traceID(span trace.Span) string {
	return span.SpanContext().TraceID().String()
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	// The status line is already sent; an encoding or write failure here means
	// the client went away and there is nothing useful left to report to it.
	_ = json.NewEncoder(w).Encode(body)
}
