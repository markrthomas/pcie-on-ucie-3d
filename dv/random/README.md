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

Determinism: same seed + knobs gives an identical `results.json` and cycle count regardless of JOBS.

## Teeth (mutation check, 2026-11-03)
Flipping tdata bit 0 on the `tlast` beat of `rtl/pcie_egress.sv` -> `make rr N=20 SEED=100`:
`fail=20`, one cluster `frame payload`; restored -> `fail=0`.  corpus entry 0 (seed 100) is this canary
(`fixed: true`, not a real RTL bug).

## Backlog (stimulus)
- B1 randomize pm_cycle / speed_change control ops mid-traffic (`expected_rand` has `ctl`, plan pending).
- B2 randomize CSR traffic and Rx-side error injection (needs scoreboard extension, cf. `cov_main.cpp`).
- B3 port `+rand` to systemc/iverilog/cocotb/uvm envs once stable; add cross-env rand crosscheck.
- B4 randomize reset timing and remote-die latencies (LAT/SB_LAT/MB_LAT).
- `board.py` + `board/*.json` — status board for Swarm B (`tools/swarm/board.py`).
