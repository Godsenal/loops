#!/bin/zsh
# loops 공통 — 모든 스크립트가 source한다.
# LOOPS_HOME(플랫폼 루트)을 _common.sh 자기 위치에서 유도하고, loops.env(머신별 도구 경로)를 읽어
# PATH / CMUX_BIN / GH_BIN / WORKTREE_BASE / DEFAULT_REPO 를 세팅한다. → 어디에 두든 동작.
_self="${(%):-%x}"
: "${LOOPS_HOME:=${_self:A:h:h}}"   # _common.sh(bin/) 의 상위상위 = repo 루트
export LOOPS_HOME
[[ -f "$LOOPS_HOME/loops.env" ]] && source "$LOOPS_HOME/loops.env"
[[ -n "${LOOPS_PATH_PREPEND:-}" ]] && export PATH="$LOOPS_PATH_PREPEND:$PATH"
export CMUX_BIN="${CMUX_BIN:-$(command -v cmux 2>/dev/null)}"
export GH_BIN="${GH_BIN:-$(command -v gh 2>/dev/null)}"
export WORKTREE_BASE="${WORKTREE_BASE:-$HOME/LTH}"
export DEFAULT_REPO="${DEFAULT_REPO:-}"
