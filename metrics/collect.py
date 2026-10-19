#!/usr/bin/env python3
"""Collect one run's metrics into metrics/metrics.db (schema.sql).

  collect.py [--run FLOW,...] [--note TEXT] [--db PATH]
  collect.py --rr-run DIR [--db PATH]         add random-regression rows (category rr) to the latest run
  collect.py --import-dir DIR [--db PATH]     merge Railway runs (runs/*/ from the metrics-data branch)

--run  runs the listed root make targets first, each timed with a wall clock
       (kind=measured) and recorded PASS/FAIL.  Default: collect only from the
       artifacts already on disk.  `make metrics` runs
       regress,crosscheck,coverage,formal,upf-tb (add nothing for uvm — crosscheck
       already runs every env's scenario pass).
Then parses real artifacts only:
  dv/iverilog/sim_build/*.log   directed test PASS lines (frames/flits)
  dv/{iverilog/sim_build,vlt/logs,systemc/logs,uvm/logs}/results.json, dv/cocotb/results.json
  coverage.info                 lcov line coverage over rtl/ (measured)
  dv/cocotb/fcov.json           PyVSC functional coverage (measured, if present)
  formal/*_prove/status, formal/*_cover/status
  yosys (+slang) coarse elaboration -> flop/memory bits (estimated)
Anything without a source is stored as kind=not_attributable with value NULL.
An artifact that is missing is recorded as NOT_RUN — never filled in.
"""
import argparse
import datetime
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, "metrics", "metrics.db")
SCHEMA = os.path.join(ROOT, "metrics", "schema.sql")
ENV_RESULTS = {
    "iverilog": "dv/iverilog/sim_build/results.json",
    "vlt": "dv/vlt/logs/results.json",
    "systemc": "dv/systemc/logs/results.json",
    "uvm": "dv/uvm/logs/results.json",
    "cocotb": "dv/cocotb/results.json",
}
TEST_PASS = {  # test -> (log, regex with named groups)
    "smoke": ("dv/iverilog/sim_build/smoke.log", r"SMOKE PASS"),
    "tx": ("dv/iverilog/sim_build/tx.log", r"TX PASS: (?P<frames>\d+) frames, (?P<flits>\d+) flits"),
    "loop": ("dv/iverilog/sim_build/loop.log", r"LOOP PASS: (?P<frames>\d+) frames, (?P<flits>\d+) flits"),
    "pm": ("dv/iverilog/sim_build/pm.log", r"PM PASS: (?P<frames>\d+) frames .*?, (?P<flits>\d+) flits"),
    "rxovf": ("dv/iverilog/sim_build/rxovf.log", r"RXOVF PASS: (?P<frames>\d+) frames sent"),
    "scen": ("dv/iverilog/sim_build/scen.log", r"SCEN PASS"),
    "upf-tb": ("lp/sim_build/upf_tb.log", r"UPF-TB PASS: (?P<frames>\d+) frames"),
}
TOP = "pcie_ucie3d_adapter"
PKG = "pcie_ucie3d_pkg"
RTL = ["async_fifo", "tx_ingress_gate", "tx_framer", "tx_egress", "rx_ingress", "rx_deframer",
       "pcie_egress", "ucie_sb_master", "fc_ctl", "adapter_ctrl_fsm", "adapter_rf", TOP]


class Run:
    def __init__(self, con, run_id):
        self.con, self.run_id, self.n = con, run_id, 0

    def add(self, category, name, value=None, unit=None, kind="measured", status=None, source=None, detail=None):
        assert kind in ("measured", "estimated", "not_attributable")
        if kind == "not_attributable":
            value = None
        self.con.execute("INSERT INTO metrics VALUES (?,?,?,?,?,?,?,?,?)",
                         (self.run_id, category, name, value, unit, status, kind, source, detail))
        self.n += 1


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, cwd=ROOT, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception:
        return ""


def tool_versions():
    v = {}
    for name, cmd in [("iverilog", "iverilog -V 2>&1 | head -1"), ("verilator", "verilator --version"),
                      ("yosys", "yosys -V"), ("sby", "sby --version 2>/dev/null || echo present"),
                      ("python", "python3 --version"),
                      ("cocotb", "python3 -c 'import cocotb;print(cocotb.__version__)'")]:
        out = sh(cmd)
        v[name] = out.splitlines()[0] if out else "not found"
    return v


def rel(p):
    return os.path.join(ROOT, p)


FLOW_TIMEOUT = int(os.environ.get("METRICS_FLOW_TIMEOUT", "2700"))   # seconds per flow (default 45 min)


def run_flows(r, flows):
    """Run each root make target, timed.  A flow that exceeds FLOW_TIMEOUT is killed (the whole process
    group, so verilator / vvp / yosys children go too) and recorded as FAIL - a hung flow must not hold a
    container (and its bill) forever.  Progress lines are flushed so a container log shows them live."""
    for f in flows:
        print(f"collect: make {f}: started (timeout {FLOW_TIMEOUT} s)", flush=True)
        t0 = time.monotonic()
        p = subprocess.Popen(["make", f], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             start_new_session=True)
        timed_out = False
        try:
            out, err = p.communicate(timeout=FLOW_TIMEOUT)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(p.pid, 9)
            except ProcessLookupError:
                pass
            out, err = p.communicate()
        dt = time.monotonic() - t0
        st = "PASS" if (p.returncode == 0 and not timed_out) else "FAIL"
        detail = None
        if st == "FAIL":
            detail = (f"TIMEOUT after {FLOW_TIMEOUT} s (killed); " if timed_out else "") + (out or "")[-400:] + (err or "")[-400:]
        r.add("flow", f"make {f}", round(dt, 2), "s", "measured", st, "wall clock around `make`", detail)
        print(f"collect: make {f}: {st}{' (TIMEOUT)' if timed_out else ''} in {dt:.1f} s", flush=True)


def tests(r):
    for t, (log, rx) in TEST_PASS.items():
        p = rel(log)
        if not os.path.exists(p):
            r.add("test", t, None, None, "not_attributable", "NOT_RUN", log, "log not found (test not run)")
            continue
        txt = open(p, errors="replace").read()
        m = re.search(rx, txt)
        if not m:
            r.add("test", t, None, None, "measured", "FAIL", log, "PASS line not found")
            continue
        gd = m.groupdict()
        r.add("test", t, float(gd["frames"]) if gd.get("frames") else None,
              "frames" if gd.get("frames") else None, "measured", "PASS", log,
              f"flits={gd['flits']}" if gd.get("flits") else None)


def scenarios(r):
    sys.path.insert(0, rel("dv/common"))
    import scenarios as sc  # noqa: E402
    exp = sc.expected()
    for env, path in ENV_RESULTS.items():
        p = rel(path)
        if not os.path.exists(p):
            r.add("scenario", f"{env}", None, None, "not_attributable", "NOT_RUN", path, "results.json not found")
            continue
        d = json.load(open(p))["scenarios"]
        ok = all(d.get(s, {}).get(k) is not None and str(d[s][k]) == str(exp[s][k])
                 for s in sc.ORDER for k in exp[s])
        nbytes = sum(d[s]["bytes"] for s in d)
        r.add("scenario", f"{env}", float(len(d)), "scenarios", "measured", "PASS" if ok else "FAIL", path,
              f"{nbytes} bytes delivered; {'matches' if ok else 'DIFFERS FROM'} golden model")


def perf(r):
    # design-parameter bounds (not measured): UCIE_BUS_W x ucie_clk, x1 lane
    raw = 64 * 500e6 / 1e9
    r.add("perf", "ucie_tx_raw_bw_bound", raw, "Gb/s", "estimated", None, f"rtl/{PKG}.sv",
          "UCIE_BUS_W=64 x ucie_clk 500 MHz (DV clock), x1 lane; ignores the single-buffered framer and flit overhead")
    r.add("perf", "flit_payload_efficiency", round(240 / 256, 4), "ratio", "estimated", None,
          f"rtl/{PKG}.sv", "FLIT_PAYLOAD_B / FLIT_BYTES (240 / 256)")
    r.add("perf", "delivered_pcie_throughput", kind="not_attributable", source=None,
          detail="no simulated-time instrumentation in any env run yet (the scenario logs record no ns)")
    r.add("perf", "latency_pcie_to_pcie", kind="not_attributable", source=None,
          detail="no latency monitor in any env yet")
    r.add("perf", "fmax", kind="not_attributable", detail="no timing library / STA in this flow")


def _lcov_line_pct(info):
    """Line coverage % over rtl/ from an lcov .info (DA records), matching dv/common/covcheck.py."""
    found = hit = 0
    cur_rtl = False
    for ln in open(info, errors="replace"):
        if ln.startswith("SF:"):
            cur_rtl = "/rtl/" in ln or ln[3:].strip().startswith("rtl/") or "/rtl" in ln
        elif cur_rtl and ln.startswith("DA:"):
            try:
                _line, hits = ln[3:].strip().split(",")[:2]
            except ValueError:
                continue
            found += 1
            if int(hits) > 0:
                hit += 1
    return found, hit


def coverage(r):
    info = rel("coverage.info")
    if os.path.exists(info):
        found, hit = _lcov_line_pct(info)
        if found:
            r.add("coverage", "line_branch_rtl", round(100.0 * hit / found, 2), "%", "measured", None,
                  "coverage.info", f"{hit}/{found} Verilator line points in rtl/ (lcov DA records; floor 80%)")
        else:
            r.add("coverage", "line_branch_rtl", kind="not_attributable", status="FAIL", source="coverage.info",
                  detail="no rtl/ DA records parsed from coverage.info")
    else:
        r.add("coverage", "line_branch_rtl", kind="not_attributable", status="NOT_RUN", source="coverage.info",
              detail="make coverage not run")
    p = rel("dv/cocotb/fcov.json")
    if os.path.exists(p):
        d = json.load(open(p))
        r.add("coverage", "functional_pyvsc", d.get("overall"), "%", "measured", None, "dv/cocotb/fcov.json",
              "mean of coverpoint coverage over " + ", ".join(d.get("covergroups", [])))
    else:
        r.add("coverage", "functional_pyvsc", kind="not_attributable", status="NOT_RUN", source="dv/cocotb/fcov.json",
              detail="cocotb fcov not produced (fcov.json absent)")


def formal(r):
    # Report the status dirs that actually ran.  `make formal` may run the committed
    # <proof>.sby directly or a tool-adapted _<proof>.sby (formal/Makefile), so the dir
    # is <proof>_prove / <proof>_cover with an optional leading '_' and '_fc' suffix.
    statuses = sorted(glob.glob(rel("formal/*_prove/status")) + glob.glob(rel("formal/*_cover/status")))
    if statuses:
        for st in statuses:
            name = os.path.basename(os.path.dirname(st)).lstrip("_")   # e.g. async_fifo_prove, ctrl_cover_fc
            s = open(st).read().split()
            r.add("formal", name, None, None, "measured", s[0] if s else "?", os.path.relpath(st, ROOT))
        return
    bases = sorted({os.path.basename(s)[:-4] for s in glob.glob(rel("formal/*.sby"))
                    if not os.path.basename(s).startswith("_")})
    if not bases:
        r.add("formal", "proofs", kind="not_attributable", status="NOT_RUN", source="formal", detail="no .sby files")
        return
    for base in bases:
        for task in ("prove", "cover"):
            r.add("formal", f"{base}_{task}", kind="not_attributable", status="NOT_RUN",
                  source=f"formal/{base}_{task}", detail="make formal not run")


def resource(r):
    has_slang = bool(shutil.which("yosys")) and subprocess.run(
        ["yosys", "-q", "-p", "plugin -i slang"], cwd=ROOT, capture_output=True).returncode == 0
    builtin = False
    if not has_slang and shutil.which("yosys"):
        # some yosys builds have read_slang built in (no plugin needed)
        builtin = subprocess.run(["yosys", "-q", "-p", "help read_slang"], cwd=ROOT,
                                 capture_output=True).returncode == 0
    if not (has_slang or builtin):
        r.add("resource", "flop_bits", kind="not_attributable", status="NOT_RUN",
              detail="yosys with slang support (plugin or built-in) not on PATH")
        return
    srcs = " ".join(f"rtl/{m}.sv" for m in RTL)
    net = os.path.join(ROOT, "metrics", "_capture", "netlist.json")
    os.makedirs(os.path.dirname(net), exist_ok=True)
    load = "plugin -i slang; " if has_slang else ""
    # coarse elaboration only (a full `synth` of the 256-byte datapath takes minutes)
    cmd = ["yosys", "-q", "-p",
           f"{load}read_slang --single-unit -I rtl --top {TOP} rtl/{PKG}.sv {srcs}; "
           f"proc; flatten; opt -fast; memory -nomap; opt_clean; write_json {net}"]
    t0 = time.monotonic()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=1800)
    dt = time.monotonic() - t0
    if res.returncode != 0 or not os.path.exists(net):
        r.add("resource", "flop_bits", kind="not_attributable", status="FAIL", source="yosys",
              detail="yosys elaboration failed: " + (res.stderr or "")[-300:])
        return
    m = json.load(open(net))["modules"][TOP]
    ff = mem = 0
    for c in m["cells"].values():
        t, p = c["type"], c["parameters"]
        if "dff" in t.lower():
            ff += int(p["WIDTH"], 2)
        if t.startswith("$mem"):
            mem += int(p["WIDTH"], 2) * int(p["SIZE"], 2)
    src = "yosys (slang) proc/flatten/opt/memory -nomap, coarse cells"
    r.add("resource", "flop_bits", float(ff), "bits", "estimated", None, src,
          f"sum of $dff/$adff widths after coarse elaboration ({dt:.0f} s); pre-optimisation, no liberty")
    r.add("resource", "memory_bits", float(mem), "bits", "estimated", None, src,
          "CDC FIFO arrays (Tx + Rx async_fifo memories)")
    r.add("resource", "coarse_cells", float(len(m["cells"])), "cells", "estimated", None, src,
          "RTLIL coarse cells (word-level), not gates")
    r.add("resource", "area_um2", kind="not_attributable",
          detail="no gate-level flow in this repo (no liberty / STA); see docs/power_intent.md")


def power(r):
    """No OSS gate-level area/power flow exists in this repo (docs/power_intent.md: 'not run; no
    area/power numbers claimed'), so these are not_attributable rather than estimated."""
    why = "no gate-level synthesis / liberty / STA flow in this repo (docs/power_intent.md)"
    r.add("power", "area_um2", kind="not_attributable", status="NOT_RUN", source="docs/power_intent.md", detail=why)
    r.add("power", "total_mW", kind="not_attributable", status="NOT_RUN", source="docs/power_intent.md", detail=why)
    r.add("power", "pd_dp_retained_bits", kind="not_attributable", source="lp/cocotb",
          detail="PD_DP retention is characterised functionally in lp/cocotb (make pd-emu), not in register bits here")


def swarm(r):
    p = rel("docker/last-run-metrics.json")
    if os.path.exists(p):
        d = json.load(open(p))
        for row in d.get("agents", []):
            r.add("swarm", f"{row.get('agent')}x{row.get('model')}", row.get("tokens"), "tokens", "measured",
                  row.get("status"), "docker/last-run-metrics.json")
    else:
        r.add("swarm", "agent_x_model", kind="not_attributable", status="NOT_RUN",
              detail="no swarm run recorded (docker/last-run-metrics.json absent)")


def rr_ingest(r, run_dir, corpus_path):
    """Random-regression results (dv/random/runs/<ts>/results.jsonl + triage.json, dv/random/corpus.json)
    -> category 'rr'.  Every number is counted from those files (kind=measured); a missing file is NOT_RUN."""
    path = os.path.join(run_dir, "results.jsonl")
    src = rel(path)
    if not os.path.exists(path):
        r.add("rr", "jobs", kind="not_attributable", status="NOT_RUN", detail=f"{src} not found")
        return
    jobs = [json.loads(l) for l in open(path) if l.strip()]
    n = len(jobs)
    npass = sum(1 for j in jobs if j.get("status") == "PASS")
    r.add("rr", "jobs", n, "jobs", "measured", None, src, "run " + os.path.basename(os.path.normpath(run_dir)))
    r.add("rr", "jobs_pass", npass, "jobs", "measured", None, src)
    r.add("rr", "jobs_fail", n - npass, "jobs", "measured", "FAIL" if n - npass else "PASS", src)
    if n:
        r.add("rr", "pass_rate", 100.0 * npass / n, "%", "measured", None, src)
    for cfg in sorted({j.get("config") for j in jobs}):
        cj = [j for j in jobs if j.get("config") == cfg]
        cp = sum(1 for j in cj if j.get("status") == "PASS")
        r.add("rr", f"config.{cfg}.jobs", len(cj), "jobs", "measured", None, src)
        r.add("rr", f"config.{cfg}.pass_rate", 100.0 * cp / len(cj), "%", "measured",
              "PASS" if cp == len(cj) else "FAIL", src, f"{cp}/{len(cj)} jobs PASS")
    tp = os.path.join(os.path.dirname(path), "triage.json")
    if os.path.exists(tp):
        tri = json.load(open(tp))
        r.add("rr", "unique_failure_clusters", len(tri.get("clusters", [])), "clusters", "measured", None,
              rel(tp), f"{tri.get('failing', 0)} failing job(s) clustered by normalised signature")
    else:
        r.add("rr", "unique_failure_clusters", kind="not_attributable", status="NOT_RUN",
              detail="triage.json absent: run `make rr-triage RUN=<dir>`")
    if os.path.exists(corpus_path):
        c = json.load(open(corpus_path))
        cs = rel(corpus_path)
        r.add("rr", "corpus_entries", len(c), "entries", "measured", None, cs)
        for st in ("open", "fixed"):
            r.add("rr", f"corpus_{st}", sum(1 for e in c if e.get("status") == st), "entries", "measured", None, cs)
    else:
        r.add("rr", "corpus_entries", kind="not_attributable", status="NOT_RUN", detail="corpus.json absent")


def import_runs(con, src_db, host):
    """Merge the runs of another metrics.db into `con` (new run ids, rows copied verbatim, so the
    kind / status of every value is preserved).  A run already present (same ts_utc + git_sha) is
    skipped, so the import can be repeated.  `host` replaces the source host (the container name)."""
    n_runs = n_rows = 0
    src = sqlite3.connect(src_db)
    for rid, ts, sha, br, dirty, h, tools, note in src.execute(
            "SELECT run_id, ts_utc, git_sha, git_branch, git_dirty, host, tools, note FROM runs ORDER BY run_id"):
        if con.execute("SELECT 1 FROM runs WHERE ts_utc=? AND git_sha IS ?", (ts, sha)).fetchone():
            continue
        note2 = (note + " | " if note else "") + f"imported from {h}"
        cur = con.execute("INSERT INTO runs (ts_utc, git_sha, git_branch, git_dirty, host, tools, note) "
                          "VALUES (?,?,?,?,?,?,?)", (ts, sha, br, dirty, host, tools, note2))
        rows = src.execute("SELECT category, name, value, unit, status, kind, source, detail FROM metrics "
                           "WHERE run_id=?", (rid,)).fetchall()
        con.executemany("INSERT INTO metrics VALUES (%d,?,?,?,?,?,?,?,?)" % cur.lastrowid, rows)
        n_runs += 1
        n_rows += len(rows)
    src.close()
    return n_runs, n_rows


def import_dir(con, d):
    n_runs = n_rows = 0
    for sub in sorted(glob.glob(os.path.join(d, "runs", "*")) or glob.glob(os.path.join(d, "*"))):
        db = os.path.join(sub, "metrics.db")
        if not os.path.exists(db):
            continue
        meta = {}
        try:
            meta = json.load(open(os.path.join(sub, "run.json")))
        except Exception:
            pass
        host = "railway/" + (meta.get("service") or "unknown")
        a, b = import_runs(con, db, host)
        n_runs += a
        n_rows += b
    con.commit()
    return n_runs, n_rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="", help="comma-separated root make targets to run and time first")
    ap.add_argument("--note", default="")
    ap.add_argument("--db", default=DB)
    ap.add_argument("--import-dir", default="", help="merge the runs of DIR/runs/*/metrics.db (host railway/<service>)")
    ap.add_argument("--rr-run", default="", metavar="DIR",
                    help="only (re)write the 'rr' rows of the latest run from a random-regression run dir "
                         "(DIR/results.jsonl, DIR/triage.json, dv/random/corpus.json); `make rr-metrics RUN=DIR`")
    a = ap.parse_args()
    con = sqlite3.connect(a.db)
    con.executescript(open(SCHEMA).read())
    if a.import_dir:
        n, rows = import_dir(con, a.import_dir)
        print(f"collect: imported {n} run(s), {rows} metric rows from {a.import_dir}")
        return 0
    if a.rr_run:
        row = con.execute("SELECT MAX(run_id) FROM runs WHERE host IS NULL OR host NOT LIKE 'railway/%'").fetchone()
        if not row or row[0] is None:
            print("collect: no local run in the database to attach rr rows to")
            return 1
        con.execute("DELETE FROM metrics WHERE run_id=? AND category='rr'", (row[0],))
        r = Run(con, row[0])
        rr_ingest(r, a.rr_run, os.path.join(ROOT, "dv", "random", "corpus.json"))
        con.commit()
        print(f"collect: run {row[0]}: {r.n} rr rows written -> {os.path.relpath(a.db, ROOT)}")
        return 0
    dirty = 1 if sh("git status --porcelain --untracked-files=no") else 0
    cur = con.execute("INSERT INTO runs (ts_utc, git_sha, git_branch, git_dirty, host, tools, note) VALUES (?,?,?,?,?,?,?)",
                      (datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                       sh("git rev-parse --short HEAD") or os.environ.get("RAILWAY_GIT_COMMIT_SHA", "")[:7],
                       sh("git rev-parse --abbrev-ref HEAD") or os.environ.get("RAILWAY_GIT_BRANCH", ""), dirty,
                       os.uname().nodename, json.dumps(tool_versions()), a.note))
    r = Run(con, cur.lastrowid)
    if a.run:
        run_flows(r, [f for f in a.run.split(",") if f])
    tests(r)
    scenarios(r)
    perf(r)
    coverage(r)
    formal(r)
    resource(r)
    power(r)
    swarm(r)
    con.commit()
    bad = con.execute("SELECT COUNT(*) FROM metrics WHERE run_id=? AND status='FAIL'", (r.run_id,)).fetchone()[0]
    print(f"collect: run {r.run_id}: {r.n} metric rows -> {os.path.relpath(a.db, ROOT)} ({bad} FAIL)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
