# Toolchain — no OSS CAD Suite

Every tool is pinned in the `Dockerfile` and built from source or apt/pip; CI builds
that image and runs the jobs inside it. To hand-build locally (what the M0 scaffold
was verified against):

| Tool | Version | How |
|---|---|---|
| **Icarus Verilog** | ≥ 12 (CI: 12.0) | apt on Ubuntu 24.04, or from source. `iverilog -V`. |
| **Verilator** | 5.050 (≥ 5.03x for UVM) | **from source** (apt 5.020 can't compile uvm-core). `--prefix=$HOME/.local`. Do **not** set `VERILATOR_ROOT`. |
| **Yosys + slang** | master w/ native slang frontend | from source (CMake). For `make formal`. |
| **SymbiYosys (sby)** | main | from source. |
| **yices2 / z3** | yices 2.6.5 / z3 | yices preferred for formal `cover` (z3 can OOM on deep covers). |
| **SystemC** | 2.3.x | apt `libsystemc-dev`. |
| **Python DV** | cocotb 1.8.1, pyuvm 5.0.0, pyvsc | `pip install -r dv/cocotb/requirements.txt`. Pins track `~/proj/dv_env.mk`. |

The UVM env clones Accellera `uvm-core` at a pinned ref (git-ignored). Local dev may
have newer cocotb/pyuvm than the pins (see `AGENT_HANDOFF.md`); the CI image is the
canonical environment.
