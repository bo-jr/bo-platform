# Picking this up on a new machine

Read `CLAUDE.md` for the standing rules and `BUILD-PLAN.md` for the spec.
This file is the mechanical setup, and the honest status of where the build is.

---

## Status — last updated 2026-09-12

**Phase 0 is complete and verified.** All four acceptance criteria pass.

| | |
|---|---|
| Repos | ✅ all seven created, public, `.gitattributes` seeded |
| Branch protection | ✅ `main-protection` active on all seven, 0 required reviews |
| Taskfile | ✅ lifecycle, status and repo targets |
| Toolchain (MacBook M1) | ✅ installed and verified — all ten `ok` |
| Container runtime (MacBook M1) | ✅ Docker Desktop 4.89.0, engine 29.7.2, 36 GiB / 100 GiB |
| 1Password vault | ✅ `gitops-lab`, 7 items; Phase 0 secrets filled |
| Clusters, registry, caches | ✅ 3 clusters, 5 registries, k3s v1.36.4+k3s1 |

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

**Next action:** Phase 1 — Argo CD in `mgmt`, spoke registration, the platform
ApplicationSet matrix generator. See BUILD-PLAN §5.

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

Installs the ten pinned tools with Homebrew into `/opt/homebrew/bin` and freezes each
with `brew pin`.

The pin list at the top of the script is the authority. Homebrew is only the installer —
it has no versioned formulae for these tools and cannot install a chosen version, so
`brew pin` is what actually holds them still. The script finishes by running `--verify`
on itself, so a brew stable that has moved ahead of the pin list fails loudly instead of
drifting quietly.

The script also carries an unused Linux path that downloads each pinned release
directly. It is kept because it is what a CI runner would use.

Open a new shell, then confirm:

```bash
./scripts/bootstrap-toolchain.sh --verify
```

Every line must say `ok`. A `DRIFT` line is the first thing to suspect when
something behaves differently on one machine than the other.

> If `--verify` reports drift after a `brew upgrade`, the fix is to decide whether the
> new version is wanted and edit the pin list — **not** `brew unpin`. The pin list is
> what makes a rebuild reproducible.

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
| `promoter-github-pat` | fine-grained PAT for `cmd/promoter` — `contents: write`, `pull_requests: write`, scoped to `bo-deploy` |
| `dockerhub-user` | Docker Hub username for the pull-through cache |
| `dockerhub-token` | Docker Hub access token |
| `discord-promotions` | webhook URL for `#promotions` |
| `discord-deploys` | webhook URL for `#deploys` |
| `discord-alerts` | webhook URL for `#alerts` |

Items are *API Credential* category, so `credential` is the native primary field
rather than a custom one. All seven can be created empty up front — only fill the
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
