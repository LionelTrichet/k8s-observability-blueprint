#!/usr/bin/env bash
# Creates or reuses the kind environment and installs the observability stack.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

"${REPO_ROOT}/scripts/doctor.sh"

log "kind cluster ${CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
	info "reusing existing cluster"
else
	kind create cluster \
		--name "${CLUSTER_NAME}" \
		--image "${KIND_NODE_IMAGE}" \
		--config "${REPO_ROOT}/infra/kind/cluster.yaml" \
		--wait 120s
fi
kc cluster-info >/dev/null

log "Building ${DEMO_IMAGE}"
docker build --tag "${DEMO_IMAGE}" "${REPO_ROOT}/demo"

log "Loading image into kind"
kind load docker-image "${DEMO_IMAGE}" --name "${CLUSTER_NAME}"

log "Namespaces"
for namespace in "${OBS_NS}" "${DEMO_NS}"; do
	kc create namespace "${namespace}" --dry-run=client -o yaml | kc apply -f -
done

log "Helm repositories"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update >/dev/null
helm repo update open-telemetry grafana-community >/dev/null

log "kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_CHART_VERSION}"
helm upgrade --install monitoring oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
	--kube-context "${KUBE_CONTEXT}" \
	--version "${KUBE_PROMETHEUS_STACK_CHART_VERSION}" \
	--namespace "${OBS_NS}" \
	--values "${REPO_ROOT}/infra/values/kube-prometheus-stack.yaml" \
	--wait \
	--timeout 5m
kc -n "${OBS_NS}" wait --for=condition=Available deployment \
	-l "release=monitoring" --timeout=180s
kc -n "${OBS_NS}" rollout status statefulset/prometheus-monitoring-kube-prometheus-prometheus --timeout=180s

log "Tempo chart ${TEMPO_CHART_VERSION}"
helm upgrade --install tempo grafana-community/tempo \
	--kube-context "${KUBE_CONTEXT}" \
	--version "${TEMPO_CHART_VERSION}" \
	--namespace "${OBS_NS}" \
	--values "${REPO_ROOT}/infra/values/tempo.yaml" \
	--wait \
	--timeout 5m
kc -n "${OBS_NS}" rollout status statefulset/tempo --timeout=180s

log "OpenTelemetry Collector chart ${OTEL_COLLECTOR_CHART_VERSION}"
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
	--kube-context "${KUBE_CONTEXT}" \
	--version "${OTEL_COLLECTOR_CHART_VERSION}" \
	--namespace "${OBS_NS}" \
	--values "${REPO_ROOT}/infra/values/otel-collector.yaml" \
	--wait \
	--timeout 5m
kc -n "${OBS_NS}" rollout status deployment/otel-collector --timeout=180s

log "demo-service"
helm upgrade --install demo-service "${REPO_ROOT}/charts/demo-service" \
	--kube-context "${KUBE_CONTEXT}" \
	--namespace "${DEMO_NS}" \
	--values "${REPO_ROOT}/charts/demo-service/values.yaml" \
	--wait \
	--timeout 2m
# A rebuilt image with the same tag is not picked up by a no-op upgrade.
kc -n "${DEMO_NS}" rollout restart deployment/demo-service
kc -n "${DEMO_NS}" rollout status deployment/demo-service --timeout=120s

log "Status"
kc get pods -n "${OBS_NS}" -o wide
kc get pods -n "${DEMO_NS}" -o wide
pass "environment is up; run 'make verify'"
