#!/usr/bin/env bash
# Shared helpers for the environment and scenario scripts.
#
# Sourced by the other scripts. It only reads repository-controlled files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# shellcheck source=../infra/versions.env
. "${REPO_ROOT}/infra/versions.env"

readonly CLUSTER_NAME="k8s-observability-blueprint"
readonly KUBE_CONTEXT="kind-${CLUSTER_NAME}"
readonly OBS_NS="observability"
readonly DEMO_NS="demo"
readonly DEMO_IMAGE="k8s-observability-blueprint/demo-service:${DEMO_VERSION}"

readonly PORT_DEMO=18080
readonly PORT_PROMETHEUS=19090
readonly PORT_GRAFANA=13000
readonly PORT_TEMPO=13200

readonly TRACE_ID_PATTERN='^[a-f0-9]{32}$'

log() { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
pass() { printf 'PASS: %s\n' "$*"; }
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

kc() {
	kubectl --context "${KUBE_CONTEXT}" "$@"
}

# ---------------------------------------------------------------------------
# Port forwarding
# ---------------------------------------------------------------------------

PORT_FORWARD_PIDS=()
PORT_FORWARD_LOGS=()

# wait_tcp PORT TIMEOUT_SECONDS
wait_tcp() {
	local port="$1" timeout="$2" waited=0
	until (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
		if ((waited >= timeout)); then
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
}

# start_port_forward NAMESPACE RESOURCE LOCAL_PORT REMOTE_PORT
# Always binds 127.0.0.1.
start_port_forward() {
	local namespace="$1" resource="$2" local_port="$3" remote_port="$4" log_file
	log_file="$(mktemp)"
	kc -n "${namespace}" port-forward --address 127.0.0.1 \
		"${resource}" "${local_port}:${remote_port}" >"${log_file}" 2>&1 &
	PORT_FORWARD_PIDS+=("$!")
	PORT_FORWARD_LOGS+=("${log_file}")
	if ! wait_tcp "${local_port}" 30; then
		cat "${log_file}" >&2
		fail "port-forward ${namespace}/${resource} -> 127.0.0.1:${local_port} did not open"
	fi
}

stop_port_forwards() {
	local pid log_file
	for pid in "${PORT_FORWARD_PIDS[@]}"; do
		kill "${pid}" 2>/dev/null || true
		wait "${pid}" 2>/dev/null || true
	done
	for log_file in "${PORT_FORWARD_LOGS[@]}"; do
		rm -f "${log_file}"
	done
	PORT_FORWARD_PIDS=()
	PORT_FORWARD_LOGS=()
}

# ---------------------------------------------------------------------------
# Service resolution by stable labels (never by pod name)
# ---------------------------------------------------------------------------

# service_by_labels NAMESPACE SELECTOR
service_by_labels() {
	local namespace="$1" selector="$2" name
	name="$(kc -n "${namespace}" get svc -l "${selector}" \
		-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -n 1)"
	[[ -n "${name}" ]] || fail "no Service in ${namespace} matches ${selector}"
	printf '%s\n' "${name}"
}

prometheus_service() {
	service_by_labels "${OBS_NS}" "app=kube-prometheus-stack-prometheus,release=monitoring"
}

grafana_service() {
	service_by_labels "${OBS_NS}" "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=monitoring"
}

tempo_service() {
	service_by_labels "${OBS_NS}" "app.kubernetes.io/name=tempo,app.kubernetes.io/instance=tempo"
}

start_demo_port_forward() {
	start_port_forward "${DEMO_NS}" "svc/demo-service" "${PORT_DEMO}" 8080
}

start_prometheus_port_forward() {
	start_port_forward "${OBS_NS}" "svc/$(prometheus_service)" "${PORT_PROMETHEUS}" 9090
}

start_tempo_port_forward() {
	start_port_forward "${OBS_NS}" "svc/$(tempo_service)" "${PORT_TEMPO}" 3200
}

start_grafana_port_forward() {
	start_port_forward "${OBS_NS}" "svc/$(grafana_service)" "${PORT_GRAFANA}" 80
}

# grafana_password prints the chart-generated admin password.
grafana_password() {
	local secret
	secret="$(kc -n "${OBS_NS}" get secret \
		-l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=monitoring" \
		-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | head -n 1)"
	[[ -n "${secret}" ]] || fail "Grafana admin Secret not found"
	kc -n "${OBS_NS}" get secret "${secret}" -o jsonpath='{.data.admin-password}' | base64 -d
}

# ---------------------------------------------------------------------------
# HTTP, Prometheus and Tempo polling
# ---------------------------------------------------------------------------

# wait_http URL EXPECTED_CODE TIMEOUT_SECONDS
wait_http() {
	local url="$1" expected="$2" timeout="$3" waited=0 code
	while true; do
		code="$(curl --silent --output /dev/null --max-time 5 --write-out '%{http_code}' "${url}" || true)"
		[[ "${code}" == "${expected}" ]] && return 0
		if ((waited >= timeout)); then
			fail "${url} returned ${code} after ${timeout}s, expected ${expected}"
		fi
		sleep 1
		waited=$((waited + 1))
	done
}

# prometheus_query PROMQL — prints the first sample value, or nothing.
prometheus_query() {
	local query="$1"
	curl --silent --fail --max-time 5 \
		--get --data-urlencode "query=${query}" \
		"http://127.0.0.1:${PORT_PROMETHEUS}/api/v1/query" |
		jq -r '.data.result[0].value[1] // empty'
}

# float_ge A B — succeeds when A >= B.
float_ge() {
	awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# wait_prometheus_value PROMQL THRESHOLD TIMEOUT_SECONDS
# Polls until the query returns a numeric value >= THRESHOLD and prints it.
wait_prometheus_value() {
	local query="$1" threshold="$2" timeout="$3" waited=0 value=""
	while true; do
		value="$(prometheus_query "${query}" || true)"
		if [[ -n "${value}" && "${value}" != "NaN" ]] && float_ge "${value}" "${threshold}"; then
			printf '%s\n' "${value}"
			return 0
		fi
		if ((waited >= timeout)); then
			fail "Prometheus query did not reach >= ${threshold} in ${timeout}s (last: '${value}'): ${query}"
		fi
		sleep 1
		waited=$((waited + 1))
	done
}

# wait_tempo_trace TRACE_ID OUTPUT_FILE TIMEOUT_SECONDS
# Retrieves one exact trace by ID. Does not use the search API.
wait_tempo_trace() {
	local trace_id="$1" output="$2" timeout="$3" waited=0 code
	[[ "${trace_id}" =~ ${TRACE_ID_PATTERN} ]] || fail "invalid trace ID '${trace_id}'"
	while true; do
		code="$(curl --silent --max-time 5 --header 'Accept: application/json' \
			--output "${output}" --write-out '%{http_code}' \
			"http://127.0.0.1:${PORT_TEMPO}/api/traces/${trace_id}" || true)"
		[[ "${code}" == "200" ]] && return 0
		if ((waited >= timeout)); then
			fail "trace ${trace_id} not retrievable from Tempo in ${timeout}s (last HTTP ${code})"
		fi
		sleep 1
		waited=$((waited + 1))
	done
}

# trace_has_attribute FILE KEY VALUE
# Recursive search, independent of the exact OTLP JSON shape.
trace_has_attribute() {
	local file="$1" key="$2" value="$3"
	jq -e --arg key "${key}" --arg value "${value}" '
		[ .. | objects | select(.key? == $key) | .value
		  | (.stringValue // .intValue // .boolValue // .doubleValue) | tostring ]
		| any(. == $value)
	' "${file}" >/dev/null
}

# require_trace_attributes FILE KEY=VALUE...
require_trace_attributes() {
	local file="$1" pair key value
	shift
	for pair in "$@"; do
		key="${pair%%=*}"
		value="${pair#*=}"
		trace_has_attribute "${file}" "${key}" "${value}" ||
			fail "trace lacks attribute ${key}=${value}"
		info "trace attribute ${key}=${value}"
	done
}

# ---------------------------------------------------------------------------
# Demo requests
# ---------------------------------------------------------------------------

# demo_request PATH EXPECTED_CODE BODY_FILE — prints curl time_total.
demo_request() {
	local path="$1" expected="$2" body="$3" result code time_total
	result="$(curl --silent --max-time 10 --output "${body}" \
		--write-out '%{http_code} %{time_total}' "http://127.0.0.1:${PORT_DEMO}${path}")" ||
		fail "request to ${path} failed"
	code="${result%% *}"
	time_total="${result##* }"
	[[ "${code}" == "${expected}" ]] || fail "GET ${path} returned ${code}, expected ${expected}"
	jq -e . "${body}" >/dev/null || fail "GET ${path} did not return valid JSON"
	printf '%s\n' "${time_total}"
}

# extract_trace_id BODY_FILE
extract_trace_id() {
	local trace_id
	trace_id="$(jq -r '.traceId // empty' "$1")"
	[[ "${trace_id}" =~ ${TRACE_ID_PATTERN} ]] || fail "response traceId '${trace_id}' is not 32 lowercase hex characters"
	printf '%s\n' "${trace_id}"
}

# demo_restart_count — restartCount of the container named demo-service.
# Never assumes containerStatuses[0].
demo_restart_count() {
	kc -n "${DEMO_NS}" get pods -l app.kubernetes.io/name=demo-service -o json |
		jq -r '[ .items[].status.containerStatuses[]? | select(.name == "demo-service") | .restartCount ] | max // 0'
}

# ---------------------------------------------------------------------------
# Static render checks (no cluster required)
# ---------------------------------------------------------------------------

render_collector_config() {
	helm template otel-collector open-telemetry/opentelemetry-collector \
		--version "${OTEL_COLLECTOR_CHART_VERSION}" \
		--namespace "${OBS_NS}" \
		--values "${REPO_ROOT}/infra/values/otel-collector.yaml" |
		awk '/^kind: ConfigMap$/ { inside = 1 } inside && /^---/ { inside = 0 } inside && /relay: \|/ { relay = 1 } inside && relay { print }'
}

check_collector_render() {
	local config
	config="$(render_collector_config)"
	[[ -n "${config}" ]] || fail "rendered Collector ConfigMap is empty"

	grep -Eq '^ {8}traces:$' <<<"${config}" || fail "Collector has no traces pipeline"
	grep -Eq '^ {6}otlp:$' <<<"${config}" || fail "Collector has no otlp receiver"
	grep -Eq '^ {6}otlp(_grpc)?/tempo:$' <<<"${config}" || fail "Collector has no OTLP Tempo exporter"
	grep -Eq '^ {6}memory_limiter:$' <<<"${config}" || fail "Collector has no memory_limiter"
	grep -Eq '^ {6}batch:$' <<<"${config}" || fail "Collector has no batch processor"

	if grep -Eq '^ {8}(logs|metrics):$' <<<"${config}"; then
		fail "Collector renders an active logs or metrics pipeline"
	fi
	if grep -Eq '^ {6}(debug|jaeger|zipkin|prometheus):' <<<"${config}"; then
		fail "Collector renders an unused exporter or receiver"
	fi
	if grep -q 'limit_percentage' <<<"${config}"; then
		fail "Collector memory_limiter mixes limit_mib and limit_percentage"
	fi
	pass "rendered Collector config is trace-only"
}

# selector_block KEY — reads a rendered Prometheus spec on stdin and prints the
# value of a two-space-indented spec key: `{}` for an inline empty map, or the
# non-empty lines of its nested block joined by spaces.
selector_block() {
	awk -v key="$1" '
		$0 ~ "^  " key ":" {
			value = $0
			sub("^  " key ":[ ]*", "", value)
			if (value != "") { print value; exit }
			inside = 1
			next
		}
		inside && /^    / { sub(/^[ ]+/, ""); out = out (out == "" ? "" : " ") $0; next }
		inside { inside = 0 }
		END { if (out != "") print out }
	'
}

check_prometheus_render() {
	local rendered
	rendered="$(helm template monitoring oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
		--version "${KUBE_PROMETHEUS_STACK_CHART_VERSION}" \
		--namespace "${OBS_NS}" \
		--values "${REPO_ROOT}/infra/values/kube-prometheus-stack.yaml" 2>/dev/null |
		awk '/^kind: Prometheus$/ { inside = 1 } inside && /^---/ { inside = 0 } inside { print }')"
	[[ -n "${rendered}" ]] || fail "rendered Prometheus resource is empty"

	local selector namespace_selector
	selector="$(selector_block "serviceMonitorSelector" <<<"${rendered}")"
	namespace_selector="$(selector_block "serviceMonitorNamespaceSelector" <<<"${rendered}")"

	# Unrestricted means exactly `{}`. `matchLabels: null` renders but is
	# rejected by the Prometheus CRD schema under Helm 4 server-side apply.
	[[ "${selector}" == "{}" ]] ||
		fail "Prometheus serviceMonitorSelector must render as {}: ${selector:-<missing>}"
	[[ "${namespace_selector}" == "{}" ]] ||
		fail "Prometheus serviceMonitorNamespaceSelector is restricted: ${namespace_selector:-<missing>}"
	pass "rendered Prometheus selects ServiceMonitors in all namespaces without a release label"
}
