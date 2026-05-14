#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="$ROOT_DIR/fraud-api/vector-index"
RESOURCES_DIR="$ROOT_DIR/.cache/rinha-official/resources"

mkdir -p "$DATA_DIR"

echo "=== Checking if index exists ==="
if [ -f "$DATA_DIR/vectors_i8.bin" ] && \
   [ -f "$DATA_DIR/vectors_i16.bin" ] && \
   [ -f "$DATA_DIR/labels.bin" ] && \
   [ -f "$DATA_DIR/centroids_i8.bin" ] && \
   [ -f "$DATA_DIR/cluster_offsets.bin" ] && \
   [ -f "$DATA_DIR/scales.bin" ] && \
   [ -f "$DATA_DIR/offsets.bin" ]; then
    echo "Index files already exist, skipping generation"
    exit 0
fi

echo "=== Copying reference files from cache ==="
if [ ! -f "$RESOURCES_DIR/references.json.gz" ] || \
   [ ! -f "$RESOURCES_DIR/normalization.json" ] || \
   [ ! -f "$RESOURCES_DIR/mcc_risk.json" ]; then
    echo "Missing files in $RESOURCES_DIR"
    exit 1
fi

cp "$RESOURCES_DIR/references.json.gz" "$DATA_DIR/references.json.gz"
cp "$RESOURCES_DIR/normalization.json" "$DATA_DIR/normalization.json"
cp "$RESOURCES_DIR/mcc_risk.json" "$DATA_DIR/mcc_risk.json"

echo "=== Decompressing references ==="
gunzip -f "$DATA_DIR/references.json.gz"

echo "=== Compiling vector indexer ==="
zig build-exe "$SCRIPT_DIR/vector_indexer.zig" -O ReleaseSmall -femit-bin="$SCRIPT_DIR/vector_indexer"

echo "=== Running vector indexer ==="
"$SCRIPT_DIR/vector_indexer"
