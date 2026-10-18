# docker/ — toolchain image, batch entrypoint, agent swarm

| File | Role |
|---|---|
| `../Dockerfile` | multi-stage image: `builder` → `tools` (CI) → `full` (Railway/batch). |
| `entrypoint.sh` | `full`-stage entrypoint: `ci` (run flows → dashboard → publish), `swarm`, or any command. Derives `JOBS` from the cgroup memory limit. |
| `swarm.sh` | run Claude Code non-interactively (non-bare, so `.claude/agents/` load). `--task FILE --model M --dry-run`. |
| `publish_metrics.sh` | push `metrics.db` / `dashboard.html` to the orphan branch `metrics-data`; re-import with `make railway-import`. |
| `swarm-task.md` | default task: end-to-end re-verification (Swarm A). |
| `rr-swarm-task.md` | task: random-regression loop (Swarm B). |
| `extra_ca/` | drop `*.crt` here to trust extra CAs (TLS-intercept proxies). |

**CI** builds `--target tools` and runs each job in the image via `container:`
(so Verilator only ever runs in a container). **Railway** builds the default
(`full`) stage and runs `entrypoint.sh` once (see `../railway.toml`,
`../docs/railway.md`). The swarm needs a credential secret
(`CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`) and, to open a draft PR,
`GITHUB_TOKEN`.
