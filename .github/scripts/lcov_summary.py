#!/usr/bin/env python3
"""Render an lcov.info file as a markdown coverage summary.

Used by `.github/workflows/foundry-coverage.yml` to post PR comments and
job-summary blocks without depending on any third-party action.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class FileCoverage:
    path: str
    lines_found: int = 0
    lines_hit: int = 0
    branches_found: int = 0
    branches_hit: int = 0
    funcs_found: int = 0
    funcs_hit: int = 0

    @property
    def line_pct(self) -> float:
        return 100.0 * self.lines_hit / self.lines_found if self.lines_found else 100.0

    @property
    def branch_pct(self) -> float:
        return 100.0 * self.branches_hit / self.branches_found if self.branches_found else 100.0

    @property
    def func_pct(self) -> float:
        return 100.0 * self.funcs_hit / self.funcs_found if self.funcs_found else 100.0


def parse_lcov(path: Path) -> dict[str, FileCoverage]:
    files: dict[str, FileCoverage] = {}
    current: FileCoverage | None = None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            current = FileCoverage(path=line[3:])
        elif current is None:
            continue
        elif line == "end_of_record":
            files[current.path] = current
            current = None
        elif line.startswith("LF:"):
            current.lines_found = int(line[3:])
        elif line.startswith("LH:"):
            current.lines_hit = int(line[3:])
        elif line.startswith("BRF:"):
            current.branches_found = int(line[4:])
        elif line.startswith("BRH:"):
            current.branches_hit = int(line[4:])
        elif line.startswith("FNF:"):
            current.funcs_found = int(line[4:])
        elif line.startswith("FNH:"):
            current.funcs_hit = int(line[4:])
    return files


def totals(files: dict[str, FileCoverage]) -> FileCoverage:
    agg = FileCoverage(path="Total")
    for f in files.values():
        agg.lines_found += f.lines_found
        agg.lines_hit += f.lines_hit
        agg.branches_found += f.branches_found
        agg.branches_hit += f.branches_hit
        agg.funcs_found += f.funcs_found
        agg.funcs_hit += f.funcs_hit
    return agg


def fmt_pct(pct: float) -> str:
    return f"{pct:.2f}%"


def fmt_delta(current: float, baseline: float | None) -> str:
    if baseline is None:
        return ""
    delta = current - baseline
    if abs(delta) < 0.005:
        return " (▬)"
    arrow = "▲" if delta > 0 else "▼"
    return f" ({arrow} {abs(delta):.2f}%)"


def render(
    current: dict[str, FileCoverage],
    baseline: dict[str, FileCoverage] | None,
    threshold: float,
    src_prefix: str,
) -> tuple[str, bool]:
    cur_total = totals(current)
    base_total = totals(baseline) if baseline else None

    passed = cur_total.line_pct >= threshold
    gate_icon = "✅" if passed else "❌"
    gate_label = (
        f"**Threshold**: {fmt_pct(threshold)} {gate_icon}"
        if threshold > 0
        else ""
    )

    lines: list[str] = []
    lines.append("## Forge Coverage")
    lines.append("")
    summary = (
        f"**Lines**: {fmt_pct(cur_total.line_pct)}"
        f"{fmt_delta(cur_total.line_pct, base_total.line_pct if base_total else None)}"
        f" ({cur_total.lines_hit}/{cur_total.lines_found}) · "
        f"**Branches**: {fmt_pct(cur_total.branch_pct)}"
        f"{fmt_delta(cur_total.branch_pct, base_total.branch_pct if base_total else None)} · "
        f"**Functions**: {fmt_pct(cur_total.func_pct)}"
        f"{fmt_delta(cur_total.func_pct, base_total.func_pct if base_total else None)}"
    )
    lines.append(summary)
    if gate_label:
        lines.append("")
        lines.append(gate_label)
    lines.append("")
    lines.append("<details>")
    lines.append(f"<summary>Per-file coverage ({len(current)} files)</summary>")
    lines.append("")
    has_baseline = base_total is not None
    header = "| File | Lines | Branches | Funcs |"
    sep = "|---|---|---|---|"
    if has_baseline:
        header = "| File | Lines | Δ | Branches | Funcs |"
        sep = "|---|---|---|---|---|"
    lines.append(header)
    lines.append(sep)

    def sort_key(item: tuple[str, FileCoverage]) -> tuple[int, str]:
        return (0 if item[0].startswith(src_prefix) else 1, item[0])

    for path, fc in sorted(current.items(), key=sort_key):
        base = baseline.get(path) if baseline else None
        line_cell = f"{fmt_pct(fc.line_pct)} ({fc.lines_hit}/{fc.lines_found})"
        row = f"| `{path}` | {line_cell} |"
        if has_baseline:
            delta = fmt_delta(fc.line_pct, base.line_pct if base else None).strip()
            row += f" {delta if delta else '—'} |"
        row += f" {fmt_pct(fc.branch_pct)} | {fmt_pct(fc.func_pct)} |"
        lines.append(row)

    lines.append("")
    lines.append("</details>")
    lines.append("")
    return "\n".join(lines), passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lcov", required=True, type=Path, help="Path to current lcov.info")
    parser.add_argument("--baseline", type=Path, default=None, help="Path to baseline lcov.info (optional)")
    parser.add_argument("--threshold", type=float, default=0.0, help="Minimum acceptable line-coverage percent")
    parser.add_argument("--src-prefix", default="src/", help="Prefix to sort first in the file list")
    parser.add_argument("--output", type=Path, default=None, help="Also write the rendered markdown to this file")
    args = parser.parse_args()

    current = parse_lcov(args.lcov)
    if not current:
        print(f"error: no coverage records parsed from {args.lcov}", file=sys.stderr)
        return 2

    baseline = None
    if args.baseline and args.baseline.exists():
        baseline = parse_lcov(args.baseline)

    markdown, passed = render(current, baseline, args.threshold, args.src_prefix)
    print(markdown)
    if args.output:
        args.output.write_text(markdown)

    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
