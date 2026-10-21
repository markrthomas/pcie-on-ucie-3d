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

**Status:** the Railway job is **defined**, not yet deployed. The weekly cron is for
long runs that exceed the GitHub runner budget (e.g. random regression). To run the
identical batch without a Railway account, see `docs/codespaces.md` (same toolchain,
same `metrics-data` output, in a GitHub Codespace).

## Verifying the path locally (no Railway, no GitHub)
The whole publish → import round-trip runs against a throwaway bare repo, so the batch
job is proven push-button before any deploy:

```
bare=$(mktemp -d)/m.git; git init -q --bare "$bare"; git push -q "$bare" HEAD:main
# run the container's work and publish exactly as Railway would (full ci chain):
METRICS_FLOWS=regress PUBLISH_METRICS=1 GITHUB_TOKEN=unused \
  METRICS_GIT_URL="$bare" ./docker/entrypoint.sh ci
# pull the published runs back into the local dashboard:
make railway-import METRICS_REMOTE="$bare"
```

`METRICS_GIT_URL` overrides the GitHub URL in `publish_metrics.sh` (default unchanged, so
real deploys are unaffected); `METRICS_REMOTE` (default `origin`) is the remote
`railway-import` fetches `metrics-data` from. The github-scoped auth header is ignored off
github.com, so the local remote needs no token. Imported runs are deduped by
`ts_utc`+`git_sha`, so re-importing is a no-op.
