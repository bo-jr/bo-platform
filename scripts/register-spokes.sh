#!/usr/bin/env bash
# Registers dev and prod with Argo CD in mgmt, declaratively. Idempotent.
#
# Not `argocd cluster add` — see DECISIONS.md 2026-09-29. It cannot set the
# in-network server URL, and in --core mode it stores the spoke's admin client
# certificate instead of argocd-manager's token.
#
# The server URL is the whole point of this script. k3d writes
# https://0.0.0.0:<port> into the kubeconfig, which means nothing from inside a
# container. Argo CD reaches each spoke by its Docker DNS name on gitops-lab,
# which the k3s serving certificate already carries as a SAN.
#
# Credentials never touch disk, argv, a shell variable, or git: the token is
# streamed from the spoke through jq into a server-side apply in mgmt.
set -euo pipefail
cd "$(dirname "$0")/.."

MGMT=k3d-mgmt

for env in dev prod; do
  ctx=k3d-$env

  kubectl --context "$ctx" apply --server-side --force-conflicts \
    --field-manager=register-spokes -f clusters/argocd-manager.yaml >/dev/null

  # The token controller fills the Secret asynchronously after creation.
  for _ in $(seq 1 30); do
    n=$(kubectl --context "$ctx" -n kube-system get secret argocd-manager-long-lived-token \
      -o jsonpath='{.data.token}' | wc -c | tr -d ' ')
    [ "$n" -gt 0 ] && break
    sleep 1
  done
  [ "$n" -gt 0 ] || { echo "no token issued for argocd-manager in $env" >&2; exit 1; }

  # Drop any registration for this env that is not ours — e.g. one left by a
  # manual `argocd cluster add` — so exactly one Secret claims the spoke.
  kubectl --context "$MGMT" -n argocd delete secret \
    -l "argocd.argoproj.io/secret-type=cluster,env=$env" \
    --field-selector "metadata.name!=cluster-$env" --ignore-not-found 2>&1 \
    | { grep -v '^No resources found' || true; }

  kubectl --context "$ctx" -n kube-system get secret argocd-manager-long-lived-token -o json \
  | jq --arg env "$env" '{
      apiVersion: "v1", kind: "Secret", type: "Opaque",
      metadata: {
        name: "cluster-\($env)", namespace: "argocd",
        labels: { "argocd.argoproj.io/secret-type": "cluster", env: $env }
      },
      stringData: {
        name: $env,
        server: "https://k3d-\($env)-server-0:6443",
        config: ({ bearerToken: (.data.token | @base64d),
                   tlsClientConfig: { caData: .data["ca.crt"], insecure: false } } | tojson)
      }
    }' \
  | kubectl --context "$MGMT" apply --server-side --field-manager=register-spokes -f - >/dev/null

  echo "registered $env -> https://k3d-$env-server-0:6443 (label env=$env)"
done
