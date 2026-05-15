#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
mkdir -p vector-index
g++ -O3 -std=c++20 scripts/preprocess.cpp -o scripts/preprocess -lz
./scripts/preprocess .cache/rinha-official/resources/references.json.gz
