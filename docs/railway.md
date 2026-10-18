# Railway — batch job + metrics publishing

Railway runs the full suite as an **ephemeral batch job**, not a web service
(`railway.toml`: `builder=DOCKERFILE`, `restartPolicyType="NEVER"`, weekly
`cronSchedule`). It builds the Dockerfile's `full` stage (ENTRYPOINT
`docker/entrypoint.sh`), runs once, and exits.

## Data flow
The container has no persistent disk, so results leave via
`docker/publish_metrics.sh`, which pushes `metrics/metrics.db` +
`metrics/dashboard.html` to the orphan branch **`metrics-data`** (a per-run dir +
`latest/`). Locally, pull them back into the dashboard:

```
make railway-import     # git fetch origin metrics-data; collect --import-dir; re-render
```

## Service variables
- `GITHUB_TOKEN` (or a deploy token) — for `publish_metrics.sh` (used via an http
  extraheader, never in the URL/config).
- `METRICS_REPO` — `owner/repo` for the push (default `markrthomas/pcie-on-ucie-3d`).
- `METRICS_FLOWS` — which flows `entrypoint.sh` runs (default
  `regress,coverage,systemc,cocotb,uvm,formal`).
- `PUBLISH_METRICS=1` — enable the publish step.

**Status:** the Railway job is **defined**, not yet deployed (no remote this pass —
see `AGENT_HANDOFF.md`). The weekly cron is for long runs that exceed the GitHub
runner budget (e.g. random regression).
