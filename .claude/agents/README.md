# .claude/agents — the AI agent swarms

Two swarms (run Claude Code non-bare via `docker/swarm.sh` so these load).
Default task: `../docker/swarm-task.md` (Swarm A) or `../docker/rr-swarm-task.md`
(Swarm B).

## Swarm A — end-to-end re-verification (`docker/swarm-task.md`)
| Agent | Model | Role |
|---|---|---|
| `swarm-manager` | opus | Orchestrates; dispatches testers + infra; verifies every claim against a real artifact; draft PRs only. |
| `dv-env-tester` | sonnet | Owns one DV env; runs it, cross-checks the golden model, proves it can FAIL (reverted mutation). |
| `infra-agent` | sonnet | formal / lp / waves / metrics / CI / Docker / Railway / Makefile; CI-vs-Makefile + tool-pin drift. |
| `dv-runner` | haiku | Mechanical: run the exact targets, report command/exit/PASS-FAIL/log. |

## Swarm B — random-regression loop (`docker/rr-swarm-task.md`)
| Agent | Model | Role |
|---|---|---|
| `rr-manager` | opus | Runs the loop: runner batches → triage clusters → one debugger per cluster → promote repros. |
| `rr-runner` | haiku | Mechanical: `rr-build` + a seeded `rr` batch; report run dir + counts. |
| `rr-triage` | sonnet | Read-only: cluster failures by signature, classify DUT/TB/harness/flaky. |
| `rr-debugger` | opus | Root-cause one cluster; fix TB/harness/model; DUT changes → OPEN_DECISIONS, not merged. |
| `rr-test-author` | sonnet | Promote repros into `dv/random/corpus.json`; grow stimulus; golden model is the contract. |

## Doctrine (all agents)
Verify every claim against a real artifact ("no artifact = not verified"); never
weaken a checker or fabricate output; keep `rtl/` assertion-free; **RTL/DUT
behaviour changes are the human's call** (write to `docs/OPEN_DECISIONS.md`, draft
PR, human merges); branches `swarm/<date>-<topic>`, never force-push, never push
to `main`.
