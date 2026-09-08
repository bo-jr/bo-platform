# Picking this up on a new machine

Read `CLAUDE.md` for the standing rules and `BUILD-PLAN.md` for the spec.
This file is the mechanical setup, and the honest status of where the build is.

---

## Status — last updated 2026-09-07

**Phase 0 has not started.** No clusters exist on any machine.

| | |
|---|---|
| Repos | ✅ all seven created, public, `.gitattributes` seeded |
| Branch protection | ❌ not applied — needs `task repos:protect`, which needs the Taskfile |
| Taskfile | ❌ not written |
| Toolchain (Windows/WSL2) | ✅ installed and verified |
| Toolchain (MacBook M1) | ✅ installed and verified — all nine `ok` |
| Container runtime (MacBook M1) | ✅ Docker Desktop 4.89.0, engine 29.7.2, 36 GiB / 100 GiB |
| 1Password vault | ❌ not created |
| Clusters, registry, caches | ❌ Phase 0 |

**Next action:** Phase 0 on the MacBook — registry, four pull-through caches,
three k3d clusters. See BUILD-PLAN §5. The 1Password vault (§5 below) is a
prerequisite: the Docker Hub pull-through cache needs `dockerhub-user` and
`dockerhub-token` at creation time.

**The Windows box cannot host the lab.** 31GB host, WSL2 capped at 8GB by choice.
It builds, tests, and authors CI. The MacBook M1 (64GB) is the runtime target —
see `DECISIONS.md`.

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

Repo root is `~/git/` on both machines. On Windows that means the WSL2
home directory — **never `/mnt/c/`**, which mangles script permissions and is an
order of magnitude slower.

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

Detects the host and installs the nine pinned tools two different ways:

| | Installer | Location | Frozen by |
|---|---|---|---|
| **macOS** | Homebrew | `/opt/homebrew/bin` | `brew pin` |
| **WSL2** | `curl` from each release | `~/.local/bin` | the URL itself |

The pin list at the top of the script is the authority on **both**. Homebrew is only
the installer — it has no versioned formulae for these tools and cannot install a
chosen version, so `brew pin` is what actually holds them still. On macOS the script
finishes by running `--verify` on itself, so a brew stable that has moved ahead of the
pin list fails loudly instead of drifting quietly.

Open a new shell, then confirm both machines agree:

```bash
./scripts/bootstrap-toolchain.sh --verify
```

Every line must say `ok`. A `DRIFT` line is the first thing to suspect when
something behaves differently on one machine than the other.

> If `--verify` reports drift on macOS after a `brew upgrade`, the fix is to decide
> whether the new version is wanted and edit the pin list — **not** `brew unpin`. The
> two machines have to agree, and the WSL2 box installs by exact URL.

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
