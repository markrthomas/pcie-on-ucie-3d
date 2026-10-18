#!/usr/bin/env python3
"""playground/assemble.py — build the single-file EDA Playground bundle.

Concatenates the modular sources (package + RTL + UVM interface/pkg/top) into one
self-contained file, `playground/pcie_ucie3d_playground.sv`, so the bundle never
drifts from the real design.  `` `include "pcie_ucie3d_pkg.sv" `` lines are dropped
because the package is inlined once at the top.

M0: assembles the stub DUT + the UVM smoke TB (a minimal but real EDA Playground
artifact).  As the datapath + UVM env grow (M1/M4), re-running this regenerates
the bundle; M4 swaps the smoke TB for the Config-1 loopback scenario TB.

Usage:  python3 playground/assemble.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, "pcie_ucie3d_playground.sv")

# order matters: package first, then RTL, then the UVM TB
SOURCES = [
    "rtl/pcie_ucie3d_pkg.sv",
    "rtl/pcie_ucie3d_adapter.sv",
    "dv/uvm/adapter_if.sv",
    "dv/uvm/adapter_uvm_pkg.sv",
    "dv/uvm/tb_uvm_top.sv",
]

HEADER = """// ============================================================================
// pcie_ucie3d_playground.sv — GENERATED single-file bundle for EDA Playground.
// Do not edit by hand: regenerate with `python3 playground/assemble.py`.
//
// EDA Playground setup: Tools = "Aldec Riviera-PRO" (or any UVM-capable sim),
// UVM/OVM = "UVM 1.2"; top = tb_uvm_top; run with +UVM_TESTNAME=smoke_test.
// M0 carries the stub DUT + the UVM smoke test; M4 swaps in the Config-1
// loopback scenario TB.  See docs/PLAN.md §5.
// ============================================================================
"""


def main():
    chunks = [HEADER]
    for rel in SOURCES:
        path = os.path.join(ROOT, rel)
        with open(path) as fh:
            lines = [ln for ln in fh if '`include "pcie_ucie3d_pkg.sv"' not in ln]
        chunks.append(f"\n// ---- {rel} " + "-" * (70 - len(rel)) + "\n")
        chunks.append("".join(lines))
    with open(OUT, "w") as fh:
        fh.write("".join(chunks))
    print(f"[playground] wrote {OUT} from {len(SOURCES)} source file(s)")


if __name__ == "__main__":
    main()
