SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := check

include infra/versions.env

DEMO_IMAGE := k8s-observability-blueprint/demo-service:$(DEMO_VERSION)

.PHONY: doctor fmt-check unit build helm-lint check up verify \
	scenario-errors scenario-latency scenario-crash test-e2e grafana down

doctor:
	@scripts/doctor.sh

fmt-check:
	@unformatted="$$(cd demo && gofmt -l .)"; \
	if [[ -n "$$unformatted" ]]; then printf 'FAIL: gofmt:\n%s\n' "$$unformatted"; exit 1; fi; \
	printf 'PASS: gofmt\n'

unit:
	cd demo && go test ./...

build:
	cd demo && go build ./...
	docker build --tag "$(DEMO_IMAGE)" demo
	$(MAKE) --no-print-directory helm-lint

helm-lint:
	helm lint charts/demo-service
	helm template demo-service charts/demo-service --namespace demo >/dev/null
	@printf 'PASS: demo chart renders\n'
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
	helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update >/dev/null
	helm repo update open-telemetry grafana-community >/dev/null
	helm template tempo grafana-community/tempo --version "$(TEMPO_CHART_VERSION)" \
		--namespace observability --values infra/values/tempo.yaml >/dev/null
	@printf 'PASS: Tempo chart renders\n'
	@bash -c '. scripts/lib.sh && check_collector_render && check_prometheus_render'

check: fmt-check
	cd demo && go vet ./...
	cd demo && go test ./...
	$(MAKE) --no-print-directory helm-lint
	bash -n scripts/*.sh
	@printf 'PASS: make check\n'

up:
	@scripts/up.sh

verify:
	@scripts/verify.sh

scenario-errors:
	@scripts/scenario-errors.sh

scenario-latency:
	@scripts/scenario-latency.sh

scenario-crash:
	@scripts/scenario-crash.sh

test-e2e:
	$(MAKE) --no-print-directory verify
	$(MAKE) --no-print-directory scenario-errors
	$(MAKE) --no-print-directory scenario-latency
	$(MAKE) --no-print-directory scenario-crash

grafana:
	@bash -c '. scripts/lib.sh && \
		printf "Grafana:  http://127.0.0.1:%s\n" "$$PORT_GRAFANA" && \
		printf "Username: admin\n" && \
		printf "Password: kubectl --context %s -n %s get secret -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=monitoring -o jsonpath=\"{.items[0].data.admin-password}\" | base64 -d\n" "$$KUBE_CONTEXT" "$$OBS_NS" && \
		printf "Press Ctrl+C to stop port forwarding.\n" && \
		kc -n "$$OBS_NS" port-forward --address 127.0.0.1 "svc/$$(grafana_service)" "$$PORT_GRAFANA:80"'

down:
	@scripts/down.sh
