#!/usr/bin/env bash
# Latency scenario: a fixed 750ms delay must be visible in the duration
# histogram and as an exact trace. The average is computed from the sum/count
# deltas of this run's observations, not from cumulative values or rate().
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work_dir="$(mktemp -d)"
cleanup() {
	stop_port_forwards
	rm -rf "${work_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_demo_port_forward
start_prometheus_port_forward
start_tempo_port_forward

log "Slow request"
count_query='sum(demo_http_request_duration_seconds_count{route="/slow"}) or vector(0)'
sum_query='sum(demo_http_request_duration_seconds_sum{route="/slow"}) or vector(0)'

count_before="$(prometheus_query "${count_query}")"
sum_before="$(prometheus_query "${sum_query}")"

body="${work_dir}/slow.json"
elapsed="$(demo_request /slow 200 "${body}")"
float_ge "${elapsed}" 0.70 || fail "GET /slow took ${elapsed}s, expected >= 0.70s"
float_ge "${elapsed}" 3.00 && fail "GET /slow took ${elapsed}s, expected < 3.00s"
trace_id="$(extract_trace_id "${body}")"
pass "GET /slow -> 200 in ${elapsed}s, traceId ${trace_id}"

log "Latency metric"

count="$(wait_prometheus_increase "${count_query}" "${count_before}" 30)"
sum_after="$(prometheus_query "${sum_query}")"

[[ -n "${sum_after}" ]] || fail "duration sum for /slow is not available"

float_ge "${sum_after}" "${sum_before}" ||
	fail "duration sum decreased during /slow scenario"

average="$(awk -v sum_after="${sum_after}" \
	-v sum_before="${sum_before}" \
	-v count_after="${count}" \
	-v count_before="${count_before}" \
	'BEGIN {
		printf "%.6f", (sum_after - sum_before) / (count_after - count_before)
	}')"

float_ge "${average}" 0.70 ||
	fail "new /slow observations averaged ${average}s, expected >= 0.70s"

pass "new /slow observations average = ${average}s (count ${count_before} -> ${count})"

log "Latency trace"
trace_file="${work_dir}/trace.json"
wait_tempo_trace "${trace_id}" "${trace_file}" 30
require_trace_attributes "${trace_file}" \
	"service.name=demo-service" \
	"scenario=latency" \
	"http.route=/slow"
pass "latency scenario verified"
