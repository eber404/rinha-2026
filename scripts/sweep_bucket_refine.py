#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
KNN_CPP = ROOT / "fraud-api/native/knn.cpp"


DEFAULT_MATRIX = [
    {
        "name": "radius-1",
        "replacements": {
            "BUCKET_REFINE_NEIGHBOR_RADIUS": "1",
        },
    },
    {
        "name": "radius-2",
        "replacements": {
            "BUCKET_REFINE_NEIGHBOR_RADIUS": "2",
        },
    },
    {
        "name": "radius-3",
        "replacements": {
            "BUCKET_REFINE_NEIGHBOR_RADIUS": "3",
        },
    },
    {
        "name": "radius-4",
        "replacements": {
            "BUCKET_REFINE_NEIGHBOR_RADIUS": "4",
        },
    },
]


@dataclass
class Gates:
    p99_max_ms: float


def run(command: list[str], timeout: int | None = None) -> str:
    proc = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({proc.returncode}): {' '.join(command)}\n"
            f"stdout:\n{proc.stdout}\n"
            f"stderr:\n{proc.stderr}"
        )
    return proc.stdout


def replace_constants(source: str, replacements: dict[str, str]) -> str:
    out = source
    for name, value in replacements.items():
        pattern = re.compile(
            rf"(static constexpr (?:float|int) {re.escape(name)} = )[^;]+;"
        )
        out, count = pattern.subn(rf"\g<1>{value};", out)
        if count != 1:
            raise RuntimeError(
                f"failed replacing constant {name}; matched {count} occurrences"
            )
    return out


def parse_benchmark_json(output: str) -> dict:
    start = output.find("{")
    end = output.rfind("}")
    if start < 0 or end < 0 or end < start:
        raise RuntimeError("benchmark output does not contain JSON payload")
    return json.loads(output[start : end + 1])


def parse_p99_ms(p99_text: str) -> float:
    m = re.match(r"^([0-9]+(?:\.[0-9]+)?)ms$", p99_text.strip())
    if not m:
        raise RuntimeError(f"unexpected p99 format: {p99_text}")
    return float(m.group(1))


def wait_ready(max_wait_s: int = 120) -> None:
    deadline = time.time() + max_wait_s
    while time.time() < deadline:
        try:
            out = run(["curl", "-s", "http://localhost:9999/ready"], timeout=10)
            if out.strip() == "OK":
                return
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError("service did not become ready within timeout")


def run_one(combo: dict, gates: Gates) -> dict:
    print(f"== {combo['name']} ==", flush=True)
    run(["docker", "compose", "down", "-v"], timeout=300)
    run(["docker", "compose", "up", "--build", "-d"], timeout=900)
    wait_ready()

    bench_out = run(["make", "benchmark"], timeout=1200)
    payload = parse_benchmark_json(bench_out)
    scoring = payload["scoring"]
    p99_ms = parse_p99_ms(payload["p99"])

    row = {
        "name": combo["name"],
        "replacements": combo["replacements"],
        "p99": payload["p99"],
        "p99_ms": p99_ms,
        "final_score": scoring["final_score"],
        "failure_rate": scoring["failure_rate"],
        "fp": scoring["breakdown"]["false_positive_detections"],
        "fn": scoring["breakdown"]["false_negative_detections"],
        "http_errors": scoring["breakdown"]["http_errors"],
        "passes_gates": p99_ms < gates.p99_max_ms and scoring["breakdown"]["http_errors"] == 0,
    }
    print(json.dumps(row, ensure_ascii=True), flush=True)
    return row


def load_matrix(path: Path | None) -> list[dict]:
    if path is None:
        return DEFAULT_MATRIX
    data = json.loads(path.read_text())
    if not isinstance(data, list):
        raise RuntimeError("matrix must be a JSON array")
    for item in data:
        if "name" not in item or "replacements" not in item:
            raise RuntimeError("matrix items must contain name + replacements")
    return data


def rank_rows(rows: list[dict]) -> list[dict]:
    def key(row: dict):
        # 0 first if passes gates; then lower failure signal; then better score
        return (
            0 if row["passes_gates"] else 1,
            row["fp"] + row["fn"],
            -row["final_score"],
            row["p99_ms"],
        )

    return sorted(rows, key=key)


def main() -> int:
    parser = argparse.ArgumentParser(description="Bucket refine sweep with clean docker state")
    parser.add_argument("--matrix", type=Path, default=None, help="optional JSON matrix")
    parser.add_argument("--limit", type=int, default=0, help="run only first N cases")
    parser.add_argument("--p99-max-ms", type=float, default=1.7, help="hard p99 gate in ms")
    args = parser.parse_args()

    matrix = load_matrix(args.matrix)
    if args.limit > 0:
        matrix = matrix[: args.limit]
    gates = Gates(p99_max_ms=args.p99_max_ms)

    original = KNN_CPP.read_text()
    rows: list[dict] = []
    try:
        for combo in matrix:
            updated = replace_constants(original, combo["replacements"])
            KNN_CPP.write_text(updated)
            rows.append(run_one(combo, gates))
    finally:
        KNN_CPP.write_text(original)
        try:
            run(["docker", "compose", "down", "-v"], timeout=300)
            run(["docker", "compose", "up", "--build", "-d"], timeout=900)
        except Exception as exc:
            print(f"warning: restore stack failed: {exc}", file=sys.stderr)

    ranked = rank_rows(rows)
    print("\nSUMMARY (best first):")
    for row in ranked:
        print(json.dumps(row, ensure_ascii=True))

    out_dir = ROOT / "artifacts"
    out_dir.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_file = out_dir / f"bucket_refine_sweep_{ts}.json"
    out_file.write_text(json.dumps(ranked, indent=2))
    print(f"\nSaved: {out_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
