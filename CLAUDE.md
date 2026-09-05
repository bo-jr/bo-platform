# platform

Local three-cluster GitOps lab. Full spec: `docs/BUILD-PLAN.md` — **read the relevant
phase before writing anything.** This file is the standing rules only.

## How we work here

- **One phase per session.** Verify the phase's acceptance criteria before moving on. Do
  not start the next phase because the current one "looks done."
- **Do not add components outside §3 of the build plan.** If a phase seems to need one,
  **stop and ask.** Prefer fixing configuration over adding a workaround component.
- **When something fails, check arm64 first.** Most common cause of `ImagePullBackOff` and
  `exec format error` in this environment.
- If reality contradicts the plan (a chart version doesn't exist, an image has no arm64
  manifest), **stop and say so.** Do not improvise around it.

## Non-negotiable

- **No floating tags. Ever.** Not `latest`, `lts`, `stable`, or partial semver (`:1`,
  `:1.2`). Images pinned by **manifest-list digest**; charts by exact semver. A
  platform-specific digest breaks the other architecture — always the index digest.
- **Never install a Helm chart at default resources.** Explicit requests and limits.
- **Bootstrap installs exactly one thing: Argo CD.** Everything else arrives from git via
  the root app-of-apps. If `bootstrap.sh` grows past ~30 lines, something belongs in git
  that isn't there yet. `scripts/lint-bootstrap.sh` enforces this.
- **Gate on error-budget burn rate, never a hand-picked threshold.** If you are typing
  `0.99` into an AnalysisTemplate, the SLO layer is being bypassed.
- **Never label a Prometheus metric with a commit SHA, image digest, or Rollout hash.**
  Unbounded cardinality. Those belong in GitHub Deployments and Discord messages.
- **Promotion is level-triggered, never edge-triggered.** No webhook-driven promotion, no
  `schedule:` workflow on GitHub. A reconciler on a timer that asks what should be true.

## Explicitly rejected — do not reintroduce

These were evaluated and declined. Reasons are in the build plan; do not relitigate.

| Rejected | Because |
|---|---|
| Tekton | CI is GitHub Actions on hosted runners (free + native arm64 on public repos) |
| Argo Events | edge-triggered event bus — the model rejected in Phase 3 |
| Argo Workflows | no orchestration gap here; a component in search of a job |
| Kustomize | one shared Helm chart instead; one templating tool, not two |
| Envoy Gateway | Istio's own Gateway API implementation serves ingress |
| MinIO / SeaweedFS | `local-path` PVCs; Loki and Tempo use filesystem backends |
| SMI | CNCF archived the spec |
| GitOps Promoter | branch-per-environment by architecture; this repo is directory-per-environment |
| Renovate | `task versions:check` covers it; adopt only if that script exceeds ~150 lines |
| Backstage, Keptn, DevLake | operational surface without a lesson we don't already have |

## Repos

Seven under `github.com/bo-jr`, all `bo-` prefixed, all **public**. Public is required for
free branch protection — the prod gate depends on it, and on a private free repo the rules
are configured and **silently not enforced**.

`bo-storefront` `bo-catalog` `bo-pricing` — source only, one per service
`bo-service-kit` — shared Go module (telemetry, chaos, httpx)
`bo-service-chart` — one Helm chart for all services
`bo-deploy` — **the gate**; `rendered/{dev,prod}/`, CI writes, Argo CD reads
`bo-platform` — this repo; bootstrap, clusters, SLOs, Argo CD apps, Go binaries

**The `bo-` prefix stops at the repo boundary.** Inside the cluster the service is
`storefront` — Rollout, Service, `app` label, Prometheus `service=` label, SLO name,
Discord message. Never `bo-storefront`. Sole exception: the image is
`ghcr.io/bo-jr/bo-storefront`, since that is what `ghcr.io/${{ github.repository }}`
resolves to. The chart takes `image.repository` **with** the prefix, `name` **without**.

Personal account means no account-level rulesets — `task repos:protect` applies the same
ruleset to all seven via `gh api`.

## Clusters

`mgmt` (hub) · `dev` · `prod` — k3d, all on the `gitops-lab` Docker network.

Argo CD runs in `mgmt` only and manages both spokes. Anything that is an admission webhook
or reconciles in-cluster resources must run **per-spoke** (Istio, cert-manager, ESO,
Kyverno, Rollouts, Prometheus agent, Alloy).

**Never iterate against an Argo CD-managed namespace** — self-heal reverts it within
seconds. Use the unmanaged `sandbox` namespace in `dev`. If self-heal is inconvenient, the
answer is `sandbox`, never disabling self-heal.

## Machine setup

Two machines, one lab: **MacBook M1 (arm64)** — the runtime target — and **Windows 11 /
WSL2 (amd64)**, which builds and tests but is too small to host the clusters.
`docs/SETUP.md` is the pickup procedure. `docs/DECISIONS.md` records every delta from the
build plan and why; append to it rather than editing the plan.

- Repo root is `~/gitops-lab/` on **both** machines, all seven cloned side by side. On
  Windows that is the WSL2 home, **never `/mnt/c/`**.
- `scripts/bootstrap-toolchain.sh` owns host tool versions. That pin list is the single
  source of truth — do not install k3d, helm, kubectl, or go any other way.
- Run `./scripts/bootstrap-toolchain.sh --verify` before blaming anything else when the
  two machines disagree. Drift is the first suspect.
- Secrets come from 1Password via `scripts/get-secret.sh` on both machines. There is no
  `uname` branch here and there should never be one.
- **Helm is 4.x.** Argo CD ≥3.5 renders with Helm 4 only; rendering CI manifests with
  Helm 3 reintroduces exactly the drift rendered manifests exist to remove.

## Cross-platform, always

Every change must work on `darwin/arm64` and `linux/amd64`.

- **Pin the manifest-list (index) digest, never a per-arch digest.** A platform-specific
  digest pulls fine on the machine you tested and fails `no match for platform` on the
  other. This is the most likely portability bug in the whole lab.
- Build own images for `linux/amd64,linux/arm64`.
- Prefer plain shell and `docker` steps over marketplace actions — many ship amd64-only
  binaries.
- **LF endings**, enforced by `.gitattributes` in all seven repos. A CRLF `.sh` copied
  into a Linux image dies as `bad interpreter: /bin/bash^M`.
- No `uname` branching anywhere except `scripts/bootstrap-toolchain.sh`, which needs it
  to choose a download URL.
