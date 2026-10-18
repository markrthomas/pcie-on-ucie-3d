# dv/sva — bind-based SystemVerilog assertions

The RTL stays **assertion-free**; properties are `bind`-ed in from here and are
evaluated only in the Verilator-based envs (`--assert`); Icarus/cocotb skip them.
Property IDs are tracked in the top-level `ASSERTIONS.md`.

**M0:** placeholder. The first-cut property set lands in **M5** (docs/PLAN.md §7):
PCIe flit-stream legality (`tvalid` stable until `tready`, well-formed
`tlast`/`tkeep`), UCIe Tx legality (no Tx outside L0; `start_flit` framing), CDC/
FIFO safety (no overflow/underflow, occupancy ≤ depth), sideband request→ack
ordering, and no two outstanding power requests.
