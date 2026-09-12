#!/usr/bin/env bash
# Pinned host toolchain for the GitOps lab.
#
# The SAME script runs on macOS (darwin/arm64) and WSL2 Ubuntu (linux/amd64).
# That is the point: two machines, one pin list, no drift.
#
#   ./scripts/bootstrap-toolchain.sh            install or repair
#   ./scripts/bootstrap-toolchain.sh --verify    assert installed == pinned
#
# Pinning prevents drift. --verify DETECTS it. Run --verify first whenever
# something behaves differently on one machine than the other.
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
# ----------------------------------------------------------------------------

BIN="$HOME/.local/bin"
GOROOT_LOCAL="$HOME/.local/go"

case "$(uname -m)" in
  x86_64|amd64)   ARCH=amd64 ;;
  aarch64|arm64)  ARCH=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
# Three projects do not call macOS "darwin" in their release asset names, so the
# OS token is not universal. jq and d2 use "macos"; gh uses "macOS" and ships a
# .zip instead of a .tar.gz. On Linux all four variables collapse to the same
# value, which is why this only ever broke on the MacBook.
case "$(uname -s)" in
  Linux)  OS=linux;  OS_ALT=linux; GH_OS=linux; GH_EXT=tar.gz ;;
  Darwin) OS=darwin; OS_ALT=macos; GH_OS=macOS; GH_EXT=zip    ;;
  *) echo "unsupported os: $(uname -s)" >&2; exit 1 ;;
esac

want() { # tool -> pinned version string, normalised without leading v
  case "$1" in
    k3d) echo "${K3D#v}" ;; kubectl) echo "${KUBECTL#v}" ;; helm) echo "${HELM#v}" ;;
    task) echo "${TASK#v}" ;; d2) echo "${D2#v}" ;; cosign) echo "${COSIGN#v}" ;;
    jq) echo "${JQ#jq-}" ;; gh) echo "${GH#v}" ;; go) echo "${GO#go}" ;;
    argocd) echo "${ARGOCD#v}" ;;
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
  esac
}

if [ "${1:-}" = "--verify" ]; then
  echo "host: ${OS}/${ARCH}"
  rc=0
  for t in k3d kubectl helm task d2 cosign jq gh go argocd; do
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
      argocd)  echo argocd          ;;
      *)       echo "$1"           ;;
    esac
  }

  echo ">> installing pinned toolchain for darwin/${ARCH} via Homebrew"
  for t in k3d kubectl helm task d2 cosign jq gh go argocd; do
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
  exec "$0" --verify
fi

# ---- Linux (WSL2): no Homebrew, download each pinned release directly --------
echo ">> installing pinned toolchain for ${OS}/${ARCH} into ${BIN}"
mkdir -p "$BIN"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
get() { curl -fsSL --retry 3 -o "$2" "$1"; }

echo ">> k3d ${K3D}"
get "https://github.com/k3d-io/k3d/releases/download/${K3D}/k3d-${OS}-${ARCH}" "$BIN/k3d"; chmod +x "$BIN/k3d"

echo ">> kubectl ${KUBECTL}"
get "https://dl.k8s.io/release/${KUBECTL}/bin/${OS}/${ARCH}/kubectl" "$BIN/kubectl"; chmod +x "$BIN/kubectl"

echo ">> cosign ${COSIGN}"
get "https://github.com/sigstore/cosign/releases/download/${COSIGN}/cosign-${OS}-${ARCH}" "$BIN/cosign"; chmod +x "$BIN/cosign"

echo ">> jq ${JQ}"
get "https://github.com/jqlang/jq/releases/download/${JQ}/jq-${OS_ALT}-${ARCH}" "$BIN/jq"; chmod +x "$BIN/jq"

echo ">> helm ${HELM}"
get "https://get.helm.sh/helm-${HELM}-${OS}-${ARCH}.tar.gz" "$TMP/helm.tgz"
tar -xzf "$TMP/helm.tgz" -C "$TMP"; mv "$TMP/${OS}-${ARCH}/helm" "$BIN/helm"

echo ">> task ${TASK}"
get "https://github.com/go-task/task/releases/download/${TASK}/task_${OS}_${ARCH}.tar.gz" "$TMP/task.tgz"
mkdir -p "$TMP/task"; tar -xzf "$TMP/task.tgz" -C "$TMP/task"; mv "$TMP/task/task" "$BIN/task"

echo ">> d2 ${D2}"
get "https://github.com/terrastruct/d2/releases/download/${D2}/d2-${D2}-${OS_ALT}-${ARCH}.tar.gz" "$TMP/d2.tgz"
mkdir -p "$TMP/d2"; tar -xzf "$TMP/d2.tgz" -C "$TMP/d2" --strip-components=1; mv "$TMP/d2/bin/d2" "$BIN/d2"

echo ">> gh ${GH}"
GH_DIR="gh_${GH#v}_${GH_OS}_${ARCH}"
get "https://github.com/cli/cli/releases/download/${GH}/${GH_DIR}.${GH_EXT}" "$TMP/gh.${GH_EXT}"
mkdir -p "$TMP/gh"
if [ "$GH_EXT" = zip ]; then
  unzip -q "$TMP/gh.zip" -d "$TMP/gh"; mv "$TMP/gh/${GH_DIR}/bin/gh" "$BIN/gh"
else
  tar -xzf "$TMP/gh.tar.gz" -C "$TMP/gh" --strip-components=1; mv "$TMP/gh/bin/gh" "$BIN/gh"
fi

echo ">> argocd ${ARGOCD}"
get "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD}/argocd-${OS}-${ARCH}" "$BIN/argocd"; chmod +x "$BIN/argocd"

echo ">> go ${GO}"
get "https://go.dev/dl/${GO}.${OS}-${ARCH}.tar.gz" "$TMP/go.tgz"
rm -rf "$GOROOT_LOCAL"; tar -xzf "$TMP/go.tgz" -C "$HOME/.local"

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  # -F is load-bearing: as a regex the leading dot matches any character, so
  # '.local/bin' matches '/usr/local/bin' — present, usually commented out, in
  # almost every stock rc file. The guard then skips the append and every tool
  # silently resolves to whatever Homebrew or apt put on PATH instead.
  grep -qF '.local/bin' "$rc" || printf '\nexport PATH="$HOME/.local/bin:$HOME/.local/go/bin:$PATH"\n' >> "$rc"
done

echo ">> done — open a new shell, then: ./scripts/bootstrap-toolchain.sh --verify"
