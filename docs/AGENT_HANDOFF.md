# Agent handoff — pcie-on-ucie-3d

Read this first (with `docs/PLAN.md`) to resume. Newest state at top.

## Current state (2026-10-18)
- **M1 complete** (on branch `claude/m1-tx-datapath`). **M0 scaffold** was committed
  to `main`.
- `make regress` **GREEN**: Verilator `--lint-only -Wall` (default +
  `FLOW_CTRL_OVERRIDE` + `DP_RESET_DISABLE`, x8 refused) + Icarus `make sim`
  (`tb_smoke` reset/defaults + `tb_tx`: **TX PASS, 115 frames, 512 flits, payloads
  match**).
- **RTL — Tx datapath live**: `async_fifo.sv` (generic CDC, copied verbatim),
  `tx_framer.sv` (256B raw-mode flit assembly), `tx_egress.sv` (serialise UCIE_BUS_W
  beats), wired in `pcie_ucie3d_adapter.sv`. No control plane yet, so `tx_en=1` and
  the PCIe ingress is open when the Tx CDC FIFO is not full. Rx path + control plane
  are stubbed (reset values). `rtl/pcie_ucie3d_pkg.sv` params/enums unchanged.
- BFMs: `dv/common/pcie_mac_model.sv` (AXI4-S source), `ucie_phy_model.sv` (UCIe Tx
  sink + raw-mode flit monitor), `pcie_pat.svh`. `scenarios.py` + mirrors +
  `crosscheck.py` in; envs report against them in M4.
- Five env smokes updated to the M1 idle contract (`pcie_tready` open at idle) and
  pass: `make iverilog`/`vlt`/`systemc`/`cocotb`; `make uvm` builds Accellera UVM on
  the from-source Verilator 5.050 (uvm-core at the pinned ref; slow first build).
- Infra authored, not run against a remote: Dockerfile, CI (`ci.yml` runs each env
  in the toolchain image; now compiles the submodules too), `swarm.yml`, railway.toml,
  docker/*, both `.claude/agents/` swarms, metrics/formal/lp/playground scaffolds.
- **Repo is local only — no GitHub remote, nothing pushed** (user decision).

### Environment drift to know
- Local cocotb is **1.9.2** and pyuvm **4.0.1**; the canonical pins
  (`dv/cocotb/requirements.txt`, `~/proj/dv_env.mk`) are cocotb **1.8.1** / pyuvm
  **5.0.0**, which the CI image installs. The M0 smokes pass under both.
- Verilator must be ≥ 5.03x for the UVM env; **do not set `VERILATOR_ROOT`**.

## How to resume (three steps)
1. `make regress` — confirm green.
2. Pick up **M2** from `docs/PLAN.md` §11: the Rx datapath (`rx_ingress` flit-lock on
   `start_flit` → `rx_cdc` (async_fifo) → `rx_deframer` → `pcie_egress`), then wire the
   **Config-1 loopback** (UCIe Tx → Rx of the same DUT) and a loopback scoreboard
   (`dv/iverilog/tb_loop.sv`: frame in == frame out). Reuse `async_fifo`; mirror the
   flit format (D2) in the deframer. Remove the Rx stub drives from the top.
3. Keep `rtl/` assertion-free; record any behaviour choice in `OPEN_DECISIONS.md`.

## Gotchas
- `make uvm` needs network the first time (clones uvm-core). In the CI image it is
  pre-cloned. If offline, the Makefile prints a skip notice and exits 0.
- Icarus emits a benign "unique case qualities ignored" note; not an error.
- `make coverage` on the stub produces little to cover; the 80% floor is enforced
  from M4 (the Makefile says so).

## Guardrails (from ~/proj/CLAUDE.md)
PRs ready-for-review and finish-what-you-open — **except** the swarms (draft-only,
human merges any RTL/DUT behaviour change). Never fabricate a measured metric.

## Don't
Don't set `VERILATOR_ROOT`. Don't weaken a checker to go green. Don't push a remote
or open a PR this pass (local-only was the user's decision).
