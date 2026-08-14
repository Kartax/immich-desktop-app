#!/usr/bin/env bash

set -euo pipefail

TAP_REPO="${HOMEBREW_TAP_REPO:-Kartax/homebrew-tap}"
WORKFLOW="update-immich-desktop.yml"
TAG="${1:-}"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "!! gh not found — install with 'brew install gh && gh auth login'." >&2
  exit 1
fi

RUN_TITLE="Update Immich Desktop $TAG"
DISPATCHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "==> Dispatching Homebrew cask update for $TAG"
gh workflow run "$WORKFLOW" \
  --repo "$TAP_REPO" \
  --ref main \
  -f "tag=$TAG"

RUN_ID=""
for _ in {1..30}; do
  RUN_ID="$(gh run list \
    --repo "$TAP_REPO" \
    --workflow "$WORKFLOW" \
    --event workflow_dispatch \
    --limit 20 \
    --json databaseId,displayTitle,createdAt \
    --jq "[.[] | select(.displayTitle == \"$RUN_TITLE\" and .createdAt >= \"$DISPATCHED_AT\")] | first | .databaseId // empty")"
  [[ -n "$RUN_ID" ]] && break
  sleep 2
done

if [[ -z "$RUN_ID" ]]; then
  echo "!! Dispatched the tap workflow but could not locate its run." >&2
  echo "   Inspect: https://github.com/$TAP_REPO/actions/workflows/$WORKFLOW" >&2
  echo "   Retry: $0 $TAG" >&2
  exit 1
fi

echo "==> Waiting for Homebrew workflow run $RUN_ID"
if ! gh run watch "$RUN_ID" --repo "$TAP_REPO" --exit-status; then
  echo "!! Homebrew cask publication failed for $TAG." >&2
  echo "   Retry after fixing the workflow: $0 $TAG" >&2
  exit 1
fi

echo "Homebrew cask published: brew install --cask kartax/tap/immich-desktop"
