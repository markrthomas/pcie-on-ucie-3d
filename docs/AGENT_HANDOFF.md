# Agent handoff — pcie-on-ucie-3d

Read this first (with `docs/PLAN.md`) to resume. Newest state at top.

## Current state (2026-10-18)
- **M2 complete** (on branch `claude/m1-tx-datapath`). **M0 scaffold** was committed
  to `main`; **M1 Tx datapath** committed on this branch.
- `make regress` **GREEN**: Verilator `--lint-only -Wall` (default +
  `FLOW_CTRL_OVERRIDE` + `DP_RESET_DISABLE`, x8 refused) + Icarus `make sim`
  (`tb_smoke` reset/defaults + `tb_tx`: **TX PASS, 115 frames, 512 flits** + `tb_loop`:
  **LOOP PASS, 115 frames, 512 flits, payloads byte-exact, Rx error counters all 0**).
- **RTL — both datapaths live**. Tx: `async_fifo.sv` (generic CDC), `tx_framer.sv`
  (256B raw-mode flit assembly), `tx_egress.sv` (serialise UCIE_BUS_W beats). Rx:
  `rx_ingress.sv` (flit-lock on `ucie_rx_start_flit`, overflow/lock-error counters),
  `rx_deframer.sv` (unpack payload → PCIe beats, D9 abort on gap/sof/bad-header),
  a second `async_fifo` (rx_cdc), `pcie_egress.sv` (FWFT AXI-S master). All wired in
  `pcie_ucie3d_adapter.sv`. No control plane yet, so `tx_en=1`, the PCIe ingress is
  open when the Tx CDC FIFO is not full, and the DV-visible Rx error counters are
  observation points (no CSR read-back until M3). `rtl/pcie_ucie3d_pkg.sv` unchanged.
- BFMs: `dv/common/pcie_mac_model.sv` (AXI4-S source), `ucie_phy_model.sv` (UCIe Tx
  sink + raw-mode flit monitor), `pcie_sink_model.sv` (AXI4-S slave sink + checker),
  `pcie_pat.svh`. `scenarios.py` + mirrors + `crosscheck.py` in; envs report in M4.
- Five env smokes pass against the live datapath (`pcie_tready` open at idle,
  `pcie_rx_tvalid` low at idle = Rx CDC FIFO empty): `make iverilog`/`vlt`/`systemc`/
  `cocotb`; `make uvm` builds Accellera UVM on the from-source Verilator 5.050
  (uvm-core at the pinned ref; slow first build).
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
2. Pick up **M3** from `docs/PLAN.md` §11: the control plane — `ucie_sb_master`
   (8-bit sideband M2S/S2M transactions), `adapter_ctrl_fsm` (link bring-up
   SBINIT→MBINIT→PARAM→ACTIVE, L1/L2, speed/width, raw↔credit), and `adapter_rf`
   (CSR read/write, wire the DV-visible Rx error counters into `CSR_RXCNT0/1` and the
   `CSR_PMCNT` op counter). Replace the control stub in the top (`ucie_speed`/`width`/
   `powerdown`/`sb_m2s` constants and the combinational `csr_rdata` mux) and reintroduce
   link-up gating of the ingress (`tx_en`/`pcie_tready`). Add `tb_pm`, `tb_rxovf`, and
   extend `tb_smoke` to the link-up contract. A sideband peer model is needed on the
   UCIe side (mirror eth-dj `msgbus_mac_tgt` / `pipe_phy_ctrl_model`).
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
