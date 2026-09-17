# Kubernetes Observability Blueprint

**Reproducible Kubernetes observability reference stack with OpenTelemetry, Prometheus and failure-driven validation.**

Kubernetes Observability Blueprint is a reproducible local and CI environment that deploys a small instrumented workload, Prometheus, OpenTelemetry Collector, Tempo and Grafana on kind.

Instead of treating successful deployment as proof of observability, the repository generates known application failures and automatically verifies the resulting metrics and traces.

## Why

A dashboard that loads does not prove a telemetry pipeline works. This repository validates observability from both directions: known workload behavior is generated first, then Prometheus and Tempo are queried to prove that the expected signal arrived.

## Architecture

```text
                     ┌──────────────────┐
                     │   demo-service   │
                     │       Go         │
                     └────────┬─────────┘
                              │
                ┌─────────────┴──────────────┐
                │                            │
                │ /metrics                   │ OTLP/gRPC traces
                ▼                            ▼
        ┌───────────────┐          ┌────────────────────┐
        │  Prometheus   │          │ OpenTelemetry      │
        │               │          │ Collector          │
        └───────┬───────┘          └─────────┬──────────┘
                │                            │ OTLP/gRPC
                │                            ▼
                │                    ┌───────────────┐
                │                    │     Tempo     │
                │                    └───────┬───────┘
                └─────────────┬──────────────┘
                              ▼
                       ┌─────────────┐
                       │   Grafana   │
                       └─────────────┘
                              ▲
                              │ automated validation
                   ┌──────────┴──────────┐
                   │  scenario scripts   │
                   └─────────────────────┘
```

Two namespaces: `observability` holds the Prometheus Operator, Prometheus, kube-state-metrics, Grafana, the OpenTelemetry Collector and Tempo; `demo` holds only the demo workload, its Service, ServiceMonitor and dashboard ConfigMap. See [ARCHITECTURE.md](ARCHITECTURE.md).

## What This Proves

- Prometheus scrapes application metrics
- ServiceMonitor discovery works across namespaces
- kube-state-metrics exposes restart state
- demo-service exports OTLP traces
- Collector receives and forwards traces
- Tempo stores and retrieves traces
- Grafana is provisioned with Prometheus and Tempo
- error, latency and restart scenarios produce expected signals
- the same environment runs locally and in CI

## Stack

| Component | Version |
|-----------|---------|
| Go | 1.27.1 |
| kind | 0.32.0 |
| Kubernetes (kind node) | 1.36.1, pinned by digest |
| kubectl | 1.36.1 |
| Helm | 4.3.0 |
| kube-prometheus-stack chart | 89.2.0 |
| OpenTelemetry Collector chart | 0.173.1 |
| Tempo chart | 2.3.0 (Tempo 2.10.8) |
| Prometheus client_golang | 1.24.1 |
| OpenTelemetry Go | 1.44.0 |

All versions live in [`infra/versions.env`](infra/versions.env). Nothing uses `latest`.

## Quick Start

Requirements: Docker, kind 0.32.x, kubectl 1.36.x, Helm 4.3.x, Go 1.27.x, curl and jq. Nothing is installed automatically.

```bash
make doctor
make up
make verify
```

Scenarios:

```bash
make scenario-errors
make scenario-latency
make scenario-crash
```

Cleanup:

```bash
make down
```

`make down` deletes only the `k8s-observability-blueprint` kind cluster.

## Baseline Verification

`make verify` proves, with automated assertions:

- demo-service, the Collector, Tempo, Grafana and kube-state-metrics are Ready;
- Prometheus has an `up{namespace="demo"}` target;
- `GET /work` returns `200` with a 32-character lowercase hex `traceId`;
- `demo_http_requests_total{route="/work",status="200"}` reaches at least 1 within 30 seconds;
- Tempo returns that exact trace from `GET /api/traces/<traceId>` within 30 seconds, with `service.name=demo-service`, `scenario=baseline` and `http.route=/work`;
- the running Collector pipeline is trace-only;
- Grafana has a Prometheus datasource, a Tempo datasource and the four-panel dashboard;
- the demo pod meets the container security boundary and nothing is exposed beyond ClusterIP.

## Failure Scenarios

| Scenario | Cause | Metrics proof | Trace proof |
|----------|-------|---------------|-------------|
| Baseline | `/work` | `200` counter | required |
| Error | `/error` | `500` counter | required |
| Latency | `/slow` | duration \>= threshold | required |
| Crash | `/crash` | container restart | not required |

- **Error** — `GET /error` returns `500`; the `route="/error",status="500"` counter reaches at least 1 and the exact trace carries `scenario=error` and `http.response.status_code=500`.
- **Latency** — `GET /slow` has a fixed 750 ms delay; the request must take at least 0.70 s and less than 3 s, and the cumulative histogram average (`_sum / _count`, not `rate()`) must be at least 0.70 s.
- **Crash** — `GET /crash` returns `202` and exits the process after 500 ms; the `demo-service` container `restartCount` must increase, the pod must become Ready again and `kube_pod_container_status_restarts_total` must reach at least 1. The crash span is not required: the process exits before a guaranteed flush.

Every scenario is safe to re-run against the same cluster and asserts `>= threshold`, never an exact total.

Failure scenarios are deterministic and bounded. The repository does not use a general-purpose chaos engineering platform.

The demo workload intentionally exposes a crash endpoint for local failure validation. Do not deploy this workload as an Internet-facing application.

## Metrics

Application metrics are exposed directly for Prometheus scraping. OpenTelemetry Collector is intentionally used for the trace pipeline only in v0.1.0.

| Metric | Type | Labels |
|--------|------|--------|
| `demo_http_requests_total` | counter | `route`, `status` |
| `demo_http_request_duration_seconds` | histogram, buckets 0.05–5 s | `route` |

`route` is one of `/work`, `/error`, `/slow`, `/crash`. `/healthz`, `/readyz` and `/metrics` are not counted. No labels are derived from user input, trace IDs or pod identity.

Discovery goes through a ServiceMonitor in `demo`. Prometheus uses an unrestricted ServiceMonitor selector, so the ServiceMonitor does not need the Helm `release` label. `make check` renders the pinned chart and fails if the selector regresses to a release-label match.

## Tracing

```text
demo-service ── OTLP/gRPC ──▶ OpenTelemetry Collector ── OTLP/gRPC ──▶ Tempo
```

- Spans: `demo.work`, `demo.error`, `demo.slow`, `demo.crash`.
- Attributes: `http.request.method`, `http.route`, `http.response.status_code`, `scenario`.
- Resource: `service.name=demo-service`, `service.version=0.1.0`, `deployment.environment.name=local`.
- Sampling: always on. Export: standard batch span processor, plaintext inside the cluster.
- The Collector runs a single traces pipeline: `otlp` receiver, `memory_limiter` and `batch` processors, OTLP exporter to Tempo.
- Tempo runs as a single binary with local, non-persistent storage and 1 h retention. Its OTLP receiver binds `0.0.0.0:4317` explicitly.

Verification looks traces up by exact ID. It never relies on the search API.

## Grafana Dashboard

The dashboard **Kubernetes Observability Blueprint** (UID `k8s-observability-blueprint`) is provisioned by the Grafana sidecar from a ConfigMap labelled `grafana_dashboard: "1"`. It has four panels:

| Panel | PromQL |
|-------|--------|
| Request Rate | `sum by (route, status) (rate(demo_http_requests_total[1m]))` |
| HTTP Errors | `sum(rate(demo_http_requests_total{status=~"5.."}[1m]))` |
| p95 Request Latency | `histogram_quantile(0.95, sum by (le, route) (rate(demo_http_request_duration_seconds_bucket[1m])))` |
| Demo Container Restarts | `sum(kube_pod_container_status_restarts_total{namespace="demo",container="demo-service"})` |

```bash
make grafana
```

This port-forwards Grafana to `http://127.0.0.1:13000` and prints the username and the command that reads the chart-generated admin password. No password is stored in the repository.

## Repository Structure

```text
demo/                  instrumented Go workload and Dockerfile
charts/demo-service/   Helm chart: ServiceAccount, Deployment, Service, ServiceMonitor, dashboard
infra/versions.env     single source of pinned versions
infra/kind/            single-node kind cluster
infra/values/          values for kube-prometheus-stack, Tempo and the Collector
scripts/               environment, verification and scenario scripts
.github/workflows/     CI: quality and e2e
```

## Security Boundary

- Every Service is `ClusterIP`. No NodePort, LoadBalancer, Ingress or hostPort.
- Port forwards bind `127.0.0.1` only: demo `18080`, Prometheus `19090`, Grafana `13000`, Tempo `13200`.
- The demo pod runs as non-root with a read-only root filesystem, no privilege escalation, all capabilities dropped, the `RuntimeDefault` seccomp profile and no ServiceAccount token. The Collector ServiceAccount has no token and no ClusterRole.
- No runtime secrets are committed. Telemetry is synthetic.

See [SECURITY.md](SECURITY.md).

## Operational Limitations

This repository is a reproducible local and CI reference environment for validating Kubernetes observability pipelines. It is not a production observability platform.

This repository demonstrates observability wiring and validation patterns. It does not provide production sizing, high availability, durable trace storage, alert routing, authentication architecture or multi-cluster operations.

- Prometheus keeps 2 h of data and Tempo 1 h, both without persistent volumes. Deleting the cluster deletes all telemetry.
- The kind node uses about 2 GB of memory once the stack is running. Allow at least 4 GB for Docker to cover image pulls and startup.
- Images and charts are pulled from public registries on first run.

## What This Is / Is Not

Kubernetes Observability Blueprint is a reproducible reference environment for validating Kubernetes metrics and tracing pipelines. It combines Prometheus, OpenTelemetry Collector, Tempo and Grafana with deterministic failure scenarios that prove telemetry reaches the expected backend.

| It is | It is not |
|-------|-----------|
| a reproducible kind-based reference environment | a production observability platform |
| an automated proof that metrics and traces arrive | a complete SRE platform |
| a pattern for failure-driven validation | a chaos engineering framework |
| synthetic telemetry from a demo workload | a logs pipeline, alerting stack or long-term storage |

## CI

GitHub Actions on `ubuntu-24.04`, with `contents: read` permissions and no secrets:

- **quality** — gofmt, `go vet`, `go test`, `docker build`, `helm lint`, `helm template` with rendered Collector and Prometheus regression checks, `bash -n`. No cluster.
- **e2e** — installs pinned kind, kubectl and Helm from official release artifacts with checksum verification, then `make up` and `make test-e2e`. On failure it prints pods, Services, ServiceMonitors, events and component logs. `make down` always runs.

CI needs no paid service, cloud account, registry login, self-hosted runner or external cluster.

## Development

```bash
make check      # gofmt, go vet, go test, helm lint, helm template, bash -n
make unit       # go test ./... in demo/
make build      # go build, docker build, helm lint and template
```

The unit tests cover HTTP handlers with an injected sleeper and exiter, metrics on a dedicated registry and spans through an in-memory exporter. They need no cluster, Collector or Tempo.

## Upstream References

- [kind](https://kind.sigs.k8s.io/)
- [Kubernetes](https://kubernetes.io/docs/)
- [Helm](https://helm.sh/docs/)
- [Prometheus](https://prometheus.io/docs/)
- [Prometheus Operator](https://prometheus-operator.dev/)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [OpenTelemetry Go](https://opentelemetry.io/docs/languages/go/)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [OpenTelemetry Helm Charts](https://github.com/open-telemetry/opentelemetry-helm-charts)
- [Grafana](https://grafana.com/docs/grafana/latest/)
- [Tempo](https://grafana.com/docs/tempo/latest/)
- [Grafana Community Helm Charts](https://github.com/grafana-community/helm-charts)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Run `make check` before opening a pull request.

## License

Apache License 2.0. See [LICENSE](LICENSE).
