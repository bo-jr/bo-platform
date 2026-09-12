#!/usr/bin/env bash
# The portability seam (BUILD-PLAN §2a).
#
# Keychain does not exist on Windows, so this lab uses the 1Password CLI on BOTH
# macOS and WSL2. There is deliberately no `uname` dispatch here: one backend,
# one code path, identical behaviour on both machines.
#
#   ./scripts/get-secret.sh <item>     -> prints the credential to stdout
#
# Items expected in the vault (see SETUP.md):
#   argocd-git-credential   PAT Argo CD uses to read bo-deploy
#   promoter-github-pat     fine-grained PAT for cmd/promoter (contents+PRs)
#   dockerhub-user          Docker Hub username for the pull-through cache
#   dockerhub-token         Docker Hub access token
#   discord-promotions      webhook URL for #promotions
#   discord-deploys         webhook URL for #deploys
#   discord-alerts          webhook URL for #alerts
set -euo pipefail

VAULT="${OP_VAULT:-gitops-lab}"

[ $# -eq 1 ] || { echo "usage: $(basename "$0") <item>" >&2; exit 2; }

command -v op >/dev/null 2>&1 || {
  echo "1Password CLI (op) not found." >&2
  echo "  macOS: brew install 1password-cli" >&2
  echo "  WSL2 : see https://developer.1password.com/docs/cli/get-started/" >&2
  exit 1
}

# An item whose credential field is empty makes `op read` succeed and print
# nothing, so a caller doing --proxy-password "$(get-secret.sh dockerhub-token)"
# would build an unauthenticated registry and exit 0. That failure surfaces
# hours later as `toomanyrequests` mid-rebuild. Empty is an error here.
value=$(op read "op://${VAULT}/$1/credential")
[ -n "$value" ] || {
  echo "secret '$1' exists in vault '${VAULT}' but its credential field is empty." >&2
  echo "Fill it in 1Password, then retry." >&2
  exit 1
}
printf '%s\n' "$value"
