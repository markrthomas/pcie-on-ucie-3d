# Tutorial — getting oriented

A quick path into the **pcie-on-ucie-3d** repo for a new engineer or agent.

## What it is
A digital adapter that tunnels **PCIe 6 256-byte flits** over a **UCIe-3D raw-mode**
die-to-die bump interface, and back. One side speaks a PCIe FLIT stream
(AXI4-Stream-like); the other drives a wide raw-mode parallel bus plus an 8-bit
sideband. See `docs/ucie3d_notes.md` for the baseline and `docs/PLAN.md` for scope.

## The interfaces (frozen in `rtl/pcie_ucie3d_pkg.sv`)
- **PCIe / FDI side** (`pcie_clk`): `pcie_t*` ingress + `pcie_rx_t*` egress + a CSR port.
- **UCIe-3D side** (`ucie_clk`): `ucie_tx_*` / `ucie_rx_*` raw bus, `ucie_speed` /
  `ucie_width` / `ucie_powerdown`, link status, and the `ucie_sb_m2s` / `ucie_sb_s2m`
  sideband.

## The frame journey (M1+)
PCIe flit → `pcie_ingress` → `tx_cdc` (CDC) → `tx_framer` (pack into a 256B flit) →
`tx_egress` (serialise raw beats) → UCIe Tx. Reverse: UCIe Rx → `rx_ingress`
(flit-lock) → `rx_cdc` → `rx_deframer` → `pcie_egress`. The control plane
(`ucie_sb_master` + `adapter_ctrl_fsm` + `adapter_rf`) handles bring-up, L0/L1/L2,
and speed/width over the sideband.

## The testbenches
Five envs (`dv/{iverilog,vlt,uvm,systemc,cocotb}`) all run **Config 1** (integrated
adapter, UCIe Tx looped to Rx) on the shared scenarios in `dv/common/scenarios.py`
and agree via `dv/common/crosscheck.py`. **Config 2** (PCIe back-to-back) and
**Config 3** (UCIe-3D back-to-back) are the layer baselines. `playground/` is a
single-file UVM bundle for EDA Playground.

## Hands-on
```
make regress        # lint (Verilator) + Icarus smoke — the fast gate
make iverilog       # env 1 smoke
make vlt            # env 2 smoke (+ make coverage)
make systemc        # env 4 smoke
make cocotb         # env 5 smoke
make uvm            # env 3 smoke (clones uvm-core; slow first build)
python3 dv/common/scenarios.py   # print the golden expectations
```
Then read `docs/AGENT_HANDOFF.md` for the current state and the next milestone.
