# Power intent — pcie_ucie3d_adapter

**Status: authored, not run.** No OSS simulator here models UPF supplies,
isolation, retention or corruption. `lp/adapter.upf` has **not been parsed or
simulated by any tool**. What *has* been run is a functional (not power-aware)
Icarus simulation of the power-aware TB (`make upf-tb`), which checks the PMU
sequencing and the timing assumption below. Nothing in this document is a
power-aware simulation result.

## Files

| File | What |
|---|---|
| `lp/adapter.upf` | IEEE 1801 (UPF 2.1) power intent, scoped at `tb_adapter_upf_power`. |
| `lp/tb_adapter_upf_power.sv` | Power-aware TB top: the adapter on the shared C1 loopback harness plus `u_pmu`. `+define+UPF_SIM` turns on `supply_on` calls for a PA simulator. |
| `lp/adapter_pmu.sv` | DV-only power sequencer. **Not part of the DUT.** Drives `dp_pwr_en`, `dp_iso_en`, `dp_save`, `dp_restore` on `ucie_clk`. |
| `lp/Makefile` | `upf-pa` (commercial PA simulator if on PATH, else notice + exit 0), `upf-tb` (functional Icarus run). |
| `lp/cocotb/` | OSS UPF-like power-state emulation (`pd_top.sv`, `pd_emu.py`, `test_pd.py`, `check_pd.py`, `Makefile`); `make -C lp/cocotb pd` / `pd-ret`. See the emulation section below. |

`make upf` prints the "authored, not run" notice and exits 0. `make upf-tb` runs
the functional TB and fails on any error.

## Architecture

| Domain | Supply | Contents | Why |
|---|---|---|---|
| **PD_AON** | SS_AON (VDD) | TB, DUT top glue + datapath-reset synchroniser, `u_ctrl` (adapter_ctrl_fsm), `u_sb` (ucie_sb_master), `u_rf` (adapter_rf), `u_fc_ctl` (fc_ctl), `u_pmu` | Sequences L1/L2 entry and exit and must stay alive to wake the link. |
| **PD_DP** | SS_DP (VDD_DP, switched by SW_DP) | `u_tx_gate`, `u_tx_cdc`, `u_tx_framer`, `u_tx_egress`, `u_rx_ingress`, `u_rx_deframer`, `u_rx_cdc`, `u_pcie_egress` (both clock domains) | The datapath is idle in L1/L2 after a drain. |

- **`adapter_rf` is in PD_AON**: the AON FSM reads `pwr_req` from it, and a CSR
  write is the only way to request wake-up, so it cannot be switched off.
- **`fc_ctl` is in PD_AON** so the credit / sequence state survives a low-power
  episode (OPEN_DECISIONS D16); otherwise a flow-controlled link would lose its
  credit accounting across every L1/L2.
- **Isolation** (`-location parent`, supplied from SS_AON, `dp_iso_en` active high):
  - All PD_DP outputs clamp to 0 by default — the PCIe handshakes/data, the UCIe
    Tx bus, the egress busy flag and the Rx counters — so no traffic and no
    spurious handshakes while PD_DP is off, and CSR RXCNT reads 0.
  - Four drain-status outputs clamp to 1: `u_tx_cdc/rempty`, `u_tx_framer/idle`,
    `u_rx_ingress/idle`, `u_tx_gate/stopped`. The AON FSM therefore sees an
    isolated datapath as drained and idle.
- **Retention:** the default RTL holds PD_DP in reset from `ST_LOWPWR` to the next
  `ST_DRAIN` (OPEN_DECISIONS D18, default on), so the **default build needs no
  retention** — PD_DP comes back cleared and the FSM re-drains before use. The
  `RET_DP` block in the UPF is kept for `-DDP_RESET_DISABLE` builds (pre-D18
  behaviour), where it retains all PD_DP state; that is only correct because the
  FSM drains the datapath (empty FIFOs, no frame in flight) before power-down.
- **Level shifters:** none, both domains run at the same voltage when on.

## PMU sequence (lp/adapter_pmu.sv, on ucie_clk)

1. **Arm:** a CSR CTRL write requests L1 or L2. The PMU never powers down during
   the reset link-up, even though that also starts in L1.
2. **Power down:** once `ucie_powerdown` has been L1/L2 for `DOWN_DELAY` (16)
   ucie_clk, the PMU does `iso_en=1`, then pulses `save`, then sets `pwr_en=0`.
3. **Power up:** on a CSR CTRL write that requests L0/L0s, the PMU sets `pwr_en=1`,
   waits `PWR_UP_CYC` (2), pulses `restore`, then sets `iso_en=0` (~4 ucie_clk).

**No handshake with the FSM:** `adapter_ctrl_fsm` does not know about the PMU.
- After the wake CSR write, the FSM goes `ST_LOWPWR` → `ST_PWR_CHG` (pin to L0),
  waits for the remote die's link-status pulse, then enters `ST_DRAIN`, which
  reads the datapath idle flags.
- This works only if power-up finishes within the link-status latency of the
  L1→L0 change. That latency is **8 ucie_clk** in the DV remote model
  (`dv/common/ucie_sb_model.sv`, `lat`), comfortably more than the ~4-cycle
  power-up — `tb_adapter_upf_power` checks the assumption every cycle.
- A real implementation should add a power-good input so the FSM waits for it.
  That is an RTL change, listed as an open item.

## What `make upf-tb` checks (functional only)

- **Sequence order:** `save` only while isolated; power off only after iso+save;
  `restore` only while powered; isolation released only after power-on+restore.
- **Timing assumption:** whenever the FSM is outside `ST_RESET`, `ST_LOWPWR` or
  `ST_PWR_CHG`, PD_DP is powered and not isolated; and no Tx while isolated.
- **Low-power episodes:** one L1 episode and one L2 episode, and PD_DP really
  powers down and up twice (`n_down == n_up == 2`).
- **Traffic:** frames sent before, between and after the episodes arrive
  byte-exact and in order (via the shared loopback scoreboard).

Current result: `UPF-TB PASS` (36 frames, 2 PD_DP power-down/up cycles).

## Not verified (needs a commercial power-aware simulator; none available, none planned)

- That `adapter.upf` parses and that the element / pin paths resolve. They follow
  the RTL instance names but have never been elaborated by any tool.
- Corruption of PD_DP while off, the clamp values in action, and retention
  save/restore behaviour.
- The legality of the power states / PST.

`make upf` automates the commercial run when vcs / xrun / vsim is on PATH (command
lines untested); otherwise it reports the missing tool and exits 0. By hand:
1. Compile `lp/tb_adapter_upf_power.sv` + `lp/adapter_pmu.sv` with `+define+UPF_SIM`,
   together with the RTL and `dv/common` BFMs (see `lp/Makefile`).
2. Load `lp/adapter.upf` at `tb_adapter_upf_power`.
3. Run and look for `UPF-TB PASS`.

## OSS power-state emulation (lp/cocotb — "UPF-like without UPF")

Since no OSS tool models UPF, `lp/cocotb/` **emulates** what `adapter.upf` would do in
a power-aware simulator, driven by the PMU outputs, with cocotb on Icarus. `pd_top.sv`
is an SV loopback top (the adapter with the UCIe-3D Tx bus looped back to Rx, the SV
remote-die model `ucie_sb_model`, and `adapter_pmu`); `pd_emu.py` watches the PMU and:

- **power-off** (`dp_pwr_en=0`): writes random values into every PD_DP register each
  ucie_clk (a powered-off domain holds nothing);
- **isolation** (`dp_iso_en=1`): forces the PD_DP outputs the always-on logic / remote
  die read to their `adapter.upf` clamp values (idle/empty flags → 1; the UCIe-3D Tx
  bus, egress-busy and the Rx counters → 0);
- **retention** (`dp_save` / `dp_restore`): snapshots and restores a selectable set of
  register groups; the rest stay corrupt after power-up.

`test_pd.py` runs a retention matrix: reset, link up, send frames, power PD_DP down
through the PMU (CSR L1), hold it off, wake it (CSR L0), send more frames, and require
every frame in/out byte-exact and in order with the FSM back in `ST_ACTIVE` and the Rx
drop/abort counters zero — across three corruption seeds. `make pd-emu` (root) runs
both builds; `make -C lp/cocotb pd` / `pd-ret` run one each.

### Results (measured, Icarus + cocotb)

| Build | retain-none | minimal retained set | PD_DP register bits retained |
|---|---|---|---|
| **default** (datapath-local reset ON, D18) | **PASS** | ∅ (none) | **0 / 31754 (0 %)** |
| `-DDP_RESET_DISABLE` (pre-D18) | **FAIL** (negative control) | the 7 `/ctl` groups | **362 / 31754 (1.1 %)** |

- **This answers D18 quantitatively.** With the datapath-local reset (default) the FSM
  re-drains PD_DP on low-power exit, so **no PD_DP state needs retention** — corrupting
  any/all of it and retaining nothing still delivers every frame.
- With the reset disabled, retention is required, and the greedy-minimal set is only the
  **control/pointer registers** (CDC Gray pointers, framer/deframer/ingress-gate control
  flops): the FIFO **memories** (`/mem`) and the **wide** flit buffers are never
  sensitive, because the datapath is drained empty before power-down. The full list is
  `lp/cocotb/retention_min.txt` (67 registers), regenerated by `make -C lp/cocotb pd-ret`.
- The negative control (`-DDP_RESET_DISABLE`, retain nothing) **fails** — the corruption
  wedges the wake (FSM stuck leaving L0), confirming the emulation actually bites.

## Not yet built

- **OSS gate-level area/power estimate** (Yosys map + OpenSTA): not run; no
  area/power numbers are claimed in this repo.
