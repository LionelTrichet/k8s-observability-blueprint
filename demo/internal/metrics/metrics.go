// Package metrics defines the demo workload's Prometheus instruments.
//
// All collectors are registered on a registry owned by Metrics, never on
// prometheus.DefaultRegisterer, so tests stay isolated and repeated
// construction cannot fail with duplicate registration.
package metrics

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// DurationBuckets returns the fixed histogram buckets in seconds. It is a
// function rather than a package variable so the buckets cannot be mutated.
func DurationBuckets() []float64 {
	return []float64{0.05, 0.10, 0.25, 0.50, 1.00, 2.00, 5.00}
}

// Metrics holds the application instruments and their registry.
type Metrics struct {
	registry *prometheus.Registry
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
}

// New creates the instruments on a dedicated registry.
func New() *Metrics {
	registry := prometheus.NewRegistry()

	requests := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "demo_http_requests_total",
		Help: "Scenario HTTP requests handled by the demo workload.",
	}, []string{"route", "status"})

	duration := prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "demo_http_request_duration_seconds",
		Help:    "Scenario HTTP request duration in seconds.",
		Buckets: DurationBuckets(),
	}, []string{"route"})

	registry.MustRegister(requests, duration)

	return &Metrics{registry: registry, requests: requests, duration: duration}
}

// Observe records one scenario request. The route must be a fixed,
// low-cardinality value supplied by the application, never user input.
func (m *Metrics) Observe(route string, status int, elapsed time.Duration) {
	m.requests.WithLabelValues(route, strconv.Itoa(status)).Inc()
	m.duration.WithLabelValues(route).Observe(elapsed.Seconds())
}

// Registry exposes the registry for tests.
func (m *Metrics) Registry() *prometheus.Registry {
	return m.registry
}

// Handler serves the registry in Prometheus exposition format.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{Registry: m.registry})
}
