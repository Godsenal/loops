#!/bin/zsh
# 엔진 레포(LOOPS_HOME)를 origin 추적 브랜치로 fast-forward 자동 갱신한다.
# 안전 불변식(엔진 no-force와 동일 정신):
#   · ff-only만 — 로컬이 앞서거나 diverge면 절대 강제/리셋/stash 안 하고 스킵(사람 몫으로 로그만).
#   · 유저 데이터(loops/·state/·loops.env·*.log)는 gitignore라 pull과 무관 → 런타임 데이터 안 건드림.
#   · dirty 워킹트리 충돌 시 git이 스스로 ff-only 머지를 거부 → 그대로 스킵(무손실).
# exit: 0 = 변경 없음/안전 스킵, 10 = 업데이트 적용됨(호출자가 재시작 판단), 1 = 치명 오류.
# LOOPS_UPDATE_QUIET=1 이면 "이미 최신"·"origin 없음" 같은 무동작을 조용히(로그 무한 증식 방지).
set -u
source "${0:A:h}/_common.sh"
cd "$LOOPS_HOME" || { echo "[self-update] LOOPS_HOME 접근 불가: $LOOPS_HOME"; exit 1; }

q(){ [[ -n "${LOOPS_UPDATE_QUIET:-}" ]] || echo "$@"; }

# origin(로컬 전용 클론이면 없음) / upstream 없으면 조용히 통과.
git remote get-url origin >/dev/null 2>&1 || { q "[self-update] origin 없음 — 스킵"; exit 0; }
up="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)" || { q "[self-update] upstream 없음 — 스킵"; exit 0; }
branch="${up#*/}"

git fetch --quiet origin "$branch" 2>/dev/null || { echo "[self-update] ⚠️ fetch 실패($branch) — 네트워크? 스킵"; exit 0; }

local_sha="$(git rev-parse @ 2>/dev/null)"
remote_sha="$(git rev-parse '@{u}' 2>/dev/null)"
base_sha="$(git merge-base @ '@{u}' 2>/dev/null)"

[[ "$local_sha" == "$remote_sha" ]] && { q "[self-update] 최신 ($branch @ ${local_sha:0:7})"; exit 0; }

# 로컬이 upstream의 조상이 아니면 ff 불가(로컬 커밋 존재 or divergence) → 강제 금지, 스킵.
if [[ "$local_sha" != "$base_sha" ]]; then
  echo "[self-update] ⚠️ fast-forward 불가(로컬 커밋/divergence) — 자동 갱신 스킵. 수동 확인: git -C $LOOPS_HOME status"
  exit 0
fi

# local == base, remote 앞섬 → ff 가능. 실제 머지는 git이 dirty 충돌을 스스로 거부하므로 안전.
errf="$(mktemp)"
if git merge --ff-only '@{u}' >/dev/null 2>"$errf"; then
  rm -f "$errf"
  new_sha="$(git rev-parse @)"
  echo "[self-update] ✅ ${local_sha:0:7} → ${new_sha:0:7} ($branch) 자동 갱신"
  exit 10
else
  msg="$(tr '\n' ' ' <"$errf" 2>/dev/null)"; rm -f "$errf"
  echo "[self-update] ⚠️ ff-only 갱신 실패(로컬 변경 충돌 추정) — 스킵: ${msg}"
  exit 0
fi
