#!/usr/bin/env bash
# The portability seam (BUILD-PLAN §2a).
#
# Keychain does not exist on Windows, so this lab uses the 1Password CLI on BOTH
# macOS and WSL2. There is deliberately no `uname` dispatch here: one backend,
# one code path, identical behaviour on both machines.
#
#   ./scripts/get-secret.sh <item>     -> prints the credential to stdout
#   ./scripts/get-secret.sh --check    -> reports present/EMPTY/MISSING, prints NO values
#   ./scripts/get-secret.sh --check <item>
#
# Use --check to confirm the vault is ready. Never run the plain form just to
# "see if it works": it writes the secret into your terminal scrollback, which
# is the one place a credential is most likely to be screenshotted or shared.
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

ALL_ITEMS="argocd-git-credential promoter-github-pat dockerhub-user dockerhub-token
           discord-promotions discord-deploys discord-alerts"

# Which items each phase actually needs, so --check can say what is blocking now
# rather than demanding all seven before Phase 0.
phase_of() {
  case "$1" in
    dockerhub-user|dockerhub-token)   echo "Phase 0" ;;
    argocd-git-credential)            echo "Phase 1" ;;
    promoter-github-pat)              echo "Phase 3" ;;
    discord-*)                        echo "Phase 4" ;;
    *)                                echo "-"       ;;
  esac
}

command -v op >/dev/null 2>&1 || {
  echo "1Password CLI (op) not found." >&2
  echo "  macOS: brew install 1password-cli" >&2
  echo "  WSL2 : see https://developer.1password.com/docs/cli/get-started/" >&2
  exit 1
}

if [ "${1:-}" = "--check" ]; then
  # Deliberately never prints a value — only whether one is there.
  items="${2:-$ALL_ITEMS}"
  rc=0
  printf 'vault: %s\n' "$VAULT"
  for i in $items; do
    if ! v=$(op read "op://${VAULT}/${i}/credential" 2>/dev/null); then
      printf '  MISSING  %-22s (%s)\n' "$i" "$(phase_of "$i")"; rc=1
    elif [ -z "$v" ]; then
      printf '  EMPTY    %-22s (%s)\n' "$i" "$(phase_of "$i")"; rc=1
    else
      printf '  ok       %-22s (%s)  %s chars\n' "$i" "$(phase_of "$i")" "${#v}"
    fi
    unset v
  done
  exit $rc
fi

[ $# -eq 1 ] || { echo "usage: $(basename "$0") <item> | --check [item]" >&2; exit 2; }

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
