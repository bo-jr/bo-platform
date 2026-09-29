#!/usr/bin/env bash
# Asserts the architectural thesis of this lab: bootstrap installs exactly one
# thing (Argo CD) and applies exactly one manifest (the root app). Everything
# else must arrive from git. BUILD-PLAN §6 and Phase 8.
#
#   ./scripts/lint-bootstrap.sh              lint scripts/bootstrap.sh
#   ./scripts/lint-bootstrap.sh <file>       lint another file (for testing the lint)
#
# If this fails because bootstrap.sh needs one more thing, the fix is almost
# never to widen this script. Put the thing in git and let Argo CD deliver it.
set -euo pipefail

FILE=${1:-"$(dirname "$0")/bootstrap.sh"}
MAX_LINES=30

# Strip comments and blank lines, join `\` continuations, squeeze whitespace —
# so one logical command is one line no matter how it is wrapped.
cmds=$(awk '
  { sub(/(^|[ \t])#.*$/, "") }
  sub(/\\[ \t]*$/, "") { buf = buf $0 " "; next }
  { line = buf $0; buf = ""
    gsub(/[ \t]+/, " ", line); sub(/^ /, "", line); sub(/ $/, "", line)
    if (line != "") print line }
' "$FILE")

fail=0
bad() { echo "lint-bootstrap: $*" >&2; fail=1; }
count() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

helm_cmds=$(printf '%s\n' "$cmds" | grep -E '(^| )helm ' || true)
[ "$(count "$helm_cmds")" -le 1 ] || bad "more than one helm command"
other=$(printf '%s\n' "$helm_cmds" | grep -vE '^$|^helm upgrade --install argocd argo-cd ' || true)
[ -z "$other" ] || bad "helm may only install the argo-cd chart: $(printf '%s\n' "$other" | head -1)"

mutate=' (apply|create|replace|patch|edit|delete|label|annotate|scale|set|run|expose)( |$)'
kube_cmds=$(printf '%s\n' "$cmds" | grep -E '(^| )kubectl ' | grep -E "$mutate" || true)
[ "$(count "$kube_cmds")" -le 1 ] || bad "more than one mutating kubectl command"
other=$(printf '%s\n' "$kube_cmds" | grep -vE '^$| apply -f argocd/root-app\.yaml$' || true)
[ -z "$other" ] || bad "kubectl may only apply argocd/root-app.yaml: $(printf '%s\n' "$other" | head -1)"

# Command position only: "argocd" is also the release name and the namespace.
if printf '%s\n' "$cmds" | grep -qE '(^|[;&|(]) ?argocd '; then
  bad "the argocd CLI creates state outside git — declare it under argocd/ instead"
fi

n=$(count "$cmds")
[ "$n" -le "$MAX_LINES" ] || bad "$n command lines, limit is $MAX_LINES — something belongs in git"

[ "$fail" -eq 0 ] && echo "lint-bootstrap: ok ($n command lines, installs only Argo CD + root app)"
exit "$fail"
