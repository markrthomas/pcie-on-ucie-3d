# dv/random — random regression, triage, replay corpus, swarm board

- `rr.py` — Verilator random-regression driver (build/run/triage/replay).
- `rr_iv.py` — the same on the Icarus TBs (`+seed`). *(M4+)*
- `corpus.json` — the permanent gating repro set; `rr-replay` is part of `make ci`. *(M4+)*
- `board.py` + `board/*.json` — the git-based status board the random-regression
  swarm (Swarm B) reports to. *(M7)*

**M0:** `rr.py` is a scaffold; the loop is wired in M4+ once the Verilator
scenario env exists. See docs/PLAN.md §10 (agent swarm) and §11 (backlog).
