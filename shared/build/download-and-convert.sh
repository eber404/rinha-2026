#!/bin/bash
set -e

DATA_DIR="./fraud-api/data"
mkdir -p "$DATA_DIR"

echo "=== Downloading reference files ==="

curl -sL -o "$DATA_DIR/references.json.gz" \
    "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/references.json.gz"

curl -sL -o "$DATA_DIR/normalization.json" \
    "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/normalization.json"

curl -sL -o "$DATA_DIR/mcc_risk.json" \
    "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/mcc_risk.json"

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
console.log(`File size: ${content.length} bytes`);

// File is a JSON array
const parsed = JSON.parse(content);

if (!Array.isArray(parsed)) {
  console.error("Expected JSON array");
  process.exit(1);
}

console.log(`Loaded ${parsed.length} reference vectors`);

const buf = Buffer.alloc(parsed.length * RECORD_SIZE);

for (let i = 0; i < parsed.length; i++) {
  const obj = parsed[i];
  for (let j = 0; j < DIM; j++) {
    buf.writeFloatLE(obj.vector[j] ?? 0, i * RECORD_SIZE + j * 4);
  }
  buf[i * RECORD_SIZE + DIM * 4] = obj.label === "fraud" ? 1 : 0;
}

writeFileSync(OUTPUT_FILE, buf);
console.log(`Created ${OUTPUT_FILE}: ${buf.length} bytes`);
BUN_SCRIPT

echo "=== Build complete ==="
ls -lh "$DATA_DIR"