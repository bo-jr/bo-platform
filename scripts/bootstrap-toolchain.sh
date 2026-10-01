#!/usr/bin/env bash
# Pinned host toolchain for the GitOps lab.
#
# The lab runs on macOS (darwin/arm64), where Homebrew installs. The Linux path
# below is what the GitHub Actions runners use (Phase 3). One pin list either way.
#
#   ./scripts/bootstrap-toolchain.sh                        install or repair
#   ./scripts/bootstrap-toolchain.sh --verify               assert installed == pinned
#   ./scripts/bootstrap-toolchain.sh --only "go helm"       just these tools (either mode)
#
# Pinning prevents drift. --verify DETECTS it. Run --verify first whenever
# something behaves differently than it did yesterday.
set -euo pipefail

# ---- pin list: the single source of truth for host tools --------------------
K3D=v5.9.0
KUBECTL=v1.37.0
HELM=v4.2.4          # Argo CD >=3.5 renders with Helm 4 ONLY — see DECISIONS.md
TASK=v3.53.1
D2=v0.9.0           # follows Homebrew stable — see DECISIONS.md
COSIGN=v3.1.3
JQ=jq-1.8.2
GH=v2.100.0
GO=go1.27.1
ARGOCD=v3.5.2        # must track the Argo CD server version — see DECISIONS.md
KYVERNO=v1.19.1      # CLI; must track the admission controller from Phase 7 — see DECISIONS.md
# ----------------------------------------------------------------------------

TOOLS="k3d kubectl helm task d2 cosign jq gh go argocd kyverno"

MODE=install ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verify) MODE=verify ;;
    --only)   ONLY="${2:?--only needs a quoted list of tools}"; shift ;;
    *) echo "usage: $(basename "$0") [--verify] [--only \"<tools>\"]" >&2; exit 2 ;;
  esac
  shift
done
SELECTED="${ONLY:-$TOOLS}"
for t in $SELECTED; do
  case " $TOOLS " in *" $t "*) ;; *) echo "unknown tool: $t (known: $TOOLS)" >&2; exit 2 ;; esac
done

BIN="$HOME/.local/bin"
GOROOT_LOCAL="$HOME/.local/go"

case "$(uname -m)" in
  x86_64|amd64)   ARCH=amd64 ;;
  aarch64|arm64)  ARCH=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
case "$(uname -s)" in
  Linux)  OS=linux  ;;
  Darwin) OS=darwin ;;
  *) echo "unsupported os: $(uname -s)" >&2; exit 1 ;;
esac

want() { # tool -> pinned version string, normalised without leading v
  case "$1" in
    k3d) echo "${K3D#v}" ;; kubectl) echo "${KUBECTL#v}" ;; helm) echo "${HELM#v}" ;;
    task) echo "${TASK#v}" ;; d2) echo "${D2#v}" ;; cosign) echo "${COSIGN#v}" ;;
    jq) echo "${JQ#jq-}" ;; gh) echo "${GH#v}" ;; go) echo "${GO#go}" ;;
    argocd) echo "${ARGOCD#v}" ;; kyverno) echo "${KYVERNO#v}" ;;
  esac
}

have() { # tool -> installed version string, normalised
  command -v "$1" >/dev/null 2>&1 || { echo "absent"; return; }
  case "$1" in
    k3d)     k3d version 2>/dev/null | sed -n 's/.*k3d version v\([0-9.]*\).*/\1/p' | head -1 ;;
    kubectl) kubectl version --client 2>/dev/null | sed -n 's/^Client Version: v\([0-9.]*\).*/\1/p' ;;
    helm)    helm version --short 2>/dev/null | sed -n 's/^v\([0-9.]*\).*/\1/p' ;;
    # sed -E, not \+ : BSD sed (macOS) has no \+ in BRE and silently matches nothing.
    task)    task --version 2>/dev/null | sed -E -n 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
    d2)      d2 --version 2>/dev/null | sed -n 's/^v\{0,1\}\([0-9.]*\).*/\1/p' ;;
    cosign)  cosign version 2>/dev/null | sed -n 's/.*GitVersion: *v\([0-9.]*\).*/\1/p' ;;
    jq)      jq --version 2>/dev/null | sed -n 's/^jq-\([0-9.]*\).*/\1/p' ;;
    gh)      gh --version 2>/dev/null | sed -n 's/^gh version \([0-9.]*\).*/\1/p' ;;
    go)      go version 2>/dev/null | sed -n 's/.*go\([0-9.]*\) .*/\1/p' ;;
    argocd)  argocd version --client --short 2>/dev/null | sed -E -n 's/.*v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
    kyverno) kyverno version 2>/dev/null | sed -E -n 's/^Version: v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
  esac
}

if [ "$MODE" = verify ]; then
  echo "host: ${OS}/${ARCH}"
  rc=0
  for t in $SELECTED; do
    w=$(want "$t"); h=$(have "$t")
    if [ "$w" = "$h" ]; then
      printf '  ok     %-8s %s\n' "$t" "$h"
    else
      printf '  DRIFT  %-8s installed=%-12s pinned=%s\n' "$t" "${h:-unknown}" "$w"; rc=1
    fi
  done
  [ $rc -eq 0 ] && echo "toolchain matches the pin list" || echo "toolchain has drifted — rerun without --verify"
  exit $rc
fi

# ---- macOS: Homebrew is the installer, the pin list is still the authority ----
# Homebrew has no versioned formulae for these and cannot install a chosen
# version, so it is used to INSTALL and `brew pin` is used to FREEZE. The pin
# list above remains the source of truth: if brew's stable moves ahead, the
# verify pass at the end fails loudly and the pin list is updated deliberately,
# rather than the machine drifting silently.
if [ "$OS" = darwin ]; then
  command -v brew >/dev/null 2>&1 || { echo "Homebrew required on macOS: https://brew.sh" >&2; exit 1; }

  formula() { # our tool name -> Homebrew formula name
    case "$1" in
      kubectl) echo kubernetes-cli ;;
      task)    echo go-task        ;;
      *)       echo "$1"           ;;
    esac
  }

  echo ">> installing pinned toolchain for darwin/${ARCH} via Homebrew"
  for t in $SELECTED; do
    f=$(formula "$t")
    if brew list --versions "$f" >/dev/null 2>&1; then
      echo ">> $t ($f) already installed"
    else
      echo ">> $t ($f)"
      brew install "$f" >/dev/null
    fi
    brew pin "$f" >/dev/null 2>&1 || true
  done

  echo ">> pinned in Homebrew: $(brew list --pinned | tr '\n' ' ')"
  echo ">> verifying against the pin list"
  exec "$0" --verify --only "$SELECTED"
fi

# ---- Linux: no Homebrew, download each pinned release directly ---------------
# What the GitHub Actions runners use. Every download is checked against the
# checksum file its upstream publishes beside it, and nothing is installed on a
# mismatch. That catches corruption and a swapped asset; it does not defend
# against a compromised release, which would publish a matching checksum.
echo ">> installing pinned toolchain for ${OS}/${ARCH} into ${BIN}: ${SELECTED}"
mkdir -p "$BIN"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GHR=https://github.com
get() { curl -fsSL --retry 3 -o "$2" "$1"; }

# sum FILE CHECKSUM_URL ASSET — FILE's sha256 must equal ASSET's entry in the
# checksum file. Handles both "<hash>  <name>" lists (with or without a path
# prefix on the name) and single-hash files such as kubectl's and Go's.
sum() {
  local want got
  want=$(curl -fsSL --retry 3 "$2" | awk -v a="$3" '
    { n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n) }
    NF == 1 { h = $1 }  n == a { h = $1 }  END { print h }')
  got=$(sha256sum "$1" | awk '{ print $1 }')
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "checksum MISMATCH for $3: published=${want:-none} downloaded=$got" >&2; exit 1
  fi
  echo "   sha256 ok  $3"
}

for t in $SELECTED; do
  echo ">> $t $(want "$t")"
  case "$t" in
    k3d)
      a="k3d-linux-${ARCH}"; get "$GHR/k3d-io/k3d/releases/download/${K3D}/$a" "$TMP/$a"
      sum "$TMP/$a" "$GHR/k3d-io/k3d/releases/download/${K3D}/checksums.txt" "$a"
      install -m 0755 "$TMP/$a" "$BIN/k3d" ;;
    kubectl)
      u="https://dl.k8s.io/release/${KUBECTL}/bin/linux/${ARCH}/kubectl"; get "$u" "$TMP/kubectl"
      sum "$TMP/kubectl" "$u.sha256" kubectl
      install -m 0755 "$TMP/kubectl" "$BIN/kubectl" ;;
    cosign)
      a="cosign-linux-${ARCH}"; get "$GHR/sigstore/cosign/releases/download/${COSIGN}/$a" "$TMP/$a"
      sum "$TMP/$a" "$GHR/sigstore/cosign/releases/download/${COSIGN}/cosign_checksums.txt" "$a"
      install -m 0755 "$TMP/$a" "$BIN/cosign" ;;
    jq)
      a="jq-linux-${ARCH}"; get "$GHR/jqlang/jq/releases/download/${JQ}/$a" "$TMP/$a"
      sum "$TMP/$a" "$GHR/jqlang/jq/releases/download/${JQ}/sha256sum.txt" "$a"
      install -m 0755 "$TMP/$a" "$BIN/jq" ;;
    helm)
      a="helm-${HELM}-linux-${ARCH}.tar.gz"; get "https://get.helm.sh/$a" "$TMP/$a"
      sum "$TMP/$a" "https://get.helm.sh/$a.sha256sum" "$a"
      tar -xzf "$TMP/$a" -C "$TMP"; install -m 0755 "$TMP/linux-${ARCH}/helm" "$BIN/helm" ;;
    task)
      a="task_linux_${ARCH}.tar.gz"; get "$GHR/go-task/task/releases/download/${TASK}/$a" "$TMP/$a"
      sum "$TMP/$a" "$GHR/go-task/task/releases/download/${TASK}/task_checksums.txt" "$a"
      mkdir -p "$TMP/task"; tar -xzf "$TMP/$a" -C "$TMP/task"; install -m 0755 "$TMP/task/task" "$BIN/task" ;;
    d2)
      a="d2-${D2}-linux-${ARCH}.tar.gz"; get "$GHR/terrastruct/d2/releases/download/${D2}/$a" "$TMP/$a"
      sum "$TMP/$a" "$GHR/terrastruct/d2/releases/download/${D2}/SHA256SUMS" "$a"
      mkdir -p "$TMP/d2"; tar -xzf "$TMP/$a" -C "$TMP/d2" --strip-components=1; install -m 0755 "$TMP/d2/bin/d2" "$BIN/d2" ;;
    gh)
      a="gh_${GH#v}_linux_${ARCH}.tar.gz"; get "$GHR/cli/cli/releases/download/${GH}/$a" "$TMP/$a"
      sum "$TMP/$a" "$GHR/cli/cli/releases/download/${GH}/gh_${GH#v}_checksums.txt" "$a"
      mkdir -p "$TMP/gh"; tar -xzf "$TMP/$a" -C "$TMP/gh" --strip-components=1; install -m 0755 "$TMP/gh/bin/gh" "$BIN/gh" ;;
    argocd)
      a="argocd-linux-${ARCH}"; get "$GHR/argoproj/argo-cd/releases/download/${ARGOCD}/$a" "$TMP/$a"
      sum "$TMP/$a" "$GHR/argoproj/argo-cd/releases/download/${ARGOCD}/cli_checksums.txt" "$a"
      install -m 0755 "$TMP/$a" "$BIN/argocd" ;;
    kyverno)
      # Kyverno names amd64 "x86_64" in its release assets.
      ka=$ARCH; [ "$ka" = amd64 ] && ka=x86_64
      a="kyverno-cli_${KYVERNO}_linux_${ka}.tar.gz"; get "$GHR/kyverno/kyverno/releases/download/${KYVERNO}/$a" "$TMP/$a"
      sum "$TMP/$a" "$GHR/kyverno/kyverno/releases/download/${KYVERNO}/checksums.txt" "$a"
      mkdir -p "$TMP/kyverno"; tar -xzf "$TMP/$a" -C "$TMP/kyverno"; install -m 0755 "$TMP/kyverno/kyverno" "$BIN/kyverno" ;;
    go)
      a="${GO}.linux-${ARCH}.tar.gz"; get "https://dl.google.com/go/$a" "$TMP/$a"
      sum "$TMP/$a" "https://dl.google.com/go/$a.sha256" "$a"
      rm -rf "$GOROOT_LOCAL"; tar -xzf "$TMP/$a" -C "$HOME/.local" ;;
  esac
done

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  # -F is load-bearing: as a regex the leading dot matches any character, so
  # '.local/bin' matches '/usr/local/bin' — present, usually commented out, in
  # almost every stock rc file. The guard then skips the append and every tool
  # silently resolves to whatever Homebrew or apt put on PATH instead.
  grep -qF '.local/bin' "$rc" || printf '\nexport PATH="$HOME/.local/bin:$HOME/.local/go/bin:$PATH"\n' >> "$rc"
done

# CI steps never read an rc file; a workflow appends both directories to
# $GITHUB_PATH instead. Verify against them here so a mismatch fails this step.
PATH="$BIN:$GOROOT_LOCAL/bin:$PATH" exec "$0" --verify --only "$SELECTED"
