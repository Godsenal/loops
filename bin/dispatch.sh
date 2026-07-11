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
# 루프 일일 예산(config budget.dailyUsd) 소프트 캡: 오늘 costs.jsonl 합계가 캡 이상이면 사유를 출력(비면 통과).
# "다음 사이클을 안 돌리는" 수준 — 진행 중 워커는 건드리지 않는다. 예산 미설정이면 항상 통과.
budget_check(){ node -e 'const fs=require("fs"),[cfgF,costF]=process.argv.slice(1);const c=JSON.parse(fs.readFileSync(cfgF));const cap=c.budget&&c.budget.dailyUsd;if(!cap)process.exit(0);let lines=[];try{lines=fs.readFileSync(costF,"utf8").trim().split("\n")}catch{process.exit(0)}const d=new Date();d.setHours(0,0,0,0);const t0=Math.floor(d.getTime()/1000);let s=0;for(const l of lines){try{const e=JSON.parse(l);if(e.ts>=t0&&e.usd)s+=e.usd}catch{}}if(s>=cap)process.stdout.write("일예산 초과 $"+s.toFixed(2)+"/$"+cap)' "$1" "$2" 2>/dev/null; }
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
        bex="$(budget_check "$CFG" "$lstate/costs.jsonl")"
        if [[ -n "$bex" ]]; then
          # 예산 소프트 캡: 이번 발사만 건너뛰고 next_fire를 정상 전진 — 자정 지나 오늘 합계가 리셋되면 자동 재개.
          iv=$(ivof "$CFG"); while (( nf <= now )); do nf=$(( nf + iv )); done; echo "$nf" > "$nextf"
          echo "[$(date '+%F %T')] 💰 budget-skip $lid ($bex) → next $(date -r $nf '+%F %T')" >> "$STATE/dispatcher.log"
          print -r -- "{\"ts\":$now,\"type\":\"cycle\",\"event\":\"budget-skip\",\"note\":\"$bex\"}" >> "$lstate/runs.jsonl"
          continue
        fi
        "$ROOT/bin/spawn-orchestrator.sh" "$lid" >> "$lstate/dispatcher.log" 2>&1 &
        iv=$(ivof "$CFG")
        while (( nf <= now )); do nf=$(( nf + iv )); done
        echo "$nf" > "$nextf"
        echo "[$(date '+%F %T')] fired $lid → next $(date -r $nf '+%F %T')" >> "$STATE/dispatcher.log"
      fi
    done

    # ── event-poll: config on:{} 이벤트 소스(CI 실패·새 PR 리뷰·Linear 신규 Backlog)를 ≤60s로 폴링해
    #    조건 충족 시 해당 루프의 next_fire를 now로 당긴다(발사는 위 본 루프의 기존 경로 그대로).
    #    PAUSED 가드 **안**에 두는 이유: 이건 housekeeping이 아니라 발사 스케줄링이라, 전역 정지 중엔 폴링도 무의미.
    now=$(date +%s); lastev=$(cat "$STATE/.last_eventpoll" 2>/dev/null || echo 0)
    if (( now - lastev >= 60 )); then
      echo "$now" > "$STATE/.last_eventpoll"
      for CFG in $ROOT/loops/*/config.json; do
        [[ -f "$CFG" ]] || continue
        lid="$(field "$CFG" id)"; [[ -z "$lid" ]] && continue
        "$ROOT/bin/event-poll.sh" "$lid" >> "$ROOT/loops/$lid/state/run.log" 2>&1
      done
    fi

    # ── retro: config retro.everyCycles 개의 정규 사이클이 쌓일 때마다 성과 분석 run(LOOP_MODE=retro)을 1회 발사
    #    → learnings.md 갱신(힐 클라이밍 루프). 미설정(retro 없음/0)이면 완전 비활성. run 중(lockdir)이면 다음 체크로.
    now=$(date +%s); lastrt=$(cat "$STATE/.last_retrocheck" 2>/dev/null || echo 0)
    if (( now - lastrt >= 300 )); then
      echo "$now" > "$STATE/.last_retrocheck"
      for CFG in $ROOT/loops/*/config.json; do
        [[ -f "$CFG" ]] || continue
        lid="$(field "$CFG" id)"; [[ -z "$lid" ]] && continue
        [[ "$(field "$CFG" enabled)" == "false" ]] && continue
        lstate="$ROOT/loops/$lid/state"
        [[ -f "$lstate/PAUSED" ]] && continue
        [[ -d /tmp/loop-$lid.lockdir ]] && continue
        every="$(field "$CFG" retro.everyCycles)"; [[ -z "$every" || "$every" == "0" ]] && continue
        # 정규 사이클 done 수(retro 자신의 done은 제외) — 마지막 retro 시점 대비 every개 쌓였으면 발사.
        done_n=$(grep '"event":"done"' "$lstate/runs.jsonl" 2>/dev/null | grep -vc '"type":"retro"')
        last_n=$(cat "$lstate/.last_retro_cycles" 2>/dev/null || echo 0)
        if (( done_n - last_n >= every )); then
          echo "$done_n" > "$lstate/.last_retro_cycles"
          "$ROOT/bin/spawn-orchestrator.sh" "$lid" retro >> "$lstate/dispatcher.log" 2>&1 &
          echo "[$(date '+%F %T')] 🧠 retro fired $lid (cycles ${last_n}→${done_n}, every $every)" >> "$STATE/dispatcher.log"
        fi
      done
    fi
  fi

  # ── reaper: 종료/고아 worker 탭을 orchestrator 스케줄과 독립으로 즉시(≤60s) 회수. ──
  # cmux 소켓 접근이 필요해 이 디스패처 루프(=cmux 패널 안)에서 돈다. PAUSED와 무관한 housekeeping이라 위 가드 밖.
  # 진행 중 run(lockdir)은 스킵 — 그 run이 끝에 스스로 cleanup-terminal 하므로 중복/레이스 방지. 무동작 reap은 CLEANUP_QUIET로 조용히.
  now=$(date +%s); lastreap=$(cat "$STATE/.last_reap" 2>/dev/null || echo 0)
  if (( now - lastreap >= 60 )); then
    echo "$now" > "$STATE/.last_reap"
    for CFG in $ROOT/loops/*/config.json; do
      [[ -f "$CFG" ]] || continue
      lid="$(field "$CFG" id)"; [[ -z "$lid" ]] && continue
      [[ -d /tmp/loop-$lid.lockdir ]] && continue
      CLEANUP_QUIET=1 "$ROOT/bin/cleanup-terminal.sh" "$lid" >> "$ROOT/loops/$lid/state/run.log" 2>&1
    done
  fi

  # ── self-update: origin이 앞서면 엔진(LOOPS_HOME)을 fast-forward로 자동 갱신. 코드가 바뀌면 디스패처 재실행. ──
  # 모든 루프가 idle(진행 중 run=lockdir 없음)일 때만 — 실행 중 bin/ 스크립트 스왑 레이스 방지. reaper/watchdog처럼 housekeeping이라 PAUSED 가드 밖.
  # ff-only만(no-force 불변식); 유저 데이터는 gitignore라 무관. 주기 기본 600s(LOOPS_UPDATE_INTERVAL로 조정, 0이면 비활성).
  upiv="${LOOPS_UPDATE_INTERVAL:-600}"
  now=$(date +%s); lastup=$(cat "$STATE/.last_update" 2>/dev/null || echo 0)
  if (( upiv > 0 && now - lastup >= upiv )); then
    echo "$now" > "$STATE/.last_update"
    busy=""; for d in /tmp/loop-*.lockdir; do [[ -d "$d" ]] && { busy=1; break; }; done
    if [[ -z "$busy" ]]; then
      LOOPS_UPDATE_QUIET=1 "$ROOT/bin/self-update.sh" >> "$STATE/dispatcher.log" 2>&1
      if (( $? == 10 )); then
        echo "[$(date '+%F %T')] self-update 적용됨 → 디스패처 재실행(exec)" >> "$STATE/dispatcher.log"
        exec "$ROOT/bin/dispatch.sh"   # 같은 PID·같은 cmux 패널 유지, 새 엔진 코드 로드
      fi
    fi
  fi

  # ── watchdog: 죽은 worker(탭 사망·worktree 생존·In Progress)를 ≤60s로 자가복구하거나 escalate. ──
  # 리퍼와 같은 이유로 이 루프(cmux 패널) 안에서 돈다. 진행 중 run(lockdir)은 스킵 — 그 run이 spawn 중일 수 있어 레이스 방지.
  # 무동작이면 WATCHDOG_QUIET로 조용히(run.log 무한 증식 방지). heal/escalate 액션 로그는 watchdog.sh가 무조건 출력.
  now=$(date +%s); lastwd=$(cat "$STATE/.last_watchdog" 2>/dev/null || echo 0)
  if (( now - lastwd >= 60 )); then
    echo "$now" > "$STATE/.last_watchdog"
    for CFG in $ROOT/loops/*/config.json; do
      [[ -f "$CFG" ]] || continue
      lid="$(field "$CFG" id)"; [[ -z "$lid" ]] && continue
      [[ -d /tmp/loop-$lid.lockdir ]] && continue
      WATCHDOG_QUIET=1 "$ROOT/bin/watchdog.sh" "$lid" >> "$ROOT/loops/$lid/state/run.log" 2>&1
    done
  fi

  sleep 15
done
