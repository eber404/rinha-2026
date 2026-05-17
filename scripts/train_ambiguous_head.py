#!/usr/bin/env python3
import argparse
import json
import math
import random
from pathlib import Path


DEFAULT_SEED = 20260517
DEFAULT_THRESHOLD = 0.5
RUNTIME_DECISION_THRESHOLD = 0.6


def load_rows(path: Path):
    rows = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            rows.append(row)
    if not rows:
        raise ValueError(f"no rows in {path}")
    return rows


def build_examples(rows):
    features = []
    labels = []
    for idx, row in enumerate(rows):
        vec14 = row["features"]
        ivf = row.get("ivf_score_proxy")
        if len(vec14) != 14:
            raise ValueError("expected 14-dim features")
        if ivf is None:
            raise ValueError("missing ivf_score_proxy")
        ivf_f = float(ivf)
        x = [
            ivf_f,
            abs(ivf_f - 0.5),
            float(vec14[12]),
            1.0,
        ]
        if not all(math.isfinite(v) for v in x):
            raise ValueError(f"non-finite feature value at row={idx}")
        y = 1 if int(row["label"]) else 0
        features.append(x)
        labels.append(y)
    return features, labels


def split_indices(n: int, val_ratio: float, seed: int):
    if n < 2:
        raise ValueError("need at least 2 rows for deterministic train/val split")
    idx = list(range(n))
    rng = random.Random(seed)
    rng.shuffle(idx)
    val_n = max(1, int(n * val_ratio))
    if val_n >= n:
        val_n = n - 1
    val_idx = idx[:val_n]
    train_idx = idx[val_n:]
    return train_idx, val_idx


def sigmoid(z: float):
    if z >= 0:
        ez = math.exp(-z)
        return 1.0 / (1.0 + ez)
    ez = math.exp(z)
    return ez / (1.0 + ez)


def logit(p: float):
    eps = 1e-9
    p = min(max(p, eps), 1.0 - eps)
    return math.log(p / (1.0 - p))


def train_logistic(xs, ys, epochs: int, lr: float, l2: float, seed: int):
    dim = len(xs[0])
    w = [0.0] * dim
    b = 0.0
    order = list(range(len(xs)))
    rng = random.Random(seed)

    for _ in range(epochs):
        rng.shuffle(order)
        for i in order:
            x = xs[i]
            y = ys[i]
            z = b
            for j, xv in enumerate(x):
                z += w[j] * xv
            p = sigmoid(z)
            err = p - y
            for j, xv in enumerate(x):
                grad = err * xv + (l2 * w[j])
                w[j] -= lr * grad
            b -= lr * err
    return w, b


def predict_prob(x, w, b):
    z = b
    for j, xv in enumerate(x):
        z += w[j] * xv
    return sigmoid(z)


def weighted_error(probs, ys, threshold: float):
    fp = 0
    fn = 0
    for p, y in zip(probs, ys):
        pred = 1 if p >= threshold else 0
        if pred == 1 and y == 0:
            fp += 1
        elif pred == 0 and y == 1:
            fn += 1
    return fp + (3 * fn), fp, fn


def sweep_threshold(probs, ys):
    if not probs:
        raise ValueError("empty probability set in threshold sweep")
    max_p = max(probs)
    min_p = min(probs)
    eps = 1e-12
    candidates = sorted(set(probs + [DEFAULT_THRESHOLD, min_p - eps, max_p + eps]))
    best_t = DEFAULT_THRESHOLD
    best_err, best_fp, best_fn = weighted_error(probs, ys, best_t)
    for t in candidates:
        err, fp, fn = weighted_error(probs, ys, t)
        if err < best_err or (err == best_err and t < best_t):
            best_t = t
            best_err, best_fp, best_fn = err, fp, fn
    return best_t, best_err, best_fp, best_fn


def main():
    parser = argparse.ArgumentParser(description="Train ambiguous-only logistic head")
    parser.add_argument("--input", default="vector-index/ambiguous_samples.jsonl", help="ambiguous samples JSONL")
    parser.add_argument("--output", default="vector-index/ambiguous_head.json", help="output model JSON")
    parser.add_argument("--output-bin", default="vector-index/ambiguous_head.bin", help="output native binary head")
    parser.add_argument("--split-seed", "--seed", dest="split_seed", type=int, default=DEFAULT_SEED, help="seed used for deterministic split")
    parser.add_argument("--val-ratio", type=float, default=0.2, help="validation ratio for threshold sweep")
    parser.add_argument("--epochs", type=int, default=12, help="training epochs")
    parser.add_argument("--lr", type=float, default=0.05, help="learning rate")
    parser.add_argument("--l2", type=float, default=1e-4, help="L2 regularization")
    parser.add_argument("--threshold-override", "--threshold", dest="threshold_override", type=float, default=None, help="optional fixed threshold")
    args = parser.parse_args()

    rows = load_rows(Path(args.input))
    xs, ys = build_examples(rows)
    train_idx, val_idx = split_indices(len(xs), args.val_ratio, args.split_seed)

    xs_train = [xs[i] for i in train_idx]
    ys_train = [ys[i] for i in train_idx]
    xs_val = [xs[i] for i in val_idx]
    ys_val = [ys[i] for i in val_idx]

    w, b = train_logistic(xs_train, ys_train, epochs=args.epochs, lr=args.lr, l2=args.l2, seed=args.split_seed)
    probs_val = [predict_prob(x, w, b) for x in xs_val]

    if args.threshold_override is None:
        threshold, val_err, val_fp, val_fn = sweep_threshold(probs_val, ys_val)
    else:
        threshold = args.threshold_override
        val_err, val_fp, val_fn = weighted_error(probs_val, ys_val, threshold)

    model = {
        "model_type": "logistic_linear_head",
        "feature_schema": [
            "ivf_score",
            "abs_ivf_distance_from_0_5",
            "mcc_risk",
            "found_ratio",
        ],
        "weights": w,
        "bias": b,
        "threshold": threshold,
        "training": {
            "split_seed": args.split_seed,
            "val_ratio": args.val_ratio,
            "epochs": args.epochs,
            "lr": args.lr,
            "l2": args.l2,
            "val_weighted_error": val_err,
            "val_fp": val_fp,
            "val_fn": val_fn,
            "train_rows": len(xs_train),
            "val_rows": len(xs_val),
        },
    }

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as f:
        json.dump(model, f, separators=(",", ":"))
        f.write("\n")

    # Native runtime compares score against 0.6 in Bun (`approved: score < 0.6`).
    # We calibrate binary bias so runtime threshold 0.6 matches trained threshold.
    delta = logit(RUNTIME_DECISION_THRESHOLD) - logit(threshold)
    runtime_bias = float(b + delta)

    # Native binary format (see fraud-api/native/ambiguous_head.h)
    import struct

    out_bin = Path(args.output_bin)
    out_bin.parent.mkdir(parents=True, exist_ok=True)
    blob = struct.pack(
        "<IIIIf4f",
        0x414D4231,  # magic AMB1
        1,           # version
        4,           # feature_count
        0,           # reserved
        runtime_bias,
        float(w[0]), float(w[1]), float(w[2]), float(w[3]),
    )
    out_bin.write_bytes(blob)

    print(f"input_rows={len(xs)}")
    print(f"train_rows={len(xs_train)}")
    print(f"val_rows={len(xs_val)}")
    print(f"threshold={threshold:.8f}")
    print(f"runtime_threshold={RUNTIME_DECISION_THRESHOLD:.8f}")
    print(f"runtime_bias={runtime_bias:.8f}")
    print(f"val_weighted_error={val_err}")
    print(f"output={out}")
    print(f"output_bin={out_bin}")


if __name__ == "__main__":
    main()
