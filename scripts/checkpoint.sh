#!/usr/bin/env bash
# scripts/checkpoint.sh — Create checkpoint tags across all project repos.
# Usage: ./scripts/checkpoint.sh [reason]
#
# Applies the same "skip if no new commits" logic as the GitHub Actions workflow.
# Tags are pushed to origin immediately after creation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$REPO_ROOT")"

REASON="${1:-}"
DATE=$(date -u +%Y-%m-%d)

REPOS=(
  "collection-admin"
  "collection-market-tracker-backend"
  "collection-market-tracker-data"
)

# ---------------------------------------------------------------------------
# checkpoint_repo <repo-name>
# ---------------------------------------------------------------------------
checkpoint_repo() {
  local repo="$1"
  local dir="$PARENT_DIR/$repo"

  if [ ! -d "$dir/.git" ]; then
    echo "  [skip] $repo — not found locally (expected: $dir)"
    return
  fi

  # Skip if HEAD has not moved since the last checkpoint-* tag
  local last_tag head_commit
  last_tag=$(git -C "$dir" tag --list 'checkpoint-*' --sort=-version:refname | head -1)
  head_commit=$(git -C "$dir" rev-parse HEAD)

  if [ -n "$last_tag" ]; then
    local last_tag_commit
    last_tag_commit=$(git -C "$dir" rev-list -n 1 "$last_tag")
    if [ "$last_tag_commit" = "$head_commit" ]; then
      echo "  [skip] $repo — no new commits since $last_tag"
      return
    fi
  fi

  # Determine tag name; append -2, -3, ... if same-day tag already exists
  local base_tag="checkpoint-${DATE}"
  local tag="$base_tag"
  local suffix=2
  while git -C "$dir" rev-parse "$tag" >/dev/null 2>&1; do
    tag="${base_tag}-${suffix}"
    suffix=$((suffix + 1))
  done

  # Build annotation from short SHA + last commit subject
  local short_sha last_msg annotation
  short_sha=$(git -C "$dir" rev-parse --short HEAD)
  last_msg=$(git -C "$dir" log -1 --format="%s")

  if [ -n "$REASON" ]; then
    annotation="checkpoint at ${short_sha}: ${last_msg} (${REASON})"
  else
    annotation="checkpoint at ${short_sha}: ${last_msg}"
  fi

  git -C "$dir" tag -a "$tag" -m "$annotation"
  git -C "$dir" push origin "$tag"
  echo "  [tag]  $repo → $tag"
}

# ---------------------------------------------------------------------------

echo "Checkpoint tags — $(date -u '+%Y-%m-%d %H:%M UTC')"
[ -n "$REASON" ] && echo "Reason: $REASON"
echo ""

for repo in "${REPOS[@]}"; do
  checkpoint_repo "$repo"
done

echo ""
echo "Done."
