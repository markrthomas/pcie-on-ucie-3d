#!/usr/bin/env bash
# docker/entrypoint.sh — container entrypoint (Railway / local batch).
#   (no args) / "ci" : run METRICS_FLOWS, render the dashboard, publish results
#   "swarm" [...]     : exec docker/swarm.sh
#   anything else     : exec it verbatim
set -euo pipefail
cd "$(dirname "$0")/.."

# nproc in a container reports HOST cores; derive a safe JOBS from the cgroup
# memory limit (~3 GB/job) so heavy Verilator builds do not OOM.
derive_jobs() {
  local mem_bytes jobs cores
  mem_bytes=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
  cores=$(nproc)
  if [ "$mem_bytes" = "max" ] || ! [ "$mem_bytes" -eq "$mem_bytes" ] 2>/dev/null; then
    jobs=$cores
  else
    jobs=$(( mem_bytes / 3000000000 )); [ "$jobs" -lt 1 ] && jobs=1
    [ "$jobs" -gt "$cores" ] && jobs=$cores
  fi
  echo "$jobs"
}

mode="${1:-ci}"
case "$mode" in
  swarm) shift || true; exec ./docker/swarm.sh "$@" ;;
  ci|"")
    export JOBS="${JOBS:-$(derive_jobs)}"
    : "${METRICS_FLOWS:=regress,coverage,systemc,cocotb,uvm,formal}"
    echo "[entrypoint] JOBS=$JOBS flows=$METRICS_FLOWS"
    make metrics METRICS_FLOWS="$METRICS_FLOWS" || true
    make dashboard || true
    if [ -n "${PUBLISH_METRICS:-}" ]; then ./docker/publish_metrics.sh || true; fi
    ;;
  *) exec "$@" ;;
esac
