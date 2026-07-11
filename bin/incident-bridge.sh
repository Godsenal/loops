#!/bin/zsh
# 장애→수정 브리지: 엔진 런타임 장애 신호를 "엔진 자가개선 루프"(repo == LOOPS_HOME 인 루프, 예: loops-improve)의
# Linear Backlog 이슈로 자동 발제한다. 이후는 기존 레일 그대로 — 그 루프의 worker가 진단·수정(mission의
# 구문검증·핵심경로 human-gate 규칙 적용) → direct push → self-update → 디스패처 자가 재실행. 즉 이 스크립트는
# "알아서 수정"의 **입력**만 자동화하고, 수정·배포 판단은 기존 안전장치를 전부 통과한다.
#
# 발제하는 신호 (엔진 결함 신호만):
#   • cycle-error — 어떤 루프든 오케스트레이터 사이클(.last_run_exit)이 연속 LOOPS_INCIDENT_FAILS(2)회 실패.
#   • supervisor escalate/rollback — supervisor-events.jsonl의 crash-loop escalate·self-update 롤백.
# 발제하지 않는 신호 (의도적 제외): stuck(escalated)·rework-exhausted — 이슈별 **대상 레포** 문제라 엔진 루프의
#   worker(엔진 레포에서만 작업)가 고칠 수 없는 영역이고, 이미 대시보드·Telegram으로 사람에게 1급 표면화된다.
#
# 폭주 방지: ① 시그니처 dedup — cycle-error는 "성공 run으로 스트릭이 리셋되기 전까지 1회"(filed 플래그),
#   supervisor 이벤트는 시그니처당 쿨다운(기본 86400s). ② 전역 일일 캡 LOOPS_INCIDENT_DAILY_MAX(3) — 초과분은
#   로그로만 남긴다(신호 유실 아님 — 조건이 지속되면 다음 날 다시 발제). 상태: state/incidents.json.
# 미설정 시 스킵(fallback 아님·미개통의 정상 경로): LINEAR_API_KEY 없음 / repo==LOOPS_HOME 인 enabled 루프 없음.
# 안전: Linear 이슈 생성 + runs.jsonl append + Telegram 알림뿐 — 머지/배포/상태 전이/정리 없음.
# usage: incident-bridge.sh   (dispatch.sh가 ≤120s 케이던스로 호출, 수동 실행도 무해·멱등)
set -u
source "${0:A:h}/_common.sh"
ROOT="$LOOPS_HOME"; GSTATE=$ROOT/state; INC="$GSTATE/incidents.json"
mkdir -p "$GSTATE"
FAILS=${LOOPS_INCIDENT_FAILS:-2}
DAILY_MAX=${LOOPS_INCIDENT_DAILY_MAX:-3}
SUP_COOLDOWN=${LOOPS_INCIDENT_COOLDOWN:-86400}
now=$(date +%s); today="$(date '+%F')"

[[ -n "${LINEAR_API_KEY:-}" ]] || exit 0   # 발제 채널 미개통 — 스킵(주석의 미설정 정책)

# 엔진 자가개선 루프 탐지: repo가 이 플랫폼 레포(LOOPS_HOME) 자신인 첫 enabled 루프.
engine=""; engine_pid=""
for CFG in $ROOT/loops/*/config.json(N); do
  [[ -f "$CFG" ]] || continue
  r="$(cfgval "$CFG" repo 2>/dev/null)"; [[ -z "$r" ]] && continue
  [[ "${r:A}" == "${ROOT:A}" ]] || continue
  [[ "$(cfgval "$CFG" enabled 2>/dev/null)" == "false" ]] && continue
  engine="$(cfgval "$CFG" id 2>/dev/null)"; engine_pid="$(cfgval "$CFG" linearProjectId 2>/dev/null)"; break
done
[[ -z "$engine" || -z "$engine_pid" ]] && exit 0   # 엔진 루프 없음 — 발제할 곳이 없다(미개통 정책)

# ── incidents.json 헬퍼 (liveness.json과 동일 패턴) ──
inc_get(){ node -e 'const fs=require("fs"),[f,p]=process.argv.slice(1);let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}const v=p.split(".").reduce((a,k)=>a&&a[k],o);process.stdout.write(v==null?"":String(v))' "$INC" "$1"; }
inc_merge(){ node -e 'const fs=require("fs"),[f,k,p]=process.argv.slice(1);let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}o[k]=Object.assign({},o[k]||{},JSON.parse(p));fs.writeFileSync(f,JSON.stringify(o))' "$INC" "$1" "$2"; }

# 일일 캡: 오늘 카운트가 캡 미만이면 증가시키고 "ok" 출력, 아니면 빈 출력(발제 스킵).
cap_take(){ node -e 'const fs=require("fs"),[f,today,max]=process.argv.slice(1);let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}if(o.day!==today){o.day=today;o.filedToday=0}if((o.filedToday||0)>=+max){process.exit(0)}o.filedToday=(o.filedToday||0)+1;fs.writeFileSync(f,JSON.stringify(o));process.stdout.write("ok")' "$INC" "$today" "$DAILY_MAX"; }

# file_incident <sig> <title> <bodyfile> — 캡 통과 시 엔진 루프 프로젝트에 이슈 생성 + 피드·알림 기록.
file_incident(){
  local sig="$1" title="$2" bodyf="$3"
  if [[ -z "$(cap_take)" ]]; then
    echo "[$(date '+%F %T')] 💤 incident 일일 캡(${DAILY_MAX}) 도달 — 발제 보류: $title"
    return 1
  fi
  local out ident url
  if ! out="$(LINEAR_API_KEY="${LINEAR_API_KEY:-}" node "$ROOT/bin/linear-create.mjs" "$engine_pid" "$title" < "$bodyf" 2>&1)"; then
    echo "[$(date '+%F %T')] ⚠️ incident 발제 실패($sig): $out"
    return 1
  fi
  ident="${out%%$'\t'*}"; url="${out##*$'\t'}"
  inc_merge filed "{\"$sig\":{\"ts\":$now,\"issue\":\"$ident\"}}"
  print -r -- "{\"ts\":$now,\"type\":\"incident\",\"event\":\"filed\",\"issue\":\"$ident\",\"note\":\"$sig\"}" >> "$ROOT/loops/$engine/state/runs.jsonl"
  echo "[$(date '+%F %T')] 🧾 incident 발제: $ident ($sig) $url"
  node "$ROOT/bin/tg-notify.mjs" "🧾 incident: $title → $engine $ident 자동 발제 ($url)" 2>&1 | grep -v '미설정' || true
  return 0
}

# ── A) 사이클 연속 실패 — 루프별 .last_run_done 커서로 "새 run 종료"만 집계(폴링 중복 없음) ──
for CFG in $ROOT/loops/*/config.json(N); do
  [[ -f "$CFG" ]] || continue
  lid="$(cfgval "$CFG" id 2>/dev/null)"; [[ -z "$lid" ]] && continue
  lstate="$ROOT/loops/$lid/state"
  [[ -f "$lstate/.last_run_exit" && -f "$lstate/.last_run_done" ]] || continue
  ec="$(cat "$lstate/.last_run_exit" 2>/dev/null)"; dt="$(cat "$lstate/.last_run_done" 2>/dev/null)"
  [[ -n "$ec" && -n "$dt" ]] || continue
  # 커서 전진 + 스트릭 계산을 원자적으로: 출력 "<streak>\t<filed>" (새 run 없으면 빈 출력).
  res="$(node -e '
    const fs=require("fs"),[f,lid,dt,ec]=process.argv.slice(1);
    let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}
    const L=o.loops=o.loops||{};const e=L[lid]=L[lid]||{};
    if(+dt<=(e.lastRunDone||0)){process.exit(0)}          // 새로 끝난 run 없음
    e.lastRunDone=+dt;
    if(+ec===0){e.streak=0;e.filed=false}else{e.streak=(e.streak||0)+1}
    fs.writeFileSync(f,JSON.stringify(o));
    process.stdout.write(String(e.streak)+"\t"+String(!!e.filed))' "$INC" "$lid" "$dt" "$ec")"
  [[ -z "$res" ]] && continue
  streak="${res%%$'\t'*}"; filed="${res##*$'\t'}"
  if (( streak >= FAILS )) && [[ "$filed" != "true" ]]; then
    bodyf="$(mktemp)"
    {
      print -r -- "자동 발제(incident-bridge) — 엔진 런타임 장애 신고."
      print -r -- ""
      print -r -- "- 루프: \`$lid\`"
      print -r -- "- 신호: 오케스트레이터 사이클 연속 ${streak}회 실패 (마지막 exit ${ec}, $(date -r "$dt" '+%F %T'))"
      print -r -- "- 로그: \`loops/$lid/state/run.log\`"
      print -r -- ""
      print -r -- "**할 일**: 아래 증거에서 근본원인을 진단한다. 엔진 레포 범위(스크립트·프롬프트·렌더)면 수정하고(수용기준: mission의 구문검증 규칙 준수, 핵심 실행경로 동작 변경은 human-gate), 엔진 밖 원인(키 만료·네트워크·대상 레포 상태)이면 원인과 권고 조치를 이슈 코멘트로 남기고 본문 맨 위에 human-gate를 명시해 사람 판단으로 넘긴다."
      print -r -- ""
      print -r -- "### run.log tail"
      print -r -- '```'
      tail -60 "$lstate/run.log" 2>/dev/null
      print -r -- '```'
    } > "$bodyf"
    if file_incident "cycle|$lid" "[incident] $lid 오케스트레이터 사이클 연속 ${streak}회 실패 (exit $ec)" "$bodyf"; then
      inc_merge loops "{\"$lid\":{\"lastRunDone\":$dt,\"streak\":$streak,\"filed\":true}}"
    fi
    rm -f "$bodyf"
  fi
done

# ── B) supervisor 이벤트(escalate·rollback) — 라인 커서로 신규분만, 시그니처당 쿨다운 ──
EV="$GSTATE/supervisor-events.jsonl"
if [[ -f "$EV" ]]; then
  cur="$(inc_get supCursor)"; [[ -z "$cur" ]] && cur=0
  total="$(wc -l < "$EV" | tr -d ' ')"
  if (( total > cur )); then
    tail -n +$(( cur + 1 )) "$EV" | while IFS= read -r line; do
      etype="$(print -r -- "$line" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const j=JSON.parse(d);process.stdout.write((j.type||"")+"\t"+(j.comp||"")+"\t"+(j.note||""))}catch{}})')"
      typ="${etype%%$'\t'*}"; rest="${etype#*$'\t'}"; comp="${rest%%$'\t'*}"; note="${rest##*$'\t'}"
      [[ "$typ" == "escalate" || "$typ" == "rollback" ]] || continue
      sig="sup|$typ|$comp"
      last="$(inc_get "filed.$sig.ts")"
      [[ -n "$last" ]] && (( now - last < SUP_COOLDOWN )) && continue
      bodyf="$(mktemp)"
      {
        print -r -- "자동 발제(incident-bridge) — supervisor 이벤트 신고."
        print -r -- ""
        print -r -- "- 컴포넌트: \`$comp\` · 이벤트: **$typ**"
        print -r -- "- 내용: $note"
        print -r -- "- 이벤트 로그: \`state/supervisor-events.jsonl\` · 감독 로그: \`state/supervisor.log\`"
        print -r -- ""
        print -r -- "**할 일**: crash-loop/롤백의 근본원인을 진단한다. 엔진 레포 범위면 수정하고(수용기준: mission의 구문검증 규칙, 핵심 실행경로 동작 변경은 human-gate), 롤백 건이면 보류된 커밋(state/.update_hold)의 결함을 고쳐 origin에 올리는 것까지가 완료 조건이다."
        print -r -- ""
        print -r -- "### supervisor.log tail"
        print -r -- '```'
        tail -40 "$GSTATE/supervisor.log" 2>/dev/null
        print -r -- '```'
      } > "$bodyf"
      file_incident "$sig" "[incident] supervisor $typ — $comp ($note)" "$bodyf"
      rm -f "$bodyf"
    done
    inc_merge_root_cursor(){ node -e 'const fs=require("fs"),[f,v]=process.argv.slice(1);let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}o.supCursor=+v;fs.writeFileSync(f,JSON.stringify(o))' "$INC" "$1"; }
    inc_merge_root_cursor "$total"
  fi
fi

exit 0
