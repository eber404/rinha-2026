#!/usr/bin/env python3
import argparse
import json
import math
import os
import re
from statistics import median


HAP_RE = re.compile(
    r"req_id=(?P<req_id>\S+) .*? st=(?P<st>\d+) Tq=(?P<Tq>-?\d+) Tw=(?P<Tw>-?\d+) Tc=(?P<Tc>-?\d+) Tr=(?P<Tr>-?\d+) Tt=(?P<Tt>-?\d+)"
)


def pct(values, p):
    if not values:
        return 0.0
    vals = sorted(values)
    k = (len(vals) - 1) * p
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return float(vals[int(k)])
    d0 = vals[f] * (c - k)
    d1 = vals[c] * (k - f)
    return float(d0 + d1)


def parse_haproxy(path):
    out = {}
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            m = HAP_RE.search(line)
            if not m:
                continue
            req_id = m.group("req_id")
            out[req_id] = {
                "status": int(m.group("st")),
                "Tq": int(m.group("Tq")),
                "Tw": int(m.group("Tw")),
                "Tc": int(m.group("Tc")),
                "Tr": int(m.group("Tr")),
                "Tt": int(m.group("Tt")),
            }
    return out


def parse_server(path):
    out = {}
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            i = line.find("{\"kind\":\"req_trace\"")
            if i == -1:
                continue
            s = line[i:].strip()
            try:
                obj = json.loads(s)
            except Exception:
                continue
            req_id = obj.get("req_id")
            if not req_id:
                continue
            out[req_id] = obj
    return out


def to_ms(us):
    return us / 1000.0


def summarize(name, values):
    return (
        f"| {name} | {pct(values, 0.50):.3f} | {pct(values, 0.95):.3f} |"
        f" {pct(values, 0.99):.3f} |\n"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    hap = parse_haproxy(os.path.join(args.input, "haproxy.log"))
    s1 = parse_server(os.path.join(args.input, "server-1.log"))
    s2 = parse_server(os.path.join(args.input, "server-2.log"))
    srv = {**s1, **s2}

    rows = []
    for req_id, h in hap.items():
        g = srv.get(req_id)
        if not g:
            continue
        go_total_ms = to_ms(g.get("t_total_us", 0))
        row = {
            "req_id": req_id,
            "lb_qw_ms": float(max(h["Tq"], h["Tw"])),
            "lb_tr_ms": float(h["Tr"]),
            "lb_tt_ms": float(h["Tt"]),
            "go_read_ms": to_ms(g.get("t_read_us", 0)),
            "go_parse_ms": to_ms(g.get("t_parse_us", 0)),
            "go_eval_ms": to_ms(g.get("t_eval_us", 0)),
            "go_resp_ms": to_ms(g.get("t_resp_us", 0)),
            "go_total_ms": go_total_ms,
            "net_handoff_ms": float(h["Tr"]) - go_total_ms,
            "status": h["status"],
        }
        rows.append(row)

    metrics = [
        "lb_qw_ms",
        "lb_tr_ms",
        "lb_tt_ms",
        "go_read_ms",
        "go_parse_ms",
        "go_eval_ms",
        "go_resp_ms",
        "go_total_ms",
        "net_handoff_ms",
    ]

    md = []
    md.append("# E2E Latency Report\n")
    md.append(f"- Input dir: `{args.input}`\n")
    md.append(f"- Joined requests: `{len(rows)}`\n")
    md.append("\n## Percentiles (ms)\n")
    md.append("| metric | p50 | p95 | p99 |\n")
    md.append("|---|---:|---:|---:|\n")
    for m in metrics:
        md.append(summarize(m, [r[m] for r in rows]))

    top = sorted(rows, key=lambda r: r["lb_tt_ms"], reverse=True)[:5]
    md.append("\n## Top 5 Tail Requests (by lb_tt_ms)\n")
    md.append("| req_id | status | lb_tt_ms | lb_qw_ms | lb_tr_ms | go_total_ms | go_eval_ms | net_handoff_ms |\n")
    md.append("|---|---:|---:|---:|---:|---:|---:|---:|\n")
    for r in top:
        md.append(
            f"| `{r['req_id']}` | {r['status']} | {r['lb_tt_ms']:.3f} | {r['lb_qw_ms']:.3f}"
            f" | {r['lb_tr_ms']:.3f} | {r['go_total_ms']:.3f} | {r['go_eval_ms']:.3f} | {r['net_handoff_ms']:.3f} |\n"
        )

    bottleneck = "lb_queue_or_wait"
    p99_q = pct([r["lb_qw_ms"] for r in rows], 0.99)
    p99_eval = pct([r["go_eval_ms"] for r in rows], 0.99)
    p99_parse = pct([r["go_parse_ms"] for r in rows], 0.99)
    if p99_eval > p99_q and p99_eval > p99_parse:
        bottleneck = "zig_eval"
    elif p99_parse > p99_q and p99_parse > p99_eval:
        bottleneck = "go_parse"

    md.append("\n## Conclusion\n")
    md.append(f"- Dominant bottleneck candidate: `{bottleneck}`\n")
    md.append(f"- p99 lb_qw_ms: `{p99_q:.3f}`\n")
    md.append(f"- p99 go_eval_ms: `{p99_eval:.3f}`\n")
    md.append(f"- p99 go_parse_ms: `{p99_parse:.3f}`\n")

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        f.write("".join(md))


if __name__ == "__main__":
    main()
