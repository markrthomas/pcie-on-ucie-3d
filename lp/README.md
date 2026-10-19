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

Details, the architecture table and what is **not** verified: `../docs/power_intent.md`.
The OSS power-state emulation (cocotb) is the tracked M6 remainder — see that doc.
