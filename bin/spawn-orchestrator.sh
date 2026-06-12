#!/bin/zsh
# 한 루프의 orchestrator 1 사이클 발사. ⚠️ FOREGROUND(detach 금지 — cmux 소켓 접근 유지). 호출자가 백그라운드로 감쌈.
set -u
source "${0:A:h}/_common.sh"
LOOP="${1:?usage: spawn-orchestrator.sh <loop-id>}"
ROOT="$LOOPS_HOME"; STATE=$ROOT/loops/$LOOP/state
mkdir -p "$STATE"
ts=$(date '+%s')
print -r -- "{\"ts\":$ts,\"type\":\"cycle\",\"event\":\"start\"}" >> "$STATE/runs.jsonl"
echo "[$(date '+%F %T')] $LOOP orchestrator 사이클 시작 (foreground, cmux 접근 유지)"
env LOOP_MODE=full "$ROOT/bin/run-once.sh" "$LOOP" >> "$STATE/orchestrator.log" 2>&1
echo "[$(date '+%F %T')] $LOOP orchestrator 사이클 종료 (exit $?)"
