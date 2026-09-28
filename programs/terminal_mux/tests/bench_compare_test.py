#!/usr/bin/env python3
"""The run-to-run comparison in scripts/bench-run.py calls a change better or
WORSE only when it cannot be noise. These cases pin that rule down: a
regression report that is really noise teaches people to ignore the tool."""
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bench_run", os.path.join(HERE, "..", "scripts", "bench-run.py"))
bench_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench_run)


def metric(median, lo, hi, n=5, higher_is_better=True, trend_only=False):
    return {"median": median, "min": lo, "max": hi, "n": n,
            "higher_is_better": higher_is_better, "trend_only": trend_only}


def verdicts(old, new):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump({"metrics": old}, f)
    try:
        _, rows, regressions = bench_run.compare({"metrics": new}, f.name)
    finally:
        os.unlink(f.name)
    return {r[0]: r[4] for r in rows}, regressions


failures = 0


def check(name, cond, detail=""):
    global failures
    print(("PASS " if cond else "FAIL ") + name + (f"  ({detail})" if detail and not cond else ""))
    failures += 0 if cond else 1


v, reg = verdicts(
    {
        "drop": metric(100, 95, 105),
        "overlap": metric(100, 95, 105),
        "few": metric(100, 95, 105, n=2),
        "trend": metric(100, 99, 101, trend_only=True),
        "latency_down": metric(100, 90, 110, higher_is_better=False),
        "small": metric(100, 99, 101),
    },
    {
        "drop": metric(80, 78, 82),
        "overlap": metric(90, 85, 99),
        "few": metric(80, 78, 82, n=2),
        "trend": metric(50, 49, 51, trend_only=True),
        "latency_down": metric(80, 75, 85, higher_is_better=False),
        "small": metric(97, 96.5, 97.5),
    },
)
check("a drop with disjoint ranges and n>=5 is WORSE", v["drop"] == "WORSE", v["drop"])
check("a drop whose ranges overlap is noise", v["overlap"] == "~", v["overlap"])
check("too few samples is never a verdict", v["few"].startswith("?"), v["few"])
check("a trend-only metric is never judged", v["trend"] == "(trend)", v["trend"])
check("lower latency is better", v["latency_down"] == "better", v["latency_down"])
check("a change within 5% is noise even when ranges part", v["small"] == "~", v["small"])
check("only real regressions are returned", reg == ["drop"], reg)
check("a metric the old run lacks is skipped", "new_only" not in verdicts({}, {"new_only": metric(1, 1, 1)})[0])

if failures:
    sys.exit(f"{failures} bench comparison check(s) failed")
print("ALL BENCH COMPARE CHECKS PASS")
