#!/usr/bin/env bash
# Installs exactly ONE thing: Argo CD, in mgmt. Then applies the root app, and
# everything else arrives from git. scripts/lint-bootstrap.sh enforces that —
# if this file needs to grow, what it wants to add belongs in git instead.
#
# Clusters, registries and caches are created by `task up` before this runs.
# Idempotent: re-running against a live mgmt is a no-op upgrade.
set -euo pipefail
cd "$(dirname "$0")/.."

CTX=k3d-mgmt
# Selects Argo CD v3.5.2. The chart cannot pin by digest — see DECISIONS.md.
# Bumping this is also a bump of ARGOCD in scripts/bootstrap-toolchain.sh.
ARGOCD_CHART=10.9.0

helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART" \
  --kube-context "$CTX" --namespace argocd --create-namespace \
  --values platform/argocd-values.yaml >/dev/null   # chart NOTES are noise here

# Not `helm --wait`: its semantics changed in Helm 4. Ask Kubernetes directly.
kubectl --context "$CTX" -n argocd wait deploy --all --for=condition=Available --timeout=300s
kubectl --context "$CTX" -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

kubectl --context "$CTX" apply -f argocd/root-app.yaml
