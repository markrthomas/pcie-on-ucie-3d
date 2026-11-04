#!/usr/bin/env python3
"""Shared DV scenario set (docs/PLAN.md §5 cross-check contract).

Every DV environment (iverilog, vlt, uvm, systemc, cocotb) runs these scenarios
on the Config-1 loopback harness (UCIe-3D Tx looped to Rx, remote-PHY model,
CSR driver) with a DUT reset at the start of each scenario, and writes
``results.json``::

    {"env": "<name>", "scenarios": {"<scenario>": {"frames": int, "bytes": int,
     "flits": int, "crc32": "xxxxxxxx", "pmcnt": int, "errors": int}}}

frames/bytes/crc32 are measured on the PCIe Rx side (crc32 = zlib CRC-32 of all
received frame bytes concatenated in arrival order), flits on the UCIe Tx side
(start_flit beats), pmcnt is CSR PMCNT read at the end of the scenario.
``crosscheck.py`` compares every env against ``expected()`` below.

Frame i of a scenario carries bytes pat(i, k) for k in 0..len-1.  Random lengths
use the LCG in lcg_lengths() (same constants in SV / C++ / Python).

STATUS: M0 scaffold — the scenario table and expected() are frozen; the envs
start reporting against them in M4 (today they ship a smoke-only `make <env>`).
"""
import json
import sys
import zlib

FLIT_PAYLOAD_B = 240
LINKUP_OPS = 2          # L1->L0 + preset sideband write after every reset

# Scenario table: name -> (lengths, control op, pmcnt ops added by the control op)
#   ctrl "none"          : send all frames (pmcnt = LINKUP_OPS only)
#   ctrl "pm_cycle"      : send first half, drain, CSR L0->L1, CSR L1->L0, send rest
#                          -> +2 ops (two power transitions, no preset re-send)
#   ctrl "speed_change"  : send first half, 64->32 GT/s, 32->64 GT/s, send rest
#                          -> +4 ops: each speed change is a SPEED_CHG op plus a
#                          preset re-send (PARAM) op in raw mode (D22), x2 changes.


def pat(frame_id: int, idx: int) -> int:
    return (frame_id * 37 + idx * 13 + (idx >> 8) + 5) & 0xFF


def lcg_lengths(seed: int, n: int, max_len: int = 2000) -> list:
    x = seed & 0x7FFFFFFF
    out = []
    for _ in range(n):
        x = (1103515245 * x + 12345) & 0x7FFFFFFF
        out.append(1 + ((x >> 8) % max_len))
    return out


SCENARIOS = {
    "single":       (lambda: [256],                                               "none",         0),
    "corners":      (lambda: [1, 31, 32, 33, 239, 240, 241, 480, 481, 1500, 4096], "none",        0),
    "random":       (lambda: lcg_lengths(0xC0FFEE, 40),                           "none",         0),
    "pm_cycle":     (lambda: lcg_lengths(7, 16),                                  "pm_cycle",     2),
    "speed_change": (lambda: lcg_lengths(11, 16),                                 "speed_change", 4),
}
ORDER = ["single", "corners", "random", "pm_cycle", "speed_change"]

RAND_FRAMES_DEFAULT = 24
RAND_MAXLEN_DEFAULT = 2000


def lengths(name: str) -> list:
    return SCENARIOS[name][0]()


def _one(lens: list) -> dict:
    crc = 0
    for i, n in enumerate(lens):
        crc = zlib.crc32(bytes(pat(i, k) for k in range(n)), crc)
    return {
        "frames": len(lens),
        "bytes": sum(lens),
        "flits": sum((n + FLIT_PAYLOAD_B - 1) // FLIT_PAYLOAD_B for n in lens),
        "crc32": f"{crc & 0xFFFFFFFF:08x}",
        "errors": 0,
    }


def expected() -> dict:
    res = {}
    for name in ORDER:
        lens_fn, _ctrl, ops = SCENARIOS[name]
        r = _one(lens_fn())
        r["pmcnt"] = LINKUP_OPS + ops
        res[name] = r
    return res


def rand_ops(seed: int, ctl: int, nctl: int) -> list:
    """B1 control-op plan: 1 = pm_cycle, 2 = speed_change (ctl 3 mixes them by seed bits).
    Mirrors Harness::rnd_op_ in dv/common/cpp/adapter_bfm.h."""
    if ctl <= 0:
        return []
    return [((2 if (seed >> (i % 31)) & 1 else 1) if ctl == 3 else ctl) for i in range(nctl)]


RAND_OP_PMCNT = {1: 2, 2: 4}        # pmcnt ops added by pm_cycle / speed_change (see SCENARIOS)

# B2 Rx-side error injection: type i of injection k is (seed + 7k) % 5; counter deltas
# (lock_errors, dropped_flits, aborted_frames, bad_flits) per type - see dv/random/README.md.
RX_INJ_DELTA = {0: (1, 0, 0, 0), 1: (2, 0, 0, 0), 2: (1, 0, 0, 0), 3: (0, 0, 0, 1), 4: (0, 0, 1, 0)}


def rand_inj_types(seed: int, nrx: int) -> list:
    return [(seed + 7 * k) % 5 for k in range(nrx)]


def expected_rand(seed: int, frames: int = RAND_FRAMES_DEFAULT, maxlen: int = RAND_MAXLEN_DEFAULT,
                  ctl: int = 0, nctl: int = 0, ncfg: int = 0, nrx: int = 0, **_ignored) -> dict:
    """Optional ``rand`` scenario: `frames` LCG-length frames.
    B1: `nctl` control ops (rand_ops) -> pmcnt += 2 / 4 each; B2: `ncfg` SPEEDCFG writes -> pmcnt += 1
    each, `nrx` Rx injections -> rxcnt0 = {lock, dropped}, rxcnt1 = {aborted, bad}.
    The frame stream (frames/bytes/flits/crc32) is independent of all of them."""
    r = _one(lcg_lengths(seed, max(1, frames), max(1, maxlen)))
    r["pmcnt"] = (LINKUP_OPS + sum(RAND_OP_PMCNT[o] for o in rand_ops(seed, ctl, nctl if ctl else 0))
                  + ncfg)
    tot = [0, 0, 0, 0]
    for t in rand_inj_types(seed, nrx):
        for i, d in enumerate(RX_INJ_DELTA[t]):
            tot[i] += d
    r["rxcnt0"] = (tot[0] << 16) | tot[1]
    r["rxcnt1"] = (tot[2] << 16) | tot[3]
    return r


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--lengths":
        # used by env generators: print "name ctrl len0 len1 ..." per scenario
        for name in ORDER:
            print(name, SCENARIOS[name][1], *lengths(name))
    else:
        json.dump(expected(), sys.stdout, indent=2)
        print()
