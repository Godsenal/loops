#!/bin/zsh
# 한 루프의 **종료 상태** worker worktree·탭·브랜치를 쓸어담는다(멱등). run-once.sh가 orchestrator run 후 호출.
# "종료" 판정의 권위 신호 = Linear statusType(completed|canceled). Linear 프로젝트가 곧 상태머신이기 때문.
#   snapshot은 활성 보드만 담아 Done을 빠뜨리고, origin이 mirror면 gh PR도 안 보이므로 Linear를 1차로 쓴다.
#   Linear 미가용(키 없음/오프라인)이면 snapshot의 Done/Canceled를 폴백으로 사용.
# 진행 중(backlog/started/unstarted)·키 없을 때의 미상 항목은 보존. 실제 존재하는 worktree에만 cleanup-issue.sh 호출.
# usage: cleanup-terminal.sh <loop-id>   (env: CLEANUP_DRY_RUN=1 → 삭제 없이 정리 대상만 출력)
set -u
source "${0:A:h}/_common.sh"
LOOP="${1:?usage: cleanup-terminal.sh <loop-id>}"
ROOT="$LOOPS_HOME"; LOOPDIR=$ROOT/loops/$LOOP; STATE=$LOOPDIR/state; CFG=$LOOPDIR/config.json
[[ -f "$CFG" ]] || { echo "loop '$LOOP' config 없음 — skip"; exit 0; }
REPO="$(cfgval "$CFG" repo)"; PREFIX="$(cfgval "$CFG" worktreePrefix)"; PID="$(cfgval "$CFG" linearProjectId)"
[[ -z "$REPO" || -z "$PREFIX" ]] && { echo "repo/worktreePrefix 없음 — skip"; exit 0; }

# slug→종료여부(TERMINAL), slug→이슈id(SLUGID). slug는 spawn-worker.sh의 id→slug 규칙과 동일.
typeset -A TERMINAL SLUGID
id2slug(){ local s="${1:l}"; s="${s//[^a-z0-9]/-}"; print -r -- "${s%-}"; }

# 1) 권위 신호 — Linear statusType. (LINEAR_API_KEY는 loops.env에 export 안 돼 있어 node 자식에 명시 전달.)
#    자식 stderr를 버리지 않고 캡처 — 만료/무효 키·네트워크 장애로 인한 조용한 snapshot 강등을 로그에 노출한다.
linear_n=0
if [[ -n "$PID" && -n "${LINEAR_API_KEY:-}" ]]; then
  lserr="$(mktemp)"
  while IFS=$'\t' read -r id t; do
    [[ -z "$id" ]] && continue
    sl="$(id2slug "$id")"; SLUGID[$sl]="$id"; (( linear_n++ ))
    [[ "$t" == "completed" || "$t" == "canceled" ]] && TERMINAL[$sl]=1
  done < <(LINEAR_API_KEY="${LINEAR_API_KEY:-}" node "$ROOT/bin/linear-states.mjs" "$PID" 2>"$lserr")
  [[ -s "$lserr" ]] && echo "⚠️ cleanup-terminal $LOOP — $(<"$lserr")" >&2
  rm -f "$lserr"
  (( linear_n == 0 )) && echo "⚠️ cleanup-terminal $LOOP — LINEAR_API_KEY 있으나 linear-states 0건(만료/네트워크 의심) → snapshot 폴백" >&2
elif [[ -z "${LINEAR_API_KEY:-}" ]]; then
  echo "ℹ️ cleanup-terminal $LOOP — LINEAR_API_KEY 미설정 → snapshot 폴백" >&2
fi

# 2) 폴백/보강 — snapshot의 Done/Canceled (Linear 0건이면 폴백, 아니면 보강).
SNAP="$STATE/snapshot.json"
if [[ -f "$SNAP" ]]; then
  while IFS=$'\t' read -r sl id st; do
    [[ -z "$sl" ]] && continue
    [[ -z "${SLUGID[$sl]:-}" ]] && SLUGID[$sl]="$id"
    [[ "$st" == "Done" || "$st" == "Canceled" ]] && TERMINAL[$sl]=1
  done < <(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1]));for(const i of (s.issues||[])){const g=String(i.id||"").toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/-+$/,"");process.stdout.write(g+"\t"+(i.id||"")+"\t"+(i.state||"")+"\n")}' "$SNAP" 2>/dev/null)
fi

echo "🧹 cleanup-terminal $LOOP — Linear ${linear_n}건 조회, 종료 후보 ${#TERMINAL}개"

# 3) 실제 worker worktree(${PREFIX}-<slug>) 열거 → 종료 slug만 cleanup-issue.sh.
#    id는 SLUGID(정확한 원본 식별자) 우선, 없으면 slug 대문자화.
git -C "$REPO" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
  [[ "$line" == "worktree "* ]] || continue
  p="${line#worktree }"
  [[ "$p" == "${PREFIX}-"* ]] || continue
  sl="${p#"$PREFIX"-}"
  [[ -n "${TERMINAL[$sl]:-}" ]] || continue
  id="${SLUGID[$sl]:-${sl:u}}"
  if [[ -n "${CLEANUP_DRY_RUN:-}" ]]; then
    echo "  [dry-run] would clean $id  →  $p"
  else
    "$ROOT/bin/cleanup-issue.sh" "$LOOP" "$id"
  fi
done
