# Agent handoff — pcie-on-ucie-3d

Read this first (with `docs/PLAN.md`) to resume. Newest state at top.

## Current state (2026-10-18)
- **M3 complete** (on branch `claude/m1-tx-datapath`). **M0 scaffold** on `main`;
  **M1 Tx** and **M2 Rx** committed on this branch.
- `make regress` **GREEN**: Verilator `--lint-only -Wall` (default +
  `FLOW_CTRL_OVERRIDE` + `DP_RESET_DISABLE`, x8 refused) + Icarus `make sim`
  (**smoke + tx + loop + pm + rxovf**): `tb_smoke` reset + link-up, `tb_tx` (115 frames
  → 512 flits), `tb_loop` (115 frames looped byte-exact), `tb_pm` (**PM PASS**,
  PMCNT=17, 6 preset writes, power/speed/width/cancel/L0s/timeout), `tb_rxovf`
  (**RXOVF PASS**, overload drop/abort + recovery).
- **RTL — datapaths + control plane complete.** Datapaths as in M2. Control plane on
  `ucie_clk`: `adapter_rf.sv` (CSRs; Rx counters in RXCNT0/1, op counter in PMCNT),
  `adapter_ctrl_fsm.sv` (bring-up SBINIT/MBINIT/PARAM, L0/L1/L2, speed/width, drain),
  `ucie_sb_master.sv` (4-byte sideband write + ack), `tx_ingress_gate.sv` (drain gate).
  Out of reset the FSM trains the link, sends the Tx preset, brings power to L0, then
  opens the ingress. Datapath-local reset (D18, default on) holds the datapath in reset
  in L1/L2. `rtl/pcie_ucie3d_pkg.sv` unchanged.
- BFMs: `pcie_mac_model.sv`, `ucie_phy_model.sv`, `pcie_sink_model.sv`,
  `ucie_sb_model.sv` (remote-die control: bring-up + sideband ack + link_status pulse +
  Tx-legality checker), `pcie_pat.svh`, shared `dv/iverilog/loop_harness.svh`.
  `scenarios.py` + mirrors + `crosscheck.py` in; envs report against them in M4.
- Five env smokes pass on the M3 gated contract (`pcie_tready` **closed** before link-up;
  the C++/py/uvm smokes tie the status inputs so the FSM parks in bring-up): `make
  iverilog`/`vlt`/`systemc`/`cocotb`; `make uvm` builds Accellera UVM on the from-source
  Verilator 5.050 (uvm-core at the pinned ref; slow first build).
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
2. Pick up **M4** from `docs/PLAN.md` §11: fill out all five envs on the shared
   `dv/common/scenarios.py` (Python golden + SV/C++ mirrors), each emitting the
   `results.json` schema, and run `dv/common/crosscheck.py` across them; build the C2
   (PCIe back-to-back) and C3 (UCIe-3D back-to-back) tops; assemble the single-file EDA
   Playground bundle (`playground/assemble.py`). Also land the deferred raw-mode credit
   controller `fc_ctl` (FLOW_CTRL/D16): the Tx (`tx_egress`) and Rx (`rx_ingress`) hooks
   already exist; wire a `fc_ctl` on the Rx-credit/Tx-seq path and exercise it under
   `-DFLOW_CTRL_OVERRIDE`. Gate: `make ci`, coverage ≥ 80%.
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
