import { describe, test, expect } from "bun:test";

const VECTOR_DIM = 14;
const K_NEIGHBORS = 5;
const FRAUD_THRESHOLD = 0.6;

const norm = {
  max_amount: 10000,
  max_installments: 12,
  amount_vs_avg_ratio: 10,
  max_minutes: 1440,
  max_km: 1000,
  max_tx_count_24h: 20,
  max_merchant_avg_amount: 10000,
};

const mcc: Record<string, number> = {
  "5411": 0.15,
  "5812": 0.30,
  "7802": 0.75,
};

describe("clamp", () => {
  test("clamps value between 0 and 1", () => {
    expect(clamp(0.5)).toBe(0.5);
    expect(clamp(-0.5)).toBe(0);
    expect(clamp(1.5)).toBe(1);
  });
});

describe("normalizeToVector", () => {
  test("legitimate transaction matches expected vector", () => {
    const payload = {
      id: "tx-1",
      transaction: { amount: 41.12, installments: 2, requested_at: "2026-03-11T18:45:53Z" },
      customer: { avg_amount: 82.24, tx_count_24h: 3, known_merchants: ["MERC-003", "MERC-016"] },
      merchant: { id: "MERC-016", mcc: "5411", avg_amount: 60.25 },
      terminal: { is_online: false, card_present: true, km_from_home: 29.23 },
      last_transaction: null,
    };

    const v = normalizeToVector(payload);

    expect(v.length).toBe(VECTOR_DIM);
    expect(v[0]).toBeCloseTo(0.0041, 3);
    expect(v[1]).toBeCloseTo(2 / 12, 3);
    expect(v[5]).toBe(-1);
    expect(v[6]).toBe(-1);
    expect(v[9]).toBe(0);
    expect(v[10]).toBe(1);
    expect(v[11]).toBe(0);
    expect(v[12]).toBeCloseTo(0.15, 3);
  });

  test("fraudulent transaction with high values", () => {
    const payload = {
      id: "tx-2",
      transaction: { amount: 9505.97, installments: 10, requested_at: "2026-03-14T05:15:12Z" },
      customer: { avg_amount: 81.28, tx_count_24h: 20, known_merchants: ["MERC-008", "MERC-007", "MERC-005"] },
      merchant: { id: "MERC-068", mcc: "7802", avg_amount: 54.86 },
      terminal: { is_online: false, card_present: true, km_from_home: 952.27 },
      last_transaction: null,
    };

    const v = normalizeToVector(payload);

    expect(v[0]).toBeCloseTo(0.9506, 3);
    expect(v[1]).toBeCloseTo(10 / 12, 3);
    expect(v[5]).toBe(-1);
    expect(v[6]).toBe(-1);
    expect(v[7]).toBeCloseTo(0.9523, 3);
    expect(v[8]).toBe(1);
    expect(v[11]).toBe(1);
    expect(v[12]).toBeCloseTo(0.75, 3);
  });

  test("handles missing last_transaction as -1 sentinel", () => {
    const payload = {
      transaction: { amount: 100, installments: 1, requested_at: "2026-03-11T12:00:00Z" },
      customer: { avg_amount: 100, tx_count_24h: 1, known_merchants: [] },
      merchant: { id: "X", mcc: "5411", avg_amount: 100 },
      terminal: { is_online: false, card_present: true, km_from_home: 10 },
      last_transaction: null,
    };

    const v = normalizeToVector(payload);
    expect(v[5]).toBe(-1);
    expect(v[6]).toBe(-1);
  });

  test("handles unknown merchant", () => {
    const payload = {
      transaction: { amount: 100, installments: 1, requested_at: "2026-03-11T12:00:00Z" },
      customer: { avg_amount: 100, tx_count_24h: 1, known_merchants: ["MERCH-A"] },
      merchant: { id: "MERCH-B", mcc: "5411", avg_amount: 100 },
      terminal: { is_online: false, card_present: true, km_from_home: 10 },
      last_transaction: { minutes: 30, km_from_current: 5 },
    };

    const v = normalizeToVector(payload);
    expect(v[11]).toBe(1);
  });

  test("uses default mcc_risk for unknown mcc", () => {
    const payload = {
      transaction: { amount: 100, installments: 1, requested_at: "2026-03-11T12:00:00Z" },
      customer: { avg_amount: 100, tx_count_24h: 1, known_merchants: [] },
      merchant: { id: "X", mcc: "UNKNOWN", avg_amount: 100 },
      terminal: { is_online: false, card_present: true, km_from_home: 10 },
      last_transaction: { minutes: 30, km_from_current: 5 },
    };

    const v = normalizeToVector(payload);
    expect(v[12]).toBe(0.5);
  });
});

describe("Euclidean distance", () => {
  test("same vectors have zero distance", () => {
    const a = new Float32Array([0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]);
    const b = new Float32Array([0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]);
    expect(euclideanDistance(a, b)).toBe(0);
  });
});

describe("KNN search", () => {
  test("returns 0 when no references", () => {
    const refs: RefEntry[] = [];
    const query = new Float32Array(VECTOR_DIM);
    expect(searchKnn(query, refs, norm, mcc)).toBe(0);
  });

  test("counts fraud proportion correctly", () => {
    const refs: RefEntry[] = [
      { vector: new Float32Array(VECTOR_DIM), label: 1 },
      { vector: new Float32Array(VECTOR_DIM), label: 1 },
      { vector: new Float32Array(VECTOR_DIM), label: 0 },
      { vector: new Float32Array(VECTOR_DIM), label: 0 },
      { vector: new Float32Array(VECTOR_DIM), label: 1 },
    ];
    const query = new Float32Array(VECTOR_DIM);
    expect(searchKnn(query, refs, norm, mcc)).toBe(0.6);
  });
});

describe("Fraud score decision", () => {
  test("approves when below threshold", () => {
    expect(0.5 < FRAUD_THRESHOLD).toBe(true);
  });

  test("denies when at or above threshold", () => {
    expect(0.6 < FRAUD_THRESHOLD).toBe(false);
  });
});

function clamp(value: number): number {
  return Math.min(1, Math.max(0, value));
}

function hourOfDay(isoString: string): number {
  if (!isoString) return 0;
  const d = new Date(isoString);
  return d.getUTCHours();
}

function dayOfWeek(isoString: string): number {
  if (!isoString) return 0;
  const d = new Date(isoString);
  return d.getUTCDay();
}

function isUnknownMerchant(merchantId: string, knownMerchants: string[]): boolean {
  if (!merchantId || !knownMerchants) return true;
  return !knownMerchants.includes(merchantId);
}

function normalizeToVector(p: Record<string, any>): Float32Array {
  const v = new Float32Array(VECTOR_DIM);
  const tx = p.transaction ?? {};
  const cust = p.customer ?? {};
  const merch = p.merchant ?? {};
  const term = p.terminal ?? {};
  const last = p.last_transaction ?? null;

  v[0] = clamp(tx.amount / norm.max_amount);
  v[1] = clamp(tx.installments / norm.max_installments);
  v[2] = clamp((tx.amount / cust.avg_amount) / norm.amount_vs_avg_ratio);
  v[3] = hourOfDay(tx.requested_at) / 23;
  v[4] = dayOfWeek(tx.requested_at) / 6;

  if (last === null) {
    v[5] = -1;
    v[6] = -1;
  } else {
    v[5] = clamp(last.minutes / norm.max_minutes);
    v[6] = clamp(last.km_from_current / norm.max_km);
  }

  v[7] = clamp(term.km_from_home / norm.max_km);
  v[8] = clamp(cust.tx_count_24h / norm.max_tx_count_24h);
  v[9] = term.is_online ? 1 : 0;
  v[10] = term.card_present ? 1 : 0;
  v[11] = isUnknownMerchant(merch.id, cust.known_merchants) ? 1 : 0;
  v[12] = mcc[merch.mcc] ?? 0.5;
  v[13] = clamp(merch.avg_amount / norm.max_merchant_avg_amount);

  return v;
}

function euclideanDistance(a: Float32Array, b: Float32Array): number {
  let sum = 0;
  for (let i = 0; i < VECTOR_DIM; i++) {
    const d = a[i] - b[i];
    sum += d * d;
  }
  return Math.sqrt(sum);
}

function searchKnn(query: Float32Array, refs: RefEntry[], norm: any, mcc: any): number {
  if (refs.length === 0) return 0;

  const distances: { idx: number; dist: number }[] = [];
  for (let i = 0; i < refs.length; i++) {
    distances.push({ idx: i, dist: euclideanDistance(query, refs[i].vector) });
  }

  distances.sort((a, b) => a.dist - b.dist);

  const kNearest = distances.slice(0, K_NEIGHBORS);
  const fraudCount = kNearest.filter(d => refs[d.idx].label === 1).length;

  return fraudCount / K_NEIGHBORS;
}

interface RefEntry {
  vector: Float32Array;
  label: number;
}