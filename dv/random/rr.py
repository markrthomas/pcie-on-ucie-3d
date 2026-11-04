#!/usr/bin/env python3
"""dv/random/rr.py - random-regression driver (Verilator `rand` scenario).

A job = a build config (vlt | vlt-fc) + a seed + knobs drawn from envelopes
(frames, maxlen, MAC gap %, sink-ready %), run as `vlt_rand +rand +seed=.. ...`
in its own directory.  The checker is the existing one: the BFM scoreboard in
dv/common/cpp/adapter_bfm.h (payload/length/tkeep/flit-format/FC checks) PLUS the
golden model dv/common/scenarios.py:expected_rand() (frames/bytes/flits/crc32/pmcnt).
Nothing here is a new checker.

  rr.py build
  rr.py run   --n N --jobs J [--seed-base S]     -> runs/<UTC>/results.jsonl
  rr.py one   --seed S [--config C --frames F --maxlen L --gap G --ready R]
  rr.py triage RUN_DIR
  rr.py promote --seed S [--config ..knobs..] [--note TXT] [--fixed]
  rr.py replay [--jobs J]       fixed entries must PASS (the gate)
"""
import argparse
import collections
import concurrent.futures as cf
import datetime
import json
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "dv", "common"))
import scenarios  # noqa: E402

BUILD = os.path.join(HERE, "build")
RUNS = os.path.join(HERE, "runs")
CORPUS = os.path.join(HERE, "corpus.json")
CONFIGS = ("vlt", "vlt-fc")
FIELDS = ("frames", "bytes", "flits", "crc32", "pmcnt", "errors")
TIMEOUT_S = 600


def verilator():
    for cand in (os.environ.get("VERILATOR"), "/opt/verilator/bin/verilator", "verilator"):
        if cand:
            return cand
    return "verilator"


# ---------------------------------------------------------------- build
def build_one(cfg):
    vdir = os.path.join(ROOT, "dv", "vlt")
    rtl = os.path.join(ROOT, "rtl")
    top = "pcie_ucie3d_adapter"
    srcs = ["async_fifo", "tx_framer", "tx_egress", "rx_ingress", "rx_deframer", "pcie_egress", "fc_ctl",
            "adapter_rf", "adapter_ctrl_fsm", "ucie_sb_master", "tx_ingress_gate", top]
    srcs = [os.path.join(rtl, s + ".sv") for s in srcs]
    sva = [os.path.join(ROOT, "dv", "sva", f) for f in ("async_fifo_sva.sv", "adapter_sva.sv")]
    inc = os.path.join(ROOT, "dv", "common", "cpp")
    cflags = f"-I{inc} -O1"
    defs = []
    if cfg == "vlt-fc":
        defs = ["+define+FLOW_CTRL_OVERRIDE"]
        cflags += " -DFLOW_CTRL_OVERRIDE"
    mdir = os.path.join(BUILD, cfg)
    os.makedirs(mdir, exist_ok=True)
    cmd = [verilator(), "--cc", "--exe", "--build", "-j", "0", "-Wall", "-Wno-fatal", "--assert",
           "--top-module", top, f"-I{rtl}", "-CFLAGS", cflags, *defs, "--Mdir", mdir, "-o", "vlt_rand",
           os.path.join(vdir, "sim_main.cpp"), *srcs, *sva]
    print(f"[rr] build {cfg}: {mdir}")
    r = subprocess.run(cmd, cwd=vdir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        print(r.stdout[-3000:])
        print(f"[rr] BUILD FAIL ({cfg})")
        return False
    return True


def cmd_build(_a):
    ok = all(build_one(c) for c in CONFIGS)
    print("[rr] build OK" if ok else "[rr] build FAILED")
    return 0 if ok else 1


# ---------------------------------------------------------------- job
def draw(seed):
    """Knobs for a seed (deterministic).  Envelopes cover what the scoreboard checks."""
    r = random.Random(seed)
    return {
        "config": r.choice(CONFIGS),
        "frames": r.choice([1, 2, 4, 8, 16, 24, 40, 64]),
        "maxlen": r.choice([40, 241, 512, 2000, 4096]),
        "gap": r.choice([0, 0, 10, 30, 60, 90]),      # MAC idle % per beat
        "ready": r.choice([100, 100, 90, 50, 20]),    # sink tready %
        # B1/B2 knobs, drawn after the originals so the original knobs of a seed never change
        "ctl": (c := r.choice([0, 0, 1, 2, 3])),      # control ops: none/pm_cycle/speed_change/mix
        "nctl": r.choice([1, 2, 3]) if c else 0,
        "mid": r.choice([0, 1]) if c else 0,          # 1: ops fire with later frames in flight
        "csr": (s := r.choice([0, 0, 5, 20, 50])),    # CSR traffic activity % per cycle
        "ncfg": r.choice([0, 1, 2, 4]) if s else 0,   # exact # of SPEEDCFG writes
        "nrx": r.choice([0, 0, 1, 3, 6]),             # Rx-side error injections
    }


NEW_KNOBS = ("ctl", "nctl", "mid", "csr", "ncfg", "nrx")      # absent in an old corpus entry = 0


def knob_str(k):
    s = f"{k['config']} frames={k['frames']} maxlen={k['maxlen']} gap={k['gap']} ready={k['ready']}"
    extra = " ".join(f"{n}={k.get(n, 0)}" for n in NEW_KNOBS if k.get(n, 0))
    return s + (" " + extra if extra else "")


def repro_cmd(seed, k):
    return (f"python3 dv/random/rr.py one --seed {seed} --config {k['config']} --frames {k['frames']} "
            f"--maxlen {k['maxlen']} --gap {k['gap']} --ready {k['ready']}"
            + "".join(f" --{n} {k.get(n, 0)}" for n in NEW_KNOBS))


def run_job(seed, k, jobdir):
    """Run one job; return (status, signature, log)."""
    os.makedirs(os.path.join(jobdir, "logs"), exist_ok=True)
    log = os.path.join(jobdir, "run.log")
    exe = os.path.join(BUILD, k["config"], "vlt_rand")
    if not os.path.exists(exe):
        return "FAIL", "build missing (run make rr-build)", log
    cmd = [exe, "+rand", f"+seed={seed}", f"+frames={k['frames']}", f"+maxlen={k['maxlen']}",
           f"+gap={k['gap']}", f"+ready={k['ready']}"] + [f"+{n}={k.get(n, 0)}" for n in NEW_KNOBS]
    if k.get("probe"):
        cmd.append("+probe")                 # BFM debug prints (rr.py one --probe)
    with open(log, "w") as lf:
        lf.write(f"# {knob_str(k)} seed={seed}\n# {' '.join(cmd)}\n")
        lf.flush()
        try:
            rc = subprocess.run(cmd, cwd=jobdir, stdout=lf, stderr=subprocess.STDOUT,
                                timeout=TIMEOUT_S).returncode
        except subprocess.TimeoutExpired:
            return "FAIL", "timeout", log
    text = open(log).read()
    sigs = []
    for line in text.splitlines():
        m = re.search(r"BFM ERROR: (.*)$", line)
        if m:
            sigs.append(m.group(1).strip())
        elif "%Error" in line or "SVA" in line and "fail" in line.lower() or "Assertion failed" in line:
            sigs.append(line.strip()[:120])
    # golden-model cross-check (dv/common/scenarios.py:expected_rand)
    gold_sig = None
    try:
        d = json.load(open(os.path.join(jobdir, "logs", "results.json")))
        got = d["scenarios"]["rand"]
        exp = scenarios.expected_rand(seed, k["frames"], k["maxlen"], k.get("ctl", 0), nctl=k.get("nctl", 0),
                                      ncfg=k.get("ncfg", 0), nrx=k.get("nrx", 0))
        for f in FIELDS + ("rxcnt0", "rxcnt1"):
            if str(got.get(f)) != str(exp[f]):
                gold_sig = f"golden mismatch: {f}"
                break
    except Exception as e:  # noqa: BLE001
        gold_sig = f"no results.json ({type(e).__name__})"
    if sigs:
        return "FAIL", sigs[0], log
    if rc != 0 or "VLT PASS" not in text:
        return "FAIL", gold_sig or f"sim exit {rc}", log
    if gold_sig:
        return "FAIL", gold_sig, log
    return "PASS", "", log


def cmd_one(a):
    seed = a.seed
    k = draw(seed)
    for f in ("config", "frames", "maxlen", "gap", "ready") + NEW_KNOBS:
        if getattr(a, f) is not None:
            k[f] = getattr(a, f)
    k["probe"] = getattr(a, "probe", False)
    jobdir = os.path.join(RUNS, "one", f"seed{seed}")
    st, sig, log = run_job(seed, k, jobdir)
    print(f"[rr] one seed={seed} {knob_str(k)}: {st} {sig}  ({log})")
    return 0 if st == "PASS" else 1


# ---------------------------------------------------------------- run
def cmd_run(a):
    if not all(os.path.exists(os.path.join(BUILD, c, "vlt_rand")) for c in CONFIGS):
        print("[rr] not built: run `make rr-build`")
        return 2
    base = a.seed_base if a.seed_base is not None else int(datetime.datetime.now(datetime.timezone.utc).timestamp()) % 1000000
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S")
    rundir = os.path.join(RUNS, ts)
    while os.path.exists(rundir):
        rundir += "x"
    os.makedirs(rundir)

    def one(i):
        seed = base + i
        k = draw(seed)
        st, sig, log = run_job(seed, k, os.path.join(rundir, f"job{i:04d}"))
        return {"job": i, "seed": seed, "config": knob_str(k), "status": st, "signature": sig,
                "log": os.path.relpath(log, ROOT), "repro": repro_cmd(seed, k)}

    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        res = list(ex.map(one, range(a.n)))
    with open(os.path.join(rundir, "results.jsonl"), "w") as f:
        for r in res:
            f.write(json.dumps(r) + "\n")
    fails = sum(r["status"] == "FAIL" for r in res)
    print(f"rr run: {os.path.relpath(rundir, ROOT)} seed_base={base} jobs={a.n} fail={fails}")
    return 1 if fails else 0


# ---------------------------------------------------------------- triage
def cmd_triage(a):
    path = a.run
    if not path:
        print("usage: make rr-triage RUN=<dir>")
        return 2
    if not os.path.isabs(path) and not os.path.exists(path):
        path = os.path.join(ROOT, path)
    f = os.path.join(path, "results.jsonl") if os.path.isdir(path) else path
    rows = [json.loads(x) for x in open(f) if x.strip()]
    fails = [r for r in rows if r["status"] == "FAIL"]
    cl = collections.OrderedDict()
    for r in fails:
        cl.setdefault(r["signature"], []).append(r)
    print(f"rr triage: {len(rows)} jobs, {len(fails)} fail, {len(cl)} cluster(s)")
    for sig, rs in sorted(cl.items(), key=lambda kv: -len(kv[1])):
        print(f"  [{len(rs):3d}] {sig} | e.g. seed={rs[0]['seed']} {rs[0]['config']} | repro: {rs[0]['repro']}")
    return 0


# ---------------------------------------------------------------- corpus
def load_corpus():
    return json.load(open(CORPUS)) if os.path.exists(CORPUS) else {"entries": []}


def cmd_promote(a):
    c = load_corpus()
    k = draw(a.seed)
    for f in ("config", "frames", "maxlen", "gap", "ready") + NEW_KNOBS:
        if getattr(a, f) is not None:
            k[f] = getattr(a, f)
    c["entries"].append({"seed": a.seed, **k, "note": a.note or "", "fixed": bool(a.fixed),
                         "signature": a.signature or ""})
    json.dump(c, open(CORPUS, "w"), indent=2)
    open(CORPUS, "a").write("\n")
    print(f"[rr] promoted seed={a.seed} {knob_str(k)} fixed={bool(a.fixed)} -> {os.path.relpath(CORPUS, ROOT)}")
    return 0


def cmd_replay(a):
    c = load_corpus()
    ents = c["entries"]
    if not ents:
        print("rr replay: corpus empty (0 entries) - nothing to gate")
        return 0
    if not all(os.path.exists(os.path.join(BUILD, x, "vlt_rand")) for x in CONFIGS):
        if cmd_build(a):
            return 1
    rundir = os.path.join(RUNS, "replay")

    def one(ie):
        i, e = ie
        st, sig, log = run_job(e["seed"], e, os.path.join(rundir, f"e{i:03d}"))
        return i, e, st, sig

    bad = 0
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        for i, e, st, sig in ex.map(one, list(enumerate(ents))):
            want = "PASS" if e.get("fixed") else "FAIL (open)"
            gate_ok = st == "PASS" or not e.get("fixed")
            bad += not gate_ok
            print(f"  e{i:03d} seed={e['seed']} {knob_str(e)} fixed={bool(e.get('fixed'))}: {st} {sig} "
                  f"[{'ok' if gate_ok else 'GATE FAIL, want ' + want}]")
    print(f"rr replay: {len(ents)} entries, gate failures={bad}")
    return 1 if bad else 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("build").set_defaults(fn=cmd_build)
    p = sp.add_parser("run")
    p.add_argument("--n", type=int, default=30)
    p.add_argument("--jobs", type=int, default=4)
    p.add_argument("--seed-base", type=int, default=None)
    p.set_defaults(fn=cmd_run)

    def knobs(p):
        p.add_argument("--seed", type=int, required=True)
        p.add_argument("--config", choices=CONFIGS)
        for n in ("frames", "maxlen", "gap", "ready") + NEW_KNOBS:
            p.add_argument("--" + n, type=int)

    p = sp.add_parser("one"); knobs(p); p.add_argument("--probe", action="store_true"); p.set_defaults(fn=cmd_one)
    p = sp.add_parser("promote"); knobs(p)
    p.add_argument("--note"); p.add_argument("--signature"); p.add_argument("--fixed", action="store_true")
    p.set_defaults(fn=cmd_promote)
    p = sp.add_parser("triage"); p.add_argument("run", nargs="?"); p.set_defaults(fn=cmd_triage)
    p = sp.add_parser("replay"); p.add_argument("--jobs", type=int, default=4); p.set_defaults(fn=cmd_replay)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
