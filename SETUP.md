# Picking this up on a new machine

Read `CLAUDE.md` for the standing rules and `BUILD-PLAN.md` for the spec.
This file is the mechanical setup, and the honest status of where the build is.

---

## Status — last updated 2026-09-29

**Phases 0, 1 and 2 are complete and verified.** All acceptance criteria pass — Phase 2's
as amended in DECISIONS.md 2026-09-29 (the Tempo check moved to Phase 4).

| | |
|---|---|
| Repos | ✅ all seven created, public, `.gitattributes` seeded |
| Branch protection | ⚠️ `main-protection` active on **six of seven**. `bo-platform` has **no ruleset** (`task repos:protect:show`, 2026-09-29), so its `main` is unprotected. `task repos:protect` re-applies it |
| Taskfile | ✅ lifecycle, status, repo, `builder` and `sandbox:*` targets |
| Toolchain (MacBook M1) | ✅ installed and verified — all ten `ok` |
| Container runtime (MacBook M1) | ✅ Docker Desktop 4.89.0, engine 29.7.2, 36 GiB / 100 GiB |
| 1Password vault | ✅ `gitops-lab`, 7 items; Phase 0 secrets filled |
| Clusters, registry, caches | ✅ 3 clusters, 5 registries, k3s v1.36.4+k3s1 |
| Argo CD | ✅ v3.5.2 (chart 10.9.0) in `mgmt` via `task bootstrap`; root app Synced/Healthy |
| Spokes registered | ✅ `cluster-dev` / `cluster-prod`, in-network URLs, argocd-manager token, TLS verified |
| Platform components | ✅ cert-manager: dev **v1.21.2**, prod **v1.21.1** · cloudnative-pg: dev **0.29.1**, prod **0.29.1** (operator 1.30.1) |
| Service kit | ✅ `bo-service-kit` **v0.1.0** (tag on `908b8c3`) |
| Service chart | ✅ `oci://ghcr.io/bo-jr/charts/service` **0.1.0**, `sha256:9fb25251…`, public |
| Services | ✅ storefront, catalog, pricing `v1` in `sandbox` on dev; catalog's `catalog-db` Cluster beside them |
| Local image builder | ✅ `gitops-lab` buildx builder, BuildKit v0.33.0 by digest, pushes by digest to `k3d-registry:5000` |

**Phase 0 acceptance, as measured 2026-09-12:**

| Criterion | Result |
|---|---|
| All three clusters `Ready` | ✅ 6/6 nodes, all `v1.36.4+k3s1` — the pin held, not k3d's 1.35.5 default |
| Pod in `dev` reaches `k3d-mgmt-server-0` by DNS | ✅ resolves to `172.18.0.8`, TCP 6443 open |
| Image pushed to the registry pulls in all three | ✅ `k3d-registry:5000/phase0-smoke:v1` ran on mgmt, dev, prod |
| Second build faster, proving cache hits | ✅ `dev` rebuilt in **27s** with the Docker Hub rate-limit counter **unchanged at 100** — zero upstream pulls |

The last one is the interesting measurement. Rather than timing two builds and
eyeballing the difference, compare `ratelimit-remaining` before and after a
rebuild: if the caches are working the counter does not move at all, because
nothing reached Docker Hub. Use `HEAD`, which does not itself count:

```bash
TOK=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | jq -r .token)
curl -s -I -H "Authorization: Bearer $TOK" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest | grep -i ratelimit-remaining
```

**Phase 1 acceptance, as measured 2026-09-29:**

| Criterion | Result |
|---|---|
| `kubectl delete` a platform component → Argo CD restores it | ✅ deleted `deploy/cert-manager` in dev; self-heal recreated it (new UID) in **~1s**, back to Synced/Healthy |
| A version bump in `platform/dev/versions.yaml` upgrades dev *only* | ✅ #6 bumped dev to v1.21.2. Dev rolled to the new digests (controller `70f532fd…`); prod pods kept the v1.21.1 digests and never restarted |

The second one is worth reading off the Applications themselves. At the same git commit
(`ae823ce`), `cert-manager-dev` reports revisions `[v1.21.2, ae823ce]` and
`cert-manager-prod` reports `[v1.21.1, ae823ce]`. One ApplicationSet, one commit, two
versions. The only thing that differs is which `versions.yaml` each cluster's `env` label
selects:

```bash
kubectl --context k3d-mgmt -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVS:.status.sync.revisions'
```

Also verified along the way: `task bootstrap` re-runs against a live `mgmt` are safe (Helm
revision bumps, zero pod restarts), `register-spokes.sh` re-runs are no-ops, and
`lint-bootstrap.sh` fails on each of four seeded violations.

**Phase 2 acceptance, as measured 2026-09-29:**

| Criterion | Result |
|---|---|
| All three deploy to `dev` | ✅ Ready in `sandbox`, 0 restarts, arm64 nodes. Images are `k3d-registry:5000/bo-{storefront,catalog,pricing}@sha256:<index>`, each an OCI index with linux/amd64 + linux/arm64, pushed with **no tag** |
| One request is one trace across all three *(amended: same `trace_id` in all three logs; Tempo moves to Phase 4)* | ✅ `GET /checkout?sku=SKU-0007&qty=3` → `trace_id cb8bae35d02c3c44a4791eb9b6c6cce7` in storefront, catalog and pricing, three distinct `span_id`s. A caller-supplied `traceparent` was honoured by all three |
| `FAILURE_RATE=0.5` visibly moves the error rate | ✅ storefront `/metrics`: 0 / 200 errors at 0, then **1008 / 2000 = 0.504** at 0.5. Every error `status="500"`, `version="v1"`, matching the pod label |

Read the error rate off the service itself, not the client:

```bash
curl -s localhost:18081/metrics | awk '/^http_requests_total/ { t += $NF; if ($0 ~ /status="5/) e += $NF } END { printf "%d / %d = %.3f\n", e, t, e / t }'
```

The first 200-request sample at 0.5 came out at **0.630**, 3.7σ high. Rather than record
it, 1000 then 2000 more were sampled on the same pod (0.525, then 0.504), and 200 000 rolls
through the kit's middleware locally gave 0.4982. The code is unbiased; n=200 was not
enough. Size samples before reading a rate — Phase 6 compares canaries on exactly this.

**Also measured in `sandbox`:**

| Check | Result |
|---|---|
| Dead OTLP collector never hurts a request | All three pointed at `alloy.monitoring.svc.cluster.local:4318` (no such Service): checkout p50 **46ms** vs **44ms** with no exporter, `/readyz` 200, 0 restarts, **one** `otel error` line per pod in over a minute |
| catalog `/readyz` really checks the database | `cnpg.io/hibernation=on`: once Postgres went, catalog went NotReady within ~6s (probe 503) while storefront stayed Ready (it probes `/healthz`, not `/readyz`) and answered 502. Woken: catalog Ready in 16s, data intact, **no restarts** |
| pricing latency degrades under load | Server-side histogram, qty=1: concurrency 1 → p50 **41ms**, p90 75ms; concurrency 8 → p50 **335ms**, p90 613ms, p99 961ms |
| Graceful shutdown drains | pricing pod deleted with a 5.8s request in flight: `shutdown: draining`, the request finished **200** after 5811ms, `shutdown: complete`; every follow-up checkout 200 |
| Multi-arch is real, not nominal | the **amd64** leg of `bo-pricing` run under emulation answered `/healthz` and a real quote |
| Rules hold at render time | chart `test/run.sh`: 23/23, including 17 renders that must fail (tag for digest, SHA as version, missing limits, `bo-` prefix, wrong `chartVersion`, …) |
| CNPG promoted dev → prod by PR | #12: `cloudnative-pg-prod` Synced/Healthy at 0.29.1 in ~90s, same operator digest and resources. The pod-template hash is **`56478b47b5` on both spokes** — byte-identical specs — and dev's operator pod was untouched (0 restarts, created before the merge) |

Three things worth knowing from those runs:

- **Hibernation is not instant.** The operator deletes the pod, but Postgres does a *smart*
  shutdown, which waits for sessions to end; catalog's pool held idle connections, so the
  database stayed up for the full **180s** smart-shutdown timeout before going fast. Phase 6
  and Phase 7 drills that stop the database should expect that window.
- **The VM hashes ~4× slower than the host.** `BenchmarkBurn` predicts ~10ms per unit at
  `CPU_BURN_FACTOR=200`; in-cluster qty=1 is 41ms p50 with **zero** CFS-throttled periods
  (cAdvisor: periods 1758 → 1841, throttled unchanged at 892 across 30 sequential
  requests), so it is raw speed, not throttling. The 892 had accrued earlier, under the
  concurrent load runs. Calibrate latency SLO thresholds in Phase 4 from in-cluster numbers.
- **Helm 4 prints OCI pull status on stdout** when `helm template` fetches a chart itself,
  which broke the first deploy. Render from a pulled archive (DECISIONS.md 2026-09-29) —
  including in Phase 3 CI.

The sandbox loop, end to end:

```bash
task sandbox && task sandbox:db
```

```bash
task sandbox:build -- pricing && task sandbox:deploy -- pricing
```

```bash
task sandbox:deploy -- storefront --set-string env.FAILURE_RATE=0.5
```

**Next action:** Phase 3 — CI in GitHub Actions. See BUILD-PLAN §5. New session. Carry in:

- CI must `helm pull` the chart and render the archive (DECISIONS.md 2026-09-29).
- Service images pushed to ghcr.io start **private**, like the chart did; the clusters pull
  anonymously through the `ghcr` cache, so each package must be made public.
- `~/git/go.work` spans every Go module under `~/git`. When `cmd/promoter` gives bo-platform
  a `go.mod`, add it with `go work use ./bo-platform` or its `go` commands fail.
- catalog's `Cluster` needs an Argo CD home next to the services, and it races the CNPG
  CRDs on a cold rebuild — the sync-wave gap of the 2026-09-29 entry, now with a real case.

---

## 1. Container runtime

**macOS (M1)** — **Docker Desktop 4.89.0**, engine 29.7.2, `linux/arm64`. OrbStack
and Colima also work; Docker Desktop is what is installed.

Its defaults are far too small for three clusters — **8 GiB RAM and a 59.6 GiB disk**,
against a ≤20GB steady state plus three separate containerd image stores. Set both in
Settings → Resources → Advanced:

| | Default | This lab |
|---|---|---|
| Memory | 8 GiB | **36 GiB** |
| Disk | 59.6 GiB | **100 GiB** |
| Swap | 2 GiB | 4 GiB |

Equivalent from the CLI — Docker Desktop must be **stopped** first, and it reads
`settings-store.json`, not the `settings.json` beside it (that one is a leftover from
older versions and is ignored):

```bash
docker desktop stop && jq '.MemoryMiB=36864 | .DiskSizeMiB=102400 | .SwapMiB=4096' ~/Library/Group\ Containers/group.com.docker/settings-store.json > /tmp/s.json && mv /tmp/s.json ~/Library/Group\ Containers/group.com.docker/settings-store.json && docker desktop start
```

> First boot after installing Docker Desktop takes a few minutes and gives no progress
> indication. It is not hung. `docker desktop status` reports when the engine is up.

Verify the runtime before going further:

```bash
docker info --format '{{.ServerVersion}} {{.OSType}}/{{.Architecture}}'
```

---

## 2. Clone all seven repos side by side

Repo root is `~/git/`.

```bash
mkdir -p ~/git && cd ~/git
for r in bo-platform bo-deploy bo-service-chart bo-service-kit \
         bo-storefront bo-catalog bo-pricing; do
  git clone "https://github.com/bo-jr/$r.git"
done
```

The flat side-by-side layout is required by `go.work` (BUILD-PLAN §4), which spans
`bo-service-kit` and the three service repos.

---

## 3. Install the pinned toolchain

```bash
cd ~/git/bo-platform && ./scripts/bootstrap-toolchain.sh
```

Installs the eleven pinned tools with Homebrew into `/opt/homebrew/bin` and freezes each
with `brew pin`.

The pin list at the top of the script is the authority. Homebrew is only the installer —
it has no versioned formulae for these tools and cannot install a chosen version, so
`brew pin` is what actually holds them still. The script finishes by running `--verify`
on itself, so a brew stable that has moved ahead of the pin list fails loudly instead of
drifting quietly.

The script also carries a Linux path that downloads each pinned release directly and
checks it against the checksum file its upstream publishes. It is what the GitHub
Actions runners use, for just the tools a job needs:

```bash
./scripts/bootstrap-toolchain.sh --only "go helm kyverno"
```

Open a new shell, then confirm:

```bash
./scripts/bootstrap-toolchain.sh --verify
```

Every line must say `ok`. A `DRIFT` line is the first thing to suspect when
something behaves differently on one machine than the other.

> If `--verify` reports drift after a `brew upgrade`, the fix is to decide whether the
> new version is wanted and edit the pin list — **not** `brew unpin`. The pin list is
> what makes a rebuild reproducible.

Go must run with modules on. This should print nothing or `on`:

```bash
go env GO111MODULE
```

> If it prints `off`, an old `go env -w` setting lives in the file `go env GOENV` names,
> and `go env -u GO111MODULE` removes it. An `export GO111MODULE=on` in `.zshrc` masks it
> only in interactive shells — IDEs, task runners and agents still see `off`, and fail
> with `modules disabled by GO111MODULE=off`. Found on the MacBook in Phase 2.

---

## 4. Authenticate git and GitHub

```bash
gh auth login
```

GitHub.com → HTTPS → **Yes** (authenticate git with GitHub credentials) → browser.
Then wire the credential helper and set identity:

```bash
gh auth setup-git
```

```bash
git config --global core.autocrlf input
```

> `gh auth login` does **not** reliably set the credential helper on its own.
> Without `gh auth setup-git`, `gh` works but `git push` prompts for a password.

---

## 5. Create the 1Password vault

Secrets come from 1Password — see `scripts/get-secret.sh`.
Create a vault named `gitops-lab` (override with `OP_VAULT`) with one item per
secret below, each holding the value in a field named `credential`:

| Item | What it is |
|---|---|
| `argocd-git-credential` | PAT Argo CD uses to read `bo-deploy` |
| `ci-deploy-pat` | fine-grained PAT service CI uses to open and auto-merge the rolling dev PRs — **Contents: read and write**, **Pull requests: read and write**, repository access **only `bo-deploy`**. Set as the `BO_DEPLOY_TOKEN` Actions secret in the three service repos (Phase 3) |
| `promoter-github-pat` | fine-grained PAT for `cmd/promoter` — `contents: write`, `pull_requests: write`, scoped to `bo-deploy` (the promoter slice, after Phase 7) |
| `dockerhub-user` | Docker Hub username for the pull-through cache |
| `dockerhub-token` | Docker Hub access token |
| `discord-promotions` | webhook URL for `#promotions` |
| `discord-deploys` | webhook URL for `#deploys` |
| `discord-alerts` | webhook URL for `#alerts` |

Items are *API Credential* category, so `credential` is the native primary field
rather than a custom one. All of them can be created empty up front — only fill the
ones the phase you are on needs.

Check the vault without printing anything:

```bash
./scripts/get-secret.sh --check
```

It reports `ok` / `EMPTY` / `MISSING` per item with the phase that needs it, and
never emits a value. For a single phase's gate, pass the items:

```bash
./scripts/get-secret.sh --check "dockerhub-user dockerhub-token"
```

> **Do not run the plain `./scripts/get-secret.sh <item>` form to test the vault.**
> It prints the credential to stdout — that is its purpose, since callers use it as
> `--proxy-password "$(./scripts/get-secret.sh dockerhub-token)"` — but running it
> interactively writes the secret into your terminal scrollback, which is exactly
> where a credential is most likely to end up in a screenshot. Use `--check`.

These and the git credential are the only things that outlive `task nuke`. Nothing
else is exempt from git.

---

## 6. Then start Phase 0

BUILD-PLAN §5, Phase 0 — push registry, four pull-through caches, three k3d
clusters on the `gitops-lab` Docker network. Do not skip the caches: Phase 8
requires two consecutive full rebuilds and unauthenticated Docker Hub pulls are
capped near 10/hour.

**One phase per session.** Verify the acceptance criteria before moving on.
