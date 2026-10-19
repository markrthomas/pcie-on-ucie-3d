# lp — UPF power intent (authored, not run)

- `adapter.upf` — IEEE 1801 (UPF 2.1): PD_AON (ctrl FSM, sideband master, CSRs,
  flow-control accounting, glue) + PD_DP (switchable Tx/Rx datapath, both clock
  domains, isolated; retained only in `-DDP_RESET_DISABLE` builds). Scoped at the
  TB top `tb_adapter_upf_power`.
- `tb_adapter_upf_power.sv` — power-aware TB top (adapter on the C1 loopback
  harness + PMU).
- `adapter_pmu.sv` — DV-only power sequencer on ucie_clk (iso -> save -> off;
  on -> restore -> de-iso). **Not part of the DUT.**
- `make upf` (root) / `make -C lp upf-pa` runs the UPF TB on VCS-NLP / Xcelium /
  Questa-PA if one is on PATH (untested command lines); otherwise it reports the
  missing tool and exits 0 (no OSS power-aware simulator exists).
- `make upf-tb` runs the TB on Icarus **without** power semantics: checks PMU
  sequencing, the no-handshake timing assumption and traffic across L1/L2.

- `make pd-emu` (root) / `make -C lp/cocotb pd` + `pd-ret` runs the OSS **power-state
  emulation** in `cocotb/`: `pd_top.sv` (adapter + UCIe loopback + remote-die model +
  PMU) with `pd_emu.py` emulating PD_DP power-off (state corruption), isolation clamps
  and retention save/restore — the "UPF-like without UPF" check. Result: with the
  datapath-local reset ON (default, D18) **no PD_DP retention is needed**; with
  `-DDP_RESET_DISABLE` only the control registers (362/31754 bits, 1.1 %) must be
  retained (`cocotb/retention_min.txt`).

Details, the architecture table, the measured retention matrix and what is **not**
verified: `../docs/power_intent.md`.
