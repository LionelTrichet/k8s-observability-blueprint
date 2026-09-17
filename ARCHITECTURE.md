# Architecture

## Purpose

Deploy a reproducible local Kubernetes observability environment and prove through automated assertions that known workload behavior produces expected metrics and traces.

```text
known workload behavior → telemetry generation → observability pipeline → backend query → automated assertion → PASS / FAIL
```

A successful deployment of the stack is not the result. The result is an assertion that a specific signal reached a specific backend.

## System Boundary

Everything runs inside one single-node kind cluster named `k8s-observability-blueprint`. The workstation or CI runner reaches it only through `kubectl port-forward` bound to `127.0.0.1`. Nothing is reachable from outside the host.

External dependencies are limited to public container registries and Helm chart repositories used during `make up`.

## Namespaces

| Namespace | Contents |
|-----------|----------|
| `observability` | Prometheus Operator, Prometheus, kube-state-metrics, Grafana, OpenTelemetry Collector, Tempo |
| `demo` | demo-service Deployment, Service, ServiceMonitor and Grafana dashboard ConfigMap |

Namespaces are created with an idempotent `kubectl create --dry-run=client | kubectl apply` pattern.

## Metrics Pipeline

```text
demo-service → GET /metrics → Service → ServiceMonitor → Prometheus
```

Metrics use native Prometheus pull semantics. The Collector is not in the metrics path in v0.1.0: fewer moving parts and less CI flakiness.

The workload registers its collectors on a dedicated registry, not the default registerer, so unit tests are isolated.

## Trace Pipeline

```text
demo-service → OTLP/gRPC → OpenTelemetry Collector → OTLP/gRPC → Tempo
```

The workload uses the standard batch span processor and always-on sampling. The Collector acts only as a trace gateway.

## Prometheus Discovery

kube-prometheus-stack 89.2.0 defaults to selecting only ServiceMonitors that carry the Helm release label. The chart template falls back to `release: monitoring` when `serviceMonitorSelector` is empty and `serviceMonitorSelectorNilUsesHelmValues` is true.

The values disable that fallback and set empty selectors:

```yaml
serviceMonitorSelectorNilUsesHelmValues: false
serviceMonitorSelector: {}
serviceMonitorNamespaceSelector: {}
```

The rendered Prometheus resource then contains `serviceMonitorSelector: {}` and `serviceMonitorNamespaceSelector: {}`, which select every ServiceMonitor in every namespace. The demo ServiceMonitor intentionally has no `release` label.

`serviceMonitorSelector: {matchLabels: null}` is not used. It renders with the pinned chart, but Helm 4 installs with server-side apply and the Prometheus CRD schema rejects it: `spec.serviceMonitorSelector.matchLabels ... must be of type object`.

`make check` renders the pinned chart and fails unless both selectors render as `{}`. The check has been exercised against the release-label configuration and fails on it.

## OpenTelemetry Collector

- Chart 0.173.1, `mode: deployment`, one replica, `fullnameOverride: otel-collector`.
- The image tag is not set: the pinned chart's `appVersion` selects it. The chart has no default image repository, so the repository is set to the Kubernetes distribution `otel/opentelemetry-collector-k8s`.
- Only the OTLP gRPC port 4317 is enabled on the Service.
- The ServiceAccount has no token and no ClusterRole.

The configuration is provided through `alternateConfig`, not `config`. The chart deep-merges `config` into its defaults. Rendering the pinned chart with a trace-only `config` still produces active `logs` and `metrics` pipelines, a `debug` exporter, `jaeger`, `zipkin` and `prometheus` receivers, and a `memory_limiter` carrying both `limit_mib` and `limit_percentage`. `alternateConfig` replaces the configuration completely. It includes the `health_check` extension because the chart's probes call it.

The rendered pipeline:

```text
traces: otlp → memory_limiter → batch → otlp_grpc/tempo
```

The chart renders the `otlp` exporter under its current component name `otlp_grpc`. `make check` fails if a logs or metrics pipeline, an unused receiver or exporter, or `limit_percentage` appears.

## Tempo

- Chart 2.3.0 from the Grafana Community Helm Charts repository, Tempo 2.10.8.
- Single binary, one replica, local storage for traces and WAL, no persistence, 1 h retention, usage reporting disabled.
- HTTP API on 3200, OTLP gRPC on 4317.
- The OTLP receiver binds `0.0.0.0:4317` explicitly. A localhost-only receiver would reject the Collector in another pod.

Traces are retrieved with `GET /api/traces/<traceID>`.

## Grafana Provisioning

Grafana comes from kube-prometheus-stack; no second Grafana is installed.

- The Prometheus datasource is managed by the chart.
- A Tempo datasource with UID `tempo` is added through `grafana.additionalDataSources`.
- The dashboard sidecar watches all namespaces for ConfigMaps labelled `grafana_dashboard: "1"`. The demo chart renders the dashboard from `dashboards/overview.json` with `.Files.Get`.
- The admin password is generated by the chart into a Secret. `make grafana` and the verification script find that Secret by the labels `app.kubernetes.io/name=grafana` and `app.kubernetes.io/instance=monitoring`, not by a hardcoded name.

## Demo Workload

A Go service on `net/http` with no framework, listening on `0.0.0.0:8080`.

| Endpoint | Response | Purpose |
|----------|----------|---------|
| `GET /healthz` | `200 {"status":"ok"}` | liveness |
| `GET /readyz` | `200 {"status":"ready"}` | readiness |
| `GET /work` | `200` with `traceId` | baseline |
| `GET /error` | `500` with `traceId` | error |
| `GET /slow` | `200` after a fixed 750 ms | latency |
| `GET /crash` | `202`, then exit code 1 after 500 ms | restart |
| `GET /metrics` | Prometheus exposition | scraping |

Any other path returns `404`. No endpoint accepts parameters that change delays or failure behavior.

Tracing initializes before the server listens; a tracing initialization error stops the process. `SIGTERM` and `SIGINT` trigger graceful shutdown within 5 seconds: HTTP first, then the tracer provider.

Sleeping and exiting are injected as functions, so unit tests exercise `/slow` and `/crash` without real delays or process exit.

## Failure Scenarios

| Scenario | Trigger | Backend assertion |
|----------|---------|-------------------|
| Baseline | `GET /work` | counter `>= 1`, exact trace with `scenario=baseline` |
| Error | `GET /error` | `500` counter `>= 1`, exact trace with `scenario=error` and status 500 |
| Latency | `GET /slow` | request `>= 0.70 s` and `< 3 s`, histogram `_sum / _count >= 0.70`, exact trace |
| Crash | `GET /crash` | `restartCount` increases, pod Ready, restart metric `>= 1` |

Scenarios are deterministic, bounded and re-runnable.

## Verification Strategy

- Readiness uses `helm --wait`, `kubectl rollout status`, `kubectl wait` and HTTP polling with 1-second intervals. No fixed long sleeps.
- Services are resolved by stable labels; port forwards target Services, not pod names.
- Metric assertions poll the Prometheus HTTP API for a numeric value `>= threshold`. The latency assertion uses the cumulative histogram, not `rate()`, so it does not depend on scrape windows.
- Trace assertions fetch one trace by the ID returned in the response and search attributes recursively with `jq`, independent of the exact OTLP JSON shape.
- The restart count is read from the container status whose `name` is `demo-service`, never from `containerStatuses[0]`.
- Every scenario installs `trap cleanup EXIT INT TERM` and stops its port forwards.

## Local vs CI

The same `make up` and `make test-e2e` run locally and in CI. CI installs exact tool patch versions with checksum verification; locally `make doctor` fails on a major or minor mismatch and warns on a patch mismatch.

## Security Boundary

See [SECURITY.md](SECURITY.md). In short: ClusterIP only, localhost port forwards, a hardened demo pod, no ServiceAccount tokens where not needed, no committed secrets and synthetic telemetry.

## Non-Goals

Logs pipelines, alert routing, long-term or distributed storage, service meshes, Ingress, GitOps controllers, autoscaling, network policies, persistent volumes, cloud providers, hosted observability services, multi-cluster setups, high availability and production sizing are out of scope. Supply-chain tooling such as image signing and SBOMs belongs to a separate repository.
