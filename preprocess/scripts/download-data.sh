#!/bin/bash
set -e

DATA_DIR="./fraud-api/data"
mkdir -p "$DATA_DIR"

echo "=== Downloading reference files ==="

# Download references.json.gz
if [ ! -f "$DATA_DIR/references.json.gz" ]; then
    echo "Downloading references.json.gz..."
    curl -L -o "$DATA_DIR/references.json.gz" \
        "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/data/references.json.gz"
else
    echo "references.json.gz already exists"
fi

# Download normalization.json
if [ ! -f "$DATA_DIR/normalization.json" ]; then
    echo "Downloading normalization.json..."
    curl -L -o "$DATA_DIR/normalization.json" \
        "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/data/normalization.json"
else
    echo "normalization.json already exists"
fi

# Download mcc_risk.json
if [ ! -f "$DATA_DIR/mcc_risk.json" ]; then
    echo "Downloading mcc_risk.json..."
    curl -L -o "$DATA_DIR/mcc_risk.json" \
        "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/data/mcc_risk.json"
else
    echo "mcc_risk.json already exists"
fi

echo "=== Converting to binary format ==="
cd "$DATA_DIR"

# gunzip references
if [ ! -f "references.json" ]; then
    echo "Decompressing references.json.gz..."
    gunzip -k references.json.gz
else
    echo "references.json already exists"
fi

echo "=== Build complete ==="
ls -lh "$DATA_DIR"
