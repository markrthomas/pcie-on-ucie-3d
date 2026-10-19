#!/usr/bin/env python3
"""playground/assemble.py — build the single-file EDA Playground bundle.

Concatenates the modular sources (package + full RTL datapath/control + the
shared pattern/scenario includes + the UVM interface/pkg/top) into one
self-contained file, `playground/pcie_ucie3d_playground.sv`, so the bundle never
drifts from the real design.

Include resolution:
  * `` `include "pcie_ucie3d_pkg.sv" `` is dropped (the package is inlined once
    at the top).
  * local includes shared by the DV code (``pcie_pat.svh``, ``scenarios.svh``)
    are inlined in place the first time they appear, then dropped on repeats
    (matching their ``ifndef`` guards).

Usage:  python3 playground/assemble.py
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, "pcie_ucie3d_playground.sv")

# order matters: package first, then RTL (dependencies before users), then UVM TB
SOURCES = [
    "rtl/pcie_ucie3d_pkg.sv",
    "rtl/async_fifo.sv",
    "rtl/tx_framer.sv",
    "rtl/tx_egress.sv",
    "rtl/rx_ingress.sv",
    "rtl/rx_deframer.sv",
    "rtl/pcie_egress.sv",
    "rtl/adapter_rf.sv",
    "rtl/adapter_ctrl_fsm.sv",
    "rtl/ucie_sb_master.sv",
    "rtl/tx_ingress_gate.sv",
    "rtl/pcie_ucie3d_adapter.sv",
    "dv/uvm/adapter_if.sv",
    "dv/uvm/adapter_uvm_pkg.sv",
    "dv/uvm/tb_uvm_top.sv",
]

# local includes inlined in place (searched under dv/common); their ifndef guards
# make a second textual copy harmless, but we inline each only once anyway.
INLINE_INCLUDES = {"pcie_pat.svh": "dv/common/pcie_pat.svh",
                   "scenarios.svh": "dv/common/scenarios.svh"}

INC_RE = re.compile(r'^\s*`include\s+"([^"]+)"')

HEADER = """// ============================================================================
// pcie_ucie3d_playground.sv — GENERATED single-file bundle for EDA Playground.
// Do not edit by hand: regenerate with `python3 playground/assemble.py`.
//
// EDA Playground setup: Tools = "Aldec Riviera-PRO" (or any UVM-capable sim),
// UVM/OVM = "UVM 1.2"; top = tb_uvm_top.  Run the reset/link-up demo with
//   +UVM_TESTNAME=smoke_test
// or the full Config-1 loopback scenario cross-check (5 scenarios, ~40 KB of
// looped-back traffic, byte-exact) with
//   +UVM_TESTNAME=scen_test
// The DUT is the real pcie_ucie3d_adapter + control plane; see docs/PLAN.md §5.
// ============================================================================
"""


def emit(rel, inlined):
    path = os.path.join(ROOT, rel)
    out = [f"\n// ---- {rel} " + "-" * max(4, 70 - len(rel)) + "\n"]
    with open(path) as fh:
        for ln in fh:
            m = INC_RE.match(ln)
            if not m:
                out.append(ln)
                continue
            name = os.path.basename(m.group(1))
            if name == "pcie_ucie3d_pkg.sv":
                continue  # inlined once at the top
            if name in INLINE_INCLUDES:
                if name not in inlined:
                    inlined.add(name)
                    out.append(f"// (inlined {name})\n")
                    out.extend(emit(INLINE_INCLUDES[name], inlined))
                continue  # drop repeats (ifndef-guarded)
            out.append(ln)  # leave any unknown include as-is
    return out


def main():
    inlined = set()
    chunks = [HEADER]
    for rel in SOURCES:
        chunks.extend(emit(rel, inlined))
    with open(OUT, "w") as fh:
        fh.write("".join(chunks))
    print(f"[playground] wrote {OUT} from {len(SOURCES)} source file(s), "
          f"inlined includes: {', '.join(sorted(inlined)) or 'none'}")


if __name__ == "__main__":
    main()
