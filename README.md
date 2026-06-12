# Loops — 멀티 루프 자율 에이전트 플랫폼

한 줄 mission만 주면 **주기적으로 도는 자율 Claude Code 에이전트("loop")** 를 여러 개 돌린다. 각 loop은 자기 도메인의 작업을 발굴(orchestrator)하고 worker가 1건씩 구현→PR 한다. **머지는 사람이** 한다.

- **여러 loop**: SEO 강화 / dead-code 정리 / 웹뷰 리팩토링 … 엔진은 공통, mission만 다름.
- **AI 빌더**: "웹뷰 리팩토링 루프 만들어줘" → Claude가 mission + Linear 프로젝트 + config 자동 구성.
- **대시보드**(localhost): loop 목록·이슈·세션·스케줄·🔴개입필요·mission/config 편집·생성/삭제.
- **cmux 연동**: worker는 cmux 탭에서 라이브로 돌고, 대시보드에서 세션 열기/닫기.

## 전제
- macOS + **cmux** 터미널(소켓 제어), **claude** CLI, **gh**, **node**, **git**.
- 작업 대상 repo는 git worktree를 쓰므로 git repo여야 함.

## 설치
```sh
git clone <this-repo> ~/LTH/loops      # 위치 자유
cd ~/LTH/loops
./install.sh                            # 도구 자동탐지 → loops.env, 스킬 등록
# (선택) loops.env 의 DEFAULT_REPO 에 기본 repo 절대경로 지정
./loopctl dashboard                     # 대시보드 (cmux 패널)
./loopctl start                         # 디스패처
```

## loop 만들기
- **AI**: 대시보드 `+ 새 loop` → 한 줄 설명 → `Claude로 생성`. (또는 Claude Code 세션에서 "X 루프 만들어줘" — `create-loop` 스킬)
- **수동/예시**: `examples/<...>` 를 `loops/<id>/` 로 복사 후 `config.json`(repo·Linear projectId·worktree)·`mission.md` 수정.
- 생성된 loop은 `enabled:false` — 대시보드에서 mission 검토 후 `켜기`.

## 구조
```
bin/        엔진(공통): dispatch·run-once·spawn-orchestrator·spawn-worker·worker-run·render-prompt
            orchestrator-base.md·worker-base.md (← {{MISSION}}·config 치환) · loop-builder.md
dashboard-server.mjs / dashboard.html / loopctl
skills/create-loop/   create-loop 스킬 (install.sh가 ~/.claude/skills 로 symlink)
examples/   시작 템플릿 (placeholder)
loops/      (gitignore) 유저 loop 데이터: <id>/{config.json, mission.md, state/}
state/      (gitignore) 런타임
loops.env   (gitignore) 머신별 도구 경로 (install.sh 생성)
```

## 동작
`dispatch.sh`(cmux 패널) 가 각 loop의 스케줄대로 `orchestrator`(headless)를 발사 → orchestrator가 Linear ledger로 dedup하며 작업을 발굴, capacity만큼 `worker`(cmux 라이브 탭) fan-out → worker가 구현 → `/gbase:go`(polish+PR) → preview 검증 → **머지 안 함**. human-gate 이슈는 사람에게 남긴다.

> ⚠️ 경로는 `LOOPS_HOME`(스크립트 자기위치)·`loops.env`로 전부 동적. cmux/claude/gh/node가 다른 위치여도 `install.sh`가 맞춰준다. cmux 없는 환경은 미지원.
