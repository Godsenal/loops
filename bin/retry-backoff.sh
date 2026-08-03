#!/bin/zsh
# 오케스트레이터 사이클의 일시적 실패를 백오프로 재발사한다 — 체인에서 유일하게 재시도가 없던 링크.
# dispatch.sh가 ≤60s 케이던스로 호출. event-poll.sh와 **같은 메커니즘**(next_fire를 당긴다)이라 새 실행 경로가
# 없다: 발사는 여전히 dispatcher 본 루프가 하고 cap·예산·drain·PAUSED/enabled 가드를 전부 그대로 통과한다.
#
# 왜 필요한가: run-once.sh는 claude를 딱 한 번 호출하고, 실패하면 그 루프는 **다음 스케줄까지 통째로 쉰다**
# (webview 계열은 3시간). 5일 실측에서 그렇게 날아간 사이클이 connection-closed 95 · 529 62 · 5xx/타임아웃 6건.
# 전부 1분 뒤면 그냥 성공하는 종류였다.
#
# 분류가 핵심 — claudeCmd가 `claude-acct cloop`(계정 라운드로빈)이라는 사실에서 갈린다:
#   • transient  (connection closed·529·overloaded·5xx·SIGKILL/SIGTERM 타임아웃) → 재시도. 그냥 일시적.
#   • per-account(Not logged in·Invalid API key·Credit balance) → 재시도. limit-marker 훅은 **429에만** 반응하므로
#     이 부류는 cloop의 계정 핸드오프가 안 걸리고 그 한 계정에서만 죽는다 → 다음 호출이 라운드로빈으로
#     **다른 계정**에 착지해 그대로 성공한다. 재시도가 실제 복구 수단인 유일한 계정 문제.
#   • exhausted  (weekly/session limit) → 재시도 **안 함**. cloop이 이미 호출 안에서 활성 계정을 전부 돌고 반환한
#     상태라 사이클을 다시 태워봐야 같은 벽이다(incident-bridge의 account_alert가 사람에게 알린다).
#   • 그 외 → 재시도 안 함. 엔진 결함일 수 있으니 incident-bridge의 cycle-error 발제 영역으로 넘긴다.
#
# 백오프 LOOPS_RETRY_BACKOFF("60 300 900") · 상한 LOOPS_RETRY_MAX(3). 성공(exit 0) 사이클이 카운터를 리셋한다.
# 커서는 state/retry.json의 lastRunDone — **끝난 run 하나를 한 번만** 판정한다(60s 폴링 중복 방지).
# 안전: next_fire 쓰기 + runs.jsonl append 뿐 — 머지/배포/force-push/Linear 상태 변경 없음.
# usage: retry-backoff.sh <loop-id>
set -u
source "${0:A:h}/_common.sh"
LOOP="${1:?usage: retry-backoff.sh <loop-id>}"
ROOT="$LOOPS_HOME"; LOOPDIR=$ROOT/loops/$LOOP; STATE=$LOOPDIR/state; CFG=$LOOPDIR/config.json
[[ -f "$CFG" ]] || exit 0
[[ "$(cfgval "$CFG" enabled 2>/dev/null)" == "false" ]] && exit 0
[[ -f "$STATE/PAUSED" ]] && exit 0
[[ -d /tmp/loop-$LOOP.lockdir ]] && exit 0   # run 진행 중 — 판정은 그 run이 끝난 뒤에

RETRY_MAX=${LOOPS_RETRY_MAX:-3}
typeset -a BACKOFF; BACKOFF=(${=LOOPS_RETRY_BACKOFF:-60 300 900})

# claude가 낸 문구 실측 기반. 순서가 곧 우선순위 — exhausted를 per-account보다 먼저 본다
# ("weekly limit"과 로그인 안내가 같은 tail에 섞여 있으면 계정 소진 쪽이 진실이다).
EXHAUSTED_RE='hit your weekly limit|hit your session limit|usage limit reached'
PERACCT_RE='Not logged in|Please run /login|Invalid API key|Credit balance is too low'
# 'rate limit'은 넣지 않는다 — 정상 동작 중에도 "...rate limits when they reset" 문장이 나온다(claude는
# rate limit을 abort가 아니라 자체 재시도로 처리). incident-bridge의 ACCOUNT_ABORT_RE와 같은 이유.
TRANSIENT_RE='Connection closed mid-response|Overloaded|overloaded_error|Internal server error|API Error: 5[0-9][0-9]|API Error: 429|status.claude.com'

now=$(date +%s)
ec="$(cat "$STATE/.last_run_exit" 2>/dev/null)"; dt="$(cat "$STATE/.last_run_done" 2>/dev/null)"
[[ "$ec" == <-> && "$dt" == <-> ]] || exit 0

RJ="$STATE/retry.json"
rj_get(){ node -e 'const fs=require("fs"),[f,k]=process.argv.slice(1);let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}process.stdout.write(o[k]==null?"":String(o[k]))' "$RJ" "$1"; }
rj_set(){ node -e 'const fs=require("fs"),[f,p]=process.argv.slice(1);let o={};try{o=JSON.parse(fs.readFileSync(f))}catch{}Object.assign(o,JSON.parse(p));fs.writeFileSync(f,JSON.stringify(o))' "$RJ" "$1"; }

seen="$(rj_get lastRunDone)"; [[ "$seen" == <-> ]] || seen=0
(( dt > seen )) || exit 0            # 이미 판정한 run — 폴링 중복 없음
rj_set "{\"lastRunDone\":$dt}"

if (( ec == 0 )); then               # 성공 사이클이 재시도 예산을 되돌린다
  [[ "$(rj_get attempts)" == 0 ]] || rj_set '{"attempts":0}'
  exit 0
fi

# SIGKILL(137)/SIGTERM(143)/timeout(124)은 run.log에 남는 문구가 없어 exit 코드로만 판별된다.
if (( ec == 137 || ec == 143 || ec == 124 )); then
  kind=transient; why="타임아웃 강제종료(exit $ec)"
else
  tail60="$(tail -60 "$STATE/run.log" 2>/dev/null)"
  if print -r -- "$tail60" | grep -aqE "$EXHAUSTED_RE"; then
    kind=exhausted; why="계정 한도 소진"
  elif print -r -- "$tail60" | grep -aqE "$PERACCT_RE"; then
    kind=peracct;   why="해당 계정 인증 문제 — 라운드로빈이 다음 계정으로"
  elif print -r -- "$tail60" | grep -aqE "$TRANSIENT_RE"; then
    kind=transient; why="일시적 API 오류"
  else
    kind=other;     why="분류 불가(exit $ec)"
  fi
fi

if [[ "$kind" == exhausted || "$kind" == other ]]; then
  # 재시도해도 같은 벽이거나(exhausted), 엔진 결함일 수 있어 incident-bridge에 맡긴다(other).
  # 예산은 되돌려 둔다 — 다음의 진짜 일시적 실패가 온전한 재시도 횟수를 갖도록.
  [[ "$(rj_get attempts)" == 0 ]] || rj_set '{"attempts":0}'
  exit 0
fi

att="$(rj_get attempts)"; [[ "$att" == <-> ]] || att=0
if (( att >= RETRY_MAX )); then
  echo "⏸ retry $LOOP: ${RETRY_MAX}회 재시도 소진 — 정규 스케줄로 복귀 ($why)"
  rj_set '{"attempts":0}'
  exit 0
fi

delay=${BACKOFF[$((att+1))]:-${BACKOFF[-1]}}
target=$(( now + delay ))
nf="$(cat "$STATE/next_fire" 2>/dev/null || echo 0)"
if (( nf <= target )); then
  # 정규 스케줄이 이미 더 이르다 — 당길 게 없다. 시도 횟수도 안 쓴다(재시도가 일어나지 않았으므로).
  exit 0
fi
att=$((att+1)); rj_set "{\"attempts\":$att}"
echo "$target" > "$STATE/next_fire"
print -r -- "{\"ts\":$now,\"type\":\"cycle\",\"event\":\"trigger\",\"trigger\":\"retry\",\"note\":\"$kind ${att}/${RETRY_MAX} +${delay}s — $why\"}" >> "$STATE/runs.jsonl"
echo "🔁 retry $LOOP: $kind ${att}/${RETRY_MAX} → ${delay}s 뒤 재발사 ($why)"
