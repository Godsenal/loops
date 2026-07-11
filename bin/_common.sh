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

# 자기(호출 프로세스가 사는 PTY) cmux workspace ref. `cmux identify`의 caller.workspace_ref.
# 인프라 패널(dispatcher/dashboard/bot)이 "내 탭이 어느 것인가"를 기록(state/panel.*.ref)하는 데 쓴다 —
# ref는 세션 간 불안정하지만 "지금 이 순간의 자기 탭" 식별에는 유일하게 정확하다(타이틀은 중복 가능).
# 실패(비-cmux 컨텍스트·플레이크·구버전 cmux) → 빈 stdout + 비0 종료. 호출자는 skip으로 처리(무음 fallback 금지 — 로그 남길 것).
own_workspace_ref(){
  [[ -z "${CMUX_BIN:-}" ]] && return 1
  "$CMUX_BIN" identify 2>/dev/null | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{const r=JSON.parse(d).caller.workspace_ref;if(!/^workspace:\d+$/.test(r))process.exit(1);process.stdout.write(r)}catch{process.exit(1)}})'
}

# cmux list-workspaces 라인에서 선택 마커 제거. cmux는 선택된 워크스페이스 줄 끝에 "[selected]"를 붙인다 —
# 안 벗기면 타이틀 정확매칭/마지막 토큰 파싱이 깨진다(실제 사고: 286b5a2). 신규 코드는 이 헬퍼를 쓸 것.
strip_selected(){ sed -E 's/[[:space:]]*\[selected\][[:space:]]*$//'; }
