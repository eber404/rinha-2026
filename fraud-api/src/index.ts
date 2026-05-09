import { serve } from "bun";
import { readFileSync, existsSync } from "fs";

const INSTANCE_ID = process.env.INSTANCE_ID ?? "unknown";
const UDS_PATH = process.env.UDS_PATH ?? `/tmp/rinha/api-${INSTANCE_ID}.sock`;
const DATA_DIR = process.env.DATA_DIR ?? "/app/data";

const K_NEIGHBORS = 5;
const FRAUD_THRESHOLD = 0.6;
const VECTOR_DIM = 14;

const normalization = loadNormalization();
const mccRisk = loadMccRisk();
const refIndex = loadRefIndex();

const server = serve({
  unix: UDS_PATH,
  fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/ready" && req.method === "GET") {
      return jsonResponse({ ready: true, instance: INSTANCE_ID });
    }

    if (url.pathname === "/fraud-score" && req.method === "POST") {
      return handleFraudScore(req);
    }

    return jsonResponse({ error: "not found" }, 404);
  },
});

console.log(`[${INSTANCE_ID}] UDS: ${UDS_PATH}`);
console.log(`[${INSTANCE_ID}] Refs: ${refIndex.length}`);

function handleFraudScore(req: Request): Response {
  const payload = parsePayload(req);
  if (!payload) return jsonResponse({ error: "invalid payload" }, 400);

  const vector = normalizeToVector(payload);
  const fraudScore = searchKnn(vector);
  const approved = fraudScore < FRAUD_THRESHOLD;

  return jsonResponse({
    id: payload.id ?? "unknown",
    approved,
    fraud_score: Math.round(fraudScore * 1000) / 1000,
    instance: INSTANCE_ID,
  });
}

function parsePayload(req: Request): Record<string, any> | null {
  try { return req.json(); }
  catch { return null; }
}

function normalizeToVector(p: Record<string, any>): Float32Array {
  const v = new Float32Array(VECTOR_DIM);

  v[0] = normalized(p.transaction?.amount, normalization.max_amount);
  v[1] = normalized(p.transaction?.installments, normalization.max_installments);
  v[2] = normalized(p.customer?.avg_amount, normalization.max_avg_amount);
  v[3] = normalized(p.customer?.tx_count_24h, normalization.max_tx_count);
  v[4] = mccRisk[p.merchant?.mcc] ?? 0.5;
  v[5] = normalized(p.merchant?.avg_amount, normalization.max_merchant_avg);
  v[6] = normalized(p.terminal?.km_from_home, normalization.max_km);
  v[7] = normalized(p.last_transaction?.km_from_current, normalization.max_km);
  v[8] = p.terminal?.is_online ? 1 : 0;
  v[9] = p.terminal?.card_present ? 1 : 0;
  v[10] = isHighAmount(p.transaction?.amount);
  v[11] = isHighTxCount(p.customer?.tx_count_24h);
  v[12] = isFarDistance(p.last_transaction?.km_from_current);
  v[13] = 0;

  return v;
}

function normalized(value = 0, max = 1): number {
  return Math.min(1, Math.max(0, value / max));
}

function isHighAmount(amount = 0): number {
  return (amount > normalization.max_amount * 0.8) ? 1 : 0;
}

function isHighTxCount(count = 0): number {
  return (count > 10) ? 1 : 0;
}

function isFarDistance(km = 0): number {
  return (km > 50) ? 1 : 0;
}

function searchKnn(query: Float32Array): number {
  if (refIndex.length === 0) return 0;

  const distances: { idx: number; dist: number }[] = [];

  for (let i = 0; i < refIndex.length; i++) {
    const dist = euclideanDistance(query, refIndex[i].vector);
    distances.push({ idx: i, dist });
  }

  distances.sort((a, b) => a.dist - b.dist);

  const kNearest = distances.slice(0, K_NEIGHBORS);
  const fraudCount = kNearest.filter(d => refIndex[d.idx].label === 1).length;

  return fraudCount / K_NEIGHBORS;
}

function euclideanDistance(a: Float32Array, b: Float32Array): number {
  let sum = 0;
  for (let i = 0; i < VECTOR_DIM; i++) {
    const d = a[i] - b[i];
    sum += d * d;
  }
  return Math.sqrt(sum);
}

function loadNormalization(): Record<string, number> {
  const path = `${DATA_DIR}/normalization.json`;
  if (!existsSync(path)) return {};
  return JSON.parse(readFileSync(path, "utf-8"));
}

function loadMccRisk(): Record<string, number> {
  const path = `${DATA_DIR}/mcc_risk.json`;
  if (!existsSync(path)) return {};
  return JSON.parse(readFileSync(path, "utf-8"));
}

function loadRefIndex(): RefEntry[] {
  const path = `${DATA_DIR}/refs.bin`;
  if (!existsSync(path)) return [];

  const buf = readFileSync(path);
  const count = Math.floor(buf.length / REF_RECORD_SIZE);
  const refs: RefEntry[] = [];

  for (let i = 0; i < count; i++) {
    const offset = i * REF_RECORD_SIZE;
    const vec = new Float32Array(VECTOR_DIM);
    for (let j = 0; j < VECTOR_DIM; j++) {
      vec[j] = buf.readFloatLE(offset + j * 4);
    }
    const label = buf[offset + VECTOR_DIM * 4];
    refs.push({ vector: vec, label });
  }

  return refs;
}

function jsonResponse(data: object, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const REF_RECORD_SIZE = VECTOR_DIM * 4 + 1;

interface RefEntry {
  vector: Float32Array;
  label: number;
}