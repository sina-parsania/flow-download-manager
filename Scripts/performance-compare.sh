#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Compare a candidate performance baseline JSON against an approved before-baseline.
# Fails closed on missing metrics, incompatible machines, or >10% regressions.
#
# Usage:
#   make performance-compare BASELINE=Artifacts/baselines/<approved>.json
#   CANDIDATE=Artifacts/baselines/<candidate>.json make performance-compare BASELINE=...
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE="${BASELINE:?BASELINE=<path-to-approved-baseline.json> is required}"
CANDIDATE="${CANDIDATE:-Artifacts/baselines/candidate-latest.json}"
THRESHOLD="${PERF_REGRESSION_THRESHOLD:-0.10}"

[[ -f "$BASELINE" ]] || { echo "error: baseline not found: $BASELINE" >&2; exit 2; }
[[ -f "$CANDIDATE" ]] || { echo "error: candidate not found: $CANDIDATE (run make performance-baseline first)" >&2; exit 2; }

python3 - "$BASELINE" "$CANDIDATE" "$THRESHOLD" <<'PY'
import json, sys

baseline_path, candidate_path, threshold_s = sys.argv[1:4]
threshold = float(threshold_s)

def load(path):
    with open(path) as fh:
        return json.load(fh)

base = load(baseline_path)
cand = load(candidate_path)

def machine_key(doc):
    m = doc.get("machine") or {}
    return (m.get("arch"), m.get("cpu"), m.get("memoryGB"), doc.get("os"))

if machine_key(base) != machine_key(cand):
    print("NOT COMPARABLE: machine/os metadata mismatch", file=sys.stderr)
    print(f"  baseline={machine_key(base)}", file=sys.stderr)
    print(f"  candidate={machine_key(cand)}", file=sys.stderr)
    sys.exit(3)

base_metrics = base.get("metrics") or {}
cand_metrics = cand.get("metrics") or {}
# Descriptor-only baselines carry no numbers. Reporting OK here would let a
# green `make performance-compare` be mistaken for evidence of no regression,
# which is the opposite of what this gate is for. Fail closed until XCTest
# metric extraction populates "metrics".
if not base_metrics and not cand_metrics:
    print("NO EVIDENCE: descriptor-only baselines carry no metrics to compare", file=sys.stderr)
    print("  this is not a pass — populate 'metrics' before trusting this gate", file=sys.stderr)
    sys.exit(4)

missing = sorted(set(base_metrics) - set(cand_metrics))
if missing:
    print(f"FAIL: candidate missing metrics: {', '.join(missing)}", file=sys.stderr)
    sys.exit(4)

regressions = []
improvements = []
for name, before in base_metrics.items():
    after = cand_metrics[name]
    if not isinstance(before, (int, float)) or not isinstance(after, (int, float)):
        continue
    if before == 0:
        if after != 0:
            regressions.append((name, before, after, float("inf")))
        continue
    delta = (after - before) / abs(before)
    # Higher is worse for latency/CPU/memory-style metrics unless marked invert.
    invert = name.endswith(".throughput") or name.endswith(".ops")
    worse = (-delta if invert else delta) > threshold
    if worse:
        regressions.append((name, before, after, delta))
    elif (delta if invert else -delta) > threshold:
        improvements.append((name, before, after, delta))

if regressions:
    print("FAIL: regressions above threshold", file=sys.stderr)
    for name, before, after, delta in regressions:
        print(f"  {name}: {before} → {after} ({delta:+.1%})", file=sys.stderr)
    sys.exit(1)

print("OK: no regressions above threshold")
for name, before, after, delta in improvements:
    print(f"  improved {name}: {before} → {after} ({delta:+.1%})")
sys.exit(0)
PY
