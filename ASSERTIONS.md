# Assertions inventory

`rtl/` is **assertion-free**; simulation properties are bound in from `dv/sva/` and
evaluated only in the Verilator-based envs (`--assert`); Icarus/cocotb skip them.
Formal properties live in `formal/*_fv.sv`. This file is the single inventory of
every property, where it runs, and its result.

**Status: M0 — no properties yet.** The first-cut set lands in **M5**
(docs/PLAN.md §7). The tables below are the planned inventory.

## Where each kind runs
| Kind | Source | Runs in |
|---|---|---|
| Simulation SVA | `dv/sva/*.sv` (bound) | vlt, systemc, uvm (Verilator `--assert`) |
| Formal | `formal/*_fv.sv` + `*.sby` | `make formal` (SymbiYosys bmc + cover) |

## Simulation SVA (planned, M5)
| ID | Property | Clock | File |
|---|---|---|---|
| A1 | PCIe `tvalid` stable until `tready`; no data change mid-beat | pcie_clk | `dv/sva/adapter_sva.sv` |
| A2 | `tlast` / `tkeep` well-formed on the final beat | pcie_clk | `dv/sva/adapter_sva.sv` |
| A3 | `ucie_tx_valid` only in L0; no Tx during powerdown | ucie_clk | `dv/sva/adapter_sva.sv` |
| A4 | `ucie_tx_start_flit` framing (one per 256B flit) | ucie_clk | `dv/sva/adapter_sva.sv` |
| A5 | Sideband request → ack ordering; no two outstanding power requests | ucie_clk | `dv/sva/adapter_sva.sv` |
| A6 | CDC FIFO: no overflow / underflow; occupancy ≤ depth | both | `dv/sva/async_fifo_sva.sv` |

## Formal (planned, M5)
| ID | Property | Proof | Result |
|---|---|---|---|
| F1 | async_fifo no overflow/underflow | bmc | — |
| F2 | credit scheme never exceeds advertised limit (FLOW_CTRL) | bmc | — |
| F3 | sideband master: one outstanding transaction | bmc | — |
| cover | link reaches L0; a flit traverses Tx→Rx | cover | — |

## Mutation checks (planned, M5)
Each `dv-env-tester` proves its env can FAIL by reverting one RTL mutation; the
mutation→caught-by matrix is recorded here as the property set grows.
