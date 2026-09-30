#!/usr/bin/env bash
# Render one service with the shared chart — the only render path in the lab.
#
#   ./scripts/render-service.sh <service-repo-dir> <index-digest> <commit-timestamp> [helm args...]
#
# Manifests go to stdout, byte for byte what bo-deploy stores. One line,
# "chart: <ref> <version> <digest>", goes to stderr for the PR body.
#
# Used by service CI (a placeholder-digest render before the build, the real one
# after), and by `task sandbox:deploy`, which adds --set overrides. The service
# repo pins the chart in chart-values.yaml; this reads the pin, never picks one.
set -euo pipefail

CHART=oci://ghcr.io/bo-jr/charts/service

[ $# -ge 3 ] || { echo "usage: $(basename "$0") <service-repo-dir> <index-digest> <commit-timestamp> [helm args...]" >&2; exit 2; }
dir=$1 digest=$2 ts=$3; shift 3
values="$dir/chart-values.yaml"
[ -f "$values" ] || { echo "no chart-values.yaml in $dir" >&2; exit 1; }

ver=$(awk '/^chartVersion:/ { print $2; exit }' "$values")
name=$(awk '/^name:/ { print $2; exit }' "$values")

# Pull first, render the local archive. Helm 4 prints "Pulled:" and "Digest:"
# on STDOUT when it fetches an OCI chart and has no flag to silence them; left
# in the stream they would become the first YAML document of every rendered
# manifest (DECISIONS.md 2026-09-29). Captured here, and the digest kept.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pulled=$(helm pull "$CHART" --version "$ver" -d "$tmp")
echo "chart: $CHART $ver $(printf '%s\n' "$pulled" | awk '/^Digest:/ { print $2 }')" >&2

helm template "$name" "$tmp/service-$ver.tgz" -f "$values" \
  --set image.digest="$digest" --set-string commitTimestamp="$ts" "$@"
