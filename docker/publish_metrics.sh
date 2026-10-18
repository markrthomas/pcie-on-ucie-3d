#!/usr/bin/env bash
# docker/publish_metrics.sh — push metrics.db / dashboard.html / run.json to the
# orphan branch `metrics-data` (per-run dir + latest/).  The ephemeral Railway
# container has no persistent disk, so results leave this way and re-enter the
# dashboard locally with `make railway-import`.
# Uses GITHUB_TOKEN via an http extraheader (never in the URL or git config).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
REPO="${METRICS_REPO:-markrthomas/pcie-on-ucie-3d}"
BRANCH="metrics-data"
TS="$(date -u +%Y%m%d-%H%M%S)"
URL="https://github.com/${REPO}.git"
HDR="http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)"

tmp="$(mktemp -d)"
git -c "$HDR" clone --depth 1 --branch "$BRANCH" "$URL" "$tmp" 2>/dev/null || {
  git -c "$HDR" clone --depth 1 "$URL" "$tmp"
  git -C "$tmp" checkout --orphan "$BRANCH"
  git -C "$tmp" rm -rf . >/dev/null 2>&1 || true
}
mkdir -p "$tmp/runs/$TS" "$tmp/latest"
for f in metrics/metrics.db metrics/dashboard.html metrics/run.json; do
  [ -f "$f" ] && cp "$f" "$tmp/runs/$TS/" && cp "$f" "$tmp/latest/"
done
git -C "$tmp" add -A
git -C "$tmp" -c user.email=ci@localhost -c user.name=ci commit -m "metrics $TS" || { echo "nothing to publish"; exit 0; }
for i in 1 2 3; do
  if git -C "$tmp" -c "$HDR" push origin "$BRANCH"; then echo "published $TS"; exit 0; fi
  git -C "$tmp" -c "$HDR" pull --rebase origin "$BRANCH" || true
done
echo "publish failed after retries" >&2; exit 1
