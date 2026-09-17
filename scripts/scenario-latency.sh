#!/usr/bin/env bash
# Latency scenario: a fixed 750ms delay must be visible in the cumulative
# duration histogram and as an exact trace. Uses sum/count, not rate().
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

log "Slow request"
body="${work_dir}/slow.json"
elapsed="$(demo_request /slow 200 "${body}")"
float_ge "${elapsed}" 0.70 || fail "GET /slow took ${elapsed}s, expected >= 0.70s"
float_ge "${elapsed}" 3.00 && fail "GET /slow took ${elapsed}s, expected < 3.00s"
trace_id="$(extract_trace_id "${body}")"
pass "GET /slow -> 200 in ${elapsed}s, traceId ${trace_id}"

log "Latency metric"
count="$(wait_prometheus_value 'sum(demo_http_request_duration_seconds_count{route="/slow"})' 1 30)"
average="$(prometheus_query 'sum(demo_http_request_duration_seconds_sum{route="/slow"}) / sum(demo_http_request_duration_seconds_count{route="/slow"})')"
[[ -n "${average}" ]] || fail "average /slow duration is not available"
float_ge "${average}" 0.70 || fail "average /slow duration ${average}s, expected >= 0.70s"
pass "duration count = ${count}, average = ${average}s"

log "Latency trace"
trace_file="${work_dir}/trace.json"
wait_tempo_trace "${trace_id}" "${trace_file}" 30
require_trace_attributes "${trace_file}" \
	"service.name=demo-service" \
	"scenario=latency" \
	"http.route=/slow"
pass "latency scenario verified"
