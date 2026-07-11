#!/bin/zsh
# cmux 패널 spawn의 단일 원천 — 워크스페이스 "생성"이 아니라 커맨드 "실행 시작"까지 책임진다.
#
# ⚠️ cmux 함정(실측): 워크스페이스=탭이고 --command 는 "텍스트+엔터 전송"이라, 렌더되지 않은(백그라운드/비포커스)
# 탭은 PTY가 없어 커맨드가 실행되지 않고 큐에 잠들었다가 **한참 뒤 렌더되는 순간 지연 실행**된다 — 죽은 줄 알았던
# 디스패처가 나중에 살아나 이중 기동되는 사고의 근원. cmux PTY 안(대화형 터미널·대시보드 패널)에서 호출하면 즉시
# materialize되지만, launchd·외부 셸에서는 안 된다.
# → 생성 후 read-screen으로 materialize를 검증하고, 안 되면 select → 앱 activate → 새 창 이동+포커스로 격상.
#   끝내 실패하면 워크스페이스를 **닫아서**(큐째 폐기) 지연 실행을 원천 차단하고 비0 종료한다(무소음 실패 금지).
#
# 예외 — SPAWN_PANEL_QUEUE_OK=1 (디스패처 전용): materialize 최종 실패 시 폐기 대신 타이틀에 " ⏳"를 붙여
#   큐에 남기고 exit 2. cmux가 백그라운드인 동안엔 어떤 새 탭도 렌더되지 않으므로(실측: activate/새창 격상도 무력)
#   폐기-재시도는 영원히 수렴하지 않는다 — 대신 큐 탭 1개를 남겨 사용자가 cmux를 전면화하는 순간 자동 발화시킨다.
#   이 지연 발화가 안전한 패널은 이중기동 가드(dispatch.sh pidfile alive-check)가 있는 디스패처뿐 — 워커·verifier 등에 쓰지 말 것.
#   ⏳ 마커 = "의도된 큐 탭"과 "cmux 재시작 복원 껍데기 셸"(둘 다 렌더 전 read-screen 실패)을 구분하는 신원.
#   supervisor/dashboard의 재사용·sweep 판정이 이 마커에 걸려 있고, dispatch.sh가 기동하며 마커를 벗긴다.
#
# usage: spawn-panel.sh <cwd> <command> [title]
# stdout: workspace ref (성공/큐 잔류 시). exit 0 = 커맨드 실행 시작 확인 · 1 = 실패(stderr 사유, 워크스페이스 폐기됨)
#         · 2 = SPAWN_PANEL_QUEUE_OK=1 하에 큐 잔류(⏳ — cmux 전면화 시 발화 예정).
set -u
source "${0:A:h}/_common.sh"
CWD="${1:?usage: spawn-panel.sh <cwd> <command> [title]}"
CMD="${2:?command 필요}"
TITLE="${3:-}"
CMUX="$CMUX_BIN"
[[ -z "$CMUX" ]] && { echo "spawn-panel: cmux 없음(CMUX_BIN)" >&2; exit 1; }

out="$("$CMUX" new-workspace --cwd "$CWD" --command "$CMD" 2>&1)"
ref="$(print -r -- "$out" | grep -oE 'workspace:[0-9]+' | head -1)"
[[ -z "$ref" ]] && { echo "spawn-panel: new-workspace 실패 — $out" >&2; exit 1; }
[[ -n "$TITLE" ]] && "$CMUX" rename-workspace --workspace "$ref" "$TITLE" >/dev/null 2>&1

mat(){ "$CMUX" read-screen --workspace "$ref" --lines 1 >/dev/null 2>&1; }
wait_mat(){ repeat "$1" { mat && return 0; sleep 0.5 }; return 1; }
activate(){ osascript -e "tell application id \"${CMUX_BUNDLE_ID:-com.cmuxterm.app}\" to activate" >/dev/null 2>&1; }

if ! wait_mat 4; then   # ~2s — cmux PTY 컨텍스트(대화형)면 이 안에 뜬다
  # 1차 격상: 활성 탭으로 선택 + 앱 전면화(백그라운드 탭은 렌더 안 됨 → 선택이 렌더를 강제)
  "$CMUX" select-workspace --workspace "$ref" >/dev/null 2>&1
  activate
  if ! wait_mat 4; then
    # 2차 격상: 새 창(즉시 렌더됨)으로 이동 + 포커스 — 기존 창이 다른 Space/최소화 상태여도 통한다
    wid="$("$CMUX" new-window 2>/dev/null | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
    if [[ -n "$wid" ]]; then
      "$CMUX" move-workspace-to-window --workspace "$ref" --window "$wid" >/dev/null 2>&1
      "$CMUX" focus-window --window "$wid" >/dev/null 2>&1
      activate
    fi
    if ! wait_mat 6; then
      if [[ "${SPAWN_PANEL_QUEUE_OK:-0}" == 1 ]]; then
        # 큐 잔류(헤더 참조): 폐기하지 않고 ⏳ 마킹 — cmux 전면화 시 자동 발화. 이중기동 가드 있는 패널 전용.
        [[ -n "$TITLE" ]] && "$CMUX" rename-workspace --workspace "$ref" "$TITLE ⏳" >/dev/null 2>&1
        echo "spawn-panel: PTY materialize 실패(${TITLE:-$CMD}) — 큐 잔류(⏳ $ref), cmux 전면화 시 자동 시작" >&2
        print -r -- "$ref"
        exit 2
      fi
      "$CMUX" close-workspace --workspace "$ref" >/dev/null 2>&1
      echo "spawn-panel: PTY materialize 실패(${TITLE:-$CMD}) — 지연 실행 방지 위해 워크스페이스 폐기" >&2
      exit 1
    fi
  fi
fi
print -r -- "$ref"
