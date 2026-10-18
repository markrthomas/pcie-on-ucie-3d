#!/usr/bin/env python3
"""dv/random/rr.py — random-regression driver (Verilator jobs).

M0: scaffold.  A "job" = a build config (vlt / vlt-fc / vlt-nodpr) + a seed +
plusargs drawn from envelopes, run in its own dir, then cross-checked against the
golden model (dv/common/scenarios.py).  `triage` clusters failures by signature;
`promote`/`replay` manage corpus.json (the permanent gating repro set).

The real loop lands in M4+ (once the datapath + Verilator scenario env exist);
today the subcommands are recognised and report that they are not yet wired, so
`make rr-*` runs cleanly.
"""
import sys

USAGE = "usage: rr.py {build|run|triage|replay} [...]"


def main(argv):
    if not argv:
        print(USAGE)
        return 0
    cmd = argv[0]
    if cmd in ("build", "run", "triage", "replay"):
        print(f"[rr] '{cmd}': random regression lands in M4+ (docs/PLAN.md §11); scaffold only.")
        return 0
    print(USAGE)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
