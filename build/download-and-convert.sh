#!/bin/bash
set -e

DATA_DIR="./fraud-api/data"
mkdir -p "$DATA_DIR"

echo "=== Downloading reference files ==="

curl -sL -o "$DATA_DIR/references.json.gz" \
    "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/data/references.json.gz"

curl -sL -o "$DATA_DIR/normalization.json" \
    "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/data/normalization.json"

curl -sL -o "$DATA_DIR/mcc_risk.json" \
    "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/data/mcc_risk.json"

echo "=== Decompressing references ==="
cd "$DATA_DIR"
gunzip -k references.json.gz

echo "=== Converting to binary format ==="
bun run - << 'BUN_SCRIPT'
import { readFileSync, writeFileSync } from "fs";

const REF_FILE = "references.json";
const OUTPUT_FILE = "refs.bin";
const DIM = 14;
const RECORD_SIZE = DIM * 4 + 1;

console.log("Reading references.json...");
const content = readFileSync(REF_FILE, "utf-8");
const lines = content.split("\n").filter(l => l.trim());

console.log(`Processing ${lines.length} records...`);

const refs: { vector: number[], label: number }[] = [];
for (const line of lines) {
  try {
    const obj = JSON.parse(line);
    refs.push({
      vector: obj.vector,
      label: obj.label === "fraud" ? 1 : 0,
    });
  } catch (e) {
    // skip invalid lines
  }
}

console.log(`Loaded ${refs.length} reference vectors`);

const buf = Buffer.alloc(refs.length * RECORD_SIZE);

for (let i = 0; i < refs.length; i++) {
  for (let j = 0; j < DIM; j++) {
    buf.writeFloatLE(refs[i].vector[j], i * RECORD_SIZE + j * 4);
  }
  buf[i * RECORD_SIZE + DIM * 4] = refs[i].label;
}

writeFileSync(OUTPUT_FILE, buf);
console.log(`Created ${OUTPUT_FILE}: ${buf.length} bytes (${refs.length} vectors)`);
BUN_SCRIPT

echo "=== Build complete ==="
ls -lh "$DATA_DIR"