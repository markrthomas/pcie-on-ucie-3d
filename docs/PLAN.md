# PLAN — PCIe-on-UCIe-3D raw-mode adapter

**Repo:** `pcie-on-ucie-3d` (standalone git repo since 2026-10-17)
**Baseline:** **UCIe 3.0** (Aug 2025) **UCIe-3D** variant — vertical die stacking,
hybrid-bonding bump pitch, **no D2D adapter**, **raw mode** (the protocol fills
every flit byte; the link inserts no CRC/retry). PCIe side = **PCIe 6 256-byte
FLIT mode**. See [`ucie3d_notes.md`](ucie3d_notes.md).
**Audience:** the next engineer or AI agent. If a session ends mid-task, read this
file plus [`AGENT_HANDOFF.md`](AGENT_HANDOFF.md) and resume from the §11 backlog.

Structured on the sibling repo `~/proj/eth-dj-pcie-pipe7_1-bridge` (the
gold-standard five-env DV + infra template). Where a decision is still open it is
marked **[OPEN]** with a recommended default.

---

## 0. Reference designs in this workspace (read first)
| Sibling | What to borrow |
|---|---|
| **`eth-dj-pcie-pipe7_1-bridge`** | The structural template: 14-module datapath+control RTL, five DV envs (`dv/{iverilog,vlt,uvm,systemc,cocotb}`) sharing one golden model (`dv/common/scenarios.py`) + `crosscheck.py`, bind-based `dv/sva`, `formal/*.sby`, UPF in `lp/`, SQLite metrics dashboard, from-source toolchain Dockerfile + GHCR/`container:` CI, Railway batch, two `.claude/agents/` swarms. Clone the skeleton; rename eth/PIPE → PCIe/UCIe. |
| **`axi-on-ucie-to-mem`** | The original DV+infra template eth-dj itself was ported from. |
| **`~/proj/DV_STANDARDS.md`** | Mandatory Makefile targets, CI layout, coverage/formal standards, directory layout. |

Tool pins live in the `Dockerfile` (Verilator 5.050 / Yosys+slang / SBY / yices;
`cocotb==1.8.1`) — **no OSS CAD Suite**. CI builds that image and runs jobs inside it.

---

## 1. Scope & goals
### In scope
- Synthesizable RTL adapter: **PCIe 6 FLIT stream ⇄ UCIe-3D raw-mode bump bus**, both directions.
- CDC, width gearbox, flit framing/deframing, elastic buffering, opt-in credit flow control.
- UCIe **sideband** command/status for link bring-up, speed/width, and power (L0/L1/L2), via a small control FSM.
- Five independent testbenches (§5), coverage, SVA, formal, and an authored UPF power intent.
- A single-file UVM bundle for **EDA Playground** (`playground/`).
- Full infra: `make` targets, Python tooling, GTKWave per test, metrics dashboard,
  GitHub Actions CI, Railway, and two AI agent swarms (§10).

### Out of scope (first cut)
- Analog / hybrid-bond electricals, SerDes, UCIe link-training state machines beyond the
  sideband handshakes we model; full PCIe TL/DL/LTSSM. Both peers are **DV BFMs**, not RTL.
- ASIC synthesis / PnR sign-off. Verilator `--lint-only` + Yosys generic elaboration is the bar.

### Success criteria (definition of done)
1. `make regress` (lint + primary sim) green locally and in CI.
2. `make ci` green; line coverage ≥ 99% on the datapath + control.
3. All five DV envs build and pass their smoke; the three TB configs (§5) run.
4. SVA bound + passing in the Verilator-based flows; formal proves the flow-control safety properties.
5. UPF authored + documented; `make upf` runs it if a commercial PA simulator is on PATH, else notice + exit 0.
6. Dashboard renders; GTKWave per test; Railway job defined; single-file EDA Playground bundle builds.

---

## 2. Interfaces
Frozen in `rtl/pcie_ucie3d_pkg.sv`; keep this section in sync.

### 2.1 PCIe / FDI side (`pcie_*`, `pcie_clk`)
AXI4-Stream-like flit stream carrying PCIe 6 256-byte flits:
`pcie_tvalid/tready/tdata[PCIE_DATA_W]/tkeep/tlast/tuser` ingress + mirror `pcie_rx_*`
egress, plus a CSR port (`csr_valid/write/addr/wdata/rdata`, always-ready).
`PCIE_DATA_W` default **256b** [OPEN §2.3].

### 2.2 UCIe-3D physical side (`ucie_*`, `ucie_clk`)
Raw-mode parallel bump bus: `ucie_tx_data[UCIE_BUS_W]/tx_valid/tx_start_flit`,
mirror `ucie_rx_*`; `ucie_speed[2:0]` / `ucie_width[1:0]` / `ucie_powerdown[1:0]`;
`ucie_link_status` / `ucie_rx_active` / `ucie_rx_elec_idle`; and the 8-bit
**sideband** `ucie_sb_m2s` / `ucie_sb_s2m` (idle 8'h00) for bring-up / parameter
exchange / register access. `UCIE_DATA_W` default **64b/lane**, `UCIE_NLANES`
default **1** (x2/x4 a parameter bump; x8+ refused at elaboration, D1).

### 2.3 Parameters
`FLIT_BYTES=256` / `FLIT_HDR_B=2` / `FLIT_PAYLOAD_B=240`; `PCIE_DATA_W=256`,
`PCIE_KEEP_W`, `PCIE_USER_W=8`; `UCIE_DATA_W=64`, `UCIE_NLANES`, `UCIE_BUS_W`,
`FLIT_BEATS`; `SB_W=8`, `SB_ADDR_W=16`; the CSR map; `FIFO_DEPTH=32`; `FLOW_CTRL`,
`DP_RESET`; enums `ucie_speed_e` (baseline `SPEED_64`), `ucie_pwr_e`, `adapter_state_e`.

---

## 3. Microarchitecture
```
      PCIe 6 FLIT (pcie_clk)            adapter core                 UCIe-3D raw (ucie_clk)
  [ PCIe controller (BFM) ] --pcie_tx--> ingress -> tx_cdc -> tx_framer -> tx_egress --ucie_tx--> [ UCIe-3D
                                          (AXI4-S)  (async    (256B flit    (serialise             PHY (BFM),
                                           sink)    FIFO)      assembly)     raw beats)             raw mode) ]
  [ PCIe controller (BFM) ] <--pcie_rx-- egress <- rx_cdc <- rx_deframer <- rx_ingress <--ucie_rx--
                                control plane: ucie_sb_master + adapter_ctrl_fsm (bring-up, L1/L2,
                                speed/width, raw/credit) + adapter_rf (CSRs) [+ fc_ctl]
```
### Module inventory (target `rtl/`; built M1+)
`pcie_ucie3d_pkg`, `pcie_ucie3d_adapter` (top), `pcie_ingress`, `tx_cdc`
(`async_fifo`), `tx_framer`, `tx_egress`, `rx_ingress` (flit-lock on `start_flit`),
`rx_cdc`, `rx_deframer`, `pcie_egress`, `ucie_sb_master`, `adapter_ctrl_fsm`,
`adapter_rf`, optional `fc_ctl`. DV-only: a power sequencer + the two peer BFMs.

---

## 4. Directory layout
```
rtl/  dv/{iverilog,vlt,uvm,systemc,cocotb,common,sva,waves,random}  formal/  lp/
metrics/  playground/  docker/  .claude/agents/  .github/workflows/  docs/
Dockerfile  railway.toml  Makefile  README.md  ASSERTIONS.md  NOTES.md
```
The root `Makefile` `-include`s `../dv_env.mk` (pins `cocotb==1.8.1`).

---

## 5. The five verification environments + the three TB configs
| # | Env | Simulator | Purpose |
|---|---|---|---|
| 1 | `dv/iverilog/` | Icarus 12 | Fast directed golden tests; first bring-up. |
| 2 | `dv/vlt/` | Verilator C++ | Fast regression + the **coverage** vehicle (`coverage.info`, 99% floor). |
| 3 | `dv/uvm/` | Verilator + Accellera UVM | UVM env (Verilator ≥ 5.03x; uvm-core cloned at a pinned ref; keep `VERILATOR_ROOT` unset). |
| 4 | `dv/systemc/` | Verilator → SystemC | TL/system co-sim reference cross-check. |
| 5 | `dv/cocotb/` | cocotb + PyUVM | Constrained-random + **PyVSC functional coverage** (`fcov.json`). |

**Three TB configs** (user decision 2026-10-17):
- **C1 — PCIe on UCIe-3D only** (the primary harness, all 5 envs): one integrated
  adapter, UCIe-3D Tx looped to Rx (remote PHY modeled); runs the shared scenarios.
- **C2 — PCIe back-to-back**: two PCIe endpoints wired directly (no UCIe); the PCIe
  flit path in isolation (baseline).
- **C3 — UCIe-3D back-to-back**: two UCIe-3D PHYs cross-connected at the bump
  interface (eth-dj `tb_link` style); the raw-mode link in isolation (baseline).

**Cross-check contract:** all five envs run C1 on the shared scenario set
(`dv/common/scenarios.py`: single / corners / random / pm_cycle / speed_change) and
agree via `dv/common/crosscheck.py`. Schema: `{env, scenarios:{name:{frames,bytes,
flits,crc32,pmcnt,errors}}}`.

**EDA Playground bundle** (`playground/`): a generated single-file (RTL + UVM TB)
assembled by `playground/assemble.py` — net-new to this family of repos.

---

## 6. Coverage
Verilator `--coverage` → `coverage.info` (lcov) at repo root, CI artifact, floor
**≥ 99%** on datapath + control, enforced by `dv/common/covcheck.py` (M4 shared-scenario
run alone: 87.2%; M7 adds the directed `dv/vlt/cov_main.cpp` battery + the FLOW_CTRL
build, merged to **99.6%**; floor raised 80 → 99). PyVSC covergroups in `dv/cocotb/` →
`fcov.json`: flit sizes, tkeep-last, speed/width combos, L0/L1/L2 transitions,
sideband opcodes, back-to-back vs gapped, CDC near-full/near-empty. SVA `cover`s counted.

## 7. Assertions (SVA)
`dv/sva/` bind-based (RTL assertion-free), Verilator `--assert` only. First-cut set:
PCIe flit-stream legality; UCIe Tx legality (no Tx outside L0; `start_flit` framing);
CDC/FIFO safety (no overflow/underflow; occupancy ≤ depth); sideband request→ack
ordering; no two outstanding power requests. Track each in `ASSERTIONS.md`.

## 8. Root Makefile targets (mandatory)
`lint sim regress coverage formal ci <env> crosscheck config1|2|3 waves wave-<test>
upf upf-tb metrics dashboard stress clean` + `-fc` variants + `rr-*`. Several always
exit 0 (`formal`/`upf` when a tool is absent). Python is the glue (metrics, waves,
rr, playground assembler).

## 9. UPF power intent (authored, not run)
`lp/`: `PD_AON` always-on (control FSM + sideband master + glue — must survive L1/L2
to sequence recovery); `PD_DP` switchable (the whole datapath). `adapter_rf` in
`PD_AON` so config survives a low-power episode. OSS simulators do not model UPF;
`make upf` runs on a commercial PA simulator if present, else notice + exit 0. OSS
checks: `make upf-tb` (PMU sequencing) and `make pd-emu` (= `lp/cocotb` `pd` + `pd-ret`:
corruption/isolation/retention emulation). Documented in `docs/power_intent.md`.

## 10. Infra: dashboard, CI, Railway, agent swarms
- **Metrics**: append-only SQLite (`schema.sql` → `metrics.db`), `collect.py` reads
  real artifacts, `dashboard.py` → `dashboard.html`; every value carries a `kind`
  (`measured`/`estimated`/`not_attributable`) — never fabricate a measured number.
- **CI** (`.github/workflows/ci.yml`): `build-image` (content-hashed GHCR tag) then
  per-env jobs inside that image via `container:` (Verilator only ever in a
  container) + a bare-runner `crosscheck`. `swarm.yml` is `workflow_dispatch`-only.
- **Railway** (`railway.toml`): DOCKERFILE builder, `restartPolicyType=NEVER`, weekly
  cron; batch job; results via `docker/publish_metrics.sh` → branch `metrics-data`,
  back with `make railway-import`. See `docs/railway.md`.
- **Two swarms** (`.claude/agents/`): A = end-to-end re-verification
  (`swarm-manager` + per-env `dv-env-tester` + `infra-agent` + `dv-runner`);
  B = random regression (`rr-manager` + `rr-runner`/`rr-triage`/`rr-debugger`/
  `rr-test-author`). Draft PRs only; RTL changes → `OPEN_DECISIONS.md`, human merges.

---

## 11. Phased plan & backlog (agent-resumable)
### M0 — Scaffold ✅ done 2026-10-17
- [x] Standalone repo skeleton: root `Makefile` (§8), five `dv/` envs each with a
  Makefile + `smoke`, `dv/common` golden model + mirrors + `crosscheck.py`,
  placeholders for `sva/waves/random/formal/lp/metrics/playground`, CI/Docker/Railway,
  both swarms, docs, `.gitignore`/`.dockerignore`. Tool pins via `../dv_env.mk`.
- [x] `rtl/pcie_ucie3d_pkg.sv` (§2.3 params + enums, UCIe 3.0 / 64 GT/s baseline).
- [x] `rtl/pcie_ucie3d_adapter.sv` top **stub** (ports + reset-value drives;
  x8 refused at elaboration); five env smokes check the reset/defaults contract.
  **Gate: `make regress` (lint + Icarus smoke) — GREEN.**
### M1 — Tx datapath ✅ done 2026-10-18
- [x] `async_fifo` (tx_cdc) + `tx_framer` (256B raw-mode flit assembly) + `tx_egress`
  (serialise UCIE_BUS_W beats). Top wires the Tx path; no control plane yet, so
  `tx_en=1` and the ingress is open when the CDC FIFO is not full (M3 adds gating).
- [x] Peer BFMs `dv/common/pcie_mac_model.sv` (AXI4-S source) + `ucie_phy_model.sv`
  (UCIe Tx sink + raw-mode flit monitor/checker) + `pcie_pat.svh`.
- [x] `dv/iverilog/tb_tx.sv`: 115 frames (directed corners + random, back-to-back then
  gapped) reassembled byte-exact, flit count = Σ ceil(len/240) = 512.
  **Gate: `make sim` (smoke + tx) — GREEN.**
### M2 — Rx datapath + C1 loopback scoreboard ✅ done 2026-10-18
- [x] `rx_ingress` (flit-lock on `ucie_rx_start_flit`, overflow/lock-error counters,
  FLOW_CTRL seq/credit view) + `rx_deframer` (unpack payload into PCIe beats, D9 frame
  abort on gap/sof/bad-header) + `async_fifo` (rx_cdc) + `pcie_egress` (FWFT AXI-S
  master). Top wires the Rx path on `ucie_clk`→`pcie_clk`; DV-visible error counters
  (`rx_dropped_flits`/`lock_errors`/`bad_flits`/`aborted_frames`) are observation
  points until M3's register file reads them.
- [x] `dv/common/pcie_sink_model.sv` (AXI4-S slave sink + tkeep/abort checker, throttle).
- [x] `dv/iverilog/tb_loop.sv`: C1 loopback (UCIe Tx wired back to Rx of the same DUT);
  115 frames (directed corners + random, back-to-back then gapped w/ 90% sink throttle)
  returned byte-exact; flit count = 512; all Rx error counters 0.
  **Gate: `make regress` (smoke + tx + loop) — GREEN.**
### M3 — Control plane ✅ done 2026-10-18
- [x] `adapter_rf` (CSR read/write: CTRL/SPEEDCFG/STATUS/ERR/RXCNT0/RXCNT1/PMCNT,
  with the Rx error counters wired to RXCNT0/1 and a saturating op counter in PMCNT),
  `adapter_ctrl_fsm` (bring-up SBINIT→MBINIT→PARAM, L0/L1/L2 with L2↔L0 via L1,
  speed/width changes, drain-before-change, SB_TIMEOUT recovery), `ucie_sb_master`
  (4-byte committed sideband write + ack), `tx_ingress_gate` (close ingress at a frame
  boundary on drain). Control plane + CSRs run on `ucie_clk` (D7 updated). Datapath-local
  reset (D18, default on) holds the datapath in reset while in L1/L2.
- [x] DV `dv/common/ucie_sb_model.sv` (remote-die control BFM: link bring-up handshake,
  sideband write ack, link_status op pulse, Tx-legality checker).
- [x] `tb_smoke` extended to the link-up contract (ingress closed until L0, then open;
  PMCNT=2, one preset write). `tb_pm` (power/speed/width/preset changes + cancelled
  request + L0s + status timeout under live loopback traffic; PMCNT=17, 6 preset writes).
  `tb_rxovf` (no-backpressure drop/abort + recovery, D9). Five env smokes on the M3 gated
  contract. **Gate: `make regress` (smoke + tx + loop + pm + rxovf) — GREEN.**
- [x] Raw-mode credit flow control (`fc_ctl`, FLOW_CTRL/D16) landed in M4.
### M4 — All 5 envs on the shared scenarios + C2/C3 tops + fc_ctl + Playground ✅ done 2026-10-18
- [x] Shared-scenario runner in every env, each writing the `results.json` schema and
  self-crosschecking, then `crosscheck.py --require iverilog,vlt,uvm,systemc,cocotb`:
  `dv/iverilog/tb_scen.sv`, `dv/vlt` + `dv/systemc` on the shared C++ harness
  `dv/common/cpp/adapter_bfm.h` (POD-struct loopback + remote-die model + sequencer),
  `dv/cocotb/test_scen.py` (Python BFMs), `dv/uvm` full env (`adapter_uvm_pkg.sv`:
  sequence/driver/monitor/scoreboard + `ucie_phy_driver` remote die + `csr_agent`).
  All five agree with `dv/common/scenarios.py` **byte-exact** (identical crc32 per
  scenario). Golden `speed_change` pmcnt reconciled to the real control plane (D22:
  preset re-sent on every speed change -> 2 linkup + 4 = 6).
- [x] C2/C3 directed tops: `dv/iverilog/tb_pcie_b2b.sv` (PCIe FLIT layer / BFM baseline,
  60 frames endpoint-to-endpoint) and `dv/iverilog/tb_ucie_b2b.sv` (two adapters joined
  at the bump interface, 40 frames each way across the raw-mode link byte-exact).
- [x] `fc_ctl.sv` (D16) wired between the Rx FIFO-free/deframe accounting and the Tx flit
  launch; under `-DFLOW_CTRL_OVERRIDE` data flits are credit-gated and credit-only flits
  carry the advertised limit (vlt FC run: 209 credit-only flits, byte-exact, crosscheck OK).
- [x] EDA Playground bundle: `playground/assemble.py` inlines the full RTL + the shared
  pattern/scenario includes + the UVM TB into `playground/pcie_ucie3d_playground.sv`
  (smoke_test / scen_test).
- [x] Coverage floor enforced: `dv/common/covcheck.py` over `coverage.info`; the
  scenario run plus the M7 directed coverage battery (`dv/vlt/cov_main.cpp`) and the
  FLOW_CTRL build reach **99.6%** line coverage (floor 99%).
  **Gate: `make ci` (regress + coverage + formal + crosscheck) — GREEN.**
### M5 — bind-based SVA + SymbiYosys formal + `ASSERTIONS.md` ✅ done 2026-10-19
- [x] `dv/sva/adapter_sva.sv` (bound into `pcie_ucie3d_adapter`) + `dv/sva/async_fifo_sva.sv`
  (bound into every `async_fifo`): PCIe stream legality, UCIe Tx L0/framing, sideband
  ordering + m2s framing, CDC FIFO push/pop + occupancy/Gray-code safety, plus covers.
  Bound with `--assert` into the vlt / systemc / uvm runs (`SVA=1` default; coverage
  build omits it — a Verilator 5.0xx `--assert`+`--coverage` internal error).
- [x] `formal/*.sby` (prove + cover) proven green: `async_fifo` (CDC safety, multiclock),
  `ingress_gate` (drain gate), `ctrl` (`adapter_ctrl_fsm`+`ucie_sb_master`+`tx_egress`,
  default **and** `-DFLOW_CTRL_OVERRIDE`), `fc` (`fc_ctl` credit scheme). `formal/Makefile`
  auto-adapts the slang frontend (plugin vs built-in) and the smtbmc solver (yices→z3).
- [x] `ASSERTIONS.md` is the single property inventory (sim + formal) with results.
- [x] **Finding D25:** the new A3 / F-PP1 caught a missing `tx_idle` guard (`&& !tx_cr_req`)
  vs. the reference; a credit-only flit could leak into a post-drain state under FLOW_CTRL.
  Fixed in RTL (default builds byte-identical). See `docs/OPEN_DECISIONS.md` D25.
  **Gate: `make formal` green; SVA bound into the vlt/systemc/uvm runs; `make ci` GREEN.**
### M6 — `lp/` UPF (authored) + power sequencer + power-aware TB + power-state emulation ✅ done 2026-10-19
- [x] `lp/adapter.upf` (IEEE 1801 / UPF 2.1, authored-not-run): PD_AON (control
  plane + CSRs + flow-control accounting + glue) / PD_DP (switchable datapath, both
  clock domains), SW_DP header, ISO clamp-0/clamp-1 sets, RET_DP (for
  `-DDP_RESET_DISABLE`), power states (L0→DP_ON only; L1/L2→ON or OFF).
- [x] `lp/adapter_pmu.sv` — DV-only power sequencer on ucie_clk (iso→save→off;
  on→restore→de-iso); `lp/tb_adapter_upf_power.sv` — power-aware TB on the C1
  loopback harness. `make upf-tb` green: **UPF-TB PASS** (36 frames, 2 power-down/up
  cycles); `make upf` prints the authored-not-run notice and exits 0.
- [x] `docs/power_intent.md` (architecture, PMU sequence, what's checked vs not
  verified) + `lp/README.md`.
- [x] **OSS power-state emulation** `lp/cocotb/` (cocotb on Icarus): `pd_top.sv`
  (adapter + UCIe loopback + SV remote-die model + PMU), `pd_emu.py` (PD_DP corruption /
  isolation clamps / retention save+restore), `test_pd.py` retention matrix,
  `check_pd.py`. `make pd-emu` green: default build (D18 reset ON) survives a PD_DP
  power cycle retaining **nothing** (0/31754 bits); `-DDP_RESET_DISABLE` needs only the
  control registers (362 bits, 1.1 %, `lp/cocotb/retention_min.txt`); retain-nothing
  there is the negative control and fails. Quantifies D18.
  **Gate: `make upf` (notice, exit 0) + `make upf-tb` (PASS) + `make pd-emu` (PD PASS) — met.**
### M7 — GTKWave sessions + `wave_check.py`; metrics collectors + dashboard from real
runs; Railway job; swarms finalized.
- [x] **`dv/waves/`** — per-test GTKWave sessions (`smoke tx loop pm rxovf scen upf`)
  generated by `wave_check.py gen`; `wave_dump.sv` (second top, `WAVES=1`, scopes
  `<tb>`/`.dut`/`.dut.u_ctrl`); `wave_check.py check` verifies every session signal is
  in a fresh VCD and the clocks/reset/FSM toggle, with an optional headless-GTKWave
  trace-resolve (`gtkw_count.tcl`, skipped if gtkwave/xvfb absent). `make wave-<test>` /
  `make waves` / `make wave-check-all` (the last wired into CI's regress job). All 7
  sessions green (48 DUT signals; 53 for upf incl. the PMU).
- [x] **`metrics/`** — `collect.py` runs + times `METRICS_FLOWS`
  (`regress,crosscheck,coverage,formal,upf-tb`) and parses the real artifacts into
  `metrics.db` (every row tagged measured / estimated / not_attributable — never a
  guessed number); `dashboard.py` renders `dashboard.html` (latest run + history).
  Measured: flow wall-clock, directed-test frames/flits, each env's scenario agreement
  vs the golden model, `coverage.info` line %, SymbiYosys prove/cover status; estimated:
  raw-BW bound, flit efficiency, Yosys(+slang) flop/memory/cell bits. Honest
  not_attributable: delivered throughput / latency (no sim-time monitor), Fmax / area /
  power (no gate-level flow — `docs/power_intent.md`), swarm (not run).
- [x] Railway batch job **authored** (`railway.toml` DOCKERFILE builder,
  `restartPolicyType=NEVER`, weekly cron; `docker/{entrypoint,publish_metrics}.sh` +
  `docs/railway.md`). The actual **deploy is held for explicit user go-ahead** — nothing
  deployed to Railway.
- [x] Swarms finalized: both `.claude/agents/` sets retargeted to this design's five
  envs (no stale eth-dj/pipe7 refs), `swarm.yml` `workflow_dispatch`-only, draft-only
  doctrine preserved (human merges any RTL/DUT behaviour change).
### M8 — Close-out self-review. **[x]** All gates green (`make lint/sim/regress/coverage/
formal/ci/clean` [OK]; GitHub Actions all 8 jobs green on `main`; `dv_audit.sh` clean for
this repo). Waves (#1), metrics (#2) and the UCIe width-label fix (#3) merged to `main`.
Docs synced. Open items: the Railway deploy (held for go-ahead).

## 12. Open decisions
See [`OPEN_DECISIONS.md`](OPEN_DECISIONS.md). Headlines: `PCIE_DATA_W` / `UCIE_*`
widths [OPEN]; PCIe side as AXI4-S flit stream (recommended) vs raw; **RESOLVED**:
UCIe-3D **raw mode, no D2D adapter**, 64 GT/s baseline; 3 TB configs = integrated +
two layer baselines.

## 13. Conventions
Match workspace style; keep `rtl/` assertion-free (SVA via bind); never fabricate a
measured metric (use `kind`); PRs ready-for-review and finish-what-you-open per
`~/proj/CLAUDE.md`, **except** the swarms (draft-only, human merges RTL changes);
commit attribution per the session's active rule.
