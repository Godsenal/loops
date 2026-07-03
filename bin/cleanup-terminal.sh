#!/bin/zsh
# 한 루프의 죽은 worker 리소스(worktree·cmux 탭·브랜치)를 쓸어담는다(멱등). run-once.sh 및 dispatch.sh reaper가 호출.
# "종료" 판정의 권위 신호 = Linear statusType(completed|canceled). Linear 프로젝트가 곧 상태머신이기 때문.
#   snapshot은 활성 보드만 담아 Done을 빠뜨리고, origin이 mirror면 gh PR도 안 보이므로 Linear를 1차로 쓴다.
#   Linear 미가용(키 없음/오프라인)이면 snapshot의 Done/Canceled를 폴백으로 사용.
# 회수 대상 = (worker worktree) ∪ (cmux worker 탭). 둘의 수명이 어긋나도 고아가 안 남게 합집합으로 훑는다:
#   • 종료(TERMINAL)          → cleanup-issue.sh (탭+worktree+브랜치, worktree 없어도 탭 닫음).
#   • 비종료 & worktree 소멸  → 죽은 고아 탭(cwd 사라져 resume 불가) → 탭만 닫음(브랜치는 PR 살아있을 수 있어 보존).
#   • 비종료 & worktree 존재  → In Progress/Review → 보존(claude --resume 용).
# usage: cleanup-terminal.sh <loop-id>   (env: CLEANUP_DRY_RUN=1 → 삭제 없이 정리 대상만 출력)
set -u
source "${0:A:h}/_common.sh"
LOOP="${1:?usage: cleanup-terminal.sh <loop-id>}"
ROOT="$LOOPS_HOME"; LOOPDIR=$ROOT/loops/$LOOP; STATE=$LOOPDIR/state; CFG=$LOOPDIR/config.json
[[ -f "$CFG" ]] || { echo "loop '$LOOP' config 없음 — skip"; exit 0; }
REPO="$(cfgval "$CFG" repo)"; PREFIX="$(cfgval "$CFG" worktreePrefix)"; PID="$(cfgval "$CFG" linearProjectId)"
CMUX="$CMUX_BIN"
[[ -z "$REPO" || -z "$PREFIX" ]] && { echo "repo/worktreePrefix 없음 — skip"; exit 0; }

# slug→종료여부(TERMINAL), slug→이슈id(SLUGID). slug는 spawn-worker.sh의 id→slug 규칙과 동일.
typeset -A TERMINAL SLUGID
id2slug(){ local s="${1:l}"; s="${s//[^a-z0-9]/-}"; print -r -- "${s%-}"; }

# 1) 권위 신호 — Linear statusType. (LINEAR_API_KEY는 loops.env에 export 안 돼 있어 node 자식에 명시 전달.)
linear_n=0
if [[ -n "$PID" && -n "${LINEAR_API_KEY:-}" ]]; then
  while IFS=$'\t' read -r id t; do
    [[ -z "$id" ]] && continue
    sl="$(id2slug "$id")"; SLUGID[$sl]="$id"; (( linear_n++ ))
    [[ "$t" == "completed" || "$t" == "canceled" ]] && TERMINAL[$sl]=1
  done < <(LINEAR_API_KEY="${LINEAR_API_KEY:-}" node "$ROOT/bin/linear-states.mjs" "$PID" 2>/dev/null)
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

# 3) 회수 대상 열거 = 현존 worktree slug ∪ 현존 cmux worker 탭 slug. (process substitution으로 현재 셸에 배열 유지.)
typeset -A WT_EXISTS TAB_REFS TAB_ID
# 3a) worker worktree(${PREFIX}-<slug>) 열거.
while IFS= read -r p; do
  [[ "$p" == "${PREFIX}-"* ]] || continue
  WT_EXISTS[${p#"$PREFIX"-}]=1
done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
# 3b) 이 루프의 cmux worker 탭(🛠/↩) 열거 → slug→ref들, slug→정확한 id(제목 끝 토큰). cleanup-issue.sh와 동일 매칭 경계.
tab_n=0
if [[ -n "$CMUX" ]]; then
  while IFS= read -r line; do
    ref="$(print -r -- "$line" | grep -oE 'workspace:[0-9]+' | head -1)"
    id="$(print -r -- "$line" | awk '{print $NF}')"   # 제목 "🛠 <loop> <ID>" → ID가 마지막 토큰
    [[ -z "$ref" || -z "$id" ]] && continue
    sl="$(id2slug "$id")"
    TAB_REFS[$sl]+="$ref "; TAB_ID[$sl]="$id"; (( tab_n++ ))
  done < <("$CMUX" list-workspaces 2>/dev/null | grep -iE "(🛠|↩)[[:space:]]+${LOOP}[[:space:]]")
fi

# 요약줄은 무동작이어도 매번 찍힌다 → 60s reaper(CLEANUP_QUIET=1)에선 억제(run.log 무한 증식 방지). 실제 정리 액션 로그는 아래에서 무조건 출력.
[[ -z "${CLEANUP_QUIET:-}" ]] && echo "🧹 cleanup-terminal $LOOP — Linear ${linear_n}건 조회, 종료 후보 ${#TERMINAL}개, worker 탭 ${tab_n}개"

# 3c) 합집합 slug 순회 → 판정 매트릭스. id는 탭 제목(정확) > SLUGID > slug 대문자화 순.
typeset -aU ALLSLUGS; ALLSLUGS=(${(k)WT_EXISTS} ${(k)TAB_REFS})
for sl in $ALLSLUGS; do
  id="${TAB_ID[$sl]:-${SLUGID[$sl]:-${sl:u}}}"
  if [[ -n "${TERMINAL[$sl]:-}" ]]; then
    # 종료 → 풀 정리(탭+worktree+브랜치). worktree 없어도 cleanup-issue가 남은 탭을 닫는다.
    if [[ -n "${CLEANUP_DRY_RUN:-}" ]]; then echo "  [dry-run] terminal → clean $id (${PREFIX}-$sl)"; else "$ROOT/bin/cleanup-issue.sh" "$LOOP" "$id"; fi
  elif [[ -z "${WT_EXISTS[$sl]:-}" && -n "${TAB_REFS[$sl]:-}" ]]; then
    # 비종료인데 worktree 소멸 + 탭 잔존 → 죽은 고아 탭. cwd가 사라져 resume 불가하므로 탭만 닫음(브랜치는 보존).
    if [[ -n "${CLEANUP_DRY_RUN:-}" ]]; then
      echo "  [dry-run] orphan(worktree 없음) → close tab $id (${TAB_REFS[$sl]% })"
    else
      for r in ${=TAB_REFS[$sl]}; do "$CMUX" close-workspace --workspace "$r" >/dev/null 2>&1; done
      ts=$(date '+%s'); print -r -- "{\"ts\":$ts,\"type\":\"worker\",\"event\":\"orphan-tab-closed\",\"issue\":\"$id\"}" >> "$STATE/runs.jsonl"
      echo "closed orphan tab $LOOP/$id (worktree 없음 — resume 불가)"
    fi
  fi
  # else: 비종료 & worktree 존재 → 진행/리뷰 중 → 보존(무동작).
done
