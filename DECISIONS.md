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

---

## 2026-09-12 — One machine: macOS only, Windows/WSL2 dropped

**Decision.** Supersedes the 2026-09-05 entry "The Windows machine does not host the lab"
and closes out BUILD-PLAN §2a. The lab targets **macOS / `darwin/arm64` only**. Windows 11
and WSL2 are no longer a supported host, and the two-machine framing is removed from
`CLAUDE.md`, `SETUP.md`, `README.md` and both scripts.

**Why.** Operator decision — the MacBook is where this actually runs. The Windows box was
already barred from hosting the clusters (31GB host, WSL2 capped at 8GB), so it only ever
built and authored CI, and CI itself runs on GitHub-hosted runners. It was carrying
documentation and code paths for a role nothing depended on.

**What was removed.** The `.wslconfig` memory section, the `/mnt/c/` prohibition, the
`Toolchain (Windows/WSL2)` status row, the two-installer table in SETUP.md §3, and every
"both machines" phrasing.

**What was deliberately KEPT, and why it is not vestigial.**

- **Multi-arch image builds (`linux/amd64,linux/arm64`).**
- **Manifest-list index digests, never per-arch digests.**
- **LF line endings** via `.gitattributes`.
- **The Linux install path** in `scripts/bootstrap-toolchain.sh`.

The reason these survive is that the architecture boundary did not disappear with the
Windows box — it moved. **GitHub Actions runners are `linux/amd64`; every cluster here is
`arm64`.** BUILD-PLAN §3 builds services on a runner matrix and runs `kyverno apply`
against rendered manifests in CI, so anything CI produces or validates crosses amd64 →
arm64 on its way into the lab. A per-arch digest pinned from a CI run would pass there and
fail `no match for platform` on every cluster. LF endings matter for the same reason:
scripts are copied into Linux images regardless of what edits them.

So the rule stays, with a corrected rationale. `CLAUDE.md`'s "Cross-platform, always"
section is now "Architecture discipline" and states the CI-vs-lab boundary explicitly
rather than the machine-vs-machine one.

**Consequence.** `BUILD-PLAN.md` §2, §2a and the Phase 0 acceptance line "`task up`
succeeds on both machines" are now historical. The plan is not edited — see the header of
this file — so read §2a as superseded by this entry.

**Revisit if:** a Linux host ever joins. The install path is still there and the pin list
is unchanged, so that is a documentation change rather than an engineering one.

---

## 2026-09-12 — Argo CD is pinned by chart version, not image digest

*Decided in PR #3 (`762831b`); recorded 2026-09-29. `platform/argocd-values.yaml`
pointed here before this entry existed.*

**Decision.** Argo CD is installed from `argo-cd` chart **10.9.0**, which selects app
version **v3.5.2**. `global.image.tag` is left empty so the chart's `appVersion` applies.
No image digest is set. This is the one image in the lab that is not pinned by digest.

**Why.** The chart composes image references as `repository:tag` and appends the tag
unconditionally. Setting `repository` to `quay.io/argoproj/argocd@sha256:…` renders
`…@sha256:…:v3.5.2`, which is not a valid reference. Setting `tag: ""` does not omit the
tag; it falls back to `appVersion`. The chart has no field that can express a digest,
so the exact chart version is the tightest pin available without forking the chart.

**Why this does not collide with Phase 7.** The digest-only Kyverno policy runs per-spoke
(BUILD-PLAN §3). Argo CD runs only in `mgmt`, where no admission policy applies.

**Revisit if:** the chart gains a digest field, or Phase 9b's argocd-agent charts move
Argo CD components onto the spokes.

---

## 2026-09-12 — Argo CD reads git anonymously; no git credential at bootstrap

*Decided in PR #3 (`762831b`); recorded 2026-09-29.*

**Decision.** Argo CD is given no repository credential. It reads `bo-platform` and
`bo-deploy` over anonymous HTTPS. This departs from BUILD-PLAN §6, which lists the Argo CD
git credential as one of the two bootstrap-time inputs.

**Why.** All seven repos are public, which is required for free branch protection
(BUILD-PLAN §4), so anonymous read works. A credential that grants nothing beyond
anonymous access is one more secret to seed and rotate for no gain.

**Consequence.** The `argocd-git-credential` item stays in the 1Password vault, unused.
`cmd/promoter`'s token (`promoter-github-pat`) is unaffected: it *writes*, and writing
always needs a credential. `bootstrap.sh` therefore has exactly one bootstrap-time secret
input left to handle later, the OpenBao seed (Phase 7).

**Revisit if:** any repo Argo CD reads goes private, or GitHub starts throttling anonymous
clones from this IP.

---

## 2026-09-12 — `argocd` CLI is the tenth pinned host tool

*Decided in PR #3 (`762831b`); recorded 2026-09-29.*

**Decision.** `argocd` **v3.5.2** joins the pin list in `scripts/bootstrap-toolchain.sh`,
installed by Homebrew and frozen with `brew pin` like the other nine.

**Why.** It was added for `argocd cluster add`, and CLAUDE.md forbids tools outside the
pin list. Registration no longer uses it (see the 2026-09-29 entry below), but it stays
pinned. It is still how you inspect what Argo CD sees without the UI, e.g.
`argocd cluster list --core` and `argocd app diff`. The CLI version must **track the Argo CD
server exactly**, so a bump of the Argo CD chart is also a pin-list edit.

---

## 2026-09-29 — Spokes are registered with a declarative Secret, not `argocd cluster add`

**Decision.** `scripts/register-spokes.sh` registers `dev` and `prod` with plain `kubectl`.
It applies `clusters/argocd-manager.yaml` (ServiceAccount, cluster-admin role and binding,
empty token Secret) to each spoke, then writes a `cluster-<env>` Secret into `mgmt`. That
Secret carries server `https://k3d-<env>-server-0:6443`, label `env=<env>`, and the
ServiceAccount's bearer token plus CA. BUILD-PLAN §4 describes the script as "cluster add
+ server URL override + labels". This is the same outcome by a different mechanism.

**Why.** Tried against the pinned argocd v3.5.2, `argocd cluster add` fell short twice:

1. **It cannot set the server URL.** `--cluster-endpoint` accepts only `kubeconfig`,
   `kube-public` or `internal`, and the kubeconfig says `https://0.0.0.0:<port>`. The only
   route to the in-network name is patching the Secret afterwards. The Secret's name is
   derived from the *host* URL, so a later `--upsert` works against the patch.
2. **In `--core` mode it stored the spoke's admin client certificate and key**, copied from
   the kubeconfig, instead of `argocd-manager`'s token. It created the ServiceAccount and
   then did not use it. Argo CD would have acted in each spoke as the k3s admin.

The declarative Secret is the form Argo CD itself documents for declarative setup. It also
gives stable names (`cluster-dev`, not `cluster-0.0.0.0-2641646974`), and re-runs are no-ops.

**Credentials stay out of git.** `clusters/argocd-manager.yaml` holds no secret material;
Kubernetes issues the token inside the spoke. The script streams it from the spoke through
`jq` into a server-side apply in `mgmt`, so it never lands in a file, a shell variable, argv
or the repo. Server-side apply matters here: client-side `kubectl apply` would copy the
whole Secret, token included, into a `last-applied-configuration` annotation.

**Verified.** The spoke API certificates already list `k3d-<env>-server-0` as a SAN, so TLS
is verified (`insecure: false`). No SAN override was needed.

**Revisit at:** Phase 9b. argocd-agent removes hub-to-spoke connections, and this script
with them.

---

## 2026-09-29 — `bootstrap.sh` does not create clusters; `task up` does

**Decision.** `scripts/bootstrap.sh` installs Argo CD in `mgmt` and applies the root app,
nothing else. The network, caches, push registry and clusters stay in `Taskfile.yml`, where
Phase 0 put them. `task up` runs them in order, then `bootstrap` and then `register`.
BUILD-PLAN §4 annotates `bootstrap.sh` as "creates clusters, installs ONLY Argo CD".

**Why.** The cluster steps already exist as idempotent, individually runnable tasks and were
verified in Phase 0. Moving them into `bootstrap.sh` would spend its ~30-line budget on
infrastructure that `lint-bootstrap.sh` does not police anyway. The script's line count
should measure one thing: how much is installed outside git.

---

## 2026-09-29 — Sync waves do not order ApplicationSet-generated Applications

**Reality check, not yet a decision.** BUILD-PLAN Phase 1 assigns sync waves across
components: 0 = CRDs + cert-manager, 1 = istiod + ztunnel, 2 = platform, 3 = gateways +
waypoints, 4 = apps. An `argocd.argoproj.io/sync-wave` annotation orders resources *within*
one sync. The platform Applications are generated by an ApplicationSet, which creates all of
them at once. No parent sync walks them in wave order, so the annotation would sit on the
generated Applications and do nothing.

**What is in place.** Each entry in `platform/<env>/versions.yaml` carries `wave`, and the
ApplicationSet stamps it on the generated Application as a **label**. It is not an
annotation that would look like it works. Phase 1 has a single component, so nothing needs
ordering yet.

**What will need deciding** when the second wave arrives (istiod, Phase 5, which needs
Gateway API CRDs first): either ApplicationSet **progressive syncs** (`RollingSync` steps
keyed on the `wave` label, enabled in `platform/argocd-values.yaml`), or rely on
self-heal retries until the dependencies exist. Progressive sync is configuration of a
component already installed, not a new one. Decide then, with the real failure in front of you.

---

## 2026-09-29 — Phase 2 acceptance: trace propagation is proven in logs, Tempo moves to Phase 4

**Decision.** BUILD-PLAN Phase 2's criterion "one request produces a single trace in Tempo
spanning all three" is amended for Phase 2:

- **Trace propagation** is proven by finding the **same `trace_id`** in the JSON logs of
  `storefront`, `catalog` and `pricing` for one request.
- **Error rate** is read from the `/metrics` counters directly
  (`http_requests_total{status="500"}` over the total).
- The **"single trace in Tempo"** check moves into **Phase 4's acceptance**, next to the
  Grafana correlation check it naturally belongs with.

**Why.** Tempo, Alloy and Prometheus arrive in Phase 4. Pulling them forward would break
one-phase-per-session and land observability components before their retention and
sizing are designed. The property Phase 2 owns is *propagation* — that `traceparent`
crosses both hops — and a shared `trace_id` in three services' logs proves exactly that.

**Constraint that comes with it.** The OTLP exporter must never block a request, crash a
service, or fail `/readyz` when no collector is listening. `bo-service-kit` therefore
always runs a real SDK TracerProvider (so trace IDs exist with no exporter at all) and
attaches the OTLP exporter only when `OTEL_EXPORTER_OTLP_ENDPOINT` is set, behind an
async, bounded batch processor. Phase 2 verifies this in `sandbox` against a dead endpoint.

---

## 2026-09-29 — One Go module per service repo; `~/git/go.work` is local only

**Decision.** BUILD-PLAN §3 says "one module, three binaries, one multi-stage Dockerfile
with a build arg". §4's seven-repo layout — which exists — wins:

- Each service repo is its own module (`github.com/bo-jr/bo-<service>`) and imports
  `github.com/bo-jr/bo-service-kit` at a **tagged** version.
- One Dockerfile per service repo, not one shared Dockerfile with a build arg.
- A workspace at **`~/git/go.work`** spans the kit and the three services, so local builds
  resolve against working trees. It is **never committed**; `go.work` and `go.work.sum`
  are gitignored in all four repos as a guard.

**Why.** §4 is the more specific and the more recent choice, and the repos are already
created. The workspace gives back the inner-loop speed a monorepo would have had, while
Docker and CI (whose build context holds only one repo) resolve against tags — so a
passing local build never depends on unpublished kit code without it being obvious.

**Tags are immutable.** The kit is public, so the first fetch of a tag records its hash in
`sum.golang.org`. A tag is never moved; a fix is a new patch version.

**Side effect, accepted.** `~/git/gocroservices` has its own `go.mod` and sits under the
workspace, so `go` commands there now fail unless run with `GOWORK=off`. The operator is
archiving that repo; it does not constrain this layout.

---

## 2026-09-29 — The shared chart is published to ghcr.io, not the local registry

**Decision.** `bo-service-chart` is published as **`oci://ghcr.io/bo-jr/charts/service`**,
not BUILD-PLAN's `oci://k3d-registry:5000/charts/service`. Each service pins it by exact
version in a top-level `chartVersion:` field of its `chart-values.yaml`; the chart refuses
to render if that field disagrees with its own `Chart.yaml` version.

**Why.** Phase 3's GitHub Actions render manifests with `helm template`, and hosted
runners cannot reach a registry on this laptop. Publishing locally now would mean
re-publishing and re-pinning all three services in Phase 3. ghcr.io is also where the
service images go, and the `ghcr` pull-through cache already fronts it.

**How it is pushed (Phase 2).** From the laptop, with `gh`'s token given the
`write:packages` scope (`gh auth refresh -s write:packages` — it had only
`gist, read:org, repo, workflow`). Login is host-only (`helm registry login ghcr.io`) with
the token on **stdin**, never argv, followed by `helm registry logout` after the push.

**Visibility.** ghcr creates a new personal-account package as **private**. The operator
switches `charts/service` to public after the first push, so CI and anonymous pulls work.
That is a one-way change on GitHub's side, and it matches the "all public" premise of §4.

---

## 2026-09-29 — Before CI exists, services reach dev through the unmanaged `sandbox` namespace

**Decision.** In Phase 2 the services are rendered with `helm template` (the published,
pinned chart plus each repo's `chart-values.yaml`) and piped to `kubectl apply` in the
**`sandbox`** namespace of `dev`. `task sandbox` creates the namespace idempotently; no
Argo CD Application targets it. Images are built locally, pushed to the push registry, and
referenced by the index digest the push returns. Argo CD starts managing the services in
Phase 3, from `bo-deploy/rendered/dev/`.

**Why.** CI writes `bo-deploy`, and `bo-deploy` is never hand-edited, so there is nothing
legitimate for Argo CD to sync until Phase 3. `helm upgrade --install` was declined: the
Helm CLI never owns a release lifecycle in this lab (2026-09-05), and `helm template` is
the same render path CI will use.

---

## 2026-09-29 — The service chart grows with the platform; no CRD-backed kinds in Phase 2

**Decision.** `HTTPRoute`, `AuthorizationPolicy` and `ServiceMonitor` need CRDs that
arrive in later phases, and applying them without their CRDs fails. The chart therefore
ships each template **in the phase that installs its CRD**, added for every service at
once, as a chart minor version:

| Chart adds | Phase | CRD source |
|---|---|---|
| Deployment, Service, ServiceAccount | 2 | core |
| ServiceMonitor | 4 | Prometheus Operator |
| HTTPRoute, AuthorizationPolicy | 5 | Gateway API, Istio |
| Rollout (`workload: Rollout`) | 6 | Argo Rollouts |

In Phase 2 `values.schema.json` allows `workload: Deployment` only; Phase 6 widens the enum
and adds the Rollout branch, so services never change the shape of their values.

**Why.** It adds no conditionals and installs nothing early. The alternative — installing
CRDs-only components (Gateway API, Istio `base`, `prometheus-operator-crds`) in dev now —
would have needed an ApplicationSet `templatePatch` for Gateway API's raw-YAML release and
left inert CRs waiting for controllers. The cost accepted here is 2–3 extra chart releases
and a re-pin in each service per release.

**Rejected outright: `.Capabilities.APIVersions.Has`.** It is a hidden per-feature
conditional, and CI's `helm template` has no cluster to ask, so dev and CI would render
different manifests — the drift rendered manifests exist to remove.

---

## 2026-09-29 — CloudNativePG: operator in the platform, `Cluster` in bo-platform, schema in the binary

**Decision.**

- **Operator.** `cloudnative-pg` chart **0.29.1** (operator **1.30.1**, officially
  supporting Kubernetes 1.34–1.36) as a platform component through
  `platform/dev/versions.yaml`, promoted to prod by its own PR.
- **`Cluster` CR** for `catalog` lives in **bo-platform** at `databases/<env>/catalog.yaml`,
  namespace-less. In Phase 2 it is applied by hand to `sandbox`; Argo CD wiring comes in
  Phase 3.
- **Schema and the ~50 seed rows** are **embedded SQL migrations in the catalog binary**,
  applied at startup under a Postgres advisory lock, idempotent. Not CNPG's
  `postInitApplicationSQL`, which runs once at cluster creation and could not carry the
  scenario 5 schema change.
- **Credentials** come from the `catalog-db-app` Secret CNPG generates, via `secretKeyRef`,
  until Phase 7 moves them to OpenBao via ESO. The reference stays the same; only the
  Secret's author changes.

**Why the `Cluster` is not in the shared chart or in `bo-catalog`.** With schema in the
binary, scenario 5's atomicity comes from the **image digest** — expand, migrate and
read-both all ship inside catalog v2 and promote in the same `bo-deploy` PR as storefront —
so the `Cluster` gains nothing by riding the release. What it would gain is risk: inside
the app's Argo CD prune scope, a chart bug or a `git revert` of a release can delete the
`Cluster`, and its PVCs are garbage-collected with it. The shared-chart option also needed
a second conditional, and `bo-catalog` would have broken "source only". The cost of this
choice is a naming contract — catalog refers to `catalog-db-app` by name — carried by a
generic `secretEnv` list in the chart, which Phase 7's ESO Secrets use too.

**Known, not specific to this choice.** On a cold rebuild (Phase 8), whatever Argo CD app
holds the `Cluster` races the CNPG CRDs. The same gap would exist in any location; it is
Phase 3's to solve alongside the 2026-09-29 sync-wave entry.

**Reality check — the chart has no digest field.** It composes `repository:tag`, like the
Argo CD chart (2026-09-12). Unlike that one, `image.tag` is used only in `image:` and in
`OPERATOR_IMAGE_NAME`, never in a label, so `tag: "1.30.1@sha256:<index>"` renders a valid,
digest-pinned reference, and the bootstrap image the operator injects into Postgres pods
inherits the pin. The operand image is pinned through `config.data.POSTGRES_IMAGE_NAME` and
again in the `Cluster`'s `imageName`.

---

## 2026-09-29 — Service images build on Chainguard `go` and `static`, pinned by index digest

**Decision.** Every service Dockerfile uses:

| Stage | Image | Index digest | Verified |
|---|---|---|---|
| build | `cgr.dev/chainguard/go` | `sha256:437e77100bb4ed52e039d6430d4a97a7ec55404abbd7ec3ef968b9e499bbda49` | **go1.27.1** (`go-1.27=1.27.1-r0`, from its SPDX attestation); amd64 + arm64 |
| runtime | `cgr.dev/chainguard/static` | `sha256:41e17ed83c594a64a9396b6ab96dd26d5ddc290dacf4c177464712ff21ad534f` | amd64 + arm64 |

The build stage runs on `$BUILDPLATFORM` and cross-compiles with `GOOS`/`GOARCH` and
`CGO_ENABLED=0`, so neither architecture needs QEMU. It sets **`GOTOOLCHAIN=local`**:
the image defaults to `local+auto`, which would silently download a newer toolchain if a
`go.mod` ever asked for one. With `local`, a mismatch against the pinned go1.27.1 fails.

**Why.** BUILD-PLAN §5 names `cgr.dev`. The free tier publishes `:latest` only, which is
fine because the lab never references a tag — only the digest.

**Risk, accepted.** Chainguard's free `:latest` moves daily. If an old digest is ever
garbage-collected upstream, rebuilding an old commit fails; refreshing the pin is a
deliberate edit, like any other version bump.

---

## 2026-09-29 — Sibling repo docs refreshed before Phase 2 code

**Decision.** The six sibling `CLAUDE.md` files are corrected in six docs-only PRs, one per
repo, before any Phase 2 code lands:

- `docs/BUILD-PLAN.md` / `docs/DECISIONS.md` → repo root; `~/gitops-lab/` → `~/git/`.
- Windows/WSL2 "cross-platform" framing removed. Multi-arch builds, index digests and LF
  endings are kept and explained by the CI-`amd64` vs lab-`arm64` boundary, as in
  `bo-platform/CLAUDE.md` (2026-09-12).
- `bo-deploy`: 0 required approvals, per 2026-09-12.
- Today's outcomes where the old text had become wrong: the chart lives on ghcr.io, and
  catalog's Postgres credentials come from the CNPG `-app` Secret until Phase 7.

**Why.** Those files are what a session in each repo reads first. Left stale, they would
have sent Phase 2 code to the wrong paths and the wrong registry.

---

## 2026-09-29 — Local multi-arch images build on a pinned BuildKit builder container

**Reality check.** Docker Desktop here runs the **classic image store** (`overlay2`), and
its buildx builders use the `docker` driver, which **cannot produce a multi-platform
image**. Switching Docker Desktop to the containerd store was rejected: it hides existing
images and containers, including the running k3d nodes and registries.

**Decision.** `task builder` creates a buildx **`docker-container`** builder named
`gitops-lab`, idempotently:

- image `moby/buildkit:v0.33.0` pinned by index digest
  `sha256:6c2fa84a6b61ccd72899dde4239f8d5717f05f9a8ca6f3cad185fb1a95a94de3`
  (amd64 + arm64), held in `Taskfile.yml` `vars:` — version authority #4;
- attached to the `gitops-lab` network, with `clusters/buildkitd.toml` marking
  `k3d-registry:5000` as plain HTTP;
- pushing **by digest** (`push-by-digest=true`) straight to `k3d-registry:5000/bo-<svc>`,
  so the pushed reference is byte-for-byte the one the cluster pulls, and no tag is
  created in the registry at all.

**Why this is not a new component.** BuildKit is already in BUILD-PLAN §3 ("Build and
packaging"). It runs on the host, not in any cluster, and it is rootful here; rootless
BuildKit is a CI concern for Phase 3.

---

## 2026-09-29 — Helm 4 prints OCI pull status on stdout; always render from a pulled archive

**Reality check.** Helm 4.2.4's `helm template <name> oci://… --version X` writes two
status lines to **stdout**, ahead of the manifests:

```
Pulled: ghcr.io/bo-jr/charts/service:0.1.0
Digest: sha256:9fb2525198b84e8b4688fbb6dc81fb09debb428ca7c5017bd36b9747f87f3392
```

There is no flag to silence them. Piped into `kubectl apply`, they parse as the first YAML
document and the apply fails with `apiVersion not set, kind not set` — which is how the
first `task sandbox:deploy` failed.

**Decision.** Never `helm template` an OCI reference directly. `helm pull` the pinned
version into a temporary directory, discarding its output, then `helm template` the local
archive. `task sandbox:deploy` does exactly this.

**Consequence for Phase 3 — the one that matters.** CI renders into `bo-deploy/rendered/`
the same way. There the failure would be quieter and worse than an apply error: two
non-YAML lines committed into every rendered manifest, and into every promotion diff. The
reusable workflow must pull first as well. Pulling first also gives CI a natural place to
assert the chart's digest before rendering.

**The 2026-09-05 revisit condition, answered.** That entry said to revisit Helm 4 "if the
OCI publish flow in Phase 2 misbehaves". The *publish* flow did not: a host-only
`helm registry login ghcr.io` with the token on stdin stored the credential in the macOS
keychain (`credsStore`; `auths` stayed empty), `helm push` succeeded, and
`helm registry logout` removed it. Only the consume side needed this change.

---

## 2026-09-30 — Phase 3 is CI → dev; the promoter is a separate slice after Phase 7

**Decision.** Phase 3 delivers: push to `main` in a service repo → test + policy → a
multi-arch image on ghcr, pinned by index digest, signed and with GitHub build provenance →
a rolling dev PR in `bo-deploy` → auto-merge on a required check → Argo CD syncs dev.

`cmd/promoter`, the prod PR, the dev-health status check and the prod branch-protection
check become **a separately accepted slice after Phase 7**, built as BUILD-PLAN specifies.

**Why.** The promoter reads the live dev **Rollout** (Phase 6) and takes its GitHub token
from OpenBao via ESO (Phase 7). Building it now against Deployments and a stop-gap Secret
would mean building it twice.

**Decided now, built later: dev-health is a commit status the promoter maintains.**
BUILD-PLAN asks for a check that "re-queries dev health at merge time". A GitHub-hosted
runner cannot reach this laptop, so no Actions job can ask dev anything. The in-cluster
reconciler can: on every run it sets a `dev-health` commit status on each open prod PR's
head, from what it just read. That is level-triggered like everything else it does, and
the required check on the prod branch is that status.

**Consequence.** The dev GitHub Deployment is created `in_progress` when the dev PR merges
and stays there. "Merged into bo-deploy" is not "healthy in dev", and only the promoter can
tell the difference, so it closes the deployment.

---

## 2026-09-30 — The reusable workflows live in bo-platform, called by commit SHA

**Decision.** Two reusable workflows in `bo-platform/.github/workflows/`:

- `service-ci.yml`, called by the three service repos;
- `deploy-validate.yml`, called by `bo-deploy`.

Every caller pins them by 40-hex commit SHA, never by branch or tag. Each checks out
bo-platform at **`job.workflow_sha`**, so the toolchain script, the policies, the render
script and the BuildKit pin it uses come from the same commit as the workflow. One SHA in
the caller pins all of it.

**Why bo-platform.** It is the only repo whose job is to change things for every service,
and it already owns the pins these workflows consume. The cosign certificate identity then
names bo-platform's workflow (`…/bo-platform/.github/workflows/service-ci.yml@<sha>`). That
is exactly what Phase 7's attestation policy asserts, and what `validate` already checks.
`bo-service-chart` would have mixed a chart pin (semver) with a CI pin (SHA) in one repo.
Three copies would have drifted, and would have given Phase 7 three signer identities to
trust.

**Known gap, not changed here.** bo-platform has no ruleset (`task repos:protect:show`), so
the CI for every service sits in the one unprotected repo. SHA pinning bounds the damage:
nothing reaches a service until its caller is re-pinned by a reviewed PR. Protecting
bo-platform is the operator's call.

---

## 2026-09-30 — bo-deploy is written by a fine-grained PAT, `ci-deploy-pat`

**Decision.** Service CI writes `bo-deploy` with a fine-grained PAT that has repository access
to `bo-deploy` only, with **Contents: read and write** and **Pull requests: read and write**.
It lives in 1Password as `ci-deploy-pat` and reaches the three service repos as the Actions
secret `BO_DEPLOY_TOKEN`, set by the operator with `gh secret set` reading stdin. It is a
separate item from `promoter-github-pat`, so the two revoke independently.

`GITHUB_TOKEN` cannot push to another repository. A GitHub App was the alternative: a
distinct `[bot]` identity, and short-lived tokens via `actions/create-github-app-token`.
It was declined for now. It adds App setup, and the long-lived secret becomes its private
key. It remains the route to making a required review meaningful (2026-09-12).

**Stated plainly.** With 0 required reviews, anything holding this token can open *and
merge* a PR that changes `rendered/prod/`. That is true of any identity until the prod gate
exists. `validate` currently refuses any `rendered/` change that is not a `dev/<svc>`
branch writing its own directory, which closes the obvious path.

---

## 2026-09-30 — bo-deploy requires a `validate` check; without one, auto-merge merges at once

**Reality check.** `gh pr merge --auto` merges **immediately** when the PR's merge state is
`CLEAN` or `UNSTABLE`, read in gh's source (`isImmediatelyMergeable`). With 0 reviews and
no required check, a dev PR is `CLEAN` the moment it opens. So "auto-merge when checks
pass" gates nothing, and a *failing* optional check (`UNSTABLE`) doesn't stop it either.

**Decision.** `bo-deploy` runs `deploy-validate.yml` on every PR. A second ruleset,
`deploy-checks`, applies to bo-deploy only and makes its check run `validate / rendered`
required, bound to the GitHub Actions app (integration 15368) so a hand-posted status
cannot satisfy it. `task repos:protect:deploy-checks` applies it. It is kept apart from
`main-protection`, because a required check on a repo that never runs it blocks every
merge, and apart from `task repos:protect`, which would also start protecting bo-platform.

It checks five things:

- only CI's `dev/<svc>` branch writes `rendered/`, and only `rendered/dev/<svc>/`;
- Kyverno passes on every rendered manifest;
- every changed image resolves **anonymously**, as an OCI index of exactly
  linux/amd64 + linux/arm64;
- every changed image is cosign-signed by bo-platform's `service-ci.yml`, called by SHA,
  from the image's own repo;
- every workload carries a well-formed commit timestamp.

This supersedes "the dev-health check" that bo-deploy's CLAUDE.md listed as Phase 3's
required check. That check moves to the promoter slice (above).

---

## 2026-09-30 — Kyverno CLI v1.19.1 is the eleventh pinned host tool; policies are `ValidatingPolicy`

**Decision.** `kyverno` **v1.19.1** joins the pin list in `scripts/bootstrap-toolchain.sh`.
On the Mac, brew installs it and `brew pin` freezes it, like the other ten; brew stable
was exactly 1.19.1. CI installs it on the Linux path. Once the admission controller
arrives in Phase 7, the CLI pin **must track its version**, the way `argocd` tracks the
Argo CD server.

The three policies in `policies/` are **`ValidatingPolicy`, `policies.kyverno.io/v1`
(CEL)**:

- `require-image-digest`
- `disallow-floating-tags`, which also rejects a floating tag beside a digest, and a bare
  name (implicit `:latest`)
- `require-requests-limits`, all four values on every container and init container

Test cases live in `test/policies/` (`task policies:test`, 27 decisions).

**Reality check.** Kyverno **1.19 deprecated `ClusterPolicy`**, and 1.20 removes it. The
plan predates that; writing ClusterPolicies now would mean rewriting them in Phase 7.

**Why a host tool and not CI-only.** Phase 7 requires that both admission failures
"reproduce in CI first". Being able to run the identical check on the laptop
(`task policies:check -- <file>`) is the cheap half of that.

---

## 2026-09-30 — `kyverno apply <dir>` silently applies nothing if the directory holds a non-policy YAML

**Reality check, found writing the policies.** Given a directory, `kyverno apply` recurses.
One file it cannot parse as a policy, here the `Test` manifest of the test cases, makes it
**skip the entire directory**. It logs that only at `-v 3`, applies zero policies, and
**exits 0** on a render that violates all three. A CI gate built on
`kyverno apply policies/` would have passed everything, forever.

**Decision.**

- Test cases live in `test/policies/`, not under `policies/`.
- Nothing calls `kyverno apply` directly. `scripts/policy-check.sh` passes each policy
  file explicitly and **fails unless every policy produced at least one result**. A check
  that evaluated nothing can therefore never read as green.
- Service CI, bo-deploy's `validate` and `task policies:check` all use that script.

---

## 2026-09-30 — CI installs its tools through `bootstrap-toolchain.sh`, checksum-verified; actions are first-party, by SHA

**Decision.**

- **The Linux path of `bootstrap-toolchain.sh` is how runners get tools.** It gains
  `--only "<tools>"`, so a job installs only what it uses. It also gains sha256
  verification of every download against the checksum file its upstream publishes;
  a mismatch installs nothing. It ends by running `--verify` on what it installed.
  Tested in a digest-pinned `ubuntu:24.04` on linux/arm64 (all eleven) and linux/amd64
  (the CI subset), plus a swapped checksum that correctly failed.
- **Actions: first-party only, pinned by full commit SHA** with the version in a comment:
  `actions/checkout` v7.0.1, `actions/attest` v4.2.2, `actions/upload-artifact` v7.0.1
  and `actions/download-artifact` v8.0.1. All are node24, so they run the same on both
  runner architectures. Everything else is plain shell.
- **`actions/attest`, not `actions/attest-build-provenance`**, which BUILD-PLAN §3 names.
  As of v4 the latter is a thin wrapper around `actions/attest`, and its README says new
  work should use `actions/attest`. The predicate is the same SLSA build provenance.
  `create-storage-record: false`, so no `artifact-metadata` permission is needed.

**Cost, stated.** The script was already 178 lines, past the ~150 boundary set for it
(2026-09-05). This adds a subset flag and a checksum helper. It also removes the
macOS asset-name variables (`OS_ALT`, `GH_OS`, `GH_EXT`, 2026-09-07) from the Linux
path; they were dead code once Homebrew took over macOS.

**Unpinnable, noted.** The runner images (`ubuntu-24.04`, `ubuntu-24.04-arm`) and the
docker/buildx *client* on them move weekly. What they build with is pinned: the BuildKit
daemon image and every tool above.

---

## 2026-09-30 — CI builds on rootful, pinned BuildKit with no remote cache

**Decision.**

- Each architecture builds on its own native runner (`ubuntu-24.04`, `ubuntu-24.04-arm`).
- The builder is a buildx `docker-container` on the **same `moby/buildkit` v0.33.0 index
  digest as `task builder`**. The workflow reads it from `Taskfile.yml` `vars`, the one
  authority.
- Builds run with `--provenance=false --sbom=false` and `oci-mediatypes=true`. Each leg
  pushes one plain image manifest by digest.
- Each leg then runs the image it pushed, on its own architecture, and requires `/healthz`
  to answer 200.

BUILD-PLAN §3 says "BuildKit (rootless, registry-backed cache)". Both parts are declined:

- **No remote cache.** The Dockerfiles keep the Go module and build caches in
  `--mount=type=cache`, which no cache backend exports. A layer cache would restore
  `go mod download` as an empty layer, and `go build` would still run cold on every new
  commit. It would only help a rebuild of an identical commit. A registry cache is also a
  mutable tag, the one floating reference the lab would then have.
- **Rootful.** Rootless BuildKit on ubuntu-24.04 needs AppArmor's restriction on
  unprivileged user namespaces relaxed (`sudo sysctl
  kernel.apparmor_restrict_unprivileged_userns=0`). That means weakening a host control
  to run a "safer" daemon, on a throwaway VM where the job already has passwordless sudo.

**Why BuildKit's own provenance is off.** Provenance comes from GitHub
(`actions/attest`), signed against the workflow's OIDC identity. Leaving BuildKit's on
would make each per-arch push a one-entry index with an attestation manifest. The merged
index would then carry `unknown/unknown` entries, as the local sandbox builds do.

---

## 2026-09-30 — The image index is pushed by digest; no tag exists

**Reality check.** `docker buildx imagetools create` refuses to push without a tag
(verified: "can't push with no tags specified, please set --tag or --dry-run").

**Decision.** The publish job runs `imagetools create --dry-run` over the two per-arch
digests, which prints the index. It takes the sha256 of those bytes, `PUT`s them to
`/v2/bo-jr/bo-<svc>/manifests/sha256:<that>` with curl, reads them back by digest, and
requires identical bytes and exactly linux/amd64 + linux/arm64. The ghcr bearer token
reaches curl on stdin (`curl -K -`), never argv. Only then is the image signed, attested
and rendered. So no tag exists anywhere, which matches the local sandbox builds, and a
per-arch digest cannot reach `bo-deploy`: the render only ever sees the index digest.

Verified against the local push registry first: `201 Created`, `Docker-Content-Digest`
equal to the computed digest, identical bytes read back, and `tags/list` empty.

---

## 2026-09-30 — bo-deploy's layout, and the commit timestamp stamped by the chart

**Decision.**

- **Layout.** `rendered/dev/<svc>/manifests.yaml`, byte for byte what `helm template`
  emits for the pulled chart archive. That is `scripts/render-service.sh`, the only render
  path, which `task sandbox:deploy` also uses.
- **Annotation.** `gitops-lab/commit-timestamp: "<RFC3339, UTC>"`, the committer date of
  the built commit. It goes on the **workload's own metadata only**: the Deployment now,
  the Rollout in Phase 6. It is not on the pod template, so a timestamp alone never
  restarts pods. It is not on the Service or ServiceAccount, so they never diff. The DORA
  exporter reads it from the workload (Phase 7).
- **Stamped by the chart,** not by post-processing. Chart **0.2.0** adds a required,
  schema-checked `commitTimestamp` value; the three services re-pin. Post-processing
  would need a YAML editor in CI (`yq` is not pinned), and the committed YAML would no
  longer be what helm produced.
- **Rolling branch** `dev/<svc>`. The PR is titled `dev: <svc> <short sha>`. The body
  carries the source commit link, the timestamp, the index digest, the chart version and
  digest, the run link, and copy-paste `cosign verify` / `gh attestation verify` commands.
  No SHA, run ID or digest appears anywhere else in the repo, so a new push diffs in
  exactly two lines, the digest and the timestamp.

---

## 2026-09-30 — Dev promotions are serialized, never dropped, and never go backwards

**Reality check.** A `concurrency` group with `cancel-in-progress: false` still keeps at
most **one** pending run and cancels older pending ones (the default `queue: single`). And
GitHub does not guarantee the order runs leave the queue. So "serialize, do not cancel"
(BUILD-PLAN Phase 3) needs more than the obvious setting, and two builds finishing out of
order could promote the older one last.

**Decision.** The promote-dev job, not the build, carries
`concurrency: { group: promote-dev-<svc>, cancel-in-progress: false, queue: max }`, so up
to 100 runs wait and none is evicted. Its first step asks whether the run's commit is
still the tip of `main`. If not, it exits green with a notice ("superseded by <sha>"):
the image is built and signed, and the newer commit's own run promotes. A promotion can
therefore never regress dev to an older commit.

---

## 2026-09-30 — Argo CD delivers the services and catalog's database to `shop` in dev

**Decision.**

- **Namespace `shop`**, the name Phase 5 uses.
- A `services` ApplicationSet generates one Application per service: clusters
  (`env In [dev]`) × git directories `bo-deploy/rendered/<env>/*`. It is a directory
  source with automated prune + self-heal and label `wave: "4"`.
- A `databases` ApplicationSet generates `databases-dev` from `bo-platform/databases/dev`
  into `shop`.
- `sandbox` stays the unmanaged inner loop.
- **Prod is not selected yet.** Prod joins with the promoter slice, together with
  `databases/prod/`.

**The CNPG CRD race** (2026-09-29 carry-in): on a cold rebuild, `databases-dev` applies a
`Cluster` before `cloudnative-pg-dev` has installed its CRD. `databases-dev` therefore
carries `syncPolicy.retry` with an unlimited limit and exponential backoff capped at a few
minutes. The first sync fails on the missing kind, and a retry succeeds once the CRD
exists. catalog's pods wait on the not-yet-generated `catalog-db-app` Secret
(`CreateContainerConfigError`) and start when it appears. Nothing new is installed.

- ApplicationSet progressive sync was declined. `RollingSync` only orders Applications
  inside **one** ApplicationSet, so the database would have to move into the platform
  appset, and it still could not order the services after it.
- App-of-apps sync waves were declined. They wait only on hand-written Applications, and
  only after restoring Application health assessment.

The cold path itself is proven by Phase 8's rebuild; Phase 3 verifies the steady state.

---

## 2026-09-30 — Image visibility is a merge gate

**Decision.** ghcr creates each package **private** on first push, and the clusters pull
anonymously through the `ghcr` cache. `validate` therefore requires every image to resolve
anonymously. A service's first CI run is expected to fail at the merge timeout. The
operator then inspects the image (index, both manifests, layers, config, the full file
list of both platforms), makes the package public, and only then does the Argo CD wiring
land. Dev never sees an image it cannot pull, and the first run doubles as the proof that
a run whose PR doesn't merge fails.
