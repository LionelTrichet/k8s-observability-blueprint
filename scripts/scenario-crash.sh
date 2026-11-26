#!/usr/bin/env bash
# Crash scenario: one specific demo pod is crashed through a port forward to
# that pod; its container must restart and the restart must be visible in the
# kube-state-metrics series for the same pod. The crash span is intentionally
# not required.
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

kc -n "${DEMO_NS}" rollout status deployment/demo-service --timeout=120s

# Pods that are already being deleted (from an earlier rollout) are ignored.
pod="$(kc -n "${DEMO_NS}" get pods \
	-l app.kubernetes.io/name=demo-service -o json |
	jq -er '
		[.items[] | select(.metadata.deletionTimestamp == null)] as $pods
		| if ($pods | length) == 1 then
			$pods[0].metadata.name
		else
			error("expected exactly one demo-service pod")
		end
	')"
info "target pod: ${pod}"

before="$(demo_restart_count "${pod}")"
info "restartCount before: ${before}"

log "Crash request"
start_port_forward "${DEMO_NS}" "pod/${pod}" "${PORT_DEMO}" 8080
body="${work_dir}/crash.json"
demo_request /crash 202 "${body}" >/dev/null
# The port forward targets the pod that is about to exit.
stop_port_forwards
pass "GET /crash -> 202"

log "Kubernetes restart"
waited=0
after="${before}"
until ((after > before)); do
	((waited < 60)) || fail "restartCount did not increase within 60s (still ${after})"
	sleep 1
	waited=$((waited + 1))
	after="$(demo_restart_count "${pod}")"
done
pass "restartCount ${before} -> ${after}"

kc -n "${DEMO_NS}" wait --for=condition=Ready "pod/${pod}" --timeout=90s
pass "pod ${pod} is Ready again"

log "Restart metric"
start_prometheus_port_forward
restart_metric="max(kube_pod_container_status_restarts_total{namespace=\"demo\",pod=\"${pod}\",container=\"demo-service\"})"

value="$(wait_prometheus_value "${restart_metric}" "${after}" 30)"

pass "kube_pod_container_status_restarts_total{pod=\"${pod}\"} = ${value}"
pass "crash scenario verified"
