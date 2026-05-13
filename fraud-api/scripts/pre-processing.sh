#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="$ROOT_DIR/fraud-api/vector-index"

mkdir -p "$DATA_DIR"

echo "=== Checking if index exists ==="
if [ -f "$DATA_DIR/vectors_i8.bin" ] && \
   [ -f "$DATA_DIR/labels.bin" ] && \
   [ -f "$DATA_DIR/centroids_i8.bin" ] && \
   [ -f "$DATA_DIR/cluster_offsets.bin" ] && \
   [ -f "$DATA_DIR/scales.bin" ] && \
   [ -f "$DATA_DIR/offsets.bin" ]; then
    echo "Index files already exist, skipping generation"
    exit 0
fi

echo "=== Downloading reference files ==="

: "${REFS_URL:?REFS_URL is required}"
: "${NORMALIZATION_URL:?NORMALIZATION_URL is required}"
: "${MCC_RISK_URL:?MCC_RISK_URL is required}"

urls=(
    "$REFS_URL"
    "$NORMALIZATION_URL"
    "$MCC_RISK_URL"
)

for url in "${urls[@]}"; do
    filename=$(basename "$url")
    curl -sL -o "$DATA_DIR/$filename" "$url"
    echo "Downloaded $filename"
done

echo "=== Decompressing references ==="
gunzip -f "$DATA_DIR/references.json.gz"

echo "=== Compiling vector indexer ==="
zig build-exe "$SCRIPT_DIR/vector_indexer.zig" -O ReleaseSmall -femit-bin="$SCRIPT_DIR/vector_indexer"

echo "=== Running vector indexer ==="
"$SCRIPT_DIR/vector_indexer"
