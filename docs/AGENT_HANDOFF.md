# Agent handoff — pcie-on-ucie-3d

Read this first (with `docs/PLAN.md`) to resume. Newest state at top.

## Current state (2026-10-17)
- **M0 scaffold complete.** `make regress` is **GREEN** (Verilator `--lint-only
  -Wall` in default + `FLOW_CTRL_OVERRIDE` + `DP_RESET_DISABLE`, x8 refused; Icarus
  `tb_smoke` reset/defaults contract passes).
- RTL is a **stub**: `rtl/pcie_ucie3d_pkg.sv` (params/enums, UCIe 3.0 / 64 GT/s
  baseline) + `rtl/pcie_ucie3d_adapter.sv` (full port list, reset-value drives, no
  datapath / FSM yet). No behaviour — that starts at M1.
- Five env smokes all build the stub and check the reset/defaults contract:
  `make iverilog` / `vlt` / `systemc` / `cocotb` pass locally; `make uvm` builds
  Accellera UVM on the from-source Verilator 5.050 (clones uvm-core at the pinned
  ref) and passes (slow first build: the uvm_pkg C++ compile takes a few minutes).
- `dv/common/scenarios.py` (golden) + `scenarios.svh` + `cpp/adapter_bfm.h` +
  `crosscheck.py` are in; the envs start reporting against them in M4.
- Infra authored (not yet run against a remote): `Dockerfile`, `.github/workflows/
  {ci.yml,swarm.yml}`, `railway.toml`, `docker/*`, both `.claude/agents/` swarms,
  `metrics/` (collect+dashboard stubs), `formal/` `lp/` `playground/` stubs.
- **Repo is local only — no GitHub remote, nothing pushed** (user decision this pass).

### Environment drift to know
- Local cocotb is **1.9.2** and pyuvm **4.0.1**; the canonical pins
  (`dv/cocotb/requirements.txt`, `~/proj/dv_env.mk`) are cocotb **1.8.1** / pyuvm
  **5.0.0**, which the CI image installs. The M0 smokes pass under both.
- Verilator must be ≥ 5.03x for the UVM env; **do not set `VERILATOR_ROOT`**.

## How to resume (three steps)
1. `make regress` — confirm green.
2. Pick up **M1** from `docs/PLAN.md` §11: the Tx datapath (`pcie_ingress` →
   `tx_cdc` (async_fifo) → `tx_framer` → `tx_egress`) + the two peer BFMs in
   `dv/common/`, with an iverilog `tb_tx` directed test.
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
