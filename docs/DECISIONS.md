# Decisions log

Deltas from `docs/BUILD-PLAN.md` and answers to questions the plan left open.
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

Helm 3 is also out of runway: bug fixes ended **2026-07-08**, security fixes end
**2026-11-11**.

**Why the breaking changes don't bite us.** Helm 4's breaking changes land on
`--wait`, `--atomic`, `--force`, post-renderers, the plugin system, and the Go SDK.
This lab uses `helm template` in CI and Argo CD uses `helm template` at sync — the
Helm CLI never manages a release lifecycle here, because Argo CD does. The one place
to stay alert is `helm registry login` path components when publishing
`service-chart` as an OCI artifact.

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
`versions:check` is warned about in §3 — same ~150-line boundary applies.

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
