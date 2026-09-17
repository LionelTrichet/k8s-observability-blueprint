# Contributing

## Requirements

- Go 1.27.x
- Docker
- kind 0.32.x
- kubectl 1.36.x
- Helm 4.3.x
- curl and jq

`make doctor` checks them. Nothing is installed automatically.

## Before Opening a Pull Request

```bash
make check
```

For changes to the environment, charts, values or scripts, also run:

```bash
make up
make test-e2e
make down
```

## Rules

- No paid runtime dependency.
- No cloud requirement.
- No committed secrets.
- Keep versions exact and in `infra/versions.env`. Do not use `latest`.
- Keep every Service `ClusterIP` and every port forward on `127.0.0.1`.
- Do not change Helm selectors or values from memory; verify them against the pinned chart.

## New Failure Scenarios

A new failure scenario must:

- be deterministic;
- be bounded;
- have an automated backend assertion;
- run in CI.

## Commits

Use short conventional prefixes such as `feat:`, `fix:`, `test:`, `docs:` and `chore:`.
