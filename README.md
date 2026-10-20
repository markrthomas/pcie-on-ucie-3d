# pcie-on-ucie-3d

A synthesizable **PCIe ⇄ UCIe-3D raw-mode adapter** that tunnels **PCIe 6 256-byte
FLITs** over a **UCIe-3D** vertical die-to-die bump interface, verified in **five
independent DV environments** that cross-check against one Python golden model.

**Baseline:** UCIe **3.0** (Aug 2025) UCIe-3D — vertical stacking, hybrid-bonding
bump pitch, **no D2D adapter**, **raw mode** (the protocol owns CRC/retry); PCIe side
= PCIe 6 256B FLIT mode; 64 GT/s (Gen) baseline, datapath speed-parametric. See
[`docs/ucie3d_notes.md`](docs/ucie3d_notes.md).

**Status — M7 + M8 complete, project at close-out (2026-10-20).**
`make ci` GREEN and GitHub Actions green on `main` (8 jobs: build-image, regress,
coverage, systemc, uvm, cocotb, formal, crosscheck). Work lands via ready-for-review
PRs on `markrthomas/pcie-on-ucie-3d`, merged on green CI.

- **Five-environment cross-check** — iverilog, Verilator C++, SystemC, cocotb and UVM
  each run the shared five scenarios (`dv/common/scenarios.py`) on the Config-1 loopback
  and agree **byte-exact** (identical crc32 per scenario) via `crosscheck.py`.
- **Three TB configs** — C1 integrated loopback (all 5 envs), C2 `tb_pcie_b2b`, and C3
  `tb_ucie_b2b` (two adapters across the raw-mode link, byte-exact both ways).
- **Flow control** — `fc_ctl` credit scheme runs under `-DFLOW_CTRL_OVERRIDE`
  (credit-only flits, byte-exact).
- **Formal (M5)** — bind-based SVA in `dv/sva/` + four SymbiYosys proofs in `formal/`
  (`async_fifo`, `ingress_gate`, `ctrl` nofc+fc, `fc`), each prove + cover.
- **Power (M6)** — `lp/` UPF (authored), PMU sequencer + power-aware TB (`make upf-tb`),
  and OSS PD_DP power-state emulation (`make pd-emu` / `pd-emu-ret`).
- **Infra (M7)** — per-test GTKWave sessions + `wave_check.py`, a real-artifact metrics
  dashboard, and a Railway batch job (authored; not yet deployed).
- **Coverage** — line coverage **99.6%** (floor **99%**); the single-file EDA Playground
  bundle regenerates from the real sources.

Roadmap + open items: [`docs/PLAN.md`](docs/PLAN.md) §11, [`docs/OPEN_DECISIONS.md`](docs/OPEN_DECISIONS.md),
[`docs/AGENT_HANDOFF.md`](docs/AGENT_HANDOFF.md).

## What this adapter does
PCIe flits enter on an AXI4-Stream-like interface, cross into the UCIe clock domain,
are packed into 256-byte flits, and are serialised over a wide raw-mode parallel bump
bus; the reverse path reassembles them. A small control FSM brings the link up and
sequences L0/L1/L2 and speed/width changes over an 8-bit UCIe **sideband**.

Block diagram (data flows left-to-right on Tx, right-to-left on Rx; the `|` marks
the pcie_clk / ucie_clk boundary crossed by the two async FIFOs):

```
        pcie_clk domain          |             ucie_clk domain
                                 |
  PCIe6  --pcie_tx--> tx_ingress_gate --> tx_cdc --> tx_framer --> tx_egress --ucie_tx-->  UCIe-3D
  ctrl                                    (FIFO)    (256B flit)   (raw beats)              PHY BFM
  BFM                                     |                                              (raw mode)
                                          |                                                  |
  PCIe6  <--pcie_rx-- pcie_egress <-- rx_cdc <-- rx_deframer <-- rx_ingress  <--ucie_rx-------+
  ctrl                                (FIFO)                    (flit-lock)
                                 |
  control plane (ucie_clk):  adapter_ctrl_fsm + ucie_sb_master + adapter_rf (CSRs)
                             <================ 8-bit sideband ================> UCIe-3D PHY BFM
```

Control FSM (`adapter_ctrl_fsm.sv`). Bring-up trains the link and parks it in L1; a
CSR power request then brings it to L0. In L0 any pending speed / width / preset /
power change drains the datapath first, then performs exactly one operation:

```
  reset
    |
    v
  ST_RESET --(link reset)--> ST_SBINIT --(rx !elec_idle)--> ST_MBINIT --(rx_active)--> ST_LOWPWR
                                                                                           |
  ST_LOWPWR  (L1/L2, datapath gated) --(CSR pwr req L1->L0)--> ST_PWR_CHG ----------------> ST_ACTIVE
                                                                                           |
  ST_ACTIVE  (L0, datapath running) --(speed/width/preset/pwr change pending)--> ST_DRAIN  |
                                                                                    |      ^
  ST_DRAIN  (close ingress at frame boundary; flush Tx + Rx) then ONE op, by priority:     |
    +--> ST_SPEED_CHG --+                                                                  |
    +--> ST_WIDTH_CHG --+--> (back through ST_DRAIN) --------------------------------------+
    +--> ST_PARAM ------+     (ST_PARAM = preset sideband write)
    +--> ST_PWR_CHG ---------> ST_LOWPWR   (power down to L1/L2)
```

## Quick start
```
make regress        # lint + Icarus smoke — the fast CI gate
make iverilog vlt systemc cocotb uvm    # the five DV env smokes
make coverage       # Verilator --coverage -> coverage.info
make ci             # regress + coverage + formal + envs + crosscheck
python3 dv/common/scenarios.py          # the golden expectations
python3 playground/assemble.py          # (re)build the EDA Playground bundle
```
Tools (no OSS CAD Suite) are pinned in the [`Dockerfile`](Dockerfile); see
[`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md). Verilator-based flows run in a container
(GitHub Actions / Railway).

## The three testbench configs
- **C1 — PCIe on UCIe-3D only**: integrated adapter, UCIe Tx looped to Rx (all 5 envs).
- **C2 — PCIe back-to-back**: two PCIe endpoints direct (PCIe layer in isolation).
- **C3 — UCIe-3D back-to-back**: two UCIe-3D PHYs at the bumps (raw-mode link in isolation).

## Layout
```
rtl/   dv/{iverilog,vlt,uvm,systemc,cocotb,common,sva,waves,random}   formal/  lp/
metrics/  playground/  docker/  .claude/agents/  .github/workflows/  docs/
```

## Workspace conventions
Inherits [`~/proj/CLAUDE.md`](../CLAUDE.md) and [`~/proj/DV_STANDARDS.md`](../DV_STANDARDS.md);
tools pinned in the Dockerfile (no OSS CAD Suite). `rtl/` stays assertion-free (SVA
via `bind` in `dv/sva/`). Two AI agent swarms live in `.claude/agents/`
([index](.claude/agents/README.md)).
