#!/usr/bin/env python3
"""metrics/collect.py — append-only metrics collector.

Runs + times the requested flows and records real artifacts (logs, coverage.info,
fcov.json, /usr/bin/time, yosys stats) into metrics/metrics.db.  Every value
carries a `kind` (measured / estimated / not_attributable) — NEVER fabricate a
measured number; record the gap instead (docs/PLAN.md §10).

M0: scaffold.  Creates the DB from schema.sql and records a run row so
`make metrics` / `make dashboard` work end to end; the per-flow collectors land
in M7 as the datapath/coverage/formal artifacts become real.
"""
import argparse
import os
import sqlite3
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(HERE, "metrics.db")
SCHEMA = os.path.join(HERE, "schema.sql")


def db():
    con = sqlite3.connect(DB)
    with open(SCHEMA) as fh:
        con.executescript(fh.read())
    return con


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="")
    ap.add_argument("--note", default="")
    ap.add_argument("--import-dir", default="")
    ap.add_argument("--rr-run", default="")
    args = ap.parse_args()

    con = db()
    con.execute(
        "INSERT INTO runs(ts, flows, note) VALUES (?,?,?)",
        (int(time.time()), args.run or args.rr_run or args.import_dir, args.note),
    )
    con.commit()
    con.close()
    print(f"[metrics] recorded run (flows='{args.run or args.rr_run or args.import_dir}') -> {DB}")
    print("[metrics] per-flow collectors (measured/estimated/not_attributable) land in M7 (docs/PLAN.md §11)")


if __name__ == "__main__":
    main()
