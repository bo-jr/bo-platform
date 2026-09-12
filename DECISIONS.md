# Decisions log

Deltas from `BUILD-PLAN.md` and answers to questions the plan left open.
The plan is the spec; this file records where reality forced a choice and why.
**Append, never rewrite.** If a decision is reversed, add a new entry saying so.

---

## 2026-09-05 — Helm 4.2.4, not Helm 3

**Decision.** The pinned host Helm is `v4.2.4`. The build plan was written against
Helm 3 idioms and `v3.21.4` was installed first as the conservative pick; that was
wrong and got reversed the same day.

**Why.** Argo CD's own documentation states: *"The only Helm binary used to render
charts in Argo CD (starting with version 3.5) is v4."* Current Argo CD stable is
**v3.5.2**, so the platform charts that render at sync time (Istio,
kube-prometheus-stack) go through Helm 4 regardless of what is installed locally.
Rendering CI manifests with Helm 3 while Argo CD renders with Helm 4 is exactly the
drift the rendered-manifests design exists to eliminate.

Note that **helm.sh publishes no explicit Helm 3 end-of-life date**. Specific sunset
dates circulating in third-party migration guides are not confirmed upstream and are
not a basis for this decision. The Argo CD renderer is.

**Why the breaking changes don't bite us.** Helm 4's breaking changes land on
`--wait`, `--atomic`, `--force`, post-renderers, the plugin system, and the Go SDK.
This lab uses `helm template` in CI and Argo CD uses `helm template` at sync — the
Helm CLI never manages a release lifecycle here, because Argo CD does. The one place
to stay alert is `helm registry login` path components when publishing
`service-chart` as an OCI artifact.

**Consequence for Phase 0 — the cluster version ceiling.** Helm 4 declares
compatibility with `n-3` Kubernetes minors:

| Helm | Supported Kubernetes |
|---|---|
| 4.2.x | 1.36.x – 1.33.x |
| 4.1.x | 1.35.x – 1.32.x |
| 4.0.x | 1.34.x – 1.31.x |

So **k3d clusters must pin Kubernetes to 1.36.x**, not the 1.37.0 that is current
stable — pass an explicit `--image rancher/k3s:v1.36.<patch>-k3s1` in Phase 0 rather
than taking k3d's default. The pinned `kubectl` stays at **1.37.0**: the client is
supported within ±1 minor of the server, so 1.37 against a 1.36 cluster is fine.

**Revisit if:** the OCI publish flow in Phase 2 misbehaves.

---

## 2026-09-05 — 1Password CLI on both machines

**Decision.** `scripts/get-secret.sh` calls `op read` on macOS and WSL2 alike. No
`uname` dispatch, no Keychain, no `pass`.

**Why.** BUILD-PLAN §2a names secrets as *the* portability seam and offers two
routes: dispatch on `uname`, or "use the 1Password CLI on both and stop branching."
Branching means two backends to seed, a GPG key to manage in WSL2, and a code path
that is only ever exercised on one machine — so its failure is discovered on the
machine you were not testing on.

---

## 2026-09-05 — Host toolchain pinned in a script, not a version manager

**Decision.** `scripts/bootstrap-toolchain.sh` holds the pin list and installs to
`~/.local/bin`. `--verify` asserts installed == pinned. `mise` was considered and
declined.

**Why.** Pinning prevents drift; verification *detects* it, and that second half is
what actually matters across two machines. A committed pin list gets both. `mise`
would deliver the same guarantee while adding a component outside BUILD-PLAN §3,
against a working agreement that says the lab's value is inversely proportional to
its moving parts. Homebrew-on-Mac was rejected outright: brew resolves its own
versions, which guarantees the two machines diverge.

**Revisit if:** the script accumulates per-tool special cases the way
`versions:check` is warned about in §3 — the same ~150-line boundary applies.

---

## 2026-09-05 — Repo root is `~/gitops-lab/` on both machines

**Decision.** All seven repos are cloned side by side under `~/gitops-lab/` —
WSL2 home on Windows, `$HOME` on macOS. Never `/mnt/c/`.

**Why.** `go.work` (BUILD-PLAN §4) spans all checkouts. Relative paths only resolve
identically if the parent directory is the same shape on both machines. `/mnt/c/`
additionally mangles script permissions and is an order of magnitude slower.

---

## 2026-09-05 — The Windows machine does not host the lab

**Decision.** Windows 11 / WSL2 is for building, testing, and CI authoring. The
MacBook M1 (64GB) is the runtime target for the three-cluster lab.

**Why.** BUILD-PLAN §2 assumes a 64GB host with ~36GB to the VM and a ≤20GB steady
state. The Windows box has **31GB total** and WSL2 is deliberately capped at 8GB for
gaming headroom. Three clusters carrying Istio, kube-prometheus-stack, Argo CD, Loki,
Tempo, Kiali, OpenBao and CNPG will not fit in 8GB — not tightly, not at all.

**Consequence.** Cross-platform correctness cannot be verified by running the lab on
both machines. It is enforced instead by: one pinned toolchain, manifest-list index
digests (never per-arch), `linux/amd64,linux/arm64` builds, and LF line endings.

---

## 2026-09-07 — Repo root is `~/git/`, superseding `~/gitops-lab/`

**Decision.** Reverses the `~/gitops-lab/` entry of 2026-09-05. All seven repos are
cloned side by side under `~/git/` on both machines — WSL2 home on Windows, `$HOME` on
macOS. Never `/mnt/c/`.

**Why.** Operator preference; `~/git/` is where every other checkout on the MacBook
already lives. The original entry's reasoning was never about the *name* — it was that
`go.work` (BUILD-PLAN §4) spans all checkouts and only resolves identically if the
parent directory is the same shape on both machines. `~/git/` satisfies that exactly as
well as `~/gitops-lab/` did. The `/mnt/c/` prohibition is unaffected and still stands.

**Consequence.** `README.md`, `docs/SETUP.md` and `CLAUDE.md` updated. The Docker
network is still named `gitops-lab` — that name was never tied to the directory, and
BUILD-PLAN §3 requires it.

---

## 2026-09-07 — argocd-agent adopted at Phase 9b, not Phase 1

**Decision.** `argocd-agent` (argoproj-labs) enters the plan as **Phase 9b**, after
Phases 0–8 pass. The lab is built first on classical hub-and-spoke — Argo CD in `mgmt`,
spokes registered with `argocd cluster add` — and the multi-cluster model is swapped
afterwards.

**Verified before deciding**, against upstream rather than from memory:

| | |
|---|---|
| Version | v0.10.0 (2026-08-26), pre-1.0, active |
| Image | `quay.io/argoprojlabs/argocd-agent:v0.10.0` — OCI index, `linux/arm64` + `linux/amd64` |
| Index digest | `sha256:ec9baba6e81555bfa5ce1fa6252f06c6100b56ae7f85273ba2f7e2309303800d` |
| Charts | `oci://ghcr.io/argoproj-labs/argocd-agent/argocd-agent-principal` 0.3.3, `…/argocd-agent-agent` 0.2.7 |

Charts lag the app (chart appVersion `v0.8.1` vs image `v0.10.0`), so `image.tag` must be
pinned explicitly by index digest rather than inherited from `appVersion`.

**Why not Phase 1.** Three reasons, in order of weight:

1. **It inverts "bootstrap installs exactly one thing."** The control plane must *not*
   run an application controller (upstream: explicitly unsupported), and every spoke needs
   `application-controller` + `repo-server` + `redis` + `agent` running *before* git can
   deliver anything to it. Bootstrap goes from one component on one cluster to a stack on
   three, plus a CA, a principal server certificate, and a client certificate per agent.
   `argocd-agentctl` issues them but is upstream-labelled "highly experimental, under no
   circumstances for production." `scripts/lint-bootstrap.sh` does not survive that.
   Worse: this repo's delivery model is a root app-of-apps in `mgmt`, which needs an
   app-controller on the hub, which needs the upstream **hybrid architecture** — hub
   app-controller plus a Redis proxy in front of `argocd-server`.
2. **It costs memory rather than saving it.** At three clusters the pull model saves
   nothing — the hub watching two local k3d clusters over a shared Docker network is
   free. Adds the principal (chart default is 2 CPU / 4Gi limits — must be capped) plus a
   full app-controller/repo-server/redis per spoke. Estimate +1.5–2.5GB against a ≤20GB
   steady state.
3. **It buys nothing toward the milestone.** The abort-on-burn-rate sequence
   (BUILD-PLAN §1) happens entirely inside the spoke. argocd-agent changes nothing about
   Rollouts, Pyrra, the AnalysisTemplate, or Istio.

**Why still adopt it.** Same reasoning the plan already applies to Kargo in Phase 9:
build the thing you understand, then replace it and write down the comparison — the
comparison is the deliverable, not the install. It also removes the Phase 1 gotcha
(k3d writes `https://0.0.0.0:<port>` into the kubeconfig and `argocd cluster add` reads
it) by removing hub→spoke connections altogether.

**Locked for when it lands.** Managed mode, **destination-based mapping** — this
preserves the matrix ApplicationSet of Phase 1, since a cluster generator emits one
Application per registered agent routed by `spec.destination.name`. Namespace-based
mapping caps each ApplicationSet at a single agent and is therefore ruled out.
Spoke-local `repo-server` and `redis`, never the hub's: sharing them makes `mgmt` a SPoF
and breaks `task pause`.

**Consequence.** `lint-bootstrap.sh` will need a second permitted install with the reason
written into the script. Phase 9 and Phase 9b are independent swaps and may be done in
either order.

---

## 2026-09-07 — `bootstrap-toolchain.sh` had three macOS-only bugs

**Decision.** Fixed in place; pin list unchanged. All nine pinned versions existed and
were correct — every failure was in URL construction or output parsing.

**What was wrong.** The script had only ever run on WSL2/Linux, where all three collapse
to the working case:

1. **Asset naming.** jq and d2 call macOS `macos`, not `darwin`; `gh` calls it `macOS`
   *and* ships a `.zip` instead of a `.tar.gz`. Three 404s. Fixed with `OS_ALT`, `GH_OS`
   and `GH_EXT`, which are identical to `OS` on Linux.
2. **BSD vs GNU sed.** The `task` version parser used `\+`, which GNU sed accepts and BSD
   sed silently matches nothing with — so `task` reported `installed=unknown` forever.
   Now `sed -E`, valid on both.
3. **The PATH guard, the worst of the three.** `grep -q '.local/bin' "$rc"` treated the
   leading dot as *any character*, so it matched `/usr/local/bin` — present, commented
   out, in the stock `.zshrc`. The guard concluded PATH was already configured and skipped
   the append. Every tool then silently resolved to Homebrew's copy instead of the pinned
   one, which is the exact drift `--verify` exists to catch, arriving through the script
   meant to prevent it. Now `grep -qF`.

**Why it matters beyond this script.** All three are the same failure shape: something
that is correct on `linux/amd64` and quietly wrong on `darwin/arm64`, with no error. That
is the class of bug CLAUDE.md's cross-platform rules exist for, and it is worth
remembering that it reached the toolchain layer before it ever reached a manifest.

**Also fixed.** Both scripts were committed `100644`, so `./scripts/bootstrap-toolchain.sh`
failed with `permission denied` on a fresh clone — exactly as `docs/SETUP.md` tells you to
invoke it. Now `100755` via `git update-index --chmod=+x`.

**Open, not blocking.** Homebrew copies of `k3d`, `kubectl`, `helm`, `gh` and `go` remain
installed and currently happen to match the pin list. `~/.local/bin` precedes
`/opt/homebrew/bin` on PATH so the pins win, but a future `brew upgrade` would make the
two disagree with nothing reporting it. `brew uninstall k3d helm kubernetes-cli` would
close it.

---

## 2026-09-07 — Homebrew installs the toolchain on macOS; the pin list still rules

**Decision.** Amends the 2026-09-05 entry that chose a script over a version manager.
On macOS the nine host tools are installed by **Homebrew** and frozen with **`brew pin`**.
WSL2 is unchanged: `curl` from each pinned release URL into `~/.local/bin`. The pin list
at the top of `scripts/bootstrap-toolchain.sh` remains the single source of truth on both.

**Why.** Operator preference for brew-managed installs over hand-placed binaries. The
2026-09-05 entry's actual requirement was never "must be a script" — it was that both
machines run identical, declared versions and that drift is *detectable*. Brew as the
installer does not threaten that; brew as the *authority* would.

**How the pin survives.** Homebrew has no versioned formulae for these tools — there is
no `helm@4.2.4`, only `helm@3`, a different major — so brew cannot install a chosen
version. Two things close that gap:

1. `brew pin` on all nine, so `brew upgrade` cannot move them.
2. The macOS branch of the script ends with `exec "$0" --verify`. If brew's stable has
   moved ahead of the pin list, installation fails loudly rather than silently handing
   you a different version. The remedy is to update the pin list deliberately — never
   `brew unpin`, because the WSL2 box installs by exact URL and the two must agree.

**Cost, stated honestly.** Re-converging a drifted machine onto an *older* pinned version
is no longer a one-command operation on macOS; brew can only move forward. If that ever
bites, the answer is to move that tool back to the curl path, not to abandon the pin list.

**Version change.** `D2` moves `v0.8.2` → `v0.9.0`, the only one of the nine where brew's
stable differed from the pin. Chosen over holding 0.8.2 because d2 is not yet used
anywhere — Phase 8b is the first consumer — so there is nothing to regress.

**Consequence.** `~/.local/bin` no longer holds any of the nine on macOS, and the PATH
line the script had appended to `.zshrc` was removed, restoring the original file.
`~/.local/bin` still holds unrelated tools (`claude`, `lsd`, `webi`) and was left in place.

---

## 2026-09-07 — Repo docs live in the repo root, not `docs/`

**Decision.** `BUILD-PLAN.md`, `DECISIONS.md` and `SETUP.md` moved from `docs/` to the
repo root, joining `README.md` and `CLAUDE.md`. The `docs/` directory was removed.

**Why.** Operator preference; explicitly provisional — "keep all the repo docs in the
root of the repo for now, we can optimize them later."

**Not changed.** BUILD-PLAN §4 and Phase 8b still specify `docs/architecture.d2` and
`docs/architecture.svg`. Those are a generated diagram that does not exist yet, they are
part of the spec rather than of this move, and the plan is not edited from here — see
the header of this file. `docs/` will therefore reappear at Phase 8b holding only the
diagram. Revisit then.

**Also not changed.** Two earlier entries in this file mention `docs/SETUP.md` in prose.
That was the accurate path when they were written and this log is append-only, so they
stand as written.

---

## 2026-09-12 — Taskfile owns cluster-infrastructure image versions

**Decision.** `Taskfile.yml` `vars:` is the fourth and last version authority in this
lab, holding the two images Phase 0 introduces — the k3s node image and the k3d registry
image — both pinned by manifest-list index digest.

The complete map, so this is answerable without archaeology:

| Version class | Authority | Changed by |
|---|---|---|
| Host CLI tools (9) | `scripts/bootstrap-toolchain.sh` pin list | hand-edited; brew installs, `brew pin` freezes |
| Cluster infra images | `Taskfile.yml` `vars:` | hand-edited |
| Platform Helm charts | `platform/<env>/versions.yaml` (Phase 1) | `versions:check` PRs into **dev only**; prod by promotion |
| Service image digests | `bo-deploy/rendered/<env>/` (Phase 3) | CI writes; `cmd/promoter` copies dev→prod |

**Why not a fifth file.** `clusters/versions.yaml` would match the `platform/<env>/`
pattern, but the three k3d config files cannot interpolate a shared variable, so the
Taskfile would have to read it — and parsing YAML in shell needs `yq`, which is not in
the pin list. Adding a tenth pinned tool to avoid duplicating two strings is a bad trade.

**Pins chosen.**

- `rancher/k3s` **v1.36.4-k3s1**, index digest `sha256:edad48e1…`. Held at 1.36.x by the
  Helm 4.2 n-3 window recorded 2026-09-05, *not* by what k3d defaults to — k3d 5.9.0
  would otherwise pick v1.35.5-k3s1, which is inside the window but not deliberate.
  1.37.0 is current stable and is above the ceiling.
- `library/registry` **2.8.3**, index digest `sha256:a3d8aaa6…`. k3d's default is the
  floating tag `registry:2`; this is byte-identical to it today, but pinned. Left as a
  floating tag it would have been the only mutable reference in the lab.

Both verified multi-arch (`linux/amd64` + `linux/arm64`) before pinning.

---

## 2026-09-12 — Push registry on host port 5005, not 5000

**Decision.** The push registry publishes on host port **5005**. The four pull-through
caches keep 5001–5004 as the build plan specifies.

**Why.** On macOS, port 5000 is held by Control Center (AirPlay Receiver). Verified on
this machine — `lsof -iTCP:5000` shows `ControlCe` listening. `k3d registry create
--port 5000` would fail to bind.

**Why this changes nothing structurally.** The `--port` flag sets only the *host*-side
publish port. Inside the `gitops-lab` Docker network the registry always listens on 5000,
so `k3d-registry:5000` — the address used by `clusters/registries.yaml`, by image
references in manifests, and by the OCI chart repo in Phase 2 — is unaffected. The only
thing that moves is `docker push localhost:5005/...` from the host.

**Alternative rejected.** Turning off AirPlay Receiver in System Settings would free 5000,
but that is an undocumented change to the operator's machine that a future rebuild on a
different Mac would silently need. Moving the port is in git.

---

## 2026-09-12 — Branch protection requires 0 approving reviews, not 1

**Decision.** `task repos:protect` sets `required_approving_review_count: 0` and
`require_last_push_approval: false`, deviating from BUILD-PLAN Phase 3, which specifies
1 approving review and approval from someone other than the last pusher.

**Why.** `bo-jr` is the sole collaborator on all seven repos — verified, not assumed —
and **GitHub does not permit approving your own pull request**. With 1 required approval,
no PR could ever be merged except by admin bypass. That is strictly worse than the
private-repo failure the build plan rejects: there the rules are silently unenforced,
here they would be enforced into a deadlock whose only escape is a bypass used on every
single merge, making the bypass the normal path and the gate decoration.

**What the gate still is at 0.** A pull request is still required to modify `main`;
force-push (`non_fast_forward`) and branch deletion are blocked; stale reviews are
dismissed on push; and required status checks — including the dev-health check of
Phase 3 — must pass before merge. The merge remains a deliberate human action. What is
lost is only *second-person* review, which a solo account cannot provide under any
configuration.

**Revisit when:** a second human has write access, or a bot identity opens promotion PRs
so that `bo-jr` approving them is genuinely a second party. The latter is the more likely
path — `cmd/promoter` already authenticates as a separate fine-grained PAT, and a GitHub
App identity (noted in Phase 3 as better hygiene, and free if Phase 9 adopts Kargo) would
make `require_last_push_approval: true` meaningful.

**Not applied yet.** The ruleset has been written but deliberately not pushed to GitHub —
that is an outward-facing change to seven live repos and wants an explicit go-ahead.
`task repos:protect:show` reports the current state (all seven at 0 rulesets).

---

## 2026-09-12 — Docker Hub anonymous limit is 100/hr, not 10/hr

**Correction, not a decision.** BUILD-PLAN §5 states unauthenticated Docker Hub pulls are
"limited to roughly 10/hour per IP" and builds the case for mandatory pull-through caches
on that number. Measured from this machine on 2026-09-12:

```
x-ratelimit-limit:       100;w=3600
x-ratelimit-remaining:    99;w=3600
docker-ratelimit-source: <this IP>   → IP-based, i.e. anonymous
```

**100 pulls/hour anonymous.** The 10/hr figure is stale. Use `HEAD` to check, since a
`GET` on a manifest counts as a pull and a `HEAD` does not:

```bash
TOK=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | jq -r .token)
curl -s -I -H "Authorization: Bearer $TOK" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest | grep -i ratelimit
```

**The caches stay mandatory anyway, for a better reason than the plan gives.** Measured
during Phase 0: rebuilding `dev` took 27s and moved `ratelimit-remaining` by **zero** —
the cache served every layer and Docker Hub was never contacted. That is the property
worth having. Phase 8 requires two consecutive full rebuilds inside 20 minutes, and the
binding constraint there is latency, not a quota.

**Also worth knowing:** the lab's Docker Hub surface is much smaller than it looks,
because BUILD-PLAN §5 deliberately sources most components elsewhere. Read out of the
k3s binary rather than guessed, a cluster pulls exactly:

```
rancher/mirrored-pause              rancher/local-path-provisioner
rancher/mirrored-coredns-coredns    rancher/klipper-lb
rancher/mirrored-metrics-server     rancher/mirrored-library-busybox
```

plus `rancher/k3s` and `library/registry`, which are pulled by the **host Docker daemon**,
not by cluster containerd — the two stores are separate, so pre-pulling those on the host
helps while pre-pulling the others does not. The only remaining Docker Hub images are the
Grafana stack in Phase 4 (`grafana/{grafana,loki,tempo,alloy,k6}`). Everything else comes
from quay.io, ghcr.io, registry.k8s.io or gcr.io.
