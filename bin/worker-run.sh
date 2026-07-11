#!/bin/zsh
# worker 탭 본체 (라이브 TUI). 배정 이슈 1건을 이 worktree(=cwd)에서 구현→PR.
set -u
source "${0:A:h}/_common.sh"
LOOP="${LOOP_ID:?LOOP_ID 미설정}"
ID="${LOOP_ISSUE:?LOOP_ISSUE 미설정}"
ROOT="$LOOPS_HOME"
PROMPT="$(node "$ROOT/bin/render-prompt.mjs" "$LOOP" worker)"
# claude 실행 커맨드 (config.json claudeCmd / 대시보드 설정). 비면 기본 `claude`. headless 인자는 아래에서 항상 덧붙임.
CLAUDE_CMD="$(cfgval "$ROOT/loops/$LOOP/config.json" claudeCmd)"; [[ -z "$CLAUDE_CMD" ]] && CLAUDE_CMD=claude
# human-gate 해제: 사용자가 대시보드에서 결정을 내리면 decisions/<ISSUE>.md 에 저장된다 → 워커에 주입.
DECISION_FILE="$ROOT/loops/$LOOP/state/decisions/$ID.md"
DECISION=""
[[ -f "$DECISION_FILE" ]] && DECISION="$(cat "$DECISION_FILE")"
# 리뷰 재작업 모드 (rework-worker.sh가 LOOP_REWORK=1로 스폰): 신규 구현 절차를 덮어쓰는 재작업 지침 블록을 주입.
REWORK_BLOCK=""
if [[ -n "${LOOP_REWORK:-}" ]]; then
  REWORK_BLOCK="═══ 🔁 리뷰 재작업 모드 (피드백 반영) ═══
이 worktree의 브랜치에는 이미 열린 PR이 있고, 사람 리뷰어가 변경을 요청했거나(CHANGES_REQUESTED) 검증자(verifier)가 ❌ fail verdict를 PR 코멘트로 남겼다. **위 절차의 신규 구현·PR 생성(절차 2~)을 다시 하지 말고**, 아래만 수행한다:
1. \`gh pr view --json url,reviews,comments,statusCheckRollup\` 으로 이 브랜치 PR의 리뷰·코멘트·CI 상태를 읽는다.
2. **명시적 변경 요청만** 최소 diff로 반영한다. 질문·모호한 코멘트는 코드 수정 없이 PR 답글로만 응답한다(추측 구현 금지 — 뭘 원하는지 불분명하면 답글로 되묻고 그 항목은 건드리지 않는다).
3. CI 실패가 기계적으로 명백하면 함께 고친다.
4. 커밋 → \`git push\` (**non-force — force-push 절대 금지**). 반영한 각 리뷰 코멘트에 무엇을 어떻게 바꿨는지 답글을 남긴다.
5. Linear 이슈에 \"🔁 리뷰 반영 push: <요약>\" 코멘트. 상태는 In Review 유지.
6. **머지 금지, 머지/재리뷰 대기 금지** — push와 답글까지 끝나면 즉시 정지. (/gbase:monitor 를 쓰게 되더라도 지금 쌓인 피드백 처리까지만 — 장시간 감시로 진입하지 않는다.)"
fi
echo "════════ 🛠 $LOOP worker $ID 시작  $(date '+%F %T')  — 실시간 진행이 이 탭에 보입니다 ════════"
[[ -n "$DECISION" ]] && echo "⚖️  사람이 내린 결정 주입됨 (human-gate 해제)"
[[ -n "$REWORK_BLOCK" ]] && echo "🔁 리뷰 재작업 모드 (리뷰 피드백 반영만 수행)"
${=CLAUDE_CMD} "$PROMPT

═══ 배정 이슈 ID: $ID ═══${REWORK_BLOCK:+

$REWORK_BLOCK}${DECISION:+

═══ ⚖️ 사람이 대시보드에서 내린 결정 (human-gate 해제됨) ═══
사용자가 이 이슈의 human-gate를 직접 해제하고 아래 결정을 내렸다. 이 결정을 **최우선 지침**으로 따르라 — 이슈 본문의 \"human-gate/사람 판단 필요\" 표시는 이 결정으로 해소된 것으로 간주하고, 절차 2의 human-gate 중단을 하지 말고 구현을 진행하라. 시작 시 이 이슈를 Linear에서 In Progress로 옮기고, 이 결정 내용을 이슈에 코멘트로 남겨 기록하라.

$DECISION}" --dangerously-skip-permissions
echo "════════ 🛠 $LOOP worker $ID 종료  $(date '+%F %T') ════════"
