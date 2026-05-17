import { dlopen, FFIType, ptr } from "bun:ffi";
import { vectorize, type Payload } from "./vectorize";
import { join } from "path";

const DATASET_DIR = process.env.FRAUD_DATASET_PATH ?? "/data/vector-index";

const nativePath = join(import.meta.dir, "../native/build/knn.so");
const lib = dlopen(nativePath, {
  fraud_init: {
    args: [FFIType.ptr],
    returns: FFIType.int,
  },
  fraud_score: {
    args: [FFIType.ptr],
    returns: FFIType.float,
  },
  fraud_close: {
    args: [],
    returns: FFIType.void,
  },
});

const initRes = lib.symbols.fraud_init(Buffer.from(DATASET_DIR + "\0"));
if (initRes !== 0) {
  console.error("fatal: fraud engine init failed");
  process.exit(1);
}

const queryBuf = new Float32Array(14);

function score(payload: Payload): { approved: boolean; fraud_score: number } {
  const vec = vectorize(payload);
  if (vec.some(isNaN)) {
    return { approved: false, fraud_score: 1.0 };
  }
  queryBuf.set(vec);

  const raw = lib.symbols.fraud_score(ptr(new Uint8Array(queryBuf.buffer)));
  const fraud_score = Number.isFinite(raw) ? Math.max(0, Math.min(1, raw)) : 1.0;
  return { approved: fraud_score < 0.6, fraud_score };
}

const socketPath = `/tmp/rinha/api-${process.env.INSTANCE_ID ?? "1"}.sock`;
try { require("fs").unlinkSync(socketPath); } catch {}

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
