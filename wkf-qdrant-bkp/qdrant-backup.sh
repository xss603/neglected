#!/usr/bin/env bash
# qdrant-backup.sh — snapshot + download all Qdrant collections
set -euo pipefail

QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
API_KEY="${QDRANT_API_KEY:-}"
OUT_DIR="${OUT_DIR:-./qdrant_backups/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT_DIR"

AUTH=()
[[ -n "$API_KEY" ]] && AUTH=(-H "api-key: $API_KEY")

echo "[*] Fetching collection list..."
collections=$(curl -sf "${AUTH[@]}" "$QDRANT_URL/collections" | jq -r '.result.collections[].name')

if [[ -z "$collections" ]]; then
  echo "[!] No collections found." >&2
  exit 1
fi

for col in $collections; do
  echo "[*] Creating snapshot for: $col"
  snap_resp=$(curl -sf -X POST "${AUTH[@]}" "$QDRANT_URL/collections/$col/snapshots")
  snap_name=$(echo "$snap_resp" | jq -r '.result.name')

  if [[ -z "$snap_name" || "$snap_name" == "null" ]]; then
    echo "[!] Failed to create snapshot for $col" >&2
    continue
  fi

  echo "    -> $snap_name"
  mkdir -p "$OUT_DIR/$col"

  curl -sf "${AUTH[@]}" \
    "$QDRANT_URL/collections/$col/snapshots/$snap_name" \
    -o "$OUT_DIR/$col/$snap_name"

  echo "    downloaded to $OUT_DIR/$col/$snap_name"
done

echo "[✓] Backup complete: $OUT_DIR"
