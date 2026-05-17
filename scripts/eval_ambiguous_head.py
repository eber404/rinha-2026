#!/usr/bin/env python3
import argparse
import json
import math
import random
from pathlib import Path


DEFAULT_SEED = 20260517
DEFAULT_THRESHOLD = 0.5


def load_rows(path: Path):
    rows = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    if not rows:
        raise ValueError(f"no rows in {path}")
    return rows


def split_indices(n: int, val_ratio: float, seed: int):
    if n < 2:
        raise ValueError("need at least 2 rows for deterministic train/val split")
    idx = list(range(n))
    rng = random.Random(seed)
    rng.shuffle(idx)
    val_n = max(1, int(n * val_ratio))
    if val_n >= n:
        val_n = n - 1
    return idx[val_n:], idx[:val_n]


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


def sigmoid(z: float):
    if z >= 0:
        ez = math.exp(-z)
        return 1.0 / (1.0 + ez)
    ez = math.exp(z)
    return ez / (1.0 + ez)


def predict_prob(row, model):
    if "features" not in row:
        raise ValueError("row missing 'features'")
    if len(row["features"]) != 14:
        raise ValueError("row features must have length 14")
    if "ivf_score_proxy" not in row:
        raise ValueError("row missing 'ivf_score_proxy'")
    if "weights" not in model or "bias" not in model:
        raise ValueError("model missing weights/bias")

    ivf = float(row["ivf_score_proxy"])
    x = [
        ivf,
        abs(ivf - 0.5),
        float(row["features"][12]),
        1.0,
    ]
    if not all(math.isfinite(v) for v in x):
        raise ValueError("non-finite row features")

    w = model["weights"]
    if len(w) != len(x):
        raise ValueError(f"weights/features length mismatch: {len(w)} != {len(x)}")
    if not all(math.isfinite(float(v)) for v in w):
        raise ValueError("non-finite model weights")
    b = float(model["bias"])
    if not math.isfinite(b):
        raise ValueError("non-finite model bias")
    z = b
    for j, xv in enumerate(x):
        z += float(w[j]) * xv
    return sigmoid(z)


def main():
    parser = argparse.ArgumentParser(description="Evaluate ambiguous head against baseline")
    parser.add_argument("--input", default="vector-index/ambiguous_samples.jsonl", help="ambiguous samples JSONL")
    parser.add_argument("--model", default="vector-index/ambiguous_head.json", help="trained model JSON")
    parser.add_argument("--split-seed", "--seed", dest="split_seed", type=int, default=DEFAULT_SEED, help="seed used for deterministic split")
    parser.add_argument("--val-ratio", type=float, default=0.2, help="validation ratio")
    parser.add_argument("--threshold-override", "--threshold", dest="threshold_override", type=float, default=None, help="override model threshold")
    parser.add_argument("--baseline-threshold", type=float, default=DEFAULT_THRESHOLD, help="baseline threshold")
    parser.add_argument("--output", default=None, help="optional path to write evaluation metrics JSON")
    parser.add_argument("--baseline-only", action="store_true", help="skip model load and force assertion failure")
    parser.add_argument("--assert-improvement", action="store_true", help="assert model weighted error < baseline")
    args = parser.parse_args()

    rows = load_rows(Path(args.input))
    _, val_idx = split_indices(len(rows), args.val_ratio, args.split_seed)
    val_rows = [rows[i] for i in val_idx]

    ys = [1 if int(r["label"]) else 0 for r in val_rows]
    baseline_probs = [float(r["ivf_score_proxy"]) for r in val_rows]
    if not all(math.isfinite(v) for v in baseline_probs):
        raise ValueError("non-finite baseline ivf_score_proxy values")
    baseline_error, baseline_fp, baseline_fn = weighted_error(baseline_probs, ys, args.baseline_threshold)

    print(f"val_rows={len(val_rows)}")
    print(f"baseline_threshold={args.baseline_threshold:.8f}")
    print(f"baseline_weighted_error={baseline_error}")
    print(f"baseline_fp={baseline_fp}")
    print(f"baseline_fn={baseline_fn}")

    metrics = {
        "val_rows": len(val_rows),
        "baseline_threshold": args.baseline_threshold,
        "baseline_weighted_error": baseline_error,
        "baseline_fp": baseline_fp,
        "baseline_fn": baseline_fn,
    }

    if args.baseline_only:
        candidate_error = baseline_error + 1
        print("model=baseline_only")
        print(f"model_weighted_error={candidate_error}")
        metrics.update({
            "model": "baseline_only",
            "model_weighted_error": candidate_error,
        })
        if args.output:
            out = Path(args.output)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(json.dumps(metrics, separators=(",", ":")) + "\n", encoding="utf-8")
        if args.assert_improvement and not (candidate_error < baseline_error):
            raise RuntimeError(
                f"assert-improvement failed: model_weighted_error={candidate_error} baseline={baseline_error}"
            )
        return

    model_path = Path(args.model)
    with model_path.open("r", encoding="utf-8") as f:
        model = json.load(f)

    model_probs = [predict_prob(r, model) for r in val_rows]
    if args.threshold_override is not None:
        threshold = args.threshold_override
        model_error, model_fp, model_fn = weighted_error(model_probs, ys, threshold)
    else:
        threshold = model.get("threshold", DEFAULT_THRESHOLD)
        model_error, model_fp, model_fn = weighted_error(model_probs, ys, threshold)

    sweep_t, sweep_error, sweep_fp, sweep_fn = sweep_threshold(model_probs, ys)

    print(f"model_threshold={threshold:.8f}")
    print(f"model_weighted_error={model_error}")
    print(f"model_fp={model_fp}")
    print(f"model_fn={model_fn}")
    print(f"sweep_best_threshold={sweep_t:.8f}")
    print(f"sweep_best_weighted_error={sweep_error}")
    print(f"sweep_best_fp={sweep_fp}")
    print(f"sweep_best_fn={sweep_fn}")

    metrics.update({
        "model": str(model_path),
        "model_threshold": threshold,
        "model_weighted_error": model_error,
        "model_fp": model_fp,
        "model_fn": model_fn,
        "sweep_best_threshold": sweep_t,
        "sweep_best_weighted_error": sweep_error,
        "sweep_best_fp": sweep_fp,
        "sweep_best_fn": sweep_fn,
    })

    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(metrics, separators=(",", ":")) + "\n", encoding="utf-8")

    if args.assert_improvement and not (model_error < baseline_error):
        raise RuntimeError(
            f"assert-improvement failed: model_weighted_error={model_error} baseline={baseline_error}"
        )


if __name__ == "__main__":
    main()
