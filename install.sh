#!/bin/zsh
# Loops 플랫폼 설치 — 도구 자동탐지 → loops.env 생성, ~/.loops-home 기록, create-loop 스킬 등록.
# usage: ./install.sh
set -u
LOOPS_HOME="${0:A:h}"
echo "📦 Loops 설치 — LOOPS_HOME=$LOOPS_HOME"

# --- 도구 탐지 ---
NODE="$(command -v node 2>/dev/null)"
GH="$(command -v gh 2>/dev/null)"
CMUX="$(command -v cmux 2>/dev/null)"
CLAUDE="$(command -v claude 2>/dev/null)"
# claude: cmux 래퍼일 수 있어 실제 바이너리 우선 (~/.local/bin/claude)
[[ -x "$HOME/.local/bin/claude" ]] && CLAUDE="$HOME/.local/bin/claude"
# cmux: PATH에 없으면 macOS 앱 번들
[[ -z "$CMUX" && -x "/Applications/cmux.app/Contents/Resources/bin/cmux" ]] && CMUX="/Applications/cmux.app/Contents/Resources/bin/cmux"

miss=0
[[ -z "$NODE"   ]] && { echo "⚠️  node 미탐지";   miss=1; }
[[ -z "$CLAUDE" ]] && { echo "⚠️  claude 미탐지"; miss=1; }
[[ -z "$GH"     ]] && { echo "⚠️  gh 미탐지";     miss=1; }
[[ -z "$CMUX"   ]] && { echo "⚠️  cmux 미탐지 (이 플랫폼은 cmux 전제)"; miss=1; }

# PATH prepend = node/claude/gh 들어있는 dir (심볼릭 유지 = 래퍼 dir, 중복 제거, ':' 결합)
typeset -aU dirs
for b in "$NODE" "$CLAUDE" "$GH"; do [[ -n "$b" ]] && dirs+=("${b:h}"); done
PREPEND="${(j.:.)dirs}"

# 기존 값 보존(재실행 시) — loops.env 있으면 WORKTREE_BASE/DEFAULT_REPO/PORT/BUNDLE 유지
WT_BASE="$HOME/LTH"; DEF_REPO=""; PORT="8422"; BUNDLE="com.cmuxterm.app"
if [[ -f "$LOOPS_HOME/loops.env" ]]; then
  source "$LOOPS_HOME/loops.env" 2>/dev/null
  WT_BASE="${WORKTREE_BASE:-$WT_BASE}"; DEF_REPO="${DEFAULT_REPO:-$DEF_REPO}"
  PORT="${LOOPS_PORT:-$PORT}"; BUNDLE="${CMUX_BUNDLE_ID:-$BUNDLE}"
fi

cat > "$LOOPS_HOME/loops.env" <<EOF
# 자동 생성 (install.sh). 머신별 도구 경로 — 수정 가능.
LOOPS_PATH_PREPEND="$PREPEND"
CLAUDE_BIN="$CLAUDE"
CMUX_BIN="$CMUX"
GH_BIN="$GH"
CMUX_BUNDLE_ID="$BUNDLE"
WORKTREE_BASE="$WT_BASE"
DEFAULT_REPO="$DEF_REPO"
LOOPS_PORT="$PORT"
EOF
echo "✅ loops.env 생성"

# 스킬이 LOOPS_HOME 찾는 포인터
echo "$LOOPS_HOME" > "$HOME/.loops-home"

# create-loop 스킬 등록 (repo → ~/.claude/skills symlink)
mkdir -p "$HOME/.claude/skills"
rm -rf "$HOME/.claude/skills/create-loop"
ln -sfn "$LOOPS_HOME/skills/create-loop" "$HOME/.claude/skills/create-loop"
echo "✅ create-loop 스킬 등록 (~/.claude/skills/create-loop → repo)"

# 디렉토리 + 실행권한
mkdir -p "$LOOPS_HOME/loops" "$LOOPS_HOME/state"
chmod +x "$LOOPS_HOME/loopctl" "$LOOPS_HOME/dashboard-server.mjs" "$LOOPS_HOME/bin/"*.sh "$LOOPS_HOME/bin/render-prompt.mjs" 2>/dev/null

echo
echo "완료 ✅  다음:"
echo "  $LOOPS_HOME/loopctl dashboard   # 대시보드 (http://localhost:$PORT, cmux 패널)"
echo "  $LOOPS_HOME/loopctl start       # 디스패처 시작"
echo "  loop 추가: 대시보드 '+ 새 loop' (AI 생성) 또는 examples/ 복사 → loops/<id>/"
[[ -z "$DEF_REPO" ]] && echo "  (선택) loops.env 의 DEFAULT_REPO 에 기본 repo 절대경로를 넣으면 AI 빌더가 편함"
[[ $miss -eq 1 ]] && echo "⚠️  일부 도구 미탐지 — loops.env 를 수동 보정하세요"
