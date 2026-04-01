#!/usr/bin/env bash
# setup.sh — Clone all Collection Market Tracker sibling repos
# Run this after cloning collection-market-tracker-frontend-admin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

ORG="FutureGadgetCollections"

repos=(
  "collection-market-tracker-backend"
  "collection-market-tracker-data"
  "collection-showcase-frontend"
  "collection-market-tracker-ev-simulator"
)

echo "Cloning sibling repos into: $PARENT_DIR"
echo ""

for repo in "${repos[@]}"; do
  target="$PARENT_DIR/$repo"
  if [ -d "$target/.git" ]; then
    echo "  [skip] $repo — already exists, pulling latest..."
    git -C "$target" pull --ff-only
  else
    echo "  [clone] $repo"
    git clone "https://github.com/$ORG/$repo.git" "$target"
  fi
done

echo ""
echo "Done. Sibling repos are ready under $PARENT_DIR"
echo ""
echo "Next steps:"
echo "  1. Copy .env.example to .env and fill in Firebase + backend config"
echo "  2. Run 'hugo server' to start the admin frontend locally"
