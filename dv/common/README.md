# dv/common — shared golden model, mirrors, and BFMs

The cross-check spine every DV environment shares (docs/PLAN.md §5):

| File | Role |
|---|---|
| `scenarios.py` | **The golden model.** `expected()` over the shared scenario set; the single source of truth. |
| `scenarios.svh` | SystemVerilog mirror of `pat()` / the LCG (Icarus + UVM envs). |
| `cpp/adapter_bfm.h` | C++ mirror of `pat()` / the LCG (Verilator + SystemC harnesses). |
| `crosscheck.py` | The single arbiter: diffs each env's `results.json` against `expected()`; `--require` lists envs that must be present. "No artifact = not verified." |

**M0:** the golden model + mirrors are in; the shared BFM `.sv` models
(`pcie_ctrl_model`, `ucie_phy_model`, `pcie_sink_model`) and the per-env scenario
drivers that emit `results.json` land with the datapath (M1/M4).

Any change to the frame pattern, the LCG, or a scenario must be made in
`scenarios.py` **and** both mirrors together, or the cross-check breaks.
