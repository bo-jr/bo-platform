#!/usr/bin/env bash
# Run the lab's Kyverno policies against rendered manifests.
#
#   ./scripts/policy-check.sh <manifests.yaml>...
#
# The same check runs in three places: service CI before a build, bo-deploy's
# `validate` check on every rendered file, and here on the laptop. From Phase 7
# the same policies also run at admission.
#
# Why a wrapper and not a bare `kyverno apply policies/`: given a directory, the
# CLI recurses, and ONE non-policy YAML in it makes it skip the whole directory,
# apply nothing, and exit 0 (DECISIONS.md 2026-09-30). So this passes each
# policy file explicitly, and fails unless EVERY policy produced a result — a
# check that silently applied nothing must never read as green.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $(basename "$0") <manifests.yaml>..." >&2; exit 2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
policies=("$root"/policies/*.yaml)
res=(); for f in "$@"; do res+=(--resource "$f"); done

report=$(mktemp); trap 'rm -f "$report"' EXIT
rc=0
kyverno apply "${policies[@]}" "${res[@]}" --warnings-as-errors --remove-color \
  -p --output-format json >"$report" 2>/dev/null || rc=$?

jq -e '.summary' "$report" >/dev/null 2>&1 || {
  echo "policy-check: kyverno produced no report (exit $rc)" >&2; exit 1; }

# One line per decision, failures first.
jq -r '.results | sort_by(.result != "fail") | .[] |
  "  \(.result | ascii_upcase | .[0:4])  \(.policy)  \(.resources[0].kind)/\(.resources[0].name)" +
  (if .result == "pass" then "" else "\n        \(.message)" end)' "$report"

missing=0
for p in "${policies[@]}"; do
  name=$(awk '/^metadata:/ { m = 1 } m && /^  name:/ { print $2; exit }' "$p")
  if ! jq -e --arg n "$name" 'any(.results[]; .policy == $n)' "$report" >/dev/null; then
    echo "  MISSING  $name produced no result — the check did not run" >&2; missing=1
  fi
done

jq -r '.summary | "pass: \(.pass), fail: \(.fail), error: \(.error), warn: \(.warn)"' "$report"
if [ "$missing" -ne 0 ] || ! jq -e '.summary.fail == 0 and .summary.error == 0' "$report" >/dev/null || [ "$rc" -ne 0 ]; then
  echo "policy-check: FAILED" >&2; exit 1
fi
echo "policy-check: ok (${#policies[@]} policies, $# file(s))"
