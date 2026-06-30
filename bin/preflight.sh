#!/bin/zsh
# 전제도구 점검 + 가이드 설치 (install.sh 와 `loopctl doctor` 공용). loops.env 에 의존하지 않는다.
# 함수만 정의 — source 해서 loops_preflight <install|check> 로 호출.
#   install : 누락 도구마다 brew 설치를 y/N 으로 제안(기본 N), yes 면 실행. brew 없으면 brew부터 안내.
#   check   : 설치 안 하고 ✅/⚠️ 리포트만.
# 반환: 전역 LOOPS_MISSING 에 누락(필수) 도구 수. cmux 는 하드 전제(없으면 플랫폼 동작 불가).

# 도구의 실제 경로(없으면 ""). cmux/claude 는 PATH에 없으면 cmux.app 번들에서 찾는다(claude 는 cmux 번들 포함).
loops_tool_path() {
  case "$1" in
    cmux)   command -v cmux 2>/dev/null || { [[ -x /Applications/cmux.app/Contents/Resources/bin/cmux ]] && echo /Applications/cmux.app/Contents/Resources/bin/cmux; } ;;
    claude) [[ -x "$HOME/.local/bin/claude" ]] && { echo "$HOME/.local/bin/claude"; return; }
            command -v claude 2>/dev/null || { [[ -x /Applications/cmux.app/Contents/Resources/bin/claude ]] && echo /Applications/cmux.app/Contents/Resources/bin/claude; } ;;
    *)      command -v "$1" 2>/dev/null ;;
  esac
}

# 도구별 설치 명령(macOS/brew). claude 는 cmux 번들로 충당되거나 공식 인스톨러.
loops_install_cmd() {
  case "$1" in
    cmux)   echo "brew install --cask cmux" ;;
    gh)     echo "brew install gh" ;;
    node)   echo "brew install node" ;;
    git)    echo "xcode-select --install" ;;
    claude) echo "curl -fsSL https://claude.ai/install.sh | bash   # 또는 cmux 설치 시 번들 포함" ;;
    brew)   echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' ;;
  esac
}

# 한 도구 처리. mode=install 이면 누락 시 설치 제안. 설치/존재하면 0, 미해결 누락이면 1.
_loops_one() {
  local tool="$1" mode="$2" tp cmd   # ⚠️ zsh: 'path'는 PATH와 연동된 특수변수 → local로 쓰지 말 것
  tp="$(loops_tool_path "$tool")"
  if [[ -n "$tp" ]]; then printf '  ✅ %-7s %s\n' "$tool" "$tp"; return 0; fi
  cmd="$(loops_install_cmd "$tool")"
  printf '  ⚠️  %-7s 미설치 — 설치: %s\n' "$tool" "$cmd"
  [[ "$mode" != install ]] && return 1
  # install 모드: brew 기반 도구만 자동설치 제안(git/claude/brew 는 안내만 — 비-brew/대화형이라).
  case "$tool" in cmux|gh|node) ;; *) return 1 ;; esac
  [[ -z "$(command -v brew 2>/dev/null)" ]] && { echo "     (brew 없음 — 위 명령 전에 brew 먼저 설치)"; return 1; }
  printf '     지금 설치할까요? [y/N] '; local ans; read -r ans
  [[ "$ans" == [yY] ]] || { echo "     건너뜀 — 나중에: $cmd"; return 1; }
  eval "$cmd" && { [[ -n "$(loops_tool_path "$tool")" ]] && return 0 || return 1; } || return 1
}

# 메인. mode = install|check. 전역 LOOPS_MISSING 에 (필수) 누락 수.
loops_preflight() {
  local mode="${1:-check}" tool
  typeset -g LOOPS_MISSING=0
  echo "🔧 전제도구 점검 (mode=$mode):"
  # brew 는 설치 도우미 — 먼저 알린다(없어도 cmux 등은 수동 가능).
  [[ -z "$(command -v brew 2>/dev/null)" ]] && printf '  ⚠️  %-7s 미설치 — 설치: %s\n' brew "$(loops_install_cmd brew)"
  # 필수: git node claude gh cmux. cmux 가 핵심 전제.
  for tool in git node claude gh cmux; do
    _loops_one "$tool" "$mode" || LOOPS_MISSING=$((LOOPS_MISSING+1))
  done
  if (( LOOPS_MISSING )); then
    echo "  → 미해결 누락 ${LOOPS_MISSING}개. cmux 가 없으면 워커 spawn/대시보드가 동작하지 않습니다."
  else
    echo "  → 전제도구 모두 준비됨 ✅"
  fi
  return 0
}
