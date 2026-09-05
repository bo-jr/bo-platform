# bo-platform

Platform and bootstrap for a fully ephemeral, three-cluster GitOps lab.

The lab exists to demonstrate one thing: **progressive delivery that catches a bad
deploy and rolls it back automatically, gated on error-budget burn rate rather than an
arbitrary threshold.** Deploy `storefront` v2 with a 5% failure rate, watch Argo Rollouts
shift 10% of traffic, watch the AnalysisTemplate query a Pyrra-generated burn-rate rule,
see the rollout abort and traffic return to v1 — with zero human input.

Everything else is scaffolding for that.

## Start here

| | |
|---|---|
| [`docs/SETUP.md`](docs/SETUP.md) | **Setting up a machine — start here.** Also carries the honest build status. |
| [`docs/BUILD-PLAN.md`](docs/BUILD-PLAN.md) | The spec: locked decisions, phase boundaries, acceptance criteria |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Deltas from the plan, and why |
| [`CLAUDE.md`](CLAUDE.md) | Standing working rules |

```bash
git clone https://github.com/bo-jr/bo-platform.git ~/gitops-lab/bo-platform
cd ~/gitops-lab/bo-platform && ./scripts/bootstrap-toolchain.sh
```

Runs unmodified on `darwin/arm64` and `linux/amd64`.

## The seven repos

| Repo | Role |
|---|---|
| [bo-platform](https://github.com/bo-jr/bo-platform) | this repo — bootstrap, clusters, SLOs, Argo CD apps, Go binaries |
| [bo-deploy](https://github.com/bo-jr/bo-deploy) | **the gate** — rendered manifests; CI writes, Argo CD reads |
| [bo-service-chart](https://github.com/bo-jr/bo-service-chart) | one Helm chart for all three services |
| [bo-service-kit](https://github.com/bo-jr/bo-service-kit) | shared Go module — telemetry, chaos, httpx |
| [bo-storefront](https://github.com/bo-jr/bo-storefront) | the canary target |
| [bo-catalog](https://github.com/bo-jr/bo-catalog) | CloudNativePG-backed |
| [bo-pricing](https://github.com/bo-jr/bo-pricing) | CPU-bound by design |

All public — on a private free repo, branch protection is configured and then **silently
not enforced**, which would make the prod gate decoration.

## Shape

`mgmt` (hub) · `dev` · `prod` — k3d, one Docker network. Argo CD runs in `mgmt` only and
manages both spokes. Anything that is an admission webhook or reconciles in-cluster
resources runs per-spoke: Istio, cert-manager, ESO, Kyverno, Rollouts, Prometheus agent,
Alloy.

**Bootstrap installs exactly one thing: Argo CD.** Everything else arrives from git via
the root app-of-apps.

## Status

Phase 0 not started — no clusters exist yet. See [`docs/SETUP.md`](docs/SETUP.md).
