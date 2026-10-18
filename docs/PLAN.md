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
2. `make ci` green; line coverage ≥ 80% on the datapath + control.
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
| 2 | `dv/vlt/` | Verilator C++ | Fast regression + the **coverage** vehicle (`coverage.info`, 80% floor). |
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
**≥ 80%** on datapath + control (from M4). PyVSC covergroups in `dv/cocotb/` →
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
checks: `make upf-tb` (PMU sequencing) and `make pd-emu` / `pd-emu-ret`
(corruption/isolation/retention emulation). Document in `docs/power_intent.md`.

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
### M2 — Rx datapath + C1 loopback scoreboard (`tb_loop`). Gate: `make regress`.
### M3 — Control plane: `ucie_sb_master` + `adapter_ctrl_fsm` + `adapter_rf`
(bring-up, L1/L2, speed/width, raw↔credit); `tb_pm`, `tb_rxovf`; extend `tb_smoke`
to the link-up contract.
### M4 — All 5 envs on the shared scenarios + C2/C3 back-to-back tops + the EDA
Playground bundle; crosscheck agreement. Gate: `make ci`, coverage ≥ 80%.
### M5 — `dv/sva/` + `formal/*.sby` + `ASSERTIONS.md`.
### M6 — `lp/` UPF (authored) + power sequencer + `pd-emu`.
### M7 — GTKWave sessions + `wave_check.py`; metrics collectors + dashboard from real
runs; Railway job; swarms finalized.
### M8 — Close-out self-review.

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
