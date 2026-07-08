#!/bin/zsh
# 한 루프의 액션(Linear 이슈) 1건 → 전용 worktree + cmux worker 탭. ⚠️ cmux 안에서 시작된 프로세스에서 호출해야 함.
# usage: spawn-worker.sh <loop-id> <issue-id>
set -u
source "${0:A:h}/_common.sh"
LOOP="${1:?usage: spawn-worker.sh <loop-id> <issue-id>}"
ID="${2:?usage: spawn-worker.sh <loop-id> <issue-id>}"
ROOT="$LOOPS_HOME"; LOOPDIR=$ROOT/loops/$LOOP; STATE=$LOOPDIR/state; CFG=$LOOPDIR/config.json
CMUX="$CMUX_BIN"
RUNNER=$ROOT/bin/worker-run.sh
REPO="$(cfgval "$CFG" repo)"; BASEREF="$(cfgval "$CFG" baseRef)"; [[ -z "$BASEREF" ]] && BASEREF=origin/develop
PREFIX="$(cfgval "$CFG" worktreePrefix)"; BRPFX="$(cfgval "$CFG" branchPrefix)"; [[ -z "$BRPFX" ]] && BRPFX="loop-$LOOP"

slug="$(slugof "$ID")"
WT="${PREFIX}-${slug}"; BR="${BRPFX}/${slug}"
git -C "$REPO" fetch origin -q
git -C "$REPO" worktree remove --force "$WT" 2>/dev/null
git -C "$REPO" branch -D "$BR" 2>/dev/null
if ! git -C "$REPO" worktree add -b "$BR" "$WT" "$BASEREF" 2>&1; then echo "ERROR: worktree 생성 실패 $WT"; exit 1; fi

out="$("$CMUX" new-workspace --cwd "$WT" --command "LOOP_ID=$LOOP LOOP_ISSUE=$ID $RUNNER" 2>&1)"
ref="$(echo "$out" | grep -oE 'workspace:[0-9]+' | head -1)"
if [[ -n "$ref" ]]; then
  "$CMUX" rename-workspace --workspace "$ref" "🛠 $LOOP $ID" 2>/dev/null
  cnt=$("$CMUX" list-workspaces 2>/dev/null | grep -c 'workspace:')   # 맨 밑에 추가
  "$CMUX" reorder-workspace --workspace "$ref" --index "$cnt" >/dev/null 2>&1
  # spawn 성공(탭 생성됨) → Linear 이슈를 즉시 In Progress로 결정론적 선반영.
  #   워커(LLM)가 시작 시 스스로 In Progress로 옮기지만, dead-at-startup(그 지시 실행 전 죽음)이면 Linear가 Backlog에 고정된다.
  #   그러면 watchdog(in-flight=Linear started 기준)의 시야 밖 + 리퍼는 orphan 탭에 막혀 → 승인된 작업이 조용히 멈추는 blind spot.
  #   (오케스트레이터 팬아웃은 spawn 전 LLM이 In Progress로 옮기지만 resolve-gate·start-issue 경로는 그 단계가 없어 이 blind spot에 노출됐다.)
  #   여기서 결정론적으로 started로 올리면 dead-at-startup이어도 watchdog이 회수(heal)하거나 wedged로 표면화한다.
  #   워커·오케스트레이터의 자체 In Progress 이동은 멱등 backstop으로 남는다(이미 started면 linear-move가 no-op).
  #   best-effort — 탭은 이미 떴으므로 Linear 이동 실패는 치명적이지 않다(로그만; 워커 자체 이동이 커버). LINEAR_API_KEY는
  #   loops.env에서 source되지만 export 안 돼 node 자식에 명시 전달(watchdog/cleanup-terminal과 동일 패턴).
  if [[ -n "${LINEAR_API_KEY:-}" ]]; then
    if mvout="$(LINEAR_API_KEY="${LINEAR_API_KEY:-}" node "$ROOT/bin/linear-move.mjs" "$ID" started 2>&1)"; then
      echo "  → Linear: $mvout"
    else
      echo "[$(date '+%F %T')] WARN spawn $ID: linear-move started 실패 — $mvout (워커 자체 이동으로 커버, 무해)" >> "$STATE/dispatcher.log"
    fi
  fi
fi
ts=$(date '+%s')
print -r -- "{\"ts\":$ts,\"type\":\"worker\",\"event\":\"spawned\",\"issue\":\"$ID\",\"workspace\":\"$ref\",\"branch\":\"$BR\"}" >> "$STATE/runs.jsonl"
[[ -z "$ref" ]] && echo "[$(date '+%F %T')] WARN spawn $ID: cmux 응답=[$out] (detach된 컨텍스트?)" >> "$STATE/dispatcher.log"
echo "spawned $LOOP/$ID → worktree=$WT branch=$BR tab=$ref"
