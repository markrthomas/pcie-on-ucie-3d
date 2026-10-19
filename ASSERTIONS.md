# Assertions inventory

`rtl/` is **assertion-free**; simulation properties are bound in from `dv/sva/` and
evaluated only in the Verilator-based envs (`--assert`); Icarus/cocotb skip them.
Formal properties live in `formal/*_fv.sv` and are proven by `make formal`
(SymbiYosys: a `prove` task + a `cover` task per `.sby`).  This file is the single
inventory of every property, where it runs, and its result.

**Status: M5 — property set landed and green.**  Simulation SVA bound into the
vlt / systemc / uvm runs (`make scen`, `make fc`); `make formal` proves four
`.sby` (async_fifo, ingress_gate, ctrl, fc), each `prove` + `cover`, the control
proof also with `-DFLOW_CTRL_OVERRIDE`.

## Where each kind runs
| Kind | Source | Runs in |
|---|---|---|
| Simulation SVA | `dv/sva/*.sv` (bound) | vlt, systemc, uvm (Verilator `--assert`) |
| Formal | `formal/*_fv.sv` + `*.sby` | `make formal` (SymbiYosys prove + cover) |

Icarus-12 (`dv/iverilog`, `dv/cocotb`) has no concurrent-SVA support, so the
checkers are not bound there.  The vlt **coverage** vehicle is built without the
bind (`--assert` + `--coverage` hits a Verilator 5.0xx `V3Localize` internal error
on the property body); the same assertions run in `scen`/`fc`.

## Simulation SVA — `dv/sva/adapter_sva.sv` (bound into `pcie_ucie3d_adapter`)
| ID | Property | Clock | Result |
|---|---|---|---|
| A1  | egress beat (valid + payload) held until the sink accepts it | pcie_clk | pass |
| A1b | PCIe source holds its beat until accepted (environment check) | pcie_clk | pass |
| A2  | egress `tkeep` nonzero, contiguous from byte 0, all-ones except on `tlast` | pcie_clk | pass |
| A2b | `tuser[0]` (abort/err) only on a `tlast` beat; rest of `tuser` zero | pcie_clk | pass |
| A3  | Tx beats only in L0 **and** only in ST_ACTIVE/ST_DRAIN (no Tx in low power / mid-change) | ucie_clk | pass |
| A4  | `start_flit` only at a flit boundary; a flit is FLIT_BEATS contiguous valid beats | ucie_clk | pass |
| A5  | sideband: one transaction outstanding; `done`/`timeout` follow a busy wait, never coincide | ucie_clk | pass |
| A5b | m2s framing: idle `8'h00` when !busy; `{SB_WR,0}` / addr hi / addr lo on the first 3 busy cycles | ucie_clk | pass |
| A6  | CDC FIFOs: ingress never writes a full FIFO, egress never pops an empty one (both sides) | both | pass |

## Simulation SVA — `dv/sva/async_fifo_sva.sv` (bound into every `async_fifo`)
| ID | Property | Result |
|---|---|---|
| CD1 | true occupancy (wbin − rbin) never exceeds DEPTH | pass |
| CD2 | no underrun (pop ⇒ nonempty) / no overrun (push ⇒ not full) | pass |
| CD3 | Gray pointers change by at most one bit per clock | pass |

## Formal — `make formal` (prove = unbounded, cover = reachability)
| .sby | Design under proof | Properties | Result |
|---|---|---|---|
| `async_fifo.sby`   | `async_fifo` (W=4, DEPTH=4), `multiclock on`, free wclk/rclk | F-CD1 occupancy ≤ DEPTH, F-CD2 no underrun, F-CD4 data integrity (anyconst) | prove+cover pass |
| `ingress_gate.sby` | `tx_ingress_gate` | F-IG1 no accept while full, F-IG2 started frame finishes, F-IG3 no new frame once stopped, F-IG4 `stopped` only between frames | prove+cover pass |
| `ctrl.sby`         | `adapter_ctrl_fsm` + `ucie_sb_master` + `tx_egress`, default **and** `-DFLOW_CTRL_OVERRIDE` | F-PP1 Tx only in L0/ACTIVE/DRAIN, F-PP3 flit framing, F-PP4 pins change only in their change state, F-PP5 change bounded by SB_TIMEOUT, F-MB1 one sideband op outstanding, F-MB3 m2s byte framing, F-MB4 no pin change while a sideband write is outstanding, F-MB5 busy ≤ SB_TIMEOUT+3 | prove+cover pass (nofc + fc) |
| `fc.sby`           | `fc_ctl` (`-DFLOW_CTRL_OVERRIDE`) | F-FC1 never past the remote credit limit, F-FC2 credit_ok ⇒ a credit left, F-FC3 cr_req only when the advertised limit is stale, F-FC4 seq = data flits sent | prove (k-induction)+cover pass |

Not proven formally (sim SVA only): CDC Gray single-bit change (F-CD3 / CD3), the
Rx datapath (`rx_ingress` / `rx_deframer`), and anything spanning both clock
domains at the top level.

## Findings surfaced by the property set
- **D25** — `a_a3_tx_only_l0` (and formal F-PP1) caught that the top's `tx_idle`
  omitted the `&& !tx_cr_req` guard the reference design carries: under FLOW_CTRL a
  credit-only flit could launch in the same cycle the FSM declared the datapath
  drained, so the flit was transmitted in a post-drain (e.g. ST_PARAM) state.
  Fixed in `rtl/pcie_ucie3d_adapter.sv`; see `docs/OPEN_DECISIONS.md` D25.  The
  crosscheck fields (data flits / bytes / crc32 / pmcnt) are unaffected.

## Mutation checks (dv-env-tester doctrine)
Each `dv-env-tester` proves its env can FAIL by reverting one RTL mutation; the
mutation→caught-by matrix is recorded here as the swarm runs exercise it.  The D25
fix doubles as a worked example: reverting it (dropping `&& !tx_cr_req`) makes
`make -C dv/vlt fc` fail on `a_a3_tx_only_l0`.
