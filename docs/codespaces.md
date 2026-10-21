# GitHub Codespaces — the Railway batch, without Railway

A Codespace built from `.devcontainer/devcontainer.json` is the **same container as
the Railway batch**: it uses the repo's own Dockerfile `tools` stage (the from-source
Verilator / Yosys / SBY / Icarus / SystemC / cocotb toolchain CI runs every job in),
with the repo mounted. So the weekly Railway job can run in a Codespace instead, with
no Railway account — useful while Railway access is pending, or for one-off long runs.

## Run it

1. **Open a Codespace** on the repo (GitHub → `Code ▸ Codespaces ▸ Create`, or
   `gh codespace create -R markrthomas/pcie-on-ucie-3d`). First build compiles the
   toolchain (~tens of minutes) unless Codespaces **prebuilds** are enabled or the
   devcontainer is pointed at the prebuilt GHCR image (see the note in
   `devcontainer.json`).
2. **Run the batch** — exactly what Railway's cron runs (`docker/entrypoint.sh ci`):
   ```
   ./docker/entrypoint.sh ci                      # flows -> metrics/metrics.db -> dashboard.html
   PUBLISH_METRICS=1 ./docker/entrypoint.sh ci    # ALSO push results to the metrics-data branch
   ```
   `entrypoint.sh` derives `JOBS` from the machine's memory, runs `METRICS_FLOWS`
   (default `regress,coverage,systemc,cocotb,uvm,formal`), renders the dashboard, and
   — when `PUBLISH_METRICS=1` — runs `docker/publish_metrics.sh`.
3. **Pull results into your local dashboard:**
   ```
   make railway-import        # fetch metrics-data, merge the runs, re-render
   ```

## Publishing

`PUBLISH_METRICS=1` pushes `metrics/{metrics.db,dashboard.html}` to the orphan
`metrics-data` branch (per-run dir + `latest/`). Codespaces injects a `GITHUB_TOKEN`
automatically; publishing works when the Codespace has **write** access to the repo
(the token is used via an http extraheader, never in the URL/config — see
`docker/publish_metrics.sh`). Same service knobs as Railway (`METRICS_REPO`,
`METRICS_FLOWS`, `METRICS_GIT_URL`) — see `docs/railway.md`.

## Codespace vs Railway

| | Railway | Codespace |
|---|---|---|
| Trigger | weekly cron (`railway.toml`) | manual (or a scheduled Action that starts it) |
| Container | Dockerfile `full` stage, repo baked in | Dockerfile `tools` stage, repo mounted |
| Runs | `entrypoint.sh` once, then exits | you run `entrypoint.sh ci` in the terminal |
| Output | `metrics-data` branch | same `metrics-data` branch |

A Codespace is **interactive and manual**, so it is not a drop-in for Railway's
unattended weekly cron — but it runs the identical workload and produces the identical
`metrics-data` output, verified by the same local round-trip in `docs/railway.md`.
