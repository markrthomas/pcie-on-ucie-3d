# CLAUDE.md — working conventions for this repo

Guidance auto-loaded into every Claude session (including each headless **swarm**
run) that works in this repo. It captures the **non-obvious** conventions and
hard-won gotchas so a run doesn't re-derive or re-trip them. It is not a spec —
`README.md` and `docs/PLAN.md` are; this is the "how we work here" layer.

**This repo:** a digital-only, open-source DV suite for a synthesizable **PCIe ⇄
UCIe-3D raw-mode adapter** that tunnels PCIe 6 256-byte FLITs over a UCIe-3D
vertical die-to-die bump interface (UCIe 3.0, raw mode — the protocol owns
CRC/retry; 64 GT/s baseline, datapath speed-parametric). No commercial simulator
on the host; every license-gated flow degrades gracefully (prints a skip, exits
0). Resuming? Read `docs/AGENT_HANDOFF.md` (the live work queue + handoff) and
`docs/OPEN_DECISIONS.md`, then `docs/PLAN.md`. Structure and conventions follow
`~/proj/eth-dj-pcie-pipe7_1-bridge`.

GitHub origin: `markrthomas/pcie-on-ucie-3d`. Work lands via **ready-for-review**
PRs, merged on green CI (8 jobs: build-image, regress, coverage, systemc, uvm,
cocotb, formal, crosscheck).

---

## Golden rules (do not violate)

1. **Additive DV — never change RTL behaviour to force a test green.** If a
   property exposes a real RTL bug, or an invariant genuinely can't be met, STOP
   and report it in the PR (mark it "PARTIAL — design blocker"). Never weaken an
   SVA, delete a coverage bin, or hack the RTL/golden model to get a green. A
   faithful partial beats a fake pass.
2. **RTL/DUT behaviour changes are the human's call.** Write them up in
   `docs/OPEN_DECISIONS.md` on a branch and open a PR; a human merges. TB,
   harness, golden-model and infra fixes you may apply.
3. **Never commit on `main`.** Branch (`swarm/<date>-<topic>` for swarm work),
   push incrementally, open a PR. Never force-push.
4. **Report results faithfully.** Quote the real banner/log line and its path.
   Never claim green without the actual run. A skip (tool absent, exit 0) is not
   a pass. **Mutation-test** any new DV env so the test has teeth.
5. **Update docs in the same PR as the code** — `README.md`, `docs/PLAN.md` (mark
   the item done + what shipped), `docs/AGENT_HANDOFF.md`, `docs/OPEN_DECISIONS.md`,
   and the root `Makefile` `help:` lines for any new target/knob. Skip a file only
   with a one-line reason it doesn't apply.

---

## Build & gate essentials

- **Pinned tools, all from the `Dockerfile`; the OSS CAD Suite is NOT used.**
  `docs/TOOLCHAIN.md` is the hand-build recipe mirroring it. CI builds the image
  and runs the jobs inside it — the CI image is the canonical environment, and
  local dev may have newer cocotb/pyuvm than the pins (see `AGENT_HANDOFF.md`).
  Python DV pins track `~/proj/dv_env.mk`.
- **Don't set `VERILATOR_ROOT`** — it breaks the UVM-on-Verilator flow.
- **UVM needs a from-source Verilator ≥ 5.03x** (apt Verilator 5.020 can't
  compile uvm-core). The UVM env clones Accellera `uvm-core` at a pinned ref into
  `dv/uvm/uvm-core/` (git-ignored). The `uvm` env runs in CI / the container
  image — before claiming the UVM tier passes, say *where* it ran.
- **Icarus must be ≥ 12** (CI 12.0); Ubuntu 24.04 apt is 12, 22.04 apt is 11 (too
  old for SV package syntax).
- **Formal `cover` prefers yices over z3** (z3 can OOM on deep covers). `make
  formal` uses a slang-capable Yosys + SymbiYosys. When a new RTL module is
  instantiated, add it to the relevant `formal/*.sby` source list.
- **Coverage floor is 99%** (line coverage was 99.6% at close-out) — much tighter
  than the workspace 80% default. A coverage regression fails the gate.

### The gate (run `make help` for the authoritative list)
- `make regress` = `lint` + `sim` — the fast CI gate. `lint` runs default +
  `FLOW_CTRL` + `DP_RESET_DISABLE` variants (x8 lane config is refused by design).
- `make coverage` — Verilator C++ `--coverage` → `coverage.info`, **floor 99%**.
- `make formal` — SymbiYosys prove + cover on `formal/*.sby`.
- `make crosscheck` — all five envs agree with `dv/common/scenarios.py`.
- `make ci` — `regress coverage formal envs crosscheck …` (the full local run).

## DV env map + TB configs

Five independent environments cross-check against one Python golden model
(`dv/common/scenarios.py`), byte-exact (identical crc32 per scenario):

| env | target | engine |
|-----|--------|--------|
| iverilog | `make iverilog` (+ directed `make sim`) | Icarus 12 |
| vlt | `make vlt` | Verilator C++ |
| systemc | `make systemc` | SystemC (apt) |
| cocotb | `make cocotb` | cocotb + PyUVM |
| uvm | `make uvm` | UVM-on-Verilator (from-source Verilator; **CI/container**) |

Three TB configs: **C1** integrated loopback (all 5 envs), **C2** `tb_pcie_b2b`,
**C3** `tb_ucie_b2b` (two adapters across the raw-mode link, byte-exact both
ways). `make config1|config2|config3`. Flow control runs under
`-DFLOW_CTRL_OVERRIDE`. A single-file EDA Playground bundle regenerates from the
real sources.

## Adding a new DV env / module (checklist)
1. `dv/<env>/` with its Makefile; add an `<env>:` target to the root `Makefile`
   and fold it into the gate as appropriate.
2. Bump the env-list / "five environments" text wherever it is enumerated
   (`docker/`, `.claude/agents/*.md`, `Dockerfile`, `railway.toml`, README).
3. If the RTL grew a module, add it to the `formal/*.sby` source list.
4. Mutation-test it. Update docs (rule 5).

## Power / UPF
`make upf` runs the UPF TB only on a commercial power-aware simulator if one is on
`PATH`, else a notice + exit 0 (UPF **authored, not run**). `make upf-tb` is the
functional Icarus power-aware TB (PMU sequencing). `make pd-emu` / `pd-emu-ret`
are the OSS PD_DP power-state emulation (`-ret` exercises the retention matrix +
negative control).

## Metrics are NOT on the gate
`metrics/` (`make metrics`, `make dashboard`, `make railway-import`) is opt-in and
runs *after* a completed gate — never fold it into `regress`/`ci`, and never make
a DV env do extra work to produce a number.

## Agent swarms (repo notes)
The swarm itself is the shared kit described in the block below; this repo's profile is `.claude/swarm.env`
(5 envs, `crosscheck`, metrics on, random regression present). Repo-specific doctrine: SVA lives in `dv/sva/`, bound
in; DUT behaviour changes go to `docs/OPEN_DECISIONS.md` ("Behaviour to review").

<!-- swarm-kit:begin (managed by markrthomas/dv-swarm-kit sync.sh — edit the kit, not this block) -->
## Agent swarms, run targets and tokens (swarm-kit)

This repo carries the shared **DV swarm kit** (`markrthomas/dv-swarm-kit`, version in `.claude/swarm-kit.version`).
Its repo-specific settings are **`.claude/swarm.env`** (`make swarm-profile` prints them); everything else in the
kit is identical across repos — change it in the kit and re-sync, never fork it here.

- **Swarm A** — end-to-end re-verification: `make swarm` (`docker/swarm-task.md`; swarm-manager + one
  dv-env-tester per `DV_ENVS` entry + infra-agent + dv-runner).
- **Swarm B** — random regression: `make swarm-rr` (`docker/rr-swarm-task.md`; rr-manager + rr-runner / rr-triage /
  rr-debugger / rr-test-author). With `RR_STATUS=bootstrap` it first builds `make rr-build/rr/rr-triage/rr-replay`
  (the `rr-bootstrap` skill), then flips the flag to `present`.
- **Plan-driven swarm** — write `docs/SWARM_PLAN.md` with front-matter `status: ready` and push it to `main`
  (`.github/workflows/plan-swarm.yml` runs `docker/plan-swarm-task.md`; reset to `status: draft` after it lands).
- Model provider: `SWARM_MODEL_PROVIDER=anthropic` (default) or `kimi` (`docker/provider-env.sh`; kimi sends repo
  contents to Moonshot - never for proprietary IP). One-off headless task: `docker/entrypoint.sh agent "<task>"`.
- Status board: `make board`; workers report via `python3 tools/swarm/board.py` (the `board-report` skill).
- Heavy targets (`HEAVY_TARGETS`) run one at a time: `make heavy T=<target>`. Headless Bash is limited to
  `.claude/settings.json`. `make swarm-dry` shows what a swarm run would execute; `make swarm-kit-check` checks drift.

Doctrine (all agents): verify every claim against a real artifact ("no artifact = not verified"); never weaken or skip
a checker to get green; a skip is "not run", not a pass; keep the RTL assertion-free; DUT behaviour changes are the
owner's call (write them up, don't merge them); branches `swarm/<date>-<topic>`; never push to `main`, never force-push.
Return findings as verdict + evidence (file:line / command + 3-10 line excerpt) + next step — no log dumps.

**Where it runs** (same image everywhere: the Dockerfile `tools` stage, plus the repo for `full`):
| where | how | credentials |
|---|---|---|
| GitHub Actions | Actions → **swarm** → Run workflow (task: Swarm A or B) | repo secret `CLAUDE_CODE_OAUTH_TOKEN` |
| Codespaces | open a Codespace (`.devcontainer/`), then `make swarm`, `make swarm-rr` or `make batch` | Codespaces secret `CLAUDE_CODE_OAUTH_TOKEN`; `GITHUB_TOKEN` is injected |
| Railway | batch service built from `railway.toml` (weekly cron); swarm service: start command `docker/entrypoint.sh swarm [--task docker/rr-swarm-task.md]` | service variables `CLAUDE_CODE_OAUTH_TOKEN` (swarm only) and `GITHUB_TOKEN` (fine-grained PAT: this repo, Contents read+write) |

Batch results go to the `metrics-data` branch (`runs/<UTC>-<sha>/`), never to `main`: automatically on Railway
(when `GITHUB_TOKEN` is set), elsewhere only with `PUBLISH_METRICS=1`. Tokens live only in
GitHub/Codespaces/Railway secret stores — never in the repo, the image, a log or a chat.
<!-- swarm-kit:end -->
