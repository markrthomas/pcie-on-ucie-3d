# formal — SymbiYosys proofs

`make formal` (root) runs `make -C formal`: each `*.sby` has a **prove** task
(unbounded) and a **cover** task.  Property modules are `*_fv.sv`; the property
IDs (`F-*`) are listed in `../ASSERTIONS.md`.

| .sby | Design under proof | What |
|---|---|---|
| `async_fifo.sby`   | `async_fifo` (W=4, DEPTH=4), `multiclock on`, free wclk/rclk | occupancy ≤ DEPTH, no underrun, data integrity (black-box, shadow counters) |
| `ingress_gate.sby` | `tx_ingress_gate` | no accept while full, started frame finishes, no new frame once stopped, `stopped` only between frames |
| `ctrl.sby`         | `adapter_ctrl_fsm` + `ucie_sb_master` + `tx_egress`, default and `-DFLOW_CTRL_OVERRIDE` | Tx only in L0/ACTIVE/DRAIN, flit framing, pins change only in their change state, change/sideband bounds, one sideband op outstanding, m2s byte framing |
| `fc.sby`           | `fc_ctl` (`-DFLOW_CTRL_OVERRIDE`) | sender never past the remote credit limit, credit_ok ⇒ a credit left, cr_req only when stale, seq = data flits sent |

Tooling (no OSS CAD Suite): SBY + a slang-capable Yosys + yices/z3, built from
source in the `Dockerfile`.  `ctrl.sby` / `fc.sby` use the yosys-slang frontend
because the RTL imports the package in module headers; upstream Yosys has it built
in (`read_slang`), while the OSS CAD Suite shipped it as a loadable plugin
(`plugin -i slang`) — `formal/Makefile` detects the local tools and adapts either
the plugin line or the `smtbmc` solver (yices → z3) into a generated `_<proof>.sby`,
running the committed `.sby` verbatim only on the OSS CAD Suite baseline.  apt
Yosys does not ship slang.  `ctrl_fv.sv` also carries `h_*` helper invariants that
read the RTL timers / sideband-master state through hierarchical references
(slang resolves them); they are proven like the other assertions and exist so PDR
converges in seconds instead of searching the SB_TIMEOUT space.

Not proven formally: the CDC Gray single-bit change (sim SVA CD3 only), the Rx
path (`rx_ingress` / `rx_deframer`), and anything spanning both clock domains at
the top level.
