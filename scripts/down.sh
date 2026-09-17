#!/usr/bin/env bash
# Deletes only this project's kind cluster. Succeeds when it is absent.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
	log "Deleting kind cluster ${CLUSTER_NAME}"
	kind delete cluster --name "${CLUSTER_NAME}"
else
	info "kind cluster ${CLUSTER_NAME} does not exist"
fi
pass "cleanup complete"
