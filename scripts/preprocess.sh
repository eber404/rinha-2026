#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
mkdir -p vector-index

# Try to compile; if zlib is missing, install it
if ! g++ -O3 -std=c++20 scripts/preprocess.cpp -o scripts/preprocess -lz 2>/dev/null; then
    apt-get update -qq && apt-get install -y -qq zlib1g-dev
    g++ -O3 -std=c++20 scripts/preprocess.cpp -o scripts/preprocess -lz
fi

./scripts/preprocess .cache/rinha-official/resources/references.json.gz
