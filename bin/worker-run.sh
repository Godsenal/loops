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
echo "════════ 🛠 $LOOP worker $ID 시작  $(date '+%F %T')  — 실시간 진행이 이 탭에 보입니다 ════════"
[[ -n "$DECISION" ]] && echo "⚖️  사람이 내린 결정 주입됨 (human-gate 해제)"
${=CLAUDE_CMD} "$PROMPT

═══ 배정 이슈 ID: $ID ═══${DECISION:+

═══ ⚖️ 사람이 대시보드에서 내린 결정 (human-gate 해제됨) ═══
사용자가 이 이슈의 human-gate를 직접 해제하고 아래 결정을 내렸다. 이 결정을 **최우선 지침**으로 따르라 — 이슈 본문의 \"human-gate/사람 판단 필요\" 표시는 이 결정으로 해소된 것으로 간주하고, 절차 2의 human-gate 중단을 하지 말고 구현을 진행하라. 시작 시 이 이슈를 Linear에서 In Progress로 옮기고, 이 결정 내용을 이슈에 코멘트로 남겨 기록하라.

$DECISION}" --dangerously-skip-permissions
echo "════════ 🛠 $LOOP worker $ID 종료  $(date '+%F %T') ════════"
