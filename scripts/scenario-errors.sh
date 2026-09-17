#!/usr/bin/env bash
# Error scenario: a known HTTP 500 must appear as a metric and as an exact trace.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work_dir="$(mktemp -d)"
cleanup() {
	stop_port_forwards
	rm -rf "${work_dir}"
}
trap cleanup EXIT INT TERM

start_demo_port_forward
start_prometheus_port_forward
start_tempo_port_forward

log "Error request"
body="${work_dir}/error.json"
demo_request /error 500 "${body}" >/dev/null
trace_id="$(extract_trace_id "${body}")"
pass "GET /error -> 500, traceId ${trace_id}"

log "Error metric"
value="$(wait_prometheus_value 'sum(demo_http_requests_total{route="/error",status="500"})' 1 30)"
pass "demo_http_requests_total{route=\"/error\",status=\"500\"} = ${value}"

log "Error trace"
trace_file="${work_dir}/trace.json"
wait_tempo_trace "${trace_id}" "${trace_file}" 30
require_trace_attributes "${trace_file}" \
	"service.name=demo-service" \
	"scenario=error" \
	"http.route=/error" \
	"http.response.status_code=500"
pass "error scenario verified"
