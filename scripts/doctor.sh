#!/usr/bin/env bash
# Checks local prerequisites. Never installs anything.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

failures=0

require_command() {
	if command -v "$1" >/dev/null 2>&1; then
		info "found $1"
	else
		printf 'FAIL: required command not found: %s\n' "$1" >&2
		failures=$((failures + 1))
	fi
}

# check_version NAME ACTUAL EXPECTED
# Major/minor mismatch fails; patch mismatch warns.
check_version() {
	local name="$1" actual="$2" expected="$3"
	if [[ -z "${actual}" ]]; then
		printf 'FAIL: could not determine %s version\n' "${name}" >&2
		failures=$((failures + 1))
		return
	fi
	if [[ "${actual}" == "${expected}" ]]; then
		info "${name} ${actual}"
	elif [[ "${actual%.*}" == "${expected%.*}" ]]; then
		warn "${name} ${actual} differs from pinned ${expected} in patch version"
	else
		printf 'FAIL: %s %s, expected %s.x\n' "${name}" "${actual}" "${expected%.*}" >&2
		failures=$((failures + 1))
	fi
}

semver() {
	grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

log "Checking commands"
for command in docker kind kubectl helm go curl jq; do
	require_command "${command}"
done
((failures == 0)) || fail "${failures} required command(s) missing"

log "Checking Docker daemon"
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"
info "Docker daemon reachable"

log "Checking tool versions"
check_version kind "$(kind version | semver)" "${KIND_VERSION}"
check_version kubectl "$(kubectl version --client 2>/dev/null | semver)" "${KUBECTL_VERSION}"
check_version helm "$(helm version --short 2>/dev/null | semver)" "${HELM_VERSION}"
check_version go "$(go env GOVERSION 2>/dev/null | semver)" "${GO_VERSION}"

((failures == 0)) || fail "${failures} version check(s) failed"
pass "prerequisites satisfied"
