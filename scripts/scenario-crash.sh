#!/usr/bin/env bash
# Crash scenario: the container must restart and the restart must be visible
# in kube-state-metrics. The crash span is intentionally not required.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work_dir="$(mktemp -d)"
cleanup() {
	stop_port_forwards
	rm -rf "${work_dir}"
}
trap cleanup EXIT INT TERM

kc -n "${DEMO_NS}" rollout status deployment/demo-service --timeout=120s
before="$(demo_restart_count)"
info "restartCount before: ${before}"

log "Crash request"
start_demo_port_forward
body="${work_dir}/crash.json"
demo_request /crash 202 "${body}" >/dev/null
# The port-forward targets the pod that is about to exit.
stop_port_forwards
pass "GET /crash -> 202"

log "Kubernetes restart"
waited=0
after="${before}"
until ((after > before)); do
	((waited < 60)) || fail "restartCount did not increase within 60s (still ${after})"
	sleep 1
	waited=$((waited + 1))
	after="$(demo_restart_count)"
done
pass "restartCount ${before} -> ${after}"

kc -n "${DEMO_NS}" wait --for=condition=Ready pod -l app.kubernetes.io/name=demo-service --timeout=90s
pass "demo-service pod is Ready again"

log "Restart metric"
start_prometheus_port_forward
value="$(wait_prometheus_value 'sum(kube_pod_container_status_restarts_total{namespace="demo",container="demo-service"})' 1 30)"
pass "kube_pod_container_status_restarts_total = ${value}"
pass "crash scenario verified"
