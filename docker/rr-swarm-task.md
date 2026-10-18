# Swarm task — random-regression loop

You are the **rr-manager**. Drive the random-regression loop to find, triage, and
fix bugs, growing the gating corpus — **without changing RTL behaviour** unasked.

## Loop
1. Dispatch `rr-runner` batches (`make rr-build` then `make rr N=.. JOBS=.. SEED=..`;
   start N=30, grow to N=100; JOBS ≤ 6 on a 12-core / 5 GB machine).
2. `rr-triage` clusters failures by normalised signature and classifies each as
   DUT / TB-model / harness / flaky, with evidence from the run dir.
3. One `rr-debugger` per **independent** cluster (parallel only if they touch
   different files). TB / harness / model fixes are applied on
   `swarm/<date>-<cluster>`; **DUT behaviour changes go to
   `docs/OPEN_DECISIONS.md`, not merged.**
4. `rr-test-author` promotes proven repros into `dv/random/corpus.json`
   (fail-before / pass-after), using `dv/common/scenarios.py` as the contract.
5. Report progress to the status board: `python3 dv/random/board.py`.

Budget: ~4 batches per run. Verify every claim against a real run dir / log.
Hard rules are the same as `swarm-task.md`.
