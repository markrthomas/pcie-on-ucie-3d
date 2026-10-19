# metrics — DV metrics database + dashboard

- `schema.sql` — append-only SQLite schema (`runs`, `metrics`). Every metric row has
  a `kind`: **measured** (read from an artifact of that run), **estimated**
  (computed from design parameters or a pre-synthesis elaboration) or
  **not_attributable** (no data source: value NULL, `detail` says why). Never store a
  guessed number as measured.
- `collect.py` — `make metrics` runs and wall-clock-times `METRICS_FLOWS`
  (default `regress,crosscheck,coverage,formal,upf-tb`), then parses the real
  artifacts: directed-test logs (frames/flits), each env's `results.json` vs the
  golden model, `coverage.info` (lcov line coverage over `rtl/`), `dv/cocotb/fcov.json`,
  the SymbiYosys `*_prove/_cover/status` files, and a Yosys(+slang) coarse elaboration
  for flop/memory bits. A missing artifact is stored as `NOT_RUN`, never filled in.
  Exit 1 if any row is FAIL.
- `dashboard.py` — `make dashboard` renders `metrics.db` → `dashboard.html`
  (static, no external assets; latest run in full + run history).
- `metrics.db` and `dashboard.html` are committed; `_capture/` is scratch
  (see `.gitignore`).

Known gaps (recorded as `not_attributable`, never guessed): delivered throughput
and PCIe→PCIe latency (no simulated-time / latency monitor in any env yet), Fmax /
area / power (no gate-level synthesis, liberty or STA flow in this repo — see
`docs/power_intent.md`), and agent-swarm token/run data (no swarm run recorded).
PD_DP retention is characterised functionally in `lp/cocotb` (`make pd-emu`), not as
register bits here.

Collecting without `--run` reads whatever artifacts are on disk, which may be from an
older build; `make metrics` always reruns the flows first. Random-regression rows are
attached separately with `collect.py --rr-run <dir>`, and Railway batch runs are merged
with `collect.py --import-dir <dir>` (host `railway/<service>`).
