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


def expected_rand(seed: int, frames: int = RAND_FRAMES_DEFAULT, maxlen: int = RAND_MAXLEN_DEFAULT,
                  ctl: int = 0) -> dict:
    """Optional ``rand`` scenario: `frames` LCG-length frames, no control plane (M0 baseline;
    the B3 control-plane machinery is added with the control plane in M3+)."""
    r = _one(lcg_lengths(seed, max(1, frames), max(1, maxlen)))
    r["pmcnt"] = LINKUP_OPS
    return r


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--lengths":
        # used by env generators: print "name ctrl len0 len1 ..." per scenario
        for name in ORDER:
            print(name, SCENARIOS[name][1], *lengths(name))
    else:
        json.dump(expected(), sys.stdout, indent=2)
        print()
