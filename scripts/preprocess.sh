#!/bin/bash
set -e
cd /workspace
mkdir -p vector-index
g++ -O3 -std=c++20 scripts/preprocess.cpp -o scripts/preprocess -lz
./scripts/preprocess .cache/rinha-official/resources/references.json.gz
