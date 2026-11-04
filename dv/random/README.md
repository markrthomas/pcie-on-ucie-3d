# dv/random — random regression, triage, replay corpus, swarm board

Engine: Verilator (`dv/vlt/sim_main.cpp` + the shared BFM `dv/common/cpp/adapter_bfm.h`),
Config-1 loopback.  The checker is the existing one: the BFM scoreboard (payload, length,
tkeep/tuser, flit format, padding, FC seq, remote-die legality, the bound SVA via `--assert`)
plus the golden model `dv/common/scenarios.py:expected_rand()` (frames/bytes/flits/crc32/pmcnt).

## Contract
- `make rr-build` — builds `dv/random/build/{vlt,vlt-fc}/vlt_rand` (default and FLOW_CTRL).
- `make rr N=30 JOBS=4 [SEED=base]` — job i uses seed `SEED+i`; writes
  `dv/random/runs/<UTC>/results.jsonl` (`job, seed, config, status, signature, log, repro`) and one
  `jobNNNN/run.log` per job; prints `rr run: <dir> seed_base=<s> jobs=<N> fail=<F>`; exit 1 iff F>0.
- `make rr-triage RUN=<dir>` — clusters FAILs by signature (count + repro per cluster).
- `make rr-replay` — reruns `corpus.json`; entries with `"fixed": true` must PASS (gate; in `make ci`, ~1 s + build).
- `python3 dv/random/rr.py one --seed S [--config --frames --maxlen --gap --ready]` — single repro.
- `python3 dv/random/rr.py promote --seed S [knobs] [--fixed] --note ..` — add a corpus entry.
- `runs/` and `build/` are git-ignored; `corpus.json` is committed.

## Knobs (all drawn from the seed, deterministically)
`config` vlt | vlt-fc; `frames` 1..64; `maxlen` 40..4096 (frame lengths = LCG(seed) % maxlen + 1);
`gap` MAC idle % per beat; `ready` sink tready %.  Plusargs on `vlt_rand`:
`+rand +seed= +frames= +maxlen= +gap= +ready=`.  Without `+rand` the env runs the five fixed
scenarios exactly as before (`make -C dv/vlt scen` + crosscheck unchanged).

### B1 / B2 knobs (added 2026-11-04; drawn after the five above, absent in an old corpus entry = 0)
Plusargs `+ctl= +nctl= +mid= +csr= +ncfg= +nrx=` (`rr.py one --ctl .. --nctl .. --mid .. --csr .. --ncfg .. --nrx ..`).
- `ctl` 0 none | 1 pm_cycle | 2 speed_change | 3 mix (per seed bit, `scenarios.rand_ops`); `nctl` 1..3 ops at frame
  boundaries `b_i = frames*(i+1)/(nctl+1)`.  `mid=0`: segment sent, drained, op, next segment.  `mid=1`: every frame is
  queued up front and the op fires when `b_i` frames were received, i.e. with later frames in flight (the ingress gate
  must hold them; payload/length/crc32 are still checked end to end).  Golden: pmcnt += 2 (pm_cycle) / 4 (speed_change).
- `csr` % per cycle of random CSR traffic while frames/ops are in progress: reads of all 7 registers, unaligned and
  unmapped addresses (must read 0), W1C writes to ERR, reserved-width CTRL writes (whole write ignored, ERR[3]), writes
  to RO/unmapped addresses (no effect), plus exactly `ncfg` SPEEDCFG writes (golden pmcnt += 1 each; checked against a
  register model: CTRL/SPEEDCFG/ERR/RXCNT/PMCNT/STATUS, and the sideband write is checked for address+data+count).
  STATUS may legally read ST_DRAIN (busy) right after an op while the datapath is not idle; everything else is fixed.
- `nrx` Rx-side injections at the quiescent end of the run (type `(seed+7k)%5`): 0 stray data beat (lock+1), 1 start_flit
  mid-flit (lock+2), 2 valid dropped mid-flit (lock+1), 3 orphan flit w/o sof (bad+1), 4 sof mid-frame (aborted+1; the
  sink must see exactly one tuser abort frame and then the 240 B good frame, compared byte for byte).  Deltas were
  measured on the RTL (cf. `cov_main.cpp`) and live in `adapter_bfm.h:inj_delta_` AND `scenarios.RX_INJ_DELTA`.
  RXCNT0/1 are read back and compared after every injection and at the end (`rxcnt0/rxcnt1` also in results.json, compared
  with `expected_rand`; a clean run must read all-zero Rx counters).  The loopback is cut while an injection (and any
  Tx flit that started meanwhile, e.g. FC credit-only) runs.  Overflow (dropped_flits) is not injected: its count is
  not exactly predictable.
Limits: injections are not mid-traffic (they would corrupt in-flight real flits); no ERR[0..2] stimulus (timeouts and
L0s need muted remote die / L0s requests, cf. `cov_main.cpp`).

Determinism: same seed + knobs gives an identical `results.json` and cycle count regardless of JOBS.

## Teeth (mutation check, 2026-11-03)
Flipping tdata bit 0 on the `tlast` beat of `rtl/pcie_egress.sv` -> `make rr N=20 SEED=100`:
`fail=20`, one cluster `frame payload`; restored -> `fail=0`.  corpus entry 0 (seed 100) is this canary
(`fixed: true`, not a real RTL bug).

## Teeth for B1/B2 (mutation check, 2026-11-04; each reverted, tree clean afterwards)
`make rr N=60 JOBS=8 SEED=100`, baseline `fail=0` on the unmutated RTL (and 1500+600+200 more seeds clean):
- TB: `inj_delta_` type 4 aborted 1->2: `fail=20` (`CSR read 0x14 = 0x10000, model 0x20000`).
- TB: pm_cycle model +3 instead of +2: `fail=21` (PMCNT mismatch / golden pmcnt).
- RTL `adapter_rf.sv` RXCNT1 halves swapped: `fail=28`.
- RTL `adapter_rf.sv` ERR[3] (reserved-width CTRL write) never set: `fail=34`.
- RTL `adapter_ctrl_fsm.sv` PWR_CHG op not counted (`ev_op_done`): `fail=60`.
Corpus entries 1 and 2 (`fixed: true`) pin a mid-traffic + CSR + injection mix on vlt-fc and vlt.

## Backlog (stimulus)
- B1 DONE 2026-11-04 randomize pm_cycle / speed_change control ops mid-traffic (`ctl/nctl/mid`, see above).
- B2 DONE 2026-11-04 randomize CSR traffic and Rx-side error injection (`csr/ncfg/nrx`, see above).
  Follow-ups: ERR[0..2] stimulus (muted remote die), dropped_flits overflow injection, true mid-traffic injection.
- B3 port `+rand` to systemc/iverilog/cocotb/uvm envs once stable; add cross-env rand crosscheck.
- B4 randomize reset timing and remote-die latencies (LAT/SB_LAT/MB_LAT).
- `board.py` + `board/*.json` — status board for Swarm B (`tools/swarm/board.py`).
