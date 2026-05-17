#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
mkdir -p vector-index

if [ -f vector-index/dataset_full.bin ] && [ -f vector-index/labels_full.bin ] && [ -f vector-index/ivf_index.bin ] && [ -f vector-index/rules_model.bin ] && [ -f vector-index/manifest.bin ]; then
    echo "Index files already exist, skipping generation"
    exit 0
fi

# Try to compile; if zlib is missing, install it
if ! g++ -O3 -std=c++20 scripts/preprocess.cpp -o scripts/preprocess -lz 2>/dev/null; then
    apt-get update -qq && apt-get install -y -qq zlib1g-dev
    g++ -O3 -std=c++20 scripts/preprocess.cpp -o scripts/preprocess -lz
fi

if [ -f vector-index/dataset_full.bin ] && [ -f vector-index/labels_full.bin ] && [ -f vector-index/ivf_index.bin ]; then
    ./scripts/preprocess --mine-rules
elif [ -f vector-index/dataset.bin ] && [ -f vector-index/labels.bin ] && [ -f vector-index/ivf_index.bin ]; then
    ./scripts/preprocess --metadata-only
else
    ./scripts/preprocess .cache/rinha-official/resources/references.json.gz
fi

test -f vector-index/dataset_full.bin
test -f vector-index/labels_full.bin
test -f vector-index/ivf_index.bin
test -f vector-index/rules_model.bin
test -f vector-index/manifest.bin
