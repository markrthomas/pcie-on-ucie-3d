#!/usr/bin/env bash
# docker/swarm.sh — run the AI agent swarm non-interactively (Claude Code).
# Runs NON-BARE so .claude/agents/ are discovered.  Needs `claude` on PATH
# (image built with --build-arg WITH_CLAUDE=1) and a credential
# (CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL+ANTHROPIC_AUTH_TOKEN).
# Optional GITHUB_TOKEN lets the swarm push a branch / open a DRAFT PR.
set -euo pipefail
cd "$(dirname "$0")/.."

TASK="docker/swarm-task.md"
MODEL=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$TASK" ] || { echo "task file not found: $TASK" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || { echo "claude CLI not found (build the image with WITH_CLAUDE=1)" >&2; exit 2; }

ARGS=(-p "$(cat "$TASK")" --output-format json --permission-mode acceptEdits
      --allowedTools "Bash Read Edit Write Glob Grep Agent")
[ -n "$MODEL" ] && ARGS+=(--model "$MODEL")

if [ "$DRY" = "1" ]; then printf 'claude'; printf ' %q' "${ARGS[@]}"; echo; exit 0; fi

claude "${ARGS[@]}" | tee docker/last-run-metrics.json
