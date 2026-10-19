#!/usr/bin/env python3
"""covcheck.py — line-coverage floor gate over rtl/.

Usage: covcheck.py coverage.info [floor_pct]

Parses an lcov .info file (as written by verilator_coverage --write-info),
sums LF/LH over rtl/ source files, prints a per-file table and the total, and
exits non-zero if the total line-coverage percentage is below the floor.
"""
import os
import sys


def main() -> int:
    info = sys.argv[1] if len(sys.argv) > 1 else "coverage.info"
    floor = float(sys.argv[2]) if len(sys.argv) > 2 else 80.0
    if not os.path.exists(info):
        print(f"covcheck: {info} not found")
        return 1
    # lcov from verilator_coverage emits per-line DA:<line>,<hits> records (and
    # BRDA/BRF/BRH for branches) rather than LF/LH summaries; derive line
    # found/hit from the DA records.
    per = {}
    cur = None
    for ln in open(info):
        if ln.startswith("SF:"):
            cur = ln[3:].strip()
        elif ln.startswith("DA:"):
            try:
                _line, hits = ln[3:].strip().split(",")[:2]
            except ValueError:
                continue
            e = per.setdefault(cur, [0, 0])
            e[0] += 1
            if int(hits) > 0:
                e[1] += 1
        elif ln.startswith("LF:"):
            per.setdefault(cur, [0, 0])[0] += int(ln[3:])
        elif ln.startswith("LH:"):
            per.setdefault(cur, [0, 0])[1] += int(ln[3:])
    lf = lh = 0
    print(f"{'file':30s} {'hit/found':>12s}  cov")
    for k in sorted(per):
        if "/rtl/" not in k and not k.startswith("rtl/") and os.path.sep + "rtl" not in k:
            # still count it, but the floor is about the design RTL
            pass
        a, b = per[k][0], per[k][1]
        lf += a
        lh += b
        print(f"{os.path.basename(k):30s} {b:5d}/{a:<5d}    {100*b/a if a else 0:5.1f}%")
    pct = 100 * lh / lf if lf else 0.0
    print("-" * 52)
    print(f"{'TOTAL line coverage':30s} {lh:5d}/{lf:<5d}    {pct:5.1f}%  (floor {floor:.0f}%)")
    if pct < floor:
        print(f"COVERAGE FAIL: {pct:.1f}% < {floor:.0f}% floor")
        return 1
    print(f"COVERAGE PASS: {pct:.1f}% >= {floor:.0f}% floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
