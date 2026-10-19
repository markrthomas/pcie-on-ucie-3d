# dv/sva — bind-based SystemVerilog assertions

The RTL stays **assertion-free**; properties are `bind`-ed in from here and are
evaluated only in the Verilator-based envs (`--assert`); Icarus/cocotb skip them.
Property IDs are tracked in the top-level `ASSERTIONS.md`.

- `adapter_sva.sv` — bound into `pcie_ucie3d_adapter`: PCIe flit-stream legality
  (egress beat held until accepted, source held until accepted, well-formed
  `tkeep`/`tuser`), UCIe Tx legality (Tx only in L0 + ST_ACTIVE/ST_DRAIN,
  `start_flit` framing), sideband request→ack ordering + m2s byte framing, and the
  CDC/FIFO push/pop guards, plus cover properties.
- `async_fifo_sva.sv` — bound into every `async_fifo`: true occupancy ≤ DEPTH,
  no underrun/overrun, Gray pointers change one bit per clock.

Compiled with Verilator `--assert` in `dv/vlt`, `dv/systemc`, `dv/uvm`
(`SVA=0` on those Makefiles builds without them).  Icarus (`dv/iverilog`,
`dv/cocotb`) cannot evaluate concurrent SVA, so they are not bound there.  The
vlt **coverage** build omits the bind (`--assert` + `--coverage` trips a Verilator
5.0xx internal error); the assertions run in `scen`/`fc`.  Property list, IDs and
results: `../../ASSERTIONS.md`.
