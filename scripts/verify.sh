#!/usr/bin/env bash
# Baseline verification: proves telemetry from a known request reaches
# Prometheus and Tempo, and that the environment matches its boundaries.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work_dir="$(mktemp -d)"
cleanup() {
	stop_port_forwards
	rm -rf "${work_dir}"
}
trap cleanup EXIT INT TERM

log "Workloads Ready"
kc -n "${DEMO_NS}" rollout status deployment/demo-service --timeout=120s
kc -n "${OBS_NS}" rollout status deployment/otel-collector --timeout=120s
kc -n "${OBS_NS}" rollout status statefulset/tempo --timeout=120s
kc -n "${OBS_NS}" wait --for=condition=Ready pod \
	-l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=monitoring" --timeout=120s
kc -n "${OBS_NS}" wait --for=condition=Ready pod \
	-l "app.kubernetes.io/name=kube-state-metrics" --timeout=120s
pass "demo-service, Collector, Tempo, Grafana and kube-state-metrics are Ready"

log "Demo pod security boundary"
pod_json="${work_dir}/pod.json"
kc -n "${DEMO_NS}" get pods -l app.kubernetes.io/name=demo-service -o json |
	jq '.items[0]' >"${pod_json}"
jq -e '
	.spec.automountServiceAccountToken == false and
	.spec.securityContext.seccompProfile.type == "RuntimeDefault" and
	([ .spec.containers[] | select(.name == "demo-service") | .securityContext
	   | .runAsNonRoot == true
	     and .readOnlyRootFilesystem == true
	     and .allowPrivilegeEscalation == false
	     and (.capabilities.drop | index("ALL")) != null ] | all)
' "${pod_json}" >/dev/null || fail "demo pod does not meet the container security boundary"
pass "runAsNonRoot, readOnlyRootFilesystem, no privilege escalation, drop ALL, RuntimeDefault seccomp, no SA token"

log "Exposure boundary"
for namespace in "${DEMO_NS}" "${OBS_NS}"; do
	non_cluster_ip="$(kc -n "${namespace}" get svc -o json |
		jq -r '[.items[] | select(.spec.type != "ClusterIP") | .metadata.name] | join(",")')"
	[[ -z "${non_cluster_ip}" ]] || fail "non-ClusterIP Services in ${namespace}: ${non_cluster_ip}"
	host_ports="$(kc -n "${namespace}" get pods -o json |
		jq -r '[.items[].spec.containers[].ports[]? | select(.hostPort != null)] | length')"
	[[ "${host_ports}" == "0" ]] || fail "hostPort used in ${namespace}"
	ingresses="$(kc -n "${namespace}" get ingress -o name 2>/dev/null | wc -l | tr -d ' ')"
	[[ "${ingresses}" == "0" ]] || fail "Ingress present in ${namespace}"
done
pass "only ClusterIP Services, no hostPort, no Ingress"

start_demo_port_forward
start_prometheus_port_forward
start_tempo_port_forward
start_grafana_port_forward

log "Prometheus discovers the demo target"
# On a fresh cluster the operator writes the new scrape job into a Secret, and
# kubelet propagates mounted Secret updates to the Prometheus pod only on its
# sync period. The reload has been measured at 82s after the ServiceMonitor was
# created, so discovery is polled for up to 180s.
wait_prometheus_value 'max(up{namespace="demo"})' 1 180 >/dev/null
pass 'up{namespace="demo"} == 1'

log "Baseline request"
body="${work_dir}/work.json"
demo_request /work 200 "${body}" >/dev/null
trace_id="$(extract_trace_id "${body}")"
pass "GET /work -> 200, traceId ${trace_id}"

log "Baseline metric"
value="$(wait_prometheus_value 'sum(demo_http_requests_total{route="/work",status="200"})' 1 30)"
pass "demo_http_requests_total{route=\"/work\",status=\"200\"} = ${value}"

log "Baseline trace"
trace_file="${work_dir}/trace.json"
wait_tempo_trace "${trace_id}" "${trace_file}" 30
require_trace_attributes "${trace_file}" \
	"service.name=demo-service" \
	"scenario=baseline" \
	"http.route=/work"
pass "Tempo returned trace ${trace_id}"

log "Running Collector configuration"
collector_config="$(kc -n "${OBS_NS}" get configmap otel-collector -o jsonpath='{.data.relay}')"
grep -Eq '^ {4}traces:$' <<<"${collector_config}" || fail "running Collector has no traces pipeline"
grep -Eq 'otlp(_grpc)?/tempo' <<<"${collector_config}" || fail "running Collector has no Tempo exporter"
if grep -Eq '^ {4}(logs|metrics):$' <<<"${collector_config}"; then
	fail "running Collector has an active logs or metrics pipeline"
fi
pass "Collector runs a trace-only pipeline"

log "Grafana provisioning"
wait_http "http://127.0.0.1:${PORT_GRAFANA}/api/health" 200 60
password="$(grafana_password)"
datasources="$(curl --silent --fail --max-time 10 --user "admin:${password}" \
	"http://127.0.0.1:${PORT_GRAFANA}/api/datasources")"
jq -e 'any(.[]; .type == "prometheus")' <<<"${datasources}" >/dev/null || fail "Grafana has no Prometheus datasource"
jq -e 'any(.[]; .type == "tempo" and .uid == "tempo")' <<<"${datasources}" >/dev/null || fail "Grafana has no Tempo datasource"

dashboard=""
for _ in $(seq 1 60); do
	dashboard="$(curl --silent --max-time 10 --user "admin:${password}" \
		"http://127.0.0.1:${PORT_GRAFANA}/api/dashboards/uid/k8s-observability-blueprint" || true)"
	jq -e '.dashboard.uid == "k8s-observability-blueprint"' <<<"${dashboard}" >/dev/null 2>&1 && break
	sleep 1
done
jq -e '.dashboard.title == "Kubernetes Observability Blueprint"' <<<"${dashboard}" >/dev/null ||
	fail "Grafana dashboard k8s-observability-blueprint was not provisioned"
panels="$(jq '.dashboard.panels | length' <<<"${dashboard}")"
[[ "${panels}" == "4" ]] || fail "dashboard has ${panels} panels, expected 4"
pass "Grafana has Prometheus and Tempo datasources and the 4-panel dashboard"

pass "baseline verification complete"
