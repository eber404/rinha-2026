#!/usr/bin/env python3
import argparse
import json
import mmap
import struct
from pathlib import Path

KNN_DIMS = 14
FRAUD_MAX_RULE_LEAVES = 128
FRAUD_MAX_LEAF_FEATURES = 4


def load_rules(path: Path):
    data = path.read_bytes()
    off = 0

    def unpack(fmt: str):
        nonlocal off
        size = struct.calcsize(fmt)
        out = struct.unpack_from(fmt, data, off)
        off += size
        return out

    _min_conf_legit, _min_conf_fraud, min_mcc_risk_fraud, max_amount_vs_avg_legit, min_amount_vs_avg_fraud, max_km_home_legit, min_km_home_fraud = unpack("<7f")
    (leaf_count,) = unpack("<I")
    leaves = []
    for _ in range(FRAUD_MAX_RULE_LEAVES):
        decision, feature_count = unpack("<BB")
        features = list(unpack("<4B"))
        unpack("<2B")
        min_values = list(unpack("<4f"))
        max_values = list(unpack("<4f"))
        (support,) = unpack("<I")
        leaves.append(
            {
                "decision": decision,
                "feature_count": feature_count,
                "features": features,
                "min_values": min_values,
                "max_values": max_values,
                "support": support,
            }
        )
    return {
        "leaf_count": min(leaf_count, FRAUD_MAX_RULE_LEAVES),
        "min_mcc_risk_fraud": min_mcc_risk_fraud,
        "max_amount_vs_avg_legit": max_amount_vs_avg_legit,
        "min_amount_vs_avg_fraud": min_amount_vs_avg_fraud,
        "max_km_home_legit": max_km_home_legit,
        "min_km_home_fraud": min_km_home_fraud,
        "leaves": leaves,
    }


def decide_conservative(v, rules):
    for i in range(rules["leaf_count"]):
        leaf = rules["leaves"][i]
        fc = leaf["feature_count"]
        if fc == 0 or fc > FRAUD_MAX_LEAF_FEATURES:
            continue
        match = True
        for j in range(fc):
            feature = leaf["features"][j]
            if feature >= KNN_DIMS:
                match = False
                break
            value = v[feature]
            if value < leaf["min_values"][j] or value > leaf["max_values"][j]:
                match = False
                break
        if not match:
            continue
        if leaf["decision"] == 0:
            return 0
        if leaf["decision"] == 1:
            return 1

    amount_vs_avg = v[2]
    km_home = v[7]
    mcc_risk = v[12]
    unknown_merchant = v[11]
    if amount_vs_avg <= rules["max_amount_vs_avg_legit"] and km_home <= rules["max_km_home_legit"] and unknown_merchant < 0.5:
        return 0
    if amount_vs_avg >= rules["min_amount_vs_avg_fraud"] and km_home >= rules["min_km_home_fraud"] and mcc_risk >= rules["min_mcc_risk_fraud"]:
        return 1
    return 2


def compute_cluster_label_proxy(ivf_path: Path, labels: bytes):
    proxy = []
    with ivf_path.open("rb") as f:
        header = f.read(8)
        if len(header) != 8:
            raise ValueError("invalid ivf header")
        n_clusters, dims = struct.unpack("<ii", header)
        if dims != KNN_DIMS:
            raise ValueError(f"unexpected ivf dims={dims}")
        centroids = struct.unpack("<" + "f" * (n_clusters * dims), f.read(n_clusters * dims * 4))
        for _ in range(n_clusters):
            raw = f.read(4)
            if len(raw) != 4:
                raise ValueError("invalid ivf list size")
            (count,) = struct.unpack("<I", raw)
            if count == 0:
                proxy.append(None)
                continue
            ids_raw = f.read(count * 4)
            if len(ids_raw) != count * 4:
                raise ValueError("invalid ivf list data")
            frauds = 0
            for i in range(count):
                idx = struct.unpack_from("<I", ids_raw, i * 4)[0]
                if idx >= len(labels):
                    raise ValueError(
                        f"ivf posting id out of range: cluster_item={i} id={idx} labels={len(labels)}"
                    )
                frauds += 1 if labels[idx] else 0
            proxy.append(frauds / float(count))
    return n_clusters, dims, centroids, proxy


def nearest_cluster(vec, n_clusters, dims, centroids):
    best = 0
    best_dist = float("inf")
    for c in range(n_clusters):
        base = c * dims
        dist = 0.0
        for i in range(dims):
            d = vec[i] - centroids[base + i]
            dist += d * d
        if dist < best_dist:
            best_dist = dist
            best = c
    return best


def main():
    parser = argparse.ArgumentParser(description="Export ambiguous samples from vector-index artifacts")
    parser.add_argument("--data-dir", default="vector-index", help="directory with dataset/labels/ivf/rules artifacts")
    parser.add_argument("--output", default="vector-index/ambiguous_samples.jsonl", help="output jsonl path")
    parser.add_argument("--limit", type=int, default=0, help="max ambiguous rows to export (0=all)")
    args = parser.parse_args()

    data_dir = Path(args.data_dir)
    dataset_path = data_dir / "dataset_full.bin"
    labels_path = data_dir / "labels_full.bin"
    if not dataset_path.exists():
        dataset_path = data_dir / "dataset.bin"
    if not labels_path.exists():
        labels_path = data_dir / "labels.bin"

    rules = load_rules(data_dir / "rules_model.bin")
    labels = labels_path.read_bytes()
    n_clusters, dims, centroids, cluster_proxy = compute_cluster_label_proxy(data_dir / "ivf_index.bin", labels)

    vector_stride = KNN_DIMS * 4
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    ambiguous_total = 0
    rows_total = 0
    ambiguous_label_0 = 0
    ambiguous_label_1 = 0

    with dataset_path.open("rb") as fd, out_path.open("w", encoding="utf-8") as out:
        mm = mmap.mmap(fd.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            if len(mm) % vector_stride != 0:
                raise ValueError("dataset size is not multiple of 14 floats")
            rows_total = len(mm) // vector_stride
            if len(labels) < rows_total:
                raise ValueError("labels shorter than dataset rows")

            for idx in range(rows_total):
                base = idx * vector_stride
                vec = struct.unpack_from("<14f", mm, base)
                decision = decide_conservative(vec, rules)
                if decision != 2:
                    continue
                label = 1 if labels[idx] else 0
                if label == 1:
                    ambiguous_label_1 += 1
                else:
                    ambiguous_label_0 += 1

                cluster_id = nearest_cluster(vec, n_clusters, dims, centroids)
                row = {
                    "id": idx,
                    "label": label,
                    "features": vec,
                    "ivf_score_proxy": cluster_proxy[cluster_id],
                }
                out.write(json.dumps(row, separators=(",", ":")) + "\n")
                ambiguous_total += 1
                if args.limit > 0 and ambiguous_total >= args.limit:
                    break
        finally:
            mm.close()

    print(f"rows_total={rows_total}")
    print(f"ambiguous_exported={ambiguous_total}")
    print(f"ambiguous_label_0={ambiguous_label_0}")
    print(f"ambiguous_label_1={ambiguous_label_1}")
    print(f"output={out_path}")


if __name__ == "__main__":
    main()
