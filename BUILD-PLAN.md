# GitOps Lab — Build Plan / Claude Code Handoff Spec

**v2** — adds SLO layer, alerting, rebuild verification, platform promotion path,
authorization policy, DORA metrics, and attestation verification.

> **How to use this doc:** Point Claude Code at this file as the standing spec for the
> repo. It defines locked decisions, phase boundaries, and acceptance criteria.
> Work **one phase at a time**. Do not start phase N+1 until phase N's acceptance
> criteria pass. Do not substitute tools listed under "Locked decisions" without
> asking first — every one of them was chosen against a specific constraint.

---

## 1. Mission

A fully ephemeral, three-cluster GitOps lab running on a single MacBook Pro, whose
purpose is to demonstrate **progressive delivery that catches a bad deploy and rolls
it back automatically, gated on error budget burn rather than arbitrary thresholds**.

Everything else in this document is scaffolding for that one demonstration.

The success milestone is not "the stack is installed." It is:

> Deploy `storefront` v2, identical to v1 except `FAILURE_RATE=0.05`. Argo Rollouts
> shifts 10% of traffic to it. The AnalysisTemplate queries the **burn-rate recording
> rule Pyrra generated from a declared SLO**, sees the error budget draining faster
> than the fast-burn threshold, aborts the rollout, and returns 100% of traffic to v1.
> The same burn-rate rule fires an Alertmanager alert. The whole sequence is legible
> in Kiali, Grafana, and the Pyrra UI — with zero human input.

---

## 2. Hard constraints

| Constraint | Implication |
|---|---|
| **Cross-platform: macOS (arm64) and Windows 11 (amd64)** | Everything above the container runtime is identical on both. See §2a. |
| **Mixed architecture** | Build own services multi-arch (`linux/amd64,linux/arm64`). **Pin the manifest-list digest, never a per-arch manifest digest** — the index resolves correctly on both machines; a platform-specific digest pulls fine on one and fails `no match for platform` on the other. Prefer plain shell/docker steps over marketplace actions and third-party plugins, which frequently ship amd64-only binaries. |
| **64GB host, ~36GB allocated to the OrbStack VM** | Steady state target ≤ 20GB across all three clusters. Every Helm install gets explicit resource requests/limits. Never install a chart at defaults. |
| **Fully ephemeral** | Teardown must leave nothing behind except the git repos and the k3d registry container. No host bind-mounts for cluster data. **This is verified, not assumed — see Phase 8.** |
| **6-hour data retention** | Prometheus, Loki, and Tempo all capped at 6h. Data dies with the cluster; that is intended. |
| **Disk, not RAM, is the real ceiling** | Three clusters keep three separate containerd image stores. Budget 60–80GB. Use the shared k3d registry aggressively. |

---

## 2a. Running on macOS and Windows 11

k3d runs k3s **inside Docker containers** — each node is a container running k3s with
containerd embedded, running your pods. Registries and pull-through caches are plain
Docker containers on the same network. On macOS and Windows there is a Linux VM beneath
Docker; on Linux there isn't. Everything above that VM is identical, which is what makes
this portable.

**macOS**
- OrbStack (preferred) or Docker Desktop / Colima. Allocate 36GB to the VM.
- Secrets from Keychain via `security find-generic-password`.

**Windows 11**
- Docker Desktop with the **WSL2 backend**, or Rancher Desktop. Not Hyper-V, not Windows containers.
- **Keep the repo inside the WSL2 filesystem** (`~/gitops-lab`), never `/mnt/c/`. Cross-filesystem I/O is an order of magnitude slower and mangles script permissions.
- Allocate memory in `.wslconfig`.
- **`.gitattributes` with `* text=auto eol=lf` and `*.sh text eol=lf`.** Without it, CRLF endings produce `bad interpreter: /bin/bash^M` on every script — a confusing failure the first time you hit it.

**The portability seam: secrets.** Keychain doesn't exist on Windows. Abstract retrieval
behind `scripts/get-secret.sh`, dispatching on `uname`: `security` on macOS, `pass` or
`secret-tool` in WSL2. Or use the 1Password CLI on both and stop branching.

**Accept when:** `task up` succeeds on both machines from a clean checkout, and the same
pinned digests resolve on both.

---

## 3. Locked decisions

These are settled. Do not re-litigate them mid-build.

**Platform**
- **k3d** for clusters (not kind) — built-in registry, working LoadBalancer via servicelb, fastest create/destroy cycle.
- **Three clusters, hub and spoke:** `mgmt` (hub), `dev`, `prod` (spokes).
- All three on one Docker network named `gitops-lab`. Mandatory for cross-cluster DNS.
- One **k3d registry** container, created outside cluster lifecycle, shared by all three.

**Hub (`mgmt`) hosts:**
Argo CD · Prometheus (central, receives remote-write) · Alertmanager · **Pyrra** ·
Grafana · Loki · Tempo · Kiali · OpenBao · **DORA exporter** · **promotion reconciler
CronJob** · **alert-sink** (webhook receiver)

**Spokes (`dev`, `prod`) each host:**
Istio (istiod + ztunnel + waypoint) · cert-manager · External Secrets Operator ·
Kyverno · Argo Rollouts controller · Prometheus in **agent mode** · Grafana Alloy ·
the three services · CloudNativePG · k6 (prod only)

> These cannot be centralized: they are admission webhooks or they reconcile
> in-cluster resources. That split is itself part of the lesson — the ESO *operator*
> runs per-spoke while authenticating to a *single* OpenBao in `mgmt`, which is
> exactly how a real central secrets store is wired.

**Tooling**
- **CI: GitHub Actions on GitHub-hosted runners.** Repos are public, so runners are free and unmetered, and **native arm64 runners** (`ubuntu-24.04-arm`) make multi-arch a matrix rather than QEMU emulation (~5x slower). No self-hosted runners — on a public repo that is the configuration GitHub warns against, since fork PRs would execute on your machine.
- **No Tekton.** Not Pipelines, Triggers, EventListener, or Chains. See Phase 3.
- **No Argo Events.** It is an edge-triggered event bus, which is exactly the model rejected in Phase 3 — an event fired while `mgmt` is paused is lost, and nothing reconciles the gap. This design has one trigger (git push, handled by Actions) and one timer (the promotion CronJob). Nothing for it to do.
- **Argo CD Notifications is observation only, never control.** Bundled with Argo CD since 2.6, so config rather than an install. Its single job is posting sync/health status to Discord `#deploys`. **Nothing in this system may depend on a notification firing** — if Notifications breaks entirely, visibility is lost and nothing else: promotion still reconciles on its 5-minute loop, canaries still abort on burn rate.
- **Promotion reconciler: a plain Kubernetes CronJob in `mgmt`** running `cmd/promoter`. It is the only part of the pipeline needing live cluster access, and it is one step on a timer — it never needed a CI engine. Do **not** implement it as a GHA `schedule:` workflow: scheduled runs are delayed under load and **GitHub disables them after 60 days of repo inactivity**, which would silently stop promotion in an idle lab.
- **Provenance: `actions/attest-build-provenance`**, not Tekton Chains. The attestation is signed against GitHub's OIDC identity — a stronger root of trust than a Tekton install on a laptop.
- **Mesh: Istio ambient.** Istio's own Gateway API implementation serves as ingress — do **not** add Envoy Gateway or any other ingress controller.
- **Delivery: Argo CD + Argo Rollouts** with the **Gateway API plugin** (requires Gateway API ≥ 1.2). Do **not** use SMI — the spec is archived.
- **SLOs: Pyrra** (`pyrra.dev/v1alpha1 ServiceLevelObjective`). Chosen over Sloth because it is still actively developed and ships a UI. Generates PrometheusRule objects consumed by the Prometheus Operator.
- **Alerting: Alertmanager** (a Prometheus component, already in kube-prometheus-stack — enable it, don't add a chart).
- **Notifications: Discord.** Three channels — `#promotions` (GitHub PR webhook, native `/github` endpoint), `#deploys` (Argo CD Notifications), `#alerts` (Alertmanager `discord_configs`). Chosen over Slack because free Discord retains full message history while free Slack truncates at 90 days, and the point of this channel is a durable promotion record. **Link-only — no interactive buttons, ever.** See §8.
- **Secrets: External Secrets Operator → OpenBao**, Kubernetes auth method.
- **Policy: Kyverno**, verifying **attestations**, not just signatures.
- **Storage: k3s `local-path` StorageClass.** No MinIO, no SeaweedFS. Loki uses `storage.filesystem`, Tempo uses `backend: local`, both in monolithic/single-binary mode.
- **Load: k6** as a permanent Deployment, `constant-arrival-rate` executor.
- **Task runner: Taskfile (go-task).** Bash is the correct tool for bootstrap — something
  must run before a cluster exists to be declarative in — but its scope ends at "Argo CD
  is running and pointed at git." `lint-bootstrap.sh` enforces that boundary.
- **Verification logic is Go, not bash.** Polling app health, parsing JSON, timing, and
  asserting is a program. `cmd/verify-rebuild` is a testable binary; the shell wrapper
  only invokes it.

**No floating tags, anywhere, ever.** Not `latest`, not `lts`, not `stable`, not
major-only (`:1`), not minor-only (`:1.2` tracking patches). Container images are pinned
by **digest**; Helm charts by **exact semver**. A Kyverno policy enforces this at
admission and the same policy runs in CI.

**Version discovery: `task versions:check`.** A script that queries each upstream for
its newest stable release, filters out prereleases, resolves tags to digests, diffs
against `platform/dev/versions.yaml`, and opens a PR. Constraints:
- Writes to **`platform/dev/versions.yaml` only.** Prod gets versions by promotion, never
  by discovery — otherwise `dev` stops being a gate.
- Report-and-propose, never auto-merge.
- "Latest stable" is not machine-decidable in general; expect per-project exceptions.
- **Boundary:** if this exceeds ~150 lines or accumulates special-cased release
  conventions, stop maintaining it and adopt Renovate. Kargo's Warehouses also subsume
  it entirely — see Phase 9.

- **Services: Go**, one module, three binaries, one multi-stage Dockerfile with a build arg.
- **DORA exporter: Go**, written in-repo. Not Keptn, not Four Keys.

**Build and packaging (used inside phases; listed here so they are not treated as
unauthorized additions):**
- **Helm** for third-party charts, versions pinned per-environment in `platform/<env>/versions.yaml`
- **One shared Helm chart** (`service-chart`) for all services, published as an OCI artifact and pinned by version. **Kustomize is not used anywhere** — one templating tool, not two.
- **Gateway API CRDs** ≥ 1.2, installed in sync wave 0
- **BuildKit** (rootless, registry-backed cache) for image builds — not Kaniko, which is archived
- **cosign** for signing; **`actions/attest-build-provenance`** for SLSA provenance
- **OpenTelemetry Go SDK** in all services, OTLP export to local Alloy
- **`gh` CLI** for opening the dev PR in Actions; the prod PR is opened by `cmd/promoter`

**Explicitly out of scope:** Renovate, Argo CD Image Updater, MinIO, Jaeger, Backstage,
Keptn, multi-tenancy/SSO, Istio multi-cluster, HA anything.

---

## 4. Repository layout

**Seven repos under `github.com/bo-jr`, all `bo-` prefixed, all public.**

Public is mandatory: on a private free repo branch protection is configured and **silently
not enforced**, which would make the prod gate decoration.

Personal account means **no account-level rulesets**, so protection is a seven-time setup.
Script it — `task repos:protect` loops `gh api` over all seven with one ruleset payload.
The one you would otherwise get wrong is `bo-deploy`, the only one where it matters.

```
github.com/bo-jr/
bo-storefront/ bo-catalog/ bo-pricing/   # one repo per service, SOURCE ONLY
├── cmd/<service>/main.go
├── Dockerfile                           # multi-arch, built natively per arch
├── chart-values.yaml                    # values for the shared chart
└── .github/workflows/ci.yml             # calls the reusable workflow

bo-service-kit/                          # shared Go module
└── telemetry/ chaos/ httpx/             # OTel setup, chaos knobs, server scaffolding

bo-service-chart/                        # ONE Helm chart for all services
└── templates/                           # Rollout|Deployment, Service, HTTPRoute,
                                         # AuthorizationPolicy, ServiceMonitor
bo-deploy/                               # THE GATE — rendered manifests only
└── rendered/{dev,prod}/<service>/       # CI writes; Argo CD reads ONLY this

bo-platform/                             # platform + bootstrap
├── Taskfile.yml
├── clusters/{mgmt,dev,prod}.yaml
├── scripts/
│   ├── bootstrap.sh                     # creates clusters, installs ONLY Argo CD
│   ├── register-spokes.sh               # cluster add + server URL override + labels
│   ├── seed-openbao.sh                  # reads from macOS Keychain / pass
│   ├── get-secret.sh                    # OS-dispatching secret retrieval
│   └── lint-bootstrap.sh                # asserts bootstrap installs only Argo CD
├── platform/
│   ├── dev/  versions.yaml + values/    # chart versions land here FIRST
│   └── prod/ versions.yaml + values/    # promoted by PR
├── slos/                                # Pyrra ServiceLevelObjective CRs
├── docs/architecture.d2
├── cmd/{promoter,dora-exporter,verify-rebuild}/
└── argocd/
    ├── root-app.yaml
    ├── appsets/                         # MATRIX: cluster generator × git files
    └── apps/{hub,spoke}/
```

**The `bo-` prefix stops at the repo boundary.** It is a GitHub namespacing artifact. Inside
the cluster the service is `storefront` — Rollout name, Service name, `app` label, Prometheus
`service=` label, SLO name, Discord message. Never `bo-storefront`. The sole exception is the
image, because `ghcr.io/${{ github.repository }}` resolves to `ghcr.io/bo-jr/bo-storefront`
and fighting that default is not worth it: the chart takes `image.repository` **with** the
prefix and `name` **without**.

**Naming.** `bo-platform` over `bo-infra` — the thing it holds *is* the platform; `infra` implies
cloud resources that do not exist here. `bo-deploy` over `bo-config` — "config repo" is the
conventional term, but this repo is the promotion gate and `deploy` says what merging into
it does. `bo-service-kit` and `bo-service-chart` are deliberately parallel: the Go scaffolding and
the Helm scaffolding every service consumes.

**Why `rendered/` lives in ONE shared `bo-deploy` repo, not per service.** Atomicity. The
catalog schema migration (Phase 6, scenario 5) requires `catalog` and `storefront` to
promote together or not at all — one PR carrying both digests, one merge, one decision.
Across three config repos that would be three coordinated merges with no transaction, and
the failure mode is prod running a half-promoted pair. It also means branch protection is
load-bearing in exactly one place.

**Source repos are one-to-one with services.** `manifests/base` does *not* live there —
each service carries only `chart-values.yaml`, consumed by the shared chart.

**`service-kit` needs a `go.work`.** The chaos knobs and OTel setup are the code you
will iterate on most, and across a polyrepo split every change becomes: tag common,
`go get -u` in three repos, three PRs. A `go.work` covering all checkouts makes local
builds resolve against your working tree while CI resolves against tags. Get the chaos-knob
interface right early and then leave it alone.

**Helm, not Kustomize — one chart for all three services.** They are the same shape (Go
HTTP, `/healthz`, `/readyz`, `/metrics`, OTel, chaos knobs), which is the internal
"golden path" chart pattern. Kustomize composes one app across environments well and many
apps sharing a shape badly. Since CI renders, the templating tool never reaches Argo CD —
and this drops Kustomize entirely, leaving one templating tool instead of two.

**Rendered manifests are non-negotiable.** CI runs `helm template` and commits plain YAML.
Argo CD never templates at sync time for *your services* — that is what makes the promotion
PR diff byte-identical to what gets applied. **Platform charts are the deliberate
exception:** Istio and kube-prometheus-stack render at sync time from
`platform/<env>/values/`, because rendering them into git would be thousands of lines
nobody reviews. You promote those by version bump, and the version bump *is* the diff.

---

## 5. Build phases

### Phase 0 — Clusters, registry, and pull-through caches

**Pull-through caches are required, not optional.** Unauthenticated Docker Hub pulls are
limited to roughly 10/hour per IP. Phase 8 requires two consecutive full rebuilds —
six cluster builds pulling ~40 distinct platform images each. Without caching you will
hit `toomanyrequests` before the first rebuild completes, and you will not hit the
20-minute target.

Registry proxy mode is single-upstream, so create one cache per registry. All of them
live outside cluster lifecycle and survive `task nuke`, alongside the push registry.

```bash
# push registry for own images
k3d registry create registry --port 5000

# pull-through caches
k3d registry create dockerhub --port 5001 --proxy-remote-url https://registry-1.docker.io \
  --proxy-username "$DOCKERHUB_USER" --proxy-password "$DOCKERHUB_TOKEN"
k3d registry create quay --port 5002 --proxy-remote-url https://quay.io
k3d registry create ghcr --port 5003 --proxy-remote-url https://ghcr.io
k3d registry create k8s  --port 5004 --proxy-remote-url https://registry.k8s.io
```

Authenticate the Docker Hub proxy — it raises the ceiling on cache misses. Credentials
come from Keychain like the other bootstrap secrets.

Write a `registries.yaml` mapping each upstream to its cache under `mirrors:`, and pass
it to all three clusters with `--registry-config`. **Layer the endpoints** — containerd
tries them in order, so a cold local cache falls through to a public mirror before ever
hitting the origin:

```yaml
mirrors:
  docker.io:
    endpoint:
      - "http://k3d-dockerhub:5000"    # local cache
      - "https://mirror.gcr.io"         # Google's free Docker Hub pull-through cache
      - "https://registry-1.docker.io"  # origin
  quay.io:
    endpoint: ["http://k3d-quay:5000", "https://quay.io"]
  ghcr.io:
    endpoint: ["http://k3d-ghcr:5000", "https://ghcr.io"]
  registry.k8s.io:
    endpoint: ["http://k3d-k8s:5000", "https://registry.k8s.io"]
  gcr.io:
    endpoint: ["https://gcr.io"]
```

**Where the stack actually lives** — most of it is not on Docker Hub:

| Registry | Hosts | Limits |
|---|---|---|
| `registry.k8s.io` | Kubernetes core | CDN-backed, none |
| `quay.io` | Prometheus, Alertmanager, cert-manager, Kiali, Argo CD/Rollouts | generous |
| `ghcr.io` | Kyverno, ESO, CloudNativePG, Pyrra, OpenBao | effectively none (public) |
| `gcr.io` | Istio (`gcr.io/istio-release`) | none |
| `public.ecr.aws` | Docker Official Images at `/docker/library/*` | generous |
| `cgr.dev` | Chainguard hardened base images for the Go builds | free tier is `:latest`-only, fine since we pin by digest |
| `docker.io` | Grafana stack, k6, BuildKit — the only unavoidable ones | ~10 pulls/hr unauthenticated |

```bash
k3d cluster create mgmt --network gitops-lab --servers 1 \
  --k3s-arg "--disable=traefik@server:*" \
  --registry-use k3d-registry:5000 --registry-config registries.yaml
k3d cluster create dev  --network gitops-lab --servers 1 --agents 1 \
  --k3s-arg "--disable=traefik@server:*" \
  --registry-use k3d-registry:5000 --registry-config registries.yaml
k3d cluster create prod --network gitops-lab --servers 1 --agents 2 \
  --k3s-arg "--disable=traefik@server:*" \
  --registry-use k3d-registry:5000 --registry-config registries.yaml
```

Disable Traefik (Istio's gateway replaces it). **Keep** servicelb, local-path, metrics-server.

**Accept when:** all three `Ready`; a pod in `dev` can reach `k3d-mgmt-server-0` by DNS;
an image pushed to the push registry pulls in all three; and a second cluster build
completes visibly faster than the first, confirming the caches are being hit.

> `task nuke` deletes clusters and the push registry but **keeps the pull-through
> caches** — they hold no state you author, only upstream images, and rebuilding them
> is the expensive part.

---

### Phase 1 — Argo CD, spoke registration, and the promotion path

Install Argo CD in `mgmt` only. Register spokes with labels `env=dev` / `env=prod`.

> **The gotcha that will cost you an hour:** `argocd cluster add` reads the server URL
> from your kubeconfig, and k3d writes it as `https://0.0.0.0:<port>` — meaningless
> from inside a container. Override to `https://k3d-dev-server-0:6443`. Handle it in
> `register-spokes.sh` once.

**Platform ApplicationSet must use a matrix generator**, not a bare cluster generator:

```yaml
generators:
- matrix:
    generators:
    - clusters:
        selector:
          matchLabels: { argocd.argoproj.io/secret-type: cluster }
    - git:
        repoURL: <infra-repo>
        files:
        - path: "platform/{{ metadata.labels.env }}/versions.yaml"
```

This is what makes `dev` a real environment. Chart versions live in
`platform/<env>/versions.yaml`, so bumping Istio in dev is a PR against one file and
promoting to prod is a second PR against another. **Platform upgrades get the same
review path as application code.** Without this, `dev` is decorative.

**Platform Applications must be multi-source.** The chart comes from its upstream repo,
the values from yours, joined with `$values`:

```yaml
sources:
  - repoURL: https://istio-release.storage.googleapis.com/charts
    chart: istiod
    targetRevision: 1.24.2                 # from platform/<env>/versions.yaml
    helm:
      valueFiles: [$values/platform/dev/values/istiod.yaml]
  - repoURL: https://github.com/<you>/platform
    targetRevision: main
    ref: values
```

Without `ref: values` you would have to vendor every upstream chart to co-locate values
with it. Keep these Applications **generated by the ApplicationSet**, never hand-written —
otherwise you get one copy per environment and they drift.

Sync waves: 0 = CRDs + cert-manager, 1 = istiod + ztunnel, 2 = platform components,
3 = gateways + waypoints, 4 = apps.

**Accept when:** `kubectl delete` any platform component and Argo CD restores it; and
a version bump in `platform/dev/versions.yaml` upgrades dev *only*.

---

### Phase 2 — The three services

One Go module, three binaries. Shared internal packages so behavior is identical.

**`storefront`** — `GET /checkout?sku=X&qty=N`. Fans out to the other two, assembles a
quote. **The canary target.**

**`catalog`** — `GET /items/{sku}`, backed by CloudNativePG. Seeded with ~50 rows.

**`pricing`** — `POST /quote`. CPU-bound by design: iterated SHA-256 over line items,
iteration count scaled by `qty * CPU_BURN_FACTOR`. Latency must degrade under load
rather than staying flat.

**Every service implements, without exception:**
- `GET /healthz` (liveness), `GET /readyz` (checks downstream deps)
- `GET /metrics` — `http_requests_total{service,route,status,version}` and
  `http_request_duration_seconds` histogram, same labels
- OTel tracing, W3C traceparent propagation, OTLP export to local Alloy
- Structured JSON logs to stdout including `trace_id`
- Graceful shutdown on SIGTERM with connection draining

**Chaos knobs** (env vars, read at startup, stamped into a `version` label):

| Var | Effect |
|---|---|
| `FAILURE_RATE` | float 0.0–1.0; that fraction of requests return 500 |
| `EXTRA_LATENCY_MS` | int; sleep injected before responding |
| `CPU_BURN_FACTOR` | int; multiplier on `pricing`'s hash iterations |
| `APP_VERSION` | string; must appear as a Prometheus label and a pod label |

**Accept when:** all three deploy to `dev`, one request produces a single trace in
Tempo spanning all three, and `FAILURE_RATE=0.5` visibly moves the error rate.

### The shared chart

One chart, published to `oci://k3d-registry:5000/charts/service`, **pinned by version in
each service repo** — an unpinned chart edit silently changes all three services' manifests
at once. Each service supplies:

```yaml
name: storefront
image: { repository: ghcr.io/<you>/storefront, digest: "sha256:..." }
workload: Rollout                  # the only conditional that earns its place
dependencies: [catalog, pricing]
canary: { analysisTemplate: storefront-burn-rate }
env: { FAILURE_RATE: "0", EXTRA_LATENCY_MS: "0" }
```

**Generate the Istio `AuthorizationPolicy` from `dependencies`.** The service declares what
it calls; the chart emits the allow rules, the `readyz` dependency checks, and the
ServiceMonitor. Under default-deny, forgetting a policy is an outage — a chart that makes
that mistake structurally impossible is worth more than one that saves typing.

**Discipline:** when a service wants something the chart lacks, the answer is "add it for
everyone" or "this service is off the golden path." Never "add another conditional."
Charts like this die by accumulated `if`s.

### Inner loop: the `sandbox` namespace

Argo CD runs auto-sync with self-heal, so any `kubectl edit` or `kubectl set image` against
a managed namespace is reverted within seconds. That is correct behavior and it will feel
like the cluster is fighting you.

Create a **`sandbox` namespace in `dev` that no Argo CD Application manages.** That is where
iteration happens. Nothing in `sandbox` is reconciled, nothing there is a source of truth,
and it is never promoted.

Fastest loop for three Go services is `go run` locally with port-forwards to `catalog` and
`pricing` — sub-second, no image build. Reach for an in-cluster loop (Tilt) only when the
thing under test is mesh behavior: authorization policy, waypoint L7 enforcement, mTLS.

**Never iterate against a managed namespace.** If self-heal is inconvenient, the answer is
`sandbox`, never disabling self-heal.



---

### Phase 3 — CI in GitHub Actions

One reusable workflow, parameterized by service, called from all three service repos.

checkout → `go test` → **`kyverno apply` against rendered manifests (policy runs in CI
before it runs at admission)** → **matrix build on `ubuntu-24.04-arm` and `ubuntu-24.04`,
pushed as a multi-arch manifest list** → push **by digest to `ghcr.io`** (free and
unlimited for public repos; clusters pull it through the ghcr cache from Phase 0) →
cosign sign → `actions/attest-build-provenance` → `helm template` →
**stamp commit timestamp as an annotation on the rendered manifests** → commit →
open the **dev** PR against the config repo.

> The local k3d push registry stays for hand-built local images. CI images come from
> ghcr.io. Both coexist; pin the **manifest-list** digest so it resolves on either arch.

> The commit-timestamp annotation is what makes DORA lead time measurable in Phase 7.
> It rides through the pipeline into the rendered manifest and onto the live Rollout,
> where the exporter reads it back. Do not skip it — retrofitting is painful.

Rolling PR **per service**, force-pushed to the latest digest. Not one PR per commit.
`dev` auto-merges on green. The **prod** PR is opened by the reconciler below, not by Actions.

**Three things that will bite otherwise:**

- **Enable "Allow auto-merge" in repo settings**, then `gh pr merge --auto --squash`. It is
  gated the same way branch protection is — public repos on the free plan.
- **Add a `concurrency` group per service** on the promotion job. Two commits landing close
  together will otherwise have the second build force-pushing the branch while the first PR
  is mid-auto-merge. Serialize, do **not** cancel — both builds must complete.
- **Fail the workflow if the dev PR does not merge.** If its checks fail, the PR sits in the
  config repo forever: Argo CD has nothing to say because nothing changed, Discord is quiet,
  and nobody watches that repo. Wait for the merge with a timeout and exit non-zero — then
  it surfaces as a red check on the repo you are already looking at.

**Emit GitHub Deployments.** Actions creates a deployment (`in_progress`) against the `dev`
environment when the dev PR merges; `cmd/promoter`, which already watches Rollout state,
marks it `success` or `failure` based on whether the canary promoted or aborted. Same for
`prod` on merge.

This gives you a native deployment-history UI — the repo's Environments tab, per
environment, with pass/fail and source commit — for zero infrastructure. It is also exactly
what Apache DevLake ingests, so full DORA with benchmarking later needs no new
instrumentation. Put the **short commit SHA** in the Discord message too; "storefront
deployed" is ambiguous the second time you merge in an hour.

### What triggers dev → prod promotion

Do **not** open both PRs at once — a prod PR that exists before dev is verified is a
review of something unproven. And do not trigger on Argo CD `Synced`, which only means
resources reconciled.

**Promotion must be level-triggered, not edge-triggered.** Do not drive it from an Argo
CD Notifications webhook. A webhook is a single event: if it fires while `mgmt` is paused,
or while the reconciler pod is restarting, the promotion is lost permanently and nothing ever
reconciles the gap. Given that `task pause` / `task resume` are first-class operations
here, that will happen regularly and will fail silently.

**A Kubernetes CronJob in `mgmt` runs `cmd/promoter` every 5 minutes.** No CI engine —
this is one step on a timer. Each run asks what should be true, not what just happened.
It reads:

1. the digest in the **live dev `Rollout`** — not the rendered dev manifest
2. the digest in `rendered/prod/`
3. the dev Rollout's `Progressing` condition `lastTransitionTime` (its "healthy since")
4. whether a prod PR is already open, and for which digest
5. whether the dev Rollout is `Healthy`, not `Degraded` or `Paused`

If dev's digest differs from prod's **and** dev has been healthy longer than the soak
(30 min here; hours to days in a real org) **and** no open PR already targets that digest,
it promotes. Otherwise it exits doing nothing.

**Idempotency is the point.** A thousand runs produce one PR. Two hundred missed runs
during a cluster pause cost nothing — the next one reconciles. There is no state to lose.

**Read the digest from the live Rollout, not the rendered manifest.** The manifest is what
*should* be running; the Rollout is what *is* running and what the analysis actually
verified. Under auto-sync they converge, but during an aborted rollout they diverge — and
that is exactly the case where you must promote what passed, not what was requested.

**The reconciler renders, it does not sed:** set the prod image digest → `helm template`
with the prod values → write `rendered/prod/` → commit to a fixed branch
(`promote/<service>`) → force-push → open or update the PR. Its GitHub token comes from
OpenBao via ESO; its dev-cluster credentials are the same ones Argo CD holds.

**Both GitHub repos must be PUBLIC.** On the Free plan, branch protection and rulesets
are only available on public repositories — on a private free repo the rules can be
configured and are then **silently not enforced**, or the API returns 403 telling you to
upgrade or go public. Since this system's entire premise is "the PR is the gate," an
unenforced gate is worse than none. The original reason for private repos (fork PRs
executing on self-hosted runners) disappeared once CI moved to GitHub-hosted runners —
which also require public repos for free arm64.

Required branch protection on `main` of the apps repo:
- require a pull request before merging
- require 1 approving review
- **require approval from someone other than the last pusher**
- dismiss stale approvals on new commits
- required status check: the dev-health check described above

**Identity:** a fine-grained PAT scoped to the two repos (`contents: write`,
`pull_requests: write`), stored in OpenBao. A GitHub App is better hygiene but the
JWT-to-installation-token exchange is code you'd have to write, and `gh` does not handle
App auth natively. If Phase 9 adopts GitOps Promoter, its `ScmProvider` supports
App auth natively and this becomes free.

Merge stays human. That merge is the only manual gate in the system.

**Break-glass (bypassing the soak):** open the prod PR **by hand** with the digest you want.
The reconciler is idempotent — it sees an open PR already targeting that digest and leaves
it alone. Branch protection still requires the review. There is deliberately **no bypass
flag and no emergency mode**: the break-glass path is doing manually exactly what the
reconciler does, so there is no code path that only executes during incidents and is
therefore never tested.

**Add a GitHub status check on the prod PR that re-queries dev health at merge time.**
Otherwise a PR opened Tuesday can be merged Thursday after dev has since degraded, and
nothing catches it. This is the most commonly missed piece of a promotion pipeline.

Platform version promotion (`platform/<env>/versions.yaml`) stays **manual-initiated**
via `task promote:platform` — a mesh or Argo CD upgrade wants a longer, human-judged
soak than an application image.

> This reconciler **is** what Kargo's controller does. Phase 9 deletes it: a Kargo Stage
> declares dev as its upstream Freight source, verification runs the AnalysisTemplate, and
> the promotion policy enforces the soak. Building it level-triggered now means the
> replacement is a swap, not a redesign.

**Accept when:** a push to main produces a signed image with provenance, and an open PR
whose diff shows only the digest and timestamp annotation changing.

---

### Phase 4 — Observability, SLOs, and alerting

Prometheus in **agent mode** in each spoke (scrape-and-forward, no local TSDB),
remote-writing to central Prometheus in `mgmt`. Alloy in each spoke ships logs to Loki
and traces to Tempo in `mgmt`.

Retention set to **6h in all three places**: Loki `limits_config.retention_period` plus
compactor `retention_enabled: true`; Tempo `block_retention`; Prometheus
`--storage.tsdb.retention.time`. All PVCs on `local-path`. No host bind-mounts.

**Pyrra** in `mgmt`. Declare SLOs as CRs in `slos/`, managed by Argo CD:

```yaml
apiVersion: pyrra.dev/v1alpha1
kind: ServiceLevelObjective
metadata:
  name: storefront-availability
spec:
  target: "99.5"
  window: 1h          # short window suits a 6h-retention lab
  indicator:
    ratio:
      errors: { metric: 'http_requests_total{service="storefront",status=~"5.."}' }
      total:  { metric: 'http_requests_total{service="storefront"}' }
```

Declare at minimum: storefront availability, storefront latency, catalog availability.

**Alertmanager**: enable in kube-prometheus-stack (do not add a separate chart). Route
Pyrra's generated burn-rate alerts to two receivers in parallel: **`alert-sink`** — a
~30-line webhook receiver that logs the alert as JSON to stdout, so Alloy ships it to
Loki and fired alerts stay queryable in Grafana — and **Discord `#alerts`** via
Alertmanager's native `discord_configs`.

**Discord wiring, three sources, three channels:**

| Channel | Source | Mechanism |
|---|---|---|
| `#promotions` | GitHub | Repo webhook → Discord webhook URL with `/github` appended. Zero code; GitHub calls Discord server-to-server, so it works even when the cluster is down. Subscribe to **Pull requests only.** |
| `#deploys` | Argo CD Notifications | `service.webhook.discord` with a Discord embeds body. **There is no first-class `discord` service type** — configuring one fails with `notification service 'discord' is not supported`. Use the generic webhook service. |
| `#alerts` | Alertmanager | Native `discord_configs`. |

> **Known noise source:** promotion PRs are rolling and force-pushed, so each new digest
> fires a `synchronize` event on an already-open PR. If `#promotions` becomes a stream
> of "PR updated" rather than a clean promotion record, drop the GitHub-native
> integration for that channel and post from Actions only on PR open and merge.

All three Discord webhook URLs are secrets: seeded into OpenBao from macOS Keychain,
consumed via ESO. They are the only stack component that outlives `task nuke`, so they
join the git credential as bootstrap-time inputs rather than living in git.

> **Central Prometheus is the largest single consumer** and scales with cardinality,
> not cluster count. Scrape at 30s, drop unused kube-prometheus-stack recording rules,
> cap it explicitly. At defaults it takes 6GB alone.

**Two cardinality rules, both load-bearing:**
- **Trim Istio telemetry labels.** Its defaults are generous and every label multiplies
  series. This is the most likely cause of Prometheus ballooning.
- **Never label a Prometheus metric with a commit SHA, image digest, or Rollout hash.**
  These are unbounded — a metric carrying every digest you have ever deployed will
  quietly consume the whole store. SHAs belong in GitHub Deployments and Discord messages,
  where cardinality is free. That split is a design requirement, not a preference.

Everything else in the observation layer (Pyrra ~100MB, Kiali ~150MB, the exporter and
promoter ~50MB combined) is thin readers over this one store. Under 400MB total — the
design works because nothing brings its own database. That is also the real reason
**not** to run DevLake here.

Kyverno: run **admission and background controllers only**, not all four.

**Accept when:** one Grafana shows metrics, logs, and traces from all three clusters
with datasource correlation working; Pyrra's UI shows a live error budget; and driving
`FAILURE_RATE` up fires an alert that lands in Loki.

---

### Phase 5 — Istio ambient, Gateway API, and authorization

Ambient mesh-wide in both spokes for L4 mTLS. **A waypoint proxy in the canary
namespace is required** — ztunnel reports only L4/TCP, so without a waypoint you get
byte counts and no HTTP request rates, which is exactly the data canary analysis needs.

Istio's Gateway API implementation serves ingress. `storefront` behind an `HTTPRoute`.
k6 hits the gateway, not the service directly.

**Authorization — default deny, then explicit allow:**

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: default-deny, namespace: shop }
spec: {}          # ALLOW action with no rules == deny everything
```

Then explicit allows keyed on **ServiceAccount identity (SPIFFE)**, not IP or label:
gateway SA → storefront; storefront SA → catalog, pricing; nothing else permitted.
Add one L7 rule (allow only `GET /items/*` from storefront SA to catalog) to exercise
waypoint enforcement.

> **Run this failure case deliberately once:** apply an L7 rule to a namespace with no
> waypoint. It will *silently not enforce* — no error, no warning, no protection. L4
> policy is enforced by ztunnel; L7 policy requires the waypoint. This is the single
> most useful ambient-specific thing in the whole lab.

Kiali in `mgmt`, pointed at central Prometheus, Traffic filter defaulted to
waypoint-only (ambient double-reports edges and the graph is unreadable otherwise).

**Accept when:** Kiali shows a live L7 graph of gateway → storefront → {catalog,
pricing}; a curl from an unauthorized pod is refused; and the L7-without-waypoint case
has been observed failing open.

---

### Phase 6 — Rollouts and the milestone

Convert `storefront` to a `Rollout` with the Gateway API plugin.

Canary steps: 10% → analysis → 25% → analysis → 50% → analysis → 100%.

**The AnalysisTemplate queries Pyrra's burn-rate recording rule, not a raw success
rate.** Inspect what Pyrra actually emits for your SLO name and query that; gate on
fast-burn threshold rather than a hand-picked "99%". A canary that consumes error
budget faster than the fast-burn rate is a canary that would page someone — that is
the correct thing to abort on, and it is the reason Pyrra is in this stack.

> **Timing gotcha:** the analysis queries a Prometheus fed by remote-write from the
> spoke, so there is ingest lag. Make each step's duration comfortably longer than
> scrape interval + remote-write lag, or analyses fail on *missing* data and you'll
> spend hours debugging a non-problem.

**On long canaries.** For bakes measured in hours, switch from step-level analysis
(`steps[].analysis`) to **background analysis** (`spec.strategy.canary.analysis`), which
runs continuously for the rollout's whole duration and aborts the moment metrics degrade
rather than sampling in discrete windows. Raise `progressDeadlineSeconds` well above the
bake time — it defaults to 600s and will otherwise mark a long canary `Degraded` for no
reason.

For bakes measured in **days, do not use a canary.** A Rollout in progress blocks every
subsequent deploy of that Rollout, so a 24h canary means 24h of not shipping. Two
versions also coexist in prod for the whole window, dragging in schema compatibility,
cache-key compatibility, and split metrics. A multi-day bake is a **feature flag**
problem: deploy fully, gate the risky behavior behind a flag, ramp the flag over days.
Canary answers "does this binary behave"; flags answer "do users want this." Keep the
axes separate.

**Run all seven scenarios and document what each teaches:**

1. **Clean** — v2 identical. Promotes cleanly.
2. **Error injection** — `storefront` v2 with `FAILURE_RATE=0.05`. Aborts on burn rate.
3. **Latency injection** — v2 with `EXTRA_LATENCY_MS=300`. Aborts on latency SLO.
4. **Downstream failure** — `pricing` v2 degraded while the canary is on `storefront`. Teaches why you measure at the edge and how cascading latency presents.
5. **Schema migration** — `catalog` v2 needs a new column. Expand-contract. The scenario most people never attempt.
6. **Drift** — `kubectl edit` a prod Deployment; watch Argo CD self-heal.
7. **Bad config rollback** — merge a broken config, then recover two ways: `git revert` vs Argo CD rollback. They have different failure modes; know which you'd reach for.

**Accept when:** scenario 2 aborts and self-heals with zero human input, the abort is
visible in Kiali, Grafana, and Pyrra, and the same burn-rate rule that aborted the
canary also fired an alert into Loki.

---

### Phase 7 — Secrets, DORA, and attestation verification

**Secrets:** ESO in each spoke authenticating to OpenBao in `mgmt` via Kubernetes auth.
Postgres credentials come from OpenBao, not a literal Secret. Exercise **CNPG
backup/restore at least once** — PITR is the reason that operator is installed.

**DORA exporter** (`cmd/dora-exporter`, runs in `mgmt`): a small Go controller watching
Argo CD Applications and Argo Rollouts across all three clusters, exposing `/metrics`:

| Metric | Source |
|---|---|
| Deployment frequency | Rollout transitions to `Healthy`, counted per service/env |
| Lead time for changes | now − commit-timestamp annotation stamped in Phase 3 |
| Change failure rate | aborted or degraded Rollouts ÷ total Rollouts |
| MTTR | duration from Rollout `Degraded` → next `Healthy` |

**Implementation requirements:**
- **Watch, don't poll.** Use a controller-runtime informer on Rollouts across all three
  clusters. A poll loop misses a fast `Degraded` → `Healthy` flip between ticks — precisely
  the incident you most want counted in MTTR.
- **Counters, not pre-averaged gauges,** for deployment frequency and failures
  (`dora_deployments_total`, `dora_rollout_failures_total`). Compute rates in PromQL. A
  gauge holding "deploys per day" bakes in a window Grafana can never re-ask.
- **Histograms for lead time and MTTR.** The distribution is the point — p50 20 min with
  p95 6 hours says something a mean of 90 min hides completely.

Grafana dashboard for all four. This is your own platform measuring itself, using the k8s
controller patterns you already write professionally.

> **Known limitation, worth being able to state:** MTTR from Rollout conditions measures
> *deployment* recovery, not incident recovery. A config change or dependency outage that
> never touches a Rollout is invisible to it. Real DORA MTTR comes from incident tracking.
> This is a good proxy; knowing why it's a proxy is the more interesting thing to have an
> opinion about.

**Kyverno must verify attestations, not just signatures.** A signature check alone proves
*something* signed the image, not that your pipeline built it. Use `verifyImages` with an
`attestations` block asserting the SLSA predicate from `actions/attest-build-provenance` —
builder ID matches GitHub Actions, source URI matches your repo, workflow path matches.
Otherwise the attestation is an artifact nobody reads.

Additional policies: resource limits required, no `latest` tags, digest-only image
references. All of them run in Actions via `kyverno apply` before they run at admission.

**Accept when:** an unsigned image is rejected at admission; an image signed but with
a mismatched provenance predicate is *also* rejected; both failures reproduce in CI
first; and the DORA dashboard shows four populated metrics.

---

### Phase 8 — Verify the ephemerality thesis

The premise of this entire lab is that it rebuilds from git. Nothing so far proves it.

**`task verify:rebuild`** runs `nuke` → `up`, then asserts:
- all three clusters `Ready`
- every Argo CD Application `Synced` **and** `Healthy`
- smoke test: `curl` storefront through the gateway returns 200 with expected body
- a trace for that request is queryable in Tempo
- Pyrra reports a live error budget for `storefront-availability`

It records wall-clock duration to `.rebuild-log` and **fails if the run exceeds 20
minutes**. Track the number over time — if it drifts upward, something has crept out of
git and into a manual step.

**`scripts/lint-bootstrap.sh`** asserts that `bootstrap.sh` contains no `kubectl apply`
or `helm install` other than the Argo CD install and the root app. This is an
executable version of the architectural thesis. If bootstrap grows past ~30 lines,
something belongs in git that isn't there yet.

**Accept when:** `task verify:rebuild` passes from a completely clean machine state,
twice in a row, unattended.

---

### Phase 8b — Architecture diagram, generated not drawn

`docs/architecture.d2` is the source of truth; `docs/architecture.svg` is generated.

Use **D2** (Terrastruct), not Mermaid — themed SVG output, real layout engines, and it
handles nested containers, which is the whole point when the diagram has three clusters.

**Render it in CI.** A GitHub Actions step runs `d2 --theme=200 --layout=elk docs/architecture.d2
docs/architecture.svg` and commits the result. A diagram nobody regenerates is a diagram
that lies within a month; generating it on every pipeline run means it can't drift.

Scope the diagram to three nested containers (mgmt, dev, prod) with the promotion path
as the spine: GitHub Actions → ghcr.io → dev canary → soak → promotion PR → prod canary.
Observability flows back to mgmt as a second, lighter set of edges.

**Accept when:** `docs/architecture.svg` is regenerated by CI, not by hand, and a
reviewer can trace one image digest from commit to prod using only the diagram.

---

### Phase 9 — Replace hand-rolled promotion with Kargo

**Kargo. GitOps Promoter is ruled out — see below.**

**Why not GitOps Promoter.** It matches this plan's philosophy closely (promotion as
continuous reconciliation gated by commit statuses, PR as the gate), but it is
**branch-per-environment by architecture, not by configuration**. Its mechanism is a
staging branch and a live branch per environment with the promotion PR running
staging→live; commit statuses attach to commits on those branches. Remove the branches and
there is nothing to gate. Issue #1336 proposes an `activePath` field, but that gives one
branch *per environment* with directories *per app* — still branch-per-environment, and
unshipped. This plan uses directory-per-environment (§4), so Promoter is out.

> Note the models are otherwise the same idea: Promoter's `environment/<env>` branches hold
> machine-generated *hydrated* manifests, which is exactly what `rendered/<env>/`
> holds here. Same concept, different storage.

**Kargo** is deliberately unopinionated about repo layout. Its promotion steps are
path-oriented (`git-clone`, `helm-update-image`, `helm-template`, `git-commit`,
`git-open-pr`), so promoting `rendered/dev/` → `rendered/prod/` in the config repo is
normal usage, not a workaround.

**Also worth evaluating: Telefonistka** (Wayfair) — built on the assumption that everything
promoted lives in an environment-specific directory. Narrower and less known than Kargo,
but directory-native by design.

---

#### Kargo model

**Do this last, and only after Phases 0–8 pass.** The point is to delete code you wrote
and understand, not to install a tool you never needed.

Kargo (Akuity, from the Argo CD creators) is a promotion control plane that sits beside
Argo CD. Its model:

- **Warehouse** — subscribes to image registries, Helm repos, and git repos; emits Freight when new versions appear
- **Freight** — an immutable bundle of artifact versions that moves as one unit
- **Stage** — an environment node in the promotion graph (`dev` → `prod`)
- **Promotion** — a durable Kubernetes object recording what advanced, to where, when, and on what evidence

**It subsumes three things built by hand in earlier phases:**

| Hand-rolled in | Replaced by |
|---|---|
| `task versions:check` (§3) | Warehouse subscriptions to registries and Helm repos |
| `cmd/promoter` CronJob (Phase 3) | Promotion steps with a git-push template |
| Seven-repo coordination | Warehouses subscribing to all three image streams |
| `platform/<env>/versions.yaml` promotion (Phase 1) | Stages with promotion policies |

Kargo also **reuses Argo Rollouts' `AnalysisTemplate` CRD** for stage verification — so
the Pyrra burn-rate query from Phase 6 can gate promotion *between environments*, not
only between canary steps. That is the strongest single reason it belongs here.

**Maturity note, since it would gate prod:** v1.9.0, post-GA, actively developed. A
missing-authorization CVE landed on its promotion REST endpoints in 2026 (the `promote`
verb was enforced on the gRPC API but not on three REST endpoints). Normal for a young
project; worth knowing before it holds the keys to your prod stage.

**Accept when:** `cmd/promoter` and its CronJob have been deleted,
`versions:check` has been deleted, promotion dev→prod happens through a Kargo Stage,
and a Pyrra burn-rate AnalysisTemplate gates that promotion. Then write down what Kargo
did better than the hand-rolled version and what it did worse — that comparison is the
deliverable, not the install.

---

## 6. Taskfile targets

| Target | Behavior |
|---|---|
| `task up` | registry (if absent) → 3 clusters → Argo CD → root app → wait for sync |
| `task down` | delete all 3 clusters; **keep** the push registry and pull-through caches |
| `task nuke` | delete clusters **and** the push registry; **keep** the pull-through caches |
| `task pause` / `task resume` | `k3d cluster stop/start` — preserves data, far faster than recreate |
| `task seed` | read from macOS Keychain, seed OpenBao |
| `task canary:<n>` | run canary scenario n from Phase 6 |
| `task verify:rebuild` | the Phase 8 assertion |
| `task repos:protect` | apply the same branch-protection ruleset to all seven repos |
| `task docs:diagram` | render `docs/architecture.d2` to SVG |
| `task status` | per service: digest in dev vs prod vs latest built |
| `task versions:check` | query upstreams for newest stable, propose bumps to `platform/dev/versions.yaml` |
| `task promote:platform -- <component>` | open the dev→prod version-bump PR |

**Bootstrap installs exactly one thing: Argo CD.** Everything else arrives from git.

Two things cannot live in git — the Argo CD git credential and the OpenBao seed data.
Both come from macOS Keychain at bootstrap. Nothing else is exempt.

---

## 7. Working agreements for Claude Code

- **One phase per session.** Verify acceptance criteria before moving on.
- **Never install a Helm chart at default resources.** Explicit requests and limits, always.
- **Pin every image by digest** in platform manifests, not by tag.
- **When something fails, check arm64 first.** It is the most common cause of
  `ImagePullBackOff` and `exec format error` in this environment.
- **Do not add components not in §3.** If a phase seems to need one, stop and ask.
- **Prefer fixing configuration over adding a workaround component.** The value of this
  lab is inversely proportional to how many moving parts it has.
- **Never write a floating tag.** No `latest`, `lts`, `stable`, or partial semver. Digest for images, exact version for charts. If a manifest has a mutable reference, it is wrong.
- **Gate on burn rate, never on a hand-picked threshold.** If you find yourself typing
  a number like `0.99` into an AnalysisTemplate, the SLO layer is being bypassed.

---

## 8. Why notifications are link-only

Discord carries links. It does not carry approve/reject buttons. This is a hard rule,
not a v1 simplification.

Interactive components require the chat platform to reach a public HTTPS endpoint,
which a laptop cluster does not have — but the ingress problem is the *smaller* reason.
The real one is that a button handler must hold a credential with authority over prod
and answer "is this Discord user allowed to approve this?" That reintroduces, as code
you maintain, every question GitHub already answers: who can approve, whether two
people are required, and what the audit trail says.

The promotion PR is the gate. GitHub owns approval, CODEOWNERS routing, review counts,
and the permanent record. Chat's only job is to tell you the PR exists.

If a future phase seems to need a button, the correct move is to make the PR easier to
find — not to move the decision into chat.
