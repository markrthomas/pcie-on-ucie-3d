# playground — single-file UVM bundle for EDA Playground

`pcie_ucie3d_playground.sv` is a **generated**, self-contained
(package + RTL + UVM TB) file you can paste into [edaplayground.com](https://edaplayground.com):

- **Testbench + Design** → paste the file (single pane is fine).
- **Tools & Simulators** → a UVM-capable simulator; **UVM** → 1.2.
- **Top module** → `tb_uvm_top`; run args → `+UVM_TESTNAME=smoke_test`.

Regenerate after any source change with:

```
python3 playground/assemble.py
```

**M0:** the bundle carries the stub DUT + the UVM smoke test. **M4** swaps the
smoke TB for the Config-1 loopback scenario TB (shared `dv/common/scenarios.py`
set). This single-file artifact is net-new to this repo (the sibling eth-dj repo
has no EDA Playground bundle). See docs/PLAN.md §5.
