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

slug="$(echo "$ID" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//')"
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
fi
ts=$(date '+%s')
print -r -- "{\"ts\":$ts,\"type\":\"worker\",\"event\":\"spawned\",\"issue\":\"$ID\",\"workspace\":\"$ref\",\"branch\":\"$BR\"}" >> "$STATE/runs.jsonl"
[[ -z "$ref" ]] && echo "[$(date '+%F %T')] WARN spawn $ID: cmux 응답=[$out] (detach된 컨텍스트?)" >> "$STATE/dispatcher.log"
echo "spawned $LOOP/$ID → worktree=$WT branch=$BR tab=$ref"
