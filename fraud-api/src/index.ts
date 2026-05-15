import { dlopen, FFIType, ptr } from "bun:ffi";
import { vectorize, type Payload } from "./vectorize";
import { join } from "path";

const DATASET_PATH = "/data/vector-index/dataset.bin";
const LABELS_PATH = "/data/vector-index/labels.bin";
const INDEX_PATH = "/data/vector-index/ivf_index.bin";

const nativePath = join(import.meta.dir, "../native/build/knn.so");
const lib = dlopen(nativePath, {
  knn_init: {
    args: [FFIType.ptr, FFIType.ptr, FFIType.ptr],
    returns: FFIType.int,
  },
  knn_search: {
    args: [FFIType.ptr, FFIType.int, FFIType.ptr, FFIType.ptr, FFIType.ptr],
    returns: FFIType.int,
  },
});

const initRes = lib.symbols.knn_init(
  Buffer.from(DATASET_PATH + "\0"),
  Buffer.from(LABELS_PATH + "\0"),
  Buffer.from(INDEX_PATH + "\0")
);
if (initRes !== 0) {
  console.error("Failed to initialize KNN engine");
  process.exit(1);
}

const queryBuf = new Float32Array(14);
const indicesBuf = new Uint32Array(5);
const distsBuf = new Float32Array(5);
const labelsBuf = new Uint8Array(5);

function score(payload: Payload): { approved: boolean; fraud_score: number } {
  const vec = vectorize(payload);
  if (vec.some(isNaN)) {
    console.warn("NaN vector detected, falling back to approve");
    return { approved: true, fraud_score: 0.0 };
  }
  queryBuf.set(vec);

  const n = lib.symbols.knn_search(
    ptr(new Uint8Array(queryBuf.buffer)),
    5,
    ptr(new Uint8Array(indicesBuf.buffer)),
    ptr(new Uint8Array(distsBuf.buffer)),
    ptr(new Uint8Array(labelsBuf.buffer))
  );

  if (n < 0) {
    return { approved: true, fraud_score: 0.0 };
  }

  let frauds = 0;
  for (let i = 0; i < n; ++i) {
    if (labelsBuf[i] === 1) frauds++;
  }
  const fraud_score = frauds / 5.0;
  return { approved: fraud_score < 0.6, fraud_score };
}

const socketPath = `/tmp/rinha/api-${process.env.INSTANCE_ID ?? "1"}.sock`;

Bun.serve({
  unix: socketPath,
  fetch(req: Request) {
    const url = new URL(req.url);
    if (url.pathname === "/ready") {
      return new Response("OK", { status: 200 });
    }
    if (url.pathname === "/fraud-score" && req.method === "POST") {
      return req.json().then((body: Payload) => {
        const result = score(body);
        return Response.json(result);
      }).catch(() => {
        return new Response("Bad Request", { status: 400 });
      });
    }
    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Fraud API listening on ${socketPath}`);
