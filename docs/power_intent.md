# Power intent (UPF) — authored, not run

**Status: M6 deliverable.** This file records the intended power architecture now so
the datapath is designed for it; the `lp/` UPF + power-aware TB land in M6.

## Architecture
- **`PD_AON`** (always-on): the control plane — `adapter_ctrl_fsm`, `ucie_sb_master`,
  `adapter_rf`, top glue. Must stay alive through L1/L2 to sequence link recovery.
- **`PD_DP`** (switchable): the whole Tx/Rx datapath (ingress/CDC/framer/egress,
  reverse path), power-gated in L1/L2.
- `adapter_rf` sits in **`PD_AON`** so programmed config survives a low-power episode.
  With the default datapath-local reset (D18) the datapath is drained before L1/L2,
  so it needs **no retention**.

## Binding & OSS reality
UPF is applied at a power-aware TB top (`tb_ucie3d_upf_power`) that instantiates the
DUT plus a DV-only power sequencer (the DUT has no power ports — controls come from
the sequencer). OSS simulators (Verilator/Icarus/Yosys) do **not** model UPF
supply/isolation/retention/corruption, and commercial PA runs are out of scope.
`make upf` runs on VCS-NLP / Xcelium / Questa-PA if one is on PATH (untested command
lines), else prints "authored, not run" and exits 0. The power behaviour is instead
checked by `make upf-tb` (PMU sequencing) and `make pd-emu` / `pd-emu-ret`
(corruption / isolation / retention emulation). This file is review-validated, not
CI-gated.
