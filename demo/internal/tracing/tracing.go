// Package tracing configures the OpenTelemetry tracer provider for the demo
// workload: OTLP/gRPC export, a batch span processor and always-on sampling.
package tracing

import (
	"context"
	"fmt"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

const (
	// ServiceName is the resource service.name of every exported span.
	ServiceName = "demo-service"
	// ServiceVersion is the resource service.version of every exported span.
	ServiceVersion = "0.1.0"
	// Environment is the resource deployment.environment.name.
	Environment = "local"
	// TracerName identifies the instrumentation scope.
	TracerName = "k8s-observability-blueprint/demo"
)

// Resource returns the resource attached to every span.
func Resource() *resource.Resource {
	return resource.NewSchemaless(
		attribute.String("service.name", ServiceName),
		attribute.String("service.version", ServiceVersion),
		attribute.String("deployment.environment.name", Environment),
	)
}

// NewProvider builds a tracer provider exporting to an OTLP/gRPC endpoint in
// plaintext. Traffic stays inside the ephemeral kind cluster.
//
// Every span is sampled: this is a validation environment where each scenario
// trace must be retrievable by ID.
func NewProvider(ctx context.Context, endpoint string) (*sdktrace.TracerProvider, error) {
	if endpoint == "" {
		return nil, fmt.Errorf("tracing: OTLP endpoint is empty")
	}

	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(endpoint),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		return nil, fmt.Errorf("tracing: create OTLP gRPC exporter for %q: %w", endpoint, err)
	}

	return sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(Resource()),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	), nil
}
