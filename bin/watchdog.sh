#!/bin/zsh
# spawn-liveness 워치독: worker 탭이 죽었는데 이슈가 아직 In Progress면 자가복구(재기동)하거나, 반복 실패면 escalate(사람에게 표면화).
# 결정론적·멱등. dispatch.sh가 리퍼와 같은 ≤60s 케이던스로 호출(진행 중 run은 lockdir로 스킵). run-once/대시보드도 손으로 호출 가능.
#
# 판정: 후보 = 현존 worker worktree. 각 slug에 대해
#   • Linear completed/canceled  → 종료 → skip(리퍼 담당) + liveness 엔트리 제거.
#   • live 탭(🛠|↩) 있음          → 건강 → liveness 엔트리 제거(복구 확인).
#   • snapshot state=="In Progress" & live 탭 없음 → 죽은 worker:
#       - 첫 감지 → deadSince 기록, grace(LOOP_WATCHDOG_GRACE_SEC=90s) 동안 대기(spawn 직후 rename 레이스·기동중 오탐 방지).
#       - grace 경과 & attempts<LOOP_HEAL_MAX(2) → heal-worker.sh 재기동, attempts++, deadSince 리셋(다음 grace 창).
#       - attempts>=MAX → escalated=true 기록. 더는 재기동 안 함(churn 중단). 서버가 attention:"stuck"으로 표면화 → 대시보드🔴+Telegram.
#   • 그 외(In Review·Backlog 등) → 우리 소관 아님 → liveness 엔트리 제거.
# ⚠️ In Progress 게이트는 snapshot을 쓴다(In Review와 구분 위해). Linear statusType는 IP/IR을 구분 못 하므로 종료 veto 용도로만.
# 안전: 머지/배포/force-push/worktree 삭제/Linear 취소 없음 — 재기동(cmux 탭)과 liveness.json 쓰기만.
# usage: watchdog.sh <loop-id>   (env: WATCHDOG_QUIET=1 무동작 요약 억제, LOOP_HEAL_MAX, LOOP_WATCHDOG_GRACE_SEC)
set -u
source "${0:A:h}/_common.sh"
LOOP="${1:?usage: watchdog.sh <loop-id>}"
ROOT="$LOOPS_HOME"; LOOPDIR=$ROOT/loops/$LOOP; STATE=$LOOPDIR/state; CFG=$LOOPDIR/config.json
[[ -f "$CFG" ]] || { echo "loop '$LOOP' config 없음 — skip"; exit 0; }
REPO="$(cfgval "$CFG" repo)"; PREFIX="$(cfgval "$CFG" worktreePrefix)"; PID="$(cfgval "$CFG" linearProjectId)"
CMUX="$CMUX_BIN"
[[ -z "$REPO" || -z "$PREFIX" ]] && { echo "repo/worktreePrefix 없음 — skip"; exit 0; }
HEAL_MAX=${LOOP_HEAL_MAX:-2}
GRACE=${LOOP_WATCHDOG_GRACE_SEC:-90}
LIVENESS="$STATE/liveness.json"

id2slug(){ local s="${1:l}"; s="${s//[^a-z0-9]/-}"; print -r -- "${s%-}"; }

# liveness.json 조작 (원자적 read-modify-write, 파싱 실패는 빈 객체로 안전 복구).
lv_get(){ node -e 'const fs=require("fs"),[f,id,k]=process.argv.slice(1);let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}const e=o[id]||{};process.stdout.write(e[k]!=null?String(e[k]):"")' "$LIVENESS" "$1" "$2"; }
lv_set(){ node -e 'const fs=require("fs"),[f,id,p]=process.argv.slice(1);let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}o[id]=Object.assign({},o[id]||{},JSON.parse(p));fs.writeFileSync(f,JSON.stringify(o))' "$LIVENESS" "$1" "$2"; }
lv_del(){ node -e 'const fs=require("fs"),[f,id]=process.argv.slice(1);let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}if(o[id]!=null){delete o[id];fs.writeFileSync(f,JSON.stringify(o))}' "$LIVENESS" "$1"; }

# 1) 종료(TERMINAL) veto — Linear statusType(권위). 키 없거나 실패하면 snapshot Done/Canceled로 폴백. (cleanup-terminal.sh와 동일 패턴)
typeset -A TERMINAL SLUGID INPROGRESS
if [[ -n "$PID" && -n "${LINEAR_API_KEY:-}" ]]; then
  while IFS=$'\t' read -r id t; do
    [[ -z "$id" ]] && continue
    sl="$(id2slug "$id")"; SLUGID[$sl]="$id"
    [[ "$t" == "completed" || "$t" == "canceled" ]] && TERMINAL[$sl]=1
  done < <(LINEAR_API_KEY="${LINEAR_API_KEY:-}" node "$ROOT/bin/linear-states.mjs" "$PID" 2>/dev/null)
fi

# 2) In Progress 게이트 + 종료 폴백 — snapshot (In Review와 구분되는 유일 소스).
SNAP="$STATE/snapshot.json"
if [[ -f "$SNAP" ]]; then
  while IFS=$'\t' read -r sl id st; do
    [[ -z "$sl" ]] && continue
    [[ -z "${SLUGID[$sl]:-}" ]] && SLUGID[$sl]="$id"
    [[ "$st" == "In Progress" ]] && INPROGRESS[$sl]=1
    [[ "$st" == "Done" || "$st" == "Canceled" ]] && TERMINAL[$sl]=1
  done < <(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1]));for(const i of (s.issues||[])){const g=String(i.id||"").toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/-+$/,"");process.stdout.write(g+"\t"+(i.id||"")+"\t"+(i.state||"")+"\n")}' "$SNAP" 2>/dev/null)
fi

# 3) 현존 worker worktree(${PREFIX}-<slug>) 열거 = 유일한 후보.
typeset -A WT_EXISTS
while IFS= read -r p; do
  [[ "$p" == "${PREFIX}-"* ]] || continue
  WT_EXISTS[${p#"$PREFIX"-}]=1
done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

# 4) live 탭(🛠|↩ <loop> <id>) slug 열거.
typeset -A TAB_LIVE
if [[ -n "$CMUX" ]]; then
  while IFS= read -r line; do
    id="$(print -r -- "$line" | awk '{print $NF}')"
    [[ -z "$id" ]] && continue
    TAB_LIVE[$(id2slug "$id")]=1
  done < <("$CMUX" list-workspaces 2>/dev/null | grep -iE "(🛠|↩)[[:space:]]+${LOOP}[[:space:]]")
fi

now=$(date +%s)
healed=0; escalated=0; waiting=0; cleared=0
for sl in ${(k)WT_EXISTS}; do
  id="${SLUGID[$sl]:-${sl:u}}"
  if [[ -n "${TERMINAL[$sl]:-}" ]]; then
    lv_del "$id"; (( cleared++ )); continue                 # 종료 → 리퍼 담당
  elif [[ -n "${TAB_LIVE[$sl]:-}" ]]; then
    lv_del "$id"; (( cleared++ )); continue                 # 건강(탭 살아있음) → 복구 확인
  elif [[ -z "${INPROGRESS[$sl]:-}" ]]; then
    lv_del "$id"; (( cleared++ )); continue                 # In Review/Backlog 등 → 소관 아님
  fi
  # ── 여기부터: In Progress + 탭 없음 = 죽은 worker ──
  deadSince="$(lv_get "$id" deadSince)"
  if [[ -z "$deadSince" ]]; then
    lv_set "$id" "{\"deadSince\":$now,\"attempts\":0}"; (( waiting++ )); continue   # 첫 감지
  fi
  (( now - deadSince < GRACE )) && { (( waiting++ )); continue; }                    # grace 대기
  [[ "$(lv_get "$id" escalated)" == "true" ]] && continue                            # 이미 escalate — 사람 대기
  attempts="$(lv_get "$id" attempts)"; [[ -z "$attempts" ]] && attempts=0
  if (( attempts < HEAL_MAX )); then
    "$ROOT/bin/heal-worker.sh" "$LOOP" "$id" $(( attempts + 1 )) >> "$STATE/run.log" 2>&1
    lv_set "$id" "{\"attempts\":$(( attempts + 1 )),\"lastHeal\":$now,\"deadSince\":$now}"
    (( healed++ )); echo "🔧 watchdog $LOOP/$id — 자가복구 재기동 (attempt $(( attempts + 1 ))/$HEAL_MAX)"
  else
    lv_set "$id" "{\"escalated\":true}"
    (( escalated++ )); echo "🧟 watchdog $LOOP/$id — ${HEAL_MAX}회 자가복구 실패 → escalate (stuck, 사람 판단 대기)"
  fi
done

[[ -z "${WATCHDOG_QUIET:-}" ]] && echo "🐕 watchdog $LOOP — worktree ${#WT_EXISTS}개 · heal ${healed} · escalate ${escalated} · 대기 ${waiting} · clear ${cleared}"
exit 0
