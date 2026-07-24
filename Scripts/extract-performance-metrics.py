#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Extract XCTest measure() averages from an xcresult into a flat metrics dict.

Uses `xcrun xcresulttool export metrics` (CSV + manifest). Metric keys are
stable for `performance-compare`:

    <TestClass>/<testName>.<metric_slug>

where metric_slug maps human CSV headers to short identifiers, e.g.
`clock_monotonic_time_s`, `cpu_time_s`, `memory_peak_physical_kb`.

Stdout: JSON object of metric name → float average.
"""

from __future__ import annotations

import csv
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# CSV column stem → (slug, unit-normalised). Values already carry units in the
# cell text ("0.04 s", "51593.984 kB"); we strip the unit token and keep the
# numeric average. Higher-is-worse unless the compare script marks .throughput/.ops.
SLUGS = {
    "Clock Monotonic Time": "clock_monotonic_time_s",
    "CPU Time": "cpu_time_s",
    "CPU Cycles": "cpu_cycles_kc",
    "CPU Instructions Retired": "cpu_instructions_retired_ki",
    "Memory Peak Physical": "memory_peak_physical_kb",
    "Memory Physical": "memory_physical_kb",
}


def parse_average(cell: str) -> float | None:
    if cell is None:
        return None
    text = cell.strip().strip('"')
    if not text:
        return None
    # "0.0428895506 s" / "51593.984 kB" / "854114.0236 kI"
    match = re.match(r"^([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)", text)
    if not match:
        return None
    return float(match.group(1))


def test_key(identifier: str) -> str:
    # "TablePerformanceTests/testBuild10kFixtures()" → same without parens
    return identifier.rstrip("()")


def extract(bundle: Path) -> dict[str, float]:
    with tempfile.TemporaryDirectory(prefix="dm-perf-metrics-") as tmp:
        out = Path(tmp)
        subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "export",
                "metrics",
                "--path",
                str(bundle),
                "--output-path",
                str(out),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        manifest_path = out / "manifest.json"
        if not manifest_path.is_file():
            return {}
        manifest = json.loads(manifest_path.read_text())
        metrics: dict[str, float] = {}
        for entry in manifest:
            ident = test_key(entry.get("testIdentifier") or "")
            # Tool writes Foo.csv but manifest sometimes lists Foo.csv.csv.
            name = entry.get("metricsFileName") or ""
            candidates = [out / name, out / name.removesuffix(".csv"), out / (name + ".csv")]
            # Also match by stem UUID if present.
            csv_path = next((p for p in candidates if p.is_file()), None)
            if csv_path is None:
                # Fall back: any CSV whose UUID prefix matches the (possibly
                # double-suffixed) name.
                stem = name.split(".")[0]
                matches = list(out.glob(f"{stem}*.csv"))
                csv_path = matches[0] if matches else None
            if csv_path is None or not ident:
                continue
            with csv_path.open(newline="") as fh:
                reader = csv.DictReader(fh)
                rows = list(reader)
            if not rows:
                continue
            row = rows[0]
            for header, value in row.items():
                if not header or not header.endswith("(Average)"):
                    continue
                stem = header[: -len("(Average)")].strip()
                slug = SLUGS.get(stem)
                if slug is None:
                    slug = re.sub(r"[^a-z0-9]+", "_", stem.lower()).strip("_")
                average = parse_average(value)
                if average is None:
                    continue
                metrics[f"{ident}.{slug}"] = average
        return metrics


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <performance.xcresult>", file=sys.stderr)
        return 2
    bundle = Path(sys.argv[1])
    if not bundle.is_dir():
        print(f"error: xcresult not found: {bundle}", file=sys.stderr)
        return 2
    print(json.dumps(extract(bundle), sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
