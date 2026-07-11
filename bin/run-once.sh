#!/bin/zsh
# 한 루프의 orchestrator 본체. render된 프롬프트로 claude -p 실행. lock per-loop.
# usage: run-once.sh <loop-id>   (env: LOOP_MODE=full|audit_only|reconcile|retro, LOOP_MAX_WORKERS 선택)
set -u
source "${0:A:h}/_common.sh"
LOOP="${1:?usage: run-once.sh <loop-id>}"
ROOT="$LOOPS_HOME"; LOOPDIR=$ROOT/loops/$LOOP; STATE=$LOOPDIR/state; CFG=$LOOPDIR/config.json
export LOOP_MODE="${LOOP_MODE:-full}"
[[ -n "${LOOP_MAX_WORKERS:-}" ]] && export LOOP_MAX_WORKERS
mkdir -p "$STATE"
LOCKDIR=/tmp/loop-$LOOP.lockdir
# PID-aware lock: 획득 시 owner.pid 기록. 획득 실패 시 owner 생존을 kill -0로 확인 —
# 죽은 owner(재부팅/kill -9/OOM/claude hang로 EXIT trap 미실행)면 stale로 보고 회수·재획득한다.
# 살아있으면 기존대로 SKIP. → 비정상 종료 후 다음 스케줄에 루프 자동 복구(조용한 영구 정지 제거).
if mkdir "$LOCKDIR" 2>/dev/null; then
  echo $$ > "$LOCKDIR/owner.pid"
else
  owner="$(cat "$LOCKDIR/owner.pid" 2>/dev/null)"
  # mkdir 성공 직후 owner.pid 기록 전의 짧은 경합 창일 수 있어, 비었으면 1회만 유예 후 재확인.
  [[ -z "$owner" ]] && sleep 1 && owner="$(cat "$LOCKDIR/owner.pid" 2>/dev/null)"
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    echo "⏭ SKIP $LOOP: 이전 run 진행중(lock, pid=$owner)"; exit 0
  fi
  echo "[$(date '+%F %T')] ⚠️ stale lock 회수(이전 pid=${owner:-unknown} 사망) $LOOP" >> "$STATE/run.log"
  rm -rf "$LOCKDIR" 2>/dev/null
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo $$ > "$LOCKDIR/owner.pid"
  else
    echo "⏭ SKIP $LOOP: stale lock 회수 경합 — 다음 스케줄에 재시도"; exit 0
  fi
fi
# lockdir 안에 owner.pid가 있으므로 rmdir 대신 rm -rf로 해제.
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT

REPO="$(cfgval "$CFG" repo)"; ORCHWT="$(cfgval "$CFG" orchestratorWorktree)"; BASEREF="$(cfgval "$CFG" baseRef)"; [[ -z "$BASEREF" ]] && BASEREF=origin/develop
# claude 실행 커맨드 (config.json claudeCmd / 대시보드 설정). 비면 기본 `claude`. headless 인자는 아래에서 항상 덧붙임.
CLAUDE_CMD="$(cfgval "$CFG" claudeCmd)"; [[ -z "$CLAUDE_CMD" ]] && CLAUDE_CMD=claude

# hung run 상한: claude가 멈추면(인증 프롬프트·네트워크 대기) 락을 무한 점유하는 wedge 방지.
# coreutils timeout(macOS 기본엔 없음 → gtimeout 폴백). 둘 다 없으면 감싸지 않고 그대로 실행(회귀 없음).
RUN_TIMEOUT="${LOOP_RUN_TIMEOUT:-1800}"
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout $RUN_TIMEOUT"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout $RUN_TIMEOUT"; fi

# 매 run 최신 기준 보장: 항상 fetch → worktree를 BASE_REF 최신으로 (LLM STEP0 fetch에 의존하지 않음).
# 유저의 로컬 working tree는 절대 쓰지 않는다 — 근거/구현은 fetch 직후의 origin 기준.
git -C "$REPO" fetch origin -q 2>/dev/null
if [[ ! -d "$ORCHWT" ]]; then
  git -C "$REPO" worktree add --detach "$ORCHWT" "$BASEREF" 2>&1 | tail -1
else
  git -C "$ORCHWT" reset --hard "$BASEREF" -q 2>/dev/null
  git -C "$ORCHWT" clean -fd -q 2>/dev/null
fi

TPL=orchestrator; [[ "$LOOP_MODE" == "retro" ]] && TPL=retro   # retro = 성과 분석→learnings.md 갱신 전용 프롬프트(발굴/fan-out 없음)
PROMPT="$(node "$ROOT/bin/render-prompt.mjs" "$LOOP" "$TPL")"
echo "[$(date '+%F %T')] ===== $LOOP orchestrator start (mode=$LOOP_MODE${TIMEOUT_BIN:+, timeout=${RUN_TIMEOUT}s}) =====" >> "$STATE/run.log"
# --output-format json 으로 실행해 비용/사용량을 캡처한다. -p 는 어차피 최종 결과만 stdout에 쓰므로(스트리밍 없음)
# 사람이 읽는 run.log 내용은 record-cost.mjs가 result 텍스트를 뽑아 그대로 보존한다(stderr는 종전처럼 run.log 직행).
OUTJSON="$STATE/.last_run_out.json"
( cd "$ORCHWT" && ${=TIMEOUT_BIN} ${=CLAUDE_CMD} -p "$PROMPT" --output-format json --dangerously-skip-permissions ) > "$OUTJSON" 2>> "$STATE/run.log"
code=$?
node "$ROOT/bin/record-cost.mjs" "$LOOP" "$OUTJSON" cycle "$LOOP_MODE" >> "$STATE/run.log" 2>&1
[[ -n "$TIMEOUT_BIN" && $code -eq 124 ]] && echo "[$(date '+%F %T')] ⏱ run timeout(${RUN_TIMEOUT}s) 초과 — claude 강제종료(exit 124)" >> "$STATE/run.log"
echo "[$(date '+%F %T')] ===== $LOOP orchestrator end (exit $code) =====" >> "$STATE/run.log"
echo "$code" > "$STATE/.last_run_exit"   # 최신 run의 exit (성공 run이 0으로 덮어 배너 자동해제)
date '+%s' > "$STATE/.last_run_done"

# 종료 상태(Linear completed/canceled) worker worktree·탭·브랜치 자동 정리(결정론적 쉘 — LLM 안 거침).
# cleanup-terminal.sh가 실제 worktree를 열거하고 Linear(권위 ledger) 상태로 종료 판정한다(snapshot은 폴백).
"$ROOT/bin/cleanup-terminal.sh" "$LOOP" >> "$STATE/run.log" 2>&1

# 제안 검증(validator, opt-in config `"validate": true`): snapshot의 미판정 human-gate Backlog 제안마다
# fresh-context 검증자를 결정론적으로 스폰(LLM 안 거침). 멱등 — 판정 파일·사람 결정·live 탭 존재 시 spawn-validator가 skip.
if [[ "$(cfgval "$CFG" validate)" == "true" ]]; then
  for vid in $(node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));for(const i of s.issues||[])if(i.flag==="human-gate"&&i.state==="Backlog")console.log(i.id)}catch{}' "$STATE/snapshot.json"); do
    [[ -f "$STATE/validate/$vid.json" ]] && continue
    "$ROOT/bin/spawn-validator.sh" "$LOOP" "$vid" >> "$STATE/run.log" 2>&1
  done
fi
