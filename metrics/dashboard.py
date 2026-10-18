#!/usr/bin/env python3
"""metrics/dashboard.py — render metrics/metrics.db -> metrics/dashboard.html.

M0: scaffold.  Renders the runs recorded so far; the throughput/latency,
coverage, and resource sections populate in M7 as real artifacts land
(docs/PLAN.md §10).
"""
import os
import sqlite3
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(HERE, "metrics.db")
OUT = os.path.join(HERE, "dashboard.html")


def main():
    rows = []
    if os.path.exists(DB):
        con = sqlite3.connect(DB)
        try:
            rows = con.execute("SELECT ts, flows, note FROM runs ORDER BY ts DESC").fetchall()
        except sqlite3.OperationalError:
            rows = []
        con.close()
    body = "\n".join(
        f"<tr><td>{time.strftime('%Y-%m-%d %H:%M', time.gmtime(ts))}</td><td>{flows or ''}</td><td>{note or ''}</td></tr>"
        for ts, flows, note in rows
    ) or "<tr><td colspan=3>no runs recorded yet</td></tr>"
    html = f"""<!doctype html><meta charset=utf-8><title>pcie-on-ucie-3d metrics</title>
<style>body{{font-family:system-ui,sans-serif;margin:2rem}}table{{border-collapse:collapse}}
td,th{{border:1px solid #ccc;padding:4px 8px}}</style>
<h1>pcie-on-ucie-3d — metrics</h1>
<p>M0 scaffold. Throughput/latency, coverage, and resource sections populate in M7.</p>
<table><tr><th>run (UTC)</th><th>flows</th><th>note</th></tr>
{body}
</table>"""
    with open(OUT, "w") as fh:
        fh.write(html)
    print(f"[dashboard] wrote {OUT} ({len(rows)} run(s))")


if __name__ == "__main__":
    main()
