# Picking this up on a new machine

Read `CLAUDE.md` for the standing rules and `docs/BUILD-PLAN.md` for the spec.
This file is the mechanical setup, and the honest status of where the build is.

---

## Status — last updated 2026-09-05

**Phase 0 has not started.** No clusters exist on any machine.

| | |
|---|---|
| Repos | ✅ all seven created, public, `.gitattributes` seeded |
| Branch protection | ❌ not applied — needs `task repos:protect`, which needs the Taskfile |
| Taskfile | ❌ not written |
| Toolchain (Windows/WSL2) | ✅ installed and verified |
| Toolchain (MacBook M1) | ❌ not installed |
| 1Password vault | ❌ not created |
| Clusters, registry, caches | ❌ Phase 0 |

**Next action:** Phase 0 on the MacBook — registry, four pull-through caches,
three k3d clusters. See BUILD-PLAN §5.

**The Windows box cannot host the lab.** 31GB host, WSL2 capped at 8GB by choice.
It builds, tests, and authors CI. The MacBook M1 (64GB) is the runtime target —
see `docs/DECISIONS.md`.

---

## 1. Container runtime

**macOS (M1)** — OrbStack preferred, allocate **36GB** to the VM.
Docker Desktop or Colima also work.

**Windows 11** — Docker Desktop with the **WSL2 backend**. Not Hyper-V, not Windows
containers. Enable WSL integration for the Ubuntu distro. Memory is set in
`%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=8GB

[experimental]
autoMemoryReclaim=gradual
```

> `autoMemoryReclaim` belongs under `[experimental]`. Under `[wsl2]` WSL logs
> `Unknown key 'wsl2.autoMemoryReclaim'` on every launch and silently ignores it.

Verify the runtime before going further:

```bash
docker info --format '{{.ServerVersion}} {{.OSType}}/{{.Architecture}}'
```

On Windows this must be run **inside WSL2**, not from PowerShell.

---

## 2. Clone all seven repos side by side

Repo root is `~/gitops-lab/` on both machines. On Windows that means the WSL2
home directory — **never `/mnt/c/`**, which mangles script permissions and is an
order of magnitude slower.

```bash
mkdir -p ~/gitops-lab && cd ~/gitops-lab
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
cd ~/gitops-lab/bo-platform && ./scripts/bootstrap-toolchain.sh
```

Detects `darwin/arm64` vs `linux/amd64` and installs to `~/.local/bin`. Open a new
shell, then confirm both machines agree:

```bash
./scripts/bootstrap-toolchain.sh --verify
```

Every line must say `ok`. A `DRIFT` line is the first thing to suspect when
something behaves differently on one machine than the other.

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

Secrets come from 1Password on **both** machines — see `scripts/get-secret.sh`.
Create a vault named `gitops-lab` (override with `OP_VAULT`) with one item per
secret below, each holding the value in a field named `credential`:

| Item | What it is |
|---|---|
| `argocd-git-credential` | PAT Argo CD uses to read `bo-deploy` |
| `promoter-github-pat` | fine-grained PAT for `cmd/promoter` — `contents: write`, `pull_requests: write`, scoped to `bo-deploy` |
| `dockerhub-user` | Docker Hub username for the pull-through cache |
| `dockerhub-token` | Docker Hub access token |
| `discord-promotions` | webhook URL for `#promotions` |
| `discord-deploys` | webhook URL for `#deploys` |
| `discord-alerts` | webhook URL for `#alerts` |

Smoke test:

```bash
./scripts/get-secret.sh dockerhub-user
```

These and the git credential are the only things that outlive `task nuke`. Nothing
else is exempt from git.

---

## 6. Then start Phase 0

BUILD-PLAN §5, Phase 0 — push registry, four pull-through caches, three k3d
clusters on the `gitops-lab` Docker network. Do not skip the caches: Phase 8
requires two consecutive full rebuilds and unauthenticated Docker Hub pulls are
capped near 10/hour.

**One phase per session.** Verify the acceptance criteria before moving on.
