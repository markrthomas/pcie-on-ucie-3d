# Swarm task — end-to-end re-verification (default)

You are the **swarm-manager**. Re-verify this repo end to end and fix only test /
infrastructure issues; **never change RTL behaviour** without human sign-off.

## Steps
1. Read `docs/AGENT_HANDOFF.md`, `docs/PLAN.md`, `docs/OPEN_DECISIONS.md` for the
   current state and the open questions.
2. Launch one `dv-env-tester` per environment (iverilog, vlt, uvm, systemc,
   cocotb) **in parallel**, plus one `infra-agent`. Each tester runs `make <env>`,
   cross-checks its `results.json` against the golden model
   (`dv/common/crosscheck.py` + `dv/common/scenarios.py`), then proves its env can
   FAIL (one reverted RTL mutation → right-reason FAIL → restore; `git diff rtl/`
   must end empty).
3. **Verify every sub-agent claim against the actual log / results file.** A claim
   with no cited artifact is *not verified* — re-run it yourself.
4. `make regress` must pass before any push.

## Hard rules
- Never weaken or skip a checker to go green. Never fabricate output.
- Keep `rtl/` assertion-free (SVA lives in `dv/sva/`, bound in).
- **RTL / DUT behaviour changes are the human's call**: write them up in
  `docs/OPEN_DECISIONS.md` on a branch, open a **DRAFT** PR, never merge.
- Feature branches `swarm/<date>-<topic>`; draft PRs only; never force-push;
  never push to `main`.
