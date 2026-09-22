#!/usr/bin/env bash
# restore-from-tar.sh — restore Qdrant collections from a qdrant-backup.sh tarball
#
# Assumes: work/<collection_name>/*.snapshot (one snapshot per folder), and that
# the extracted work/ directory is visible to the Qdrant process at the path
# given in the recover request's "location" (file:// URI resolved inside the
# Qdrant container/pod, not on the host running this script).
set -euo pipefail

QDRANT_URL="${QDRANT_URL:-http://qdrant:6333}"
API_KEY="$(cat /etc/qdrant/creds/apikey 2>/dev/null || echo '')"
AUTH_HEADER=()
[[ -n "$API_KEY" ]] && AUTH_HEADER=(-H "api-key: $API_KEY")

WORK_DIR="${WORK_DIR:-./work}"

# 1. Extract tar if not already done
[[ -d "$WORK_DIR" ]] || tar -xzf backup.tar.gz

# 2. Get collection names = folder names
mapfile -t COLLECTIONS < <(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
echo "Found ${#COLLECTIONS[@]} collections:"
printf '  - %s\n' "${COLLECTIONS[@]}"

# 3. Restore each
for COL in "${COLLECTIONS[@]}"; do
  SNAP_FILE=$(find "$WORK_DIR/$COL" -maxdepth 1 -name '*.snapshot' | head -n1)
  [[ -z "$SNAP_FILE" ]] && { echo "!! No snapshot in $COL, skipping"; continue; }
  SNAP_NAME=$(basename "$SNAP_FILE")

  echo ">> Restoring $COL from $SNAP_NAME"
  curl -sf -X PUT "${AUTH_HEADER[@]}" \
    "$QDRANT_URL/collections/$COL/snapshots/recover" \
    -H "Content-Type: application/json" \
    -d "{\"location\": \"file:///qdrant/snapshots/$COL/$SNAP_NAME\"}" \
    || echo "!! Failed: $COL"
done
