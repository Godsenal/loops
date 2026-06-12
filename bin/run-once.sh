#!/bin/zsh
# 한 루프의 orchestrator 본체. render된 프롬프트로 claude -p 실행. lock per-loop.
# usage: run-once.sh <loop-id>   (env: LOOP_MODE=full|audit_only, LOOP_MAX_WORKERS 선택)
set -u
source "${0:A:h}/_common.sh"
LOOP="${1:?usage: run-once.sh <loop-id>}"
ROOT="$LOOPS_HOME"; LOOPDIR=$ROOT/loops/$LOOP; STATE=$LOOPDIR/state; CFG=$LOOPDIR/config.json
export LOOP_MODE="${LOOP_MODE:-full}"
[[ -n "${LOOP_MAX_WORKERS:-}" ]] && export LOOP_MAX_WORKERS
mkdir -p "$STATE"
LOCKDIR=/tmp/loop-$LOOP.lockdir
if ! mkdir "$LOCKDIR" 2>/dev/null; then echo "⏭ SKIP $LOOP: 이전 run 진행중(lock)"; exit 0; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

cfgval(){ node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1]));const v=process.argv[2].split(".").reduce((o,p)=>o&&o[p],c);process.stdout.write(v==null?"":String(v))' "$CFG" "$1"; }
REPO="$(cfgval repo)"; ORCHWT="$(cfgval orchestratorWorktree)"; BASEREF="$(cfgval baseRef)"; [[ -z "$BASEREF" ]] && BASEREF=origin/develop

if [[ ! -d "$ORCHWT" ]]; then
  git -C "$REPO" fetch origin -q 2>/dev/null
  git -C "$REPO" worktree add --detach "$ORCHWT" "$BASEREF" 2>&1 | tail -1
fi

PROMPT="$(node "$ROOT/bin/render-prompt.mjs" "$LOOP" orchestrator)"
echo "[$(date '+%F %T')] ===== $LOOP orchestrator start (mode=$LOOP_MODE) =====" >> "$STATE/run.log"
( cd "$ORCHWT" && claude -p "$PROMPT" --dangerously-skip-permissions ) >> "$STATE/run.log" 2>&1
code=$?
echo "[$(date '+%F %T')] ===== $LOOP orchestrator end (exit $code) =====" >> "$STATE/run.log"
date '+%s' > "$STATE/.last_run_done"
