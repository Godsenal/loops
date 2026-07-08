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

# config.json의 dot-path 값을 읽는 단일 헬퍼. usage: cfgval <file> <dotpath>
# 부재/null/undefined → "" , 그 외 stringify(0→"0", false→"false"). stderr는 묻지 않음(loud).
# stderr를 묻고 싶은 호출자는 `cfgval ... 2>/dev/null` 로 감싼다(예: dispatch.sh의 field).
cfgval(){ node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1]));const v=process.argv[2].split(".").reduce((o,p)=>o&&o[p],c);process.stdout.write(v==null?"":String(v))' "$1" "$2"; }

# 이슈 ID → slug: 소문자화 + 비영숫자→`-` + trailing `-` 전부 제거.
# worktree(${PREFIX}-<slug>)·브랜치(${BRPFX}/<slug>)·cmux 탭 매칭·terminal 정리가 모두 이 규칙에 걸려 있어
# spawn/cleanup이 반드시 같은 slug를 산출해야 한다 — 그 단일 원천(single source of truth).
slugof(){ echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//'; }
