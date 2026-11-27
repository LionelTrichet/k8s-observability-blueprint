// Command server runs the demo workload.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"k8s-observability-blueprint/demo/internal/app"
	"k8s-observability-blueprint/demo/internal/metrics"
	"k8s-observability-blueprint/demo/internal/tracing"
)

const (
	listenAddr      = "0.0.0.0:8080"
	shutdownTimeout = 5 * time.Second
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("demo-service stopped", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) (runErr error) {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	// Tracing must initialize before the server listens: the workload never
	// runs in a partially instrumented state.
	provider, err := tracing.NewProvider(ctx, os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"))
	if err != nil {
		return fmt.Errorf("initialize tracing: %w", err)
	}

	// Always flush telemetry, including when HTTP shutdown or serving fails.
	// Give the exporter its own deadline rather than reusing HTTP's deadline.
	defer func() {
		flushCtx, cancel := context.WithTimeout(
			context.Background(),
			shutdownTimeout,
		)
		defer cancel()

		if err := provider.Shutdown(flushCtx); err != nil {
			runErr = errors.Join(
				runErr,
				fmt.Errorf("shutdown tracer provider: %w", err),
			)
		}

		if runErr == nil {
			logger.Info("stopped")
		}
	}()

	application := app.New(provider.Tracer(tracing.TracerName), metrics.New(), time.Sleep, os.Exit)

	server := &http.Server{
		Addr:              listenAddr,
		Handler:           application.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	serveErr := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", listenAddr, "version", tracing.ServiceVersion)
		serveErr <- server.ListenAndServe()
	}()

	select {
	case err := <-serveErr:
		return fmt.Errorf("serve HTTP: %w", err)
	case <-ctx.Done():
		logger.Info("shutdown signal received")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	// Stop accepting and drain HTTP first; the deferred flush sends traces last.
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown HTTP server: %w", err)
	}
	if err := <-serveErr; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve HTTP: %w", err)
	}

	return nil
}
