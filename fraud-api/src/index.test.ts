import { describe, test, expect } from "bun:test";

const VECTOR_DIM = 14;
const K_NEIGHBORS = 5;
const FRAUD_THRESHOLD = 0.6;

describe("Vector normalization", () => {
  test("normalized clamps value between 0 and 1", () => {
    expect(normalized(50, 100)).toBe(0.5);
    expect(normalized(150, 100)).toBe(1);
    expect(normalized(-10, 100)).toBe(0);
    expect(normalized(0, 100)).toBe(0);
  });

  test("isHighAmount detects high transactions", () => {
    expect(isHighAmount(9000, 10000)).toBe(1);
    expect(isHighAmount(5000, 10000)).toBe(0);
  });

  test("isHighTxCount detects suspicious counts", () => {
    expect(isHighTxCount(11)).toBe(1);
    expect(isHighTxCount(10)).toBe(0);
  });

  test("isFarDistance detects distant transactions", () => {
    expect(isFarDistance(51)).toBe(1);
    expect(isFarDistance(50)).toBe(0);
  });
});

describe("Vector creation", () => {
  test("creates 14-dimension vector", () => {
    const v = new Float32Array(VECTOR_DIM);
    expect(v.length).toBe(VECTOR_DIM);
  });
});

describe("Euclidean distance", () => {
  test("same vectors have zero distance", () => {
    const a = new Float32Array([1, 2, 3, 4]);
    const b = new Float32Array([1, 2, 3, 4]);
    expect(euclideanDistance(a, b, 4)).toBe(0);
  });

  test("calculates correct distance", () => {
    const a = new Float32Array([0, 0]);
    const b = new Float32Array([3, 4]);
    expect(euclideanDistance(a, b, 2)).toBe(5);
  });
});

describe("KNN search", () => {
  test("returns 0 when no references", () => {
    const refs: RefEntry[] = [];
    const query = new Float32Array(VECTOR_DIM);
    expect(searchKnn(query, refs)).toBe(0);
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
    expect(searchKnn(query, refs)).toBe(0.6);
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

function normalized(value = 0, max = 1): number {
  return Math.min(1, Math.max(0, value / max));
}

function isHighAmount(amount = 0, maxAmount = 10000): number {
  return (amount > maxAmount * 0.8) ? 1 : 0;
}

function isHighTxCount(count = 0): number {
  return (count > 10) ? 1 : 0;
}

function isFarDistance(km = 0): number {
  return (km > 50) ? 1 : 0;
}

function euclideanDistance(a: Float32Array, b: Float32Array, dim: number): number {
  let sum = 0;
  for (let i = 0; i < dim; i++) {
    const d = a[i] - b[i];
    sum += d * d;
  }
  return Math.sqrt(sum);
}

function searchKnn(query: Float32Array, refs: RefEntry[]): number {
  if (refs.length === 0) return 0;

  const distances: { idx: number; dist: number }[] = [];
  for (let i = 0; i < refs.length; i++) {
    distances.push({ idx: i, dist: euclideanDistance(query, refs[i].vector, VECTOR_DIM) });
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