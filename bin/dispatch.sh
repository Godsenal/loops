#!/bin/zsh
# 글로벌 디스패처: 모든 enabled 루프를 각자 스케줄대로 발사. ⚠️ cmux 패널 안에서 실행해야 함(child가 worker 탭 spawn).
set -u
source "${0:A:h}/_common.sh"
ROOT="$LOOPS_HOME"; STATE=$ROOT/state
PID=$STATE/dispatcher.pid; PAUSED=$STATE/PAUSED
mkdir -p "$STATE"; echo $$ > "$PID"
cleanup(){ rm -f "$PID"; }
trap 'cleanup; exit 0' INT TERM EXIT
echo "[$(date '+%F %T')] loops dispatcher start (pid $$)" >> "$STATE/dispatcher.log"

field(){ cfgval "$@" 2>/dev/null; }   # _common.sh의 cfgval에 stderr 억제만 덧씌운 래퍼(기존 동작 보존)
next_calc(){ node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1]));const s=c.schedule||{};const iv=Math.max(60,s.intervalSec||3600);const now=Math.floor(Date.now()/1000);let f=now;if(s.startAt){const m=String(s.startAt).match(/(\d{1,2}):(\d{2})/);if(m){const d=new Date();d.setHours(+m[1],+m[2],0,0);f=Math.floor(d.getTime()/1000);while(f<=now)f+=iv;}}console.log(f)' "$1" 2>/dev/null; }
ivof(){ node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log(Math.max(60,(c.schedule||{}).intervalSec||3600))' "$1" 2>/dev/null; }

while true; do
  if [[ ! -f "$PAUSED" ]]; then
    for CFG in $ROOT/loops/*/config.json; do
      [[ -f "$CFG" ]] || continue
      lid="$(field "$CFG" id)"; [[ -z "$lid" ]] && continue
      [[ "$(field "$CFG" enabled)" == "false" ]] && continue
      lstate="$ROOT/loops/$lid/state"; mkdir -p "$lstate"
      nextf="$lstate/next_fire"
      [[ -f "$lstate/PAUSED" ]] && continue
      [[ -f "$nextf" ]] || next_calc "$CFG" > "$nextf"
      now=$(date +%s); nf=$(cat "$nextf" 2>/dev/null || echo 0)
      if (( now >= nf )); then
        "$ROOT/bin/spawn-orchestrator.sh" "$lid" >> "$lstate/dispatcher.log" 2>&1 &
        iv=$(ivof "$CFG")
        while (( nf <= now )); do nf=$(( nf + iv )); done
        echo "$nf" > "$nextf"
        echo "[$(date '+%F %T')] fired $lid → next $(date -r $nf '+%F %T')" >> "$STATE/dispatcher.log"
      fi
    done
  fi
  sleep 15
done
