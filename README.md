# Loops — 멀티 루프 자율 에이전트 플랫폼

한 줄 mission만 주면 **주기적으로 도는 자율 Claude Code 에이전트("loop")** 를 여러 개 돌린다. 각 loop은 자기 도메인의 작업을 발굴(orchestrator)하고 worker가 1건씩 구현→PR 한다. **머지는 사람이** 한다.

- **여러 loop**: SEO 강화 / dead-code 정리 / 웹뷰 리팩토링 … 엔진은 공통, mission만 다름.
- **AI 빌더**: "웹뷰 리팩토링 루프 만들어줘" → Claude가 mission + Linear 프로젝트 + config 자동 구성.
- **대시보드**(localhost): loop 목록·이슈·세션·스케줄·🔴개입필요·mission/config 편집·생성/삭제.
- **cmux 연동**: worker는 cmux 탭에서 라이브로 돌고, 대시보드에서 세션 열기/닫기.

## 전제
macOS. `./install.sh`가 아래 도구를 점검하고 누락 시 brew 설치를 제안한다(`loopctl doctor`로 언제든 재점검).

| 도구 | 용도 | 설치 |
|---|---|---|
| **cmux** | 워커 탭 spawn·대시보드 패널 (하드 전제) | `brew install --cask cmux` |
| **claude** | 워커/오케스트레이터 본체 | cmux 번들 포함 / `curl -fsSL https://claude.ai/install.sh \| bash` |
| **gh** | PR 조회·생성 | `brew install gh` |
| **node** | 대시보드·프롬프트 렌더 | `brew install node` |
| **git** | worktree | `xcode-select --install` |

작업 대상 repo는 git worktree를 쓰므로 git repo여야 함. cmux 없는 환경은 미지원.

## 설치 / 온보딩
```sh
git clone <this-repo> ~/LTH/loops      # 위치 자유
cd ~/LTH/loops
./install.sh                            # 전제도구 점검·설치 제안 → loops.env, 스킬 등록, loopctl 전역 등록
loopctl help                            # 무엇을 할 수 있는지
loopctl doctor                          # 설치·설정·런타임 점검
loopctl dashboard                       # 대시보드 (cmux 패널)
loopctl start                           # 디스패처
```
`install.sh`는 `loopctl`을 `~/.local/bin`에 심볼릭한다 → **어느 디렉토리에서나** `loopctl …` 실행(앞에 `./` 불필요). Linear 키는 대시보드 ⚙️ 에서 입력(`loops.env`에 저장, gitignore). (선택) `loops.env`의 `DEFAULT_REPO`에 기본 repo 절대경로 지정.

### 명령
```
런타임   loopctl dashboard | start | stop | pause | resume | status | run-now <loop>
정리     loopctl worktrees <loop>           종료 이슈 잔여 worktree 진단(읽기전용)
         loopctl cleanup <loop> [--dry]     종료(Done/Canceled) worktree·탭·브랜치 정리
점검     loopctl doctor | help
원격     loopctl remote                     Cloudflare 터널로 대시보드 외부 노출(basic-auth)
```
종료 상태(Linear `completed`/`canceled`) 이슈의 worktree·cmux 탭·브랜치는 오케스트레이터 run마다 **자동 정리**된다(대시보드 `🧹 정리` 버튼·위 `loopctl cleanup`으로 수동도 가능). 진행 중 worktree는 `claude --resume` 위해 보존.

## loop 만들기
- **AI**: 대시보드 `+ 새 loop` → 한 줄 설명 → `Claude로 생성`. (또는 Claude Code 세션에서 "X 루프 만들어줘" — `create-loop` 스킬)
- **수동/예시**: `examples/<...>` 를 `loops/<id>/` 로 복사 후 `config.json`(아래 [config.json 필드](#configjson-필드) 표 참고)·`mission.md` 수정.
- 생성된 loop은 `enabled:false` — 대시보드에서 mission 검토 후 `켜기`.

### config.json 필드
예제(`examples/<...>/config.json`)를 복사해 수동으로 loop을 만들 때 쓰는 필드. 엔진은 `bin/render-prompt.mjs`(프롬프트 치환)·`bin/dispatch.sh`(스케줄)·`bin/spawn-worker.sh`(worktree)가 읽는다.

| 필드 | 의미 | 예시값 | 필수 |
|---|---|---|---|
| `id` | loop 식별자. `loops/<id>/` 디렉터리명과 일치해야 함. | `"deadcode"` | 필수 |
| `name` | 대시보드에 표시되는 이름. | `"Dead Code"` | 선택(기본 `id`) |
| `emoji` | 대시보드 표시 이모지. | `"🧹"` | 선택(기본 `🔁`) |
| `repo` | 작업 대상 repo의 **절대경로**. git repo여야 함. | `"/Users/me/proj"` | 필수 |
| `baseRef` | worktree·PR diff의 기준 ref. | `"origin/develop"` | 선택(기본 `origin/develop`) |
| `prBase` | PR을 머지할 대상 브랜치. | `"develop"` | 선택(기본 `develop`) |
| `branchPrefix` | worker 브랜치 이름 접두사. | `"loop-deadcode"` | 선택(기본 `loop-<id>`) |
| `orchestratorWorktree` | orchestrator가 도는 worktree 절대경로. | `"/Users/me/wt/loop-deadcode"` | 필수 |
| `worktreePrefix` | worker worktree 경로 접두사(이슈별 `-<slug>` 가 붙음). | `"/Users/me/wt/loop-deadcode"` | 필수 |
| `linearProjectId` | 작업 ledger로 쓰는 Linear 프로젝트 ID. | `"5d88…"` | 필수 |
| `linearProjectUrl` | 대시보드에서 여는 Linear 프로젝트 URL. | `"https://linear.app/…"` | 선택 |
| `maxWorkers` | 동시에 도는 worker 수 상한(capacity cap). | `2` | 선택(기본 `2`) |
| `backlogTarget` | 백로그 이슈 수가 **이 값 미만일 때만** orchestrator가 백로그를 보충. | `5` | 선택(기본 `5`) |
| `schedule.intervalSec` | orchestrator 발사 주기(초). 최소 60. | `10800` (3시간) | 선택(기본 `3600`) |
| `schedule.startAt` | 최초 발사 시각 `"HH:MM"`. `null`이면 즉시부터 주기 시작. | `null` / `"09:00"` | 선택(기본 `null`) |
| `enabled` | `false`면 스케줄 발사 안 함. 신규 loop은 `false`로 시작. | `false` | 선택(기본 `true`) |

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
