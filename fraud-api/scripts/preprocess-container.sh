#!/bin/sh
set -eu

ROOT_DIR="/workspace"
DATA_DIR="$ROOT_DIR/fraud-api/vector-index"
SCRIPT_DIR="$ROOT_DIR/fraud-api/scripts"

mkdir -p "$DATA_DIR"

if [ -f "$DATA_DIR/vectors_i8.bin" ] && \
   [ -f "$DATA_DIR/labels.bin" ] && \
   [ -f "$DATA_DIR/centroids_i8.bin" ] && \
   [ -f "$DATA_DIR/cluster_offsets.bin" ] && \
   [ -f "$DATA_DIR/scales.bin" ] && \
   [ -f "$DATA_DIR/offsets.bin" ]; then
    echo "Index files already exist, skipping generation"
    exit 0
fi

wget -q -O "$DATA_DIR/references.json.gz" "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/references.json.gz" 2>/dev/null
wget -q -O "$DATA_DIR/normalization.json" "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/normalization.json" 2>/dev/null
wget -q -O "$DATA_DIR/mcc_risk.json" "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/mcc_risk.json" 2>/dev/null
gunzip -f "$DATA_DIR/references.json.gz"

zig build-exe "$SCRIPT_DIR/vector_indexer.zig" -O ReleaseSmall -femit-bin="$SCRIPT_DIR/vector_indexer"
"$SCRIPT_DIR/vector_indexer"
