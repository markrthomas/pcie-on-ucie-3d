# Agent handoff — pcie-on-ucie-3d

Read this first (with `docs/PLAN.md`) to resume. Newest state at top.

## Current state (2026-10-19)
- **M5 complete** (on branch `claude/m1-tx-datapath`). **M0 scaffold** on `main`;
  **M1 Tx / M2 Rx / M3 control plane / M4 five-env + fc + playground** committed on
  this branch.
- **M5 — bind-based SVA + SymbiYosys formal.** `dv/sva/adapter_sva.sv` (bound into
  the top) + `dv/sva/async_fifo_sva.sv` (bound into every FIFO), `--assert` in the
  vlt/systemc/uvm runs (`SVA=1` default; the vlt **coverage** build omits the bind
  — Verilator 5.0xx `--assert`+`--coverage` internal error). `formal/` has four
  `.sby` (async_fifo, ingress_gate, ctrl [nofc+fc], fc), each prove + cover, all
  green via `make formal`; `formal/Makefile` auto-adapts slang (plugin vs built-in)
  and the smtbmc solver (yices→z3, since this box has z3 not yices). Inventory +
  results in `ASSERTIONS.md`.
- **RTL fix D25:** A3 / F-PP1 caught `tx_idle` missing the `&& !tx_cr_req` guard the
  reference carries — under FLOW_CTRL a credit-only flit could leak into a post-drain
  state. Fixed in `rtl/pcie_ucie3d_adapter.sv`; default builds byte-identical, fc
  crosscheck unchanged (209 credit-only flits). See `docs/OPEN_DECISIONS.md` D25.
- `make ci` **GREEN**: lint (default + `FLOW_CTRL_OVERRIDE` + `DP_RESET_DISABLE`, x8
  refused), the Icarus suite (`make -C dv/iverilog smoke tx loop pm rxovf scen pcie_b2b
  ucie_b2b`), **coverage 87.2%** (floor 80%, `dv/common/covcheck.py`), formal (skips if
  no SBY), and the **five-env cross-check**.
- **M4 — all five envs agree on `dv/common/scenarios.py`, byte-exact.** Each runs the
  five scenarios on the C1 loopback and writes the `results.json` schema, self-crosschecks,
  then `crosscheck.py --require iverilog,vlt,uvm,systemc,cocotb`:
  - iverilog `dv/iverilog/tb_scen.sv`;
  - vlt + systemc share `dv/common/cpp/adapter_bfm.h` (POD-struct loopback harness +
    remote-die model + sequencer); `dv/vlt/sim_main.cpp` / `dv/systemc/sc_main.cpp` have a
    `+scen` mode beside the smoke;
  - cocotb `dv/cocotb/test_scen.py` (Python BFMs; `COCOTB_RESOLVE_X=ZEROS`);
  - uvm full env in `dv/uvm/adapter_uvm_pkg.sv` (sequence/driver/monitor/scoreboard +
    `ucie_phy_driver` remote die + `csr_agent`); the top reads `+UVM_TESTNAME` via
    `$value$plusargs` (DPI is off under `UVM_NO_DPI`).
  Golden `speed_change` pmcnt reconciled to 6 (D23).
- **C2/C3** directed Icarus tops: `tb_pcie_b2b.sv` (PCIe layer / BFM baseline) and
  `tb_ucie_b2b.sv` (two adapters across the UCIe-3D mainband, 40 frames each way
  byte-exact; each brings up against its own `ucie_sb_model`). See D24.
- **`fc_ctl.sv`** (D16) instantiated in the top (constants when `FLOW_CTRL=0`); under
  `-DFLOW_CTRL_OVERRIDE` the vlt/systemc/uvm `fc` targets rebuild with the define reaching
  both the RTL (`+define+`) and the C++ harness (`-D`); vlt FC = 209 credit-only flits,
  byte-exact, crosscheck OK.
- **Playground**: `playground/assemble.py` inlines the full RTL + `pcie_pat.svh` +
  `scenarios.svh` + the UVM TB into `playground/pcie_ucie3d_playground.sv`.
- RTL as in M3 plus `rtl/fc_ctl.sv` wired to `tx_egress`; `rtl/pcie_ucie3d_pkg.sv` unchanged.
- `make uvm`/`make -C dv/uvm scen` build Accellera UVM on the from-source Verilator 5.050
  (uvm-core at the pinned ref; slow first build; skips cleanly if uvm-core can't clone).
- Infra authored, not run against a remote: Dockerfile, CI, `swarm.yml`, railway.toml,
  docker/*, both `.claude/agents/` swarms, metrics/formal/lp scaffolds.
- **Repo is local only — no GitHub remote, nothing pushed** (user decision).

### Environment drift to know
- Local cocotb is **1.9.2** and pyuvm **4.0.1**; the canonical pins
  (`dv/cocotb/requirements.txt`, `~/proj/dv_env.mk`) are cocotb **1.8.1** / pyuvm
  **5.0.0**, which the CI image installs. The M0 smokes pass under both.
- Verilator must be ≥ 5.03x for the UVM env; **do not set `VERILATOR_ROOT`**.

## How to resume (three steps)
1. `make regress` (fast) or `make ci` (full: + coverage + formal + 5-env crosscheck),
   and `make formal` — confirm green.
2. Pick up **M6** from `docs/PLAN.md` §11: `lp/` UPF (authored, not run) + a power
   sequencer / `pipe_pmu` analog + `pd-emu` emulation checks (see the sibling eth-dj
   repo's `lp/`). Gate: `make upf` (notice/exit 0 without a PA simulator) + `make upf-tb`.
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
