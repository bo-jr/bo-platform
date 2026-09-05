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
HELM=v4.2.4          # Argo CD >=3.5 renders with Helm 4 ONLY — see docs/DECISIONS.md
TASK=v3.53.1
D2=v0.8.2
COSIGN=v3.1.3
JQ=jq-1.8.2
GH=v2.100.0
GO=go1.27.1
# ----------------------------------------------------------------------------

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
  esac
}

have() { # tool -> installed version string, normalised
  command -v "$1" >/dev/null 2>&1 || { echo "absent"; return; }
  case "$1" in
    k3d)     k3d version 2>/dev/null | sed -n 's/.*k3d version v\([0-9.]*\).*/\1/p' | head -1 ;;
    kubectl) kubectl version --client 2>/dev/null | sed -n 's/^Client Version: v\([0-9.]*\).*/\1/p' ;;
    helm)    helm version --short 2>/dev/null | sed -n 's/^v\([0-9.]*\).*/\1/p' ;;
    task)    task --version 2>/dev/null | sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' ;;
    d2)      d2 --version 2>/dev/null | sed -n 's/^v\{0,1\}\([0-9.]*\).*/\1/p' ;;
    cosign)  cosign version 2>/dev/null | sed -n 's/.*GitVersion: *v\([0-9.]*\).*/\1/p' ;;
    jq)      jq --version 2>/dev/null | sed -n 's/^jq-\([0-9.]*\).*/\1/p' ;;
    gh)      gh --version 2>/dev/null | sed -n 's/^gh version \([0-9.]*\).*/\1/p' ;;
    go)      go version 2>/dev/null | sed -n 's/.*go\([0-9.]*\) .*/\1/p' ;;
  esac
}

if [ "${1:-}" = "--verify" ]; then
  echo "host: ${OS}/${ARCH}"
  rc=0
  for t in k3d kubectl helm task d2 cosign jq gh go; do
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
get "https://github.com/jqlang/jq/releases/download/${JQ}/jq-${OS}-${ARCH}" "$BIN/jq"; chmod +x "$BIN/jq"

echo ">> helm ${HELM}"
get "https://get.helm.sh/helm-${HELM}-${OS}-${ARCH}.tar.gz" "$TMP/helm.tgz"
tar -xzf "$TMP/helm.tgz" -C "$TMP"; mv "$TMP/${OS}-${ARCH}/helm" "$BIN/helm"

echo ">> task ${TASK}"
get "https://github.com/go-task/task/releases/download/${TASK}/task_${OS}_${ARCH}.tar.gz" "$TMP/task.tgz"
mkdir -p "$TMP/task"; tar -xzf "$TMP/task.tgz" -C "$TMP/task"; mv "$TMP/task/task" "$BIN/task"

echo ">> d2 ${D2}"
get "https://github.com/terrastruct/d2/releases/download/${D2}/d2-${D2}-${OS}-${ARCH}.tar.gz" "$TMP/d2.tgz"
mkdir -p "$TMP/d2"; tar -xzf "$TMP/d2.tgz" -C "$TMP/d2" --strip-components=1; mv "$TMP/d2/bin/d2" "$BIN/d2"

echo ">> gh ${GH}"
get "https://github.com/cli/cli/releases/download/${GH}/gh_${GH#v}_${OS}_${ARCH}.tar.gz" "$TMP/gh.tgz"
mkdir -p "$TMP/gh"; tar -xzf "$TMP/gh.tgz" -C "$TMP/gh" --strip-components=1; mv "$TMP/gh/bin/gh" "$BIN/gh"

echo ">> go ${GO}"
get "https://go.dev/dl/${GO}.${OS}-${ARCH}.tar.gz" "$TMP/go.tgz"
rm -rf "$GOROOT_LOCAL"; tar -xzf "$TMP/go.tgz" -C "$HOME/.local"

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  grep -q '.local/bin' "$rc" || printf '\nexport PATH="$HOME/.local/bin:$HOME/.local/go/bin:$PATH"\n' >> "$rc"
done

echo ">> done — open a new shell, then: ./scripts/bootstrap-toolchain.sh --verify"
