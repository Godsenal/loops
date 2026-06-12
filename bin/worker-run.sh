#!/bin/zsh
# worker 탭 본체 (라이브 TUI). 배정 이슈 1건을 이 worktree(=cwd)에서 구현→PR.
set -u
source "${0:A:h}/_common.sh"
LOOP="${LOOP_ID:?LOOP_ID 미설정}"
ID="${LOOP_ISSUE:?LOOP_ISSUE 미설정}"
ROOT="$LOOPS_HOME"
PROMPT="$(node "$ROOT/bin/render-prompt.mjs" "$LOOP" worker)"
echo "════════ 🛠 $LOOP worker $ID 시작  $(date '+%F %T')  — 실시간 진행이 이 탭에 보입니다 ════════"
claude "$PROMPT

═══ 배정 이슈 ID: $ID ═══" --dangerously-skip-permissions
echo "════════ 🛠 $LOOP worker $ID 종료  $(date '+%F %T') ════════"
