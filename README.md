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
런타임   loopctl dashboard | start | stop | pause | resume | status | run-now <loop> | update
정리     loopctl worktrees <loop>           종료 이슈 잔여 worktree 진단(읽기전용)
         loopctl cleanup <loop> [--dry]     종료(Done/Canceled) worktree·탭·브랜치 정리
점검     loopctl doctor | help
감독     loopctl supervisor install         프로세스 감독자(launchd, 60s) — 죽은 디스패처 자동 재기동
         loopctl supervisor status|remove|run
원격     loopctl bot                        Telegram 봇 — 폰으로 push 알림 + 결정·취소·재실행
         loopctl remote                     Cloudflare 터널로 대시보드 외부 노출(basic-auth)
```
종료 상태(Linear `completed`/`canceled`) 이슈의 worktree·cmux 탭·브랜치는 오케스트레이터 run마다 **자동 정리**된다(대시보드 `🧹 정리` 버튼·위 `loopctl cleanup`으로 수동도 가능). 진행 중 worktree는 `claude --resume` 위해 보존.

**멈춤·유령 자가복구(≤60s, 결정론적).** `dispatch.sh`가 리퍼와 함께 두 루프를 돌린다 — in-flight 기준은 **Linear `started`**(항상 신선; snapshot에 의존 안 함), worker 탭 생존은 신뢰 가능(cmux 탭은 명령 종료 시 auto-close). 죽은 worker는 worktree가 남았으면 `heal-worker`가 그 자리에서 resume, worktree 없이 Linear만 `started`인 **유령**(in-flight를 붙잡아 cap을 막아 "루프가 조용히 멈추는" 주범)은 리퍼가 `linear-move`로 Backlog에 자동 복귀시켜 슬롯을 푼다. 탭은 살아있으나 화면이 5분 이상 정지한 worker는 **wedged**로 대시보드에 표면화(자동 kill은 안 함). N회 자가복구 실패는 🧟 stuck으로 사람에게 넘긴다. **머지·배포·force-push·Linear 취소는 어느 경로에서도 없음**(Backlog 이동만).

**플랫폼 자체의 셀프힐링(엔진이 죽었을 때).** 위 자가복구는 전부 `dispatch.sh` 안에 살아서, 디스패처 자신이 죽으면 다 같이 멈춘다 — 그 단일 장애점을 세 겹이 막는다. ① **supervisor**(`loopctl supervisor install`, launchd 60s): 죽은 디스패처를 재기동(대시보드 프록시 우선)하고, 디스패처는 자기 housekeeping으로 죽은 대시보드·봇 패널을 재기동한다. `loopctl stop`/대시보드 ⏹ 같은 **의도적 정지는 마커로 존중**(재기동 안 함). ② **crash-loop 가드**: 10분 내 3회 죽으면 — 직전 self-update가 원인으로 추정될 때 이전 커밋으로 **로컬 롤백**(force-push 아님)하고 그 커밋을 보류, 아니면 30분 백오프 + Telegram 알림. ③ **incident-bridge**: 오케스트레이터 사이클 연속 실패·supervisor escalate/롤백을 **엔진 자가개선 루프(loops-improve)의 Backlog 이슈로 자동 발제** → 워커가 고쳐서 main에 push → self-update → 디스패처 자가 재실행, 즉 "고장 → 자가 수정 → 자가 배포"가 닫힌다(핵심 실행경로 변경은 여전히 human-gate, 일 3건 캡·dedup). 알림은 봇 프로세스를 거치지 않는 Telegram 직송(봇도 감시 대상이므로).

### 폰에서 다 돌리기 — Telegram 봇
컴퓨터 앞에 없어도 폰 하나로 **전부** 된다 — 활성 loop·진행 중 작업을 보고, 사람 판단(human-gate)·PR 준비·CI 실패 push를 받고, 그 자리에서 결정·취소·정리·재실행·디스패처 제어까지. 엔진은 그대로(봇은 대시보드 `/api/status`·`/api/control`만 호출 — **머지/배포/force-push는 여전히 안 함, 머지는 사람**).

**셋업** (둘 중 하나):
- 대시보드 ⚙️ 설정 → `🤖 Telegram 원격 봇`에 BotFather 토큰 저장 → `▶ 봇 시작`
- 또는 CLI: `loops.env`에 `TELEGRAM_BOT_TOKEN=<토큰>` → `loopctl dashboard` 뜬 상태에서 `loopctl bot`

그다음 새 봇에게 **아무 메시지** → chat-id 자동 페어링(이후 그 대화로만 알림·명령이 오간다).

**쓰는 법 — 그냥 말로.** "지금 뭐 돌아가?", "myapp 한번 돌려", "GOD-8 그냥 진행해", "그거 취소해" 처럼 자연어로 보내면 봇이 `claude`(빠른 모델)로 의도를 파악해 실행한다(현재 상태를 컨텍스트로 줘서 loop/issue id를 알아서 고름). 파괴적 작업(취소·정리)은 바로 실행하지 않고 **확인 버튼**으로 되묻는다.

탭이 편하면 **`/menu`** — 디스패처(시작/정지/일시정지/잠자기방지) → 루프(⚡실행/🧹PR정리/⏸정지/🔀on-off/📋작업) → 작업(✅진행/🗑취소/🧹정리/🔗PR). 🔴 게이트 알림엔 **답장으로 결정**을 적어도 된다. 슬래시도 있음: `/status` `/gates` `/resolve <ISSUE> <결정>` `/cancel` `/runnow <loop>` `/dispatcher start|stop` `/awake on|off` … (`/help`). 인증은 페어링된 chat-id 잠금. (자연어는 메시지마다 `claude` 1회 호출 — 몇 초 지연·토큰 비용; 모델은 `loops.env`의 `LOOPS_BOT_AGENT_MODEL`로 변경)

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
| `claudeCmd` | orchestrator·worker가 쓰는 claude 실행 커맨드. 비우면 기본 `claude`. headless 인자는 엔진이 항상 덧붙임. 래퍼 커맨드도 가능(예: `claude-acct cloop` — 멀티계정 라운드로빈+리밋 핸드오프, dotfiles 제공) — 단 stdout을 오염시키지 말 것(headless 호출자는 `--output-format json`의 JSON 정확히 1개를 기대). 대시보드 ⚙️ 설정에서도 편집 가능. | `"claude"` / `"claude-acct cloop"` | 선택(기본 `claude`) |
| `delivery` | worker 배포 방식. `"pr"`=PR만 열고 머지는 사람(기본). `"direct"`=PR 없이 `prBase`에 직접 push 후 이슈를 바로 Done(개인/리뷰어 없는 repo용). **두 모드 모두 force-push 금지.** | `"pr"` / `"direct"` | 선택(기본 `"pr"`) |
| `branchPrefix` | worker 브랜치 이름 접두사. | `"loop-deadcode"` | 선택(기본 `loop-<id>`) |
| `orchestratorWorktree` | orchestrator가 도는 worktree 절대경로. | `"/Users/me/wt/loop-deadcode"` | 필수 |
| `worktreePrefix` | worker worktree 경로 접두사(이슈별 `-<slug>` 가 붙음). | `"/Users/me/wt/loop-deadcode"` | 필수 |
| `linearProjectId` | 작업 ledger로 쓰는 Linear 프로젝트 ID. | `"5d88…"` | 필수 |
| `linearProjectUrl` | 대시보드에서 여는 Linear 프로젝트 URL. | `"https://linear.app/…"` | 선택 |
| `linearLabel` | **하나의 Linear 프로젝트를 라벨로 나눠 여러 루프가 공유**할 때, 이 루프가 담당할 라벨. 지정 시 조회·발굴·fan-out·정리가 전부 이 라벨 이슈로 스코프되고, orchestrator가 새로 만드는 이슈에도 이 라벨을 붙인다. 비우면 프로젝트 전체 담당(기존 단독-프로젝트 동작). 예: 같은 프로젝트에서 `"Feature"`=PM 루프, `"Bug"`=버그 루프. | `"Bug"` | 선택(기본 없음=전체) |
| `maxWorkers` | 동시에 도는 worker 수 상한(capacity cap). | `2` | 선택(기본 `2`) |
| `backlogTarget` | 백로그 이슈 수가 **이 값 미만일 때만** orchestrator가 백로그를 보충. | `5` | 선택(기본 `5`) |
| `schedule.intervalSec` | orchestrator 발사 주기(초). 최소 60. | `10800` (3시간) | 선택(기본 `3600`) |
| `schedule.startAt` | 최초 발사 시각 `"HH:MM"`. `null`이면 즉시부터 주기 시작. | `null` / `"09:00"` | 선택(기본 `null`) |
| `enabled` | `false`면 스케줄 발사 안 함. 신규 loop은 `false`로 시작. | `false` | 선택(기본 `true`) |
| `verify` | `true`면 worker가 PR을 연 직후 **별도 fresh-context 검증자**(maker/checker 분리)가 이슈 수용 기준으로 PR을 채점해 verdict(✅/⚠️/❌)를 PR·Linear에 코멘트. ❌면 재작업 자동 트리거. 검증자는 Edit/Write가 구조적으로 차단됨(코드 못 고침). pr 모드 전용. | `true` | 선택(기본 `false`) |
| `validate` | `true`면 매 사이클 후 **미판정 human-gate 제안 이슈**마다 별도 fresh-context **제안 검증자**(🧪 validator)가 근거를 실물 재현·심문(수요 진단·전제 도전·축소안 1개)해 판정(🟢 strengthen/🟡 narrow/🔴 reject)을 Linear 코멘트 + 게이트 UI(대시보드·Telegram)에 병기. 제안형(PM) 루프용 — 승인/기각은 여전히 사람. Edit/Write 구조 차단. `vision.md`가 있으면 정렬 기준으로 주입. | `true` | 선택(기본 `false`) |
| `budget.dailyUsd` | 일일 비용 소프트 캡(USD). 오늘 `costs.jsonl` 합계가 캡 이상이면 dispatcher가 **다음 사이클만 skip**(진행 중 worker는 안 죽임), 자정 리셋 후 자동 재개. 측정 범위=headless 사이클(오케스트레이터·retro·검증자·validator). | `5` | 선택(기본 없음=무제한) |
| `on.ciFailure` | `true`면 `prBase` 브랜치에 **새 CI 실패** 등장 시 interval을 기다리지 않고 즉시 사이클 발사. | `true` | 선택(기본 `false`) |
| `on.prReview` | `true`면 이 루프의 열린 PR에 **새 사람 리뷰** 제출 시 즉시 사이클 발사(리뷰 반영 지연 단축). | `true` | 선택(기본 `false`) |
| `on.linearNew` | `true`면 Linear 프로젝트에 **새 Backlog 이슈** 등장 시 즉시 사이클 발사(Linear에서 이슈만 만들면 곧 착수). `linearLabel` 있으면 그 라벨의 신규 이슈만. | `true` | 선택(기본 `false`) |
| `drain` | **"쌓이면 계속 처리, 비면 조용" 모드.** 지정 시 스케줄 발사가 값싼 Linear 체크로 게이트된다 — **드레인 가능** backlog(라벨 스코프 · run-log/human-gate 이슈 제외)>0 & in-flight<cap **또는** 발굴 주기(`drain.discoverySec`, 기본 600초) 도래일 때만 LLM 사이클을 태우고, 아니면 스킵(idle 토큰비용 0). `intervalSec`을 짧게(예 120) + `on.linearNew:true`와 함께 쓰면 새 이슈는 즉시 착수하고 빈 슬롯은 곧 재충전되며, 할 일 없을 땐 발굴 주기로만 폴링. 발굴을 MCP로 하는 버그 루프처럼 "빠르게 반응하되 idle 비용은 없게"에 적합. | `true` / `{ "discoverySec": 600 }` | 선택(기본 없음=매 interval 발사) |
| `retro.everyCycles` | 정규 사이클 N개마다 **retro 분석 run**(LOOP_MODE=retro)을 자동 발사해 `state/learnings.md`(교훈)를 갱신 — 머지/거절/리뷰/human-gate 판례에서 패턴을 추출해 다음 run 프롬프트에 주입. 0/미설정=비활성. | `20` | 선택(기본 없음=비활성) |
| `product` | 이 루프가 속한 **제품**(`products/<id>/product.json`) 링크. 지정 시 `repo`·`baseRef`·`prBase`·`claudeCmd`·`linearProjectId`·`linearProjectUrl`을 제품에서 상속(루프 값이 항상 우선, 이 화이트리스트만). 아래 [제품 계층](#제품product-계층) 참고. | `"myapp"` | 선택 |

### 제품(product) 계층
**제품 1개 = Linear 프로젝트 1개 = 루프 여러 개**(예: PM 루프 + 버그 루프)로 관리할 때 쓰는 상위 단위. `products/<id>/product.json`(gitignored)에 제품 공통 설정을 두고, 각 루프는 `"product": "<id>"`로 연결해 공통 필드를 상속받는다(루프별 설정 — 스케줄·cap·라벨·worktree — 은 루프 config에 남는다).

```jsonc
// products/myapp/product.json
{
  "id": "myapp", "name": "Petstagram (솜이랑)",
  "linearProjectId": "…", "linearProjectUrl": "…",           // 공유 ledger (= 이 제품)
  "repo": "/Users/me/myapp", "baseRef": "origin/main", "prBase": "main",
  "claudeCmd": "claude-acct c2",                              // MCP 붙은 계정 (루프가 오버라이드 가능)
  "triage": {                                                 // 상위 분류기 (선택)
    "routes": { "Bug": "결함 — 코드 수정으로 고침", "Feature": "새 기능·개선 — PM 검토 대상" },
    "model": "haiku", "maxPerPass": 5
  }
}
```

- **파티션**: 각 루프가 `linearLabel`로 프로젝트를 나눈다 — 예: `"Feature"`=PM 루프, `"Bug"`=버그 루프(drain).
- **triage(상위 분류기)**: 사람이 **라벨 없이 그냥 쌓은** 이슈를 dispatcher가 ≤60s 내 감지, 값싼 headless 분류(LLM은 라벨 *선택*만 — Linear 부착·코멘트는 결정론 스크립트 `bin/linear-label.mjs`, routes에 없는 라벨은 거부)로 라벨을 붙인다. 붙는 순간 그 라벨 루프의 `on.linearNew`가 잡아 **즉시 사이클** — "이슈만 쌓으면 알아서 분류돼 처리"가 이 경로다. 이슈당 3회 실패 시 "라벨 직접 지정" 코멘트를 남기고 포기(무한 재시도 없음). dedup은 Linear 자신(라벨 부재=미분류)이라 사이드 스테이트 최소(`products/<id>/state/triage.json`은 attempts만).
- 기존 이슈가 있는 프로젝트를 나눌 땐 **먼저 이슈에 라벨을 붙이고**(1회 마이그레이션) 라벨 필터를 켠다.

## 구조
```
bin/        엔진(공통):
            · 코어 파이프라인: dispatch·run-once·spawn-orchestrator·spawn-worker·worker-run·render-prompt (·_common 공통 source·preflight)
            · 프롬프트 템플릿: orchestrator-base.md·worker-base.md·verifier-base.md·validator-base.md·retro-base.md (← {{MISSION}}·{{VISION}}·{{LEARNINGS}}·config 치환) · loop-builder.md
            · 피드백 루프: rework-worker(리뷰/verdict 재작업 스폰) · spawn-verifier+verifier-run(maker/checker 검증) · spawn-validator+validator-run(제안 심문 → 게이트 병기) · event-poll(CI실패·리뷰·Linear신규 이벤트 트리거) · record-cost(사이클 비용 캡처)
            · 신뢰성/정리(결정론적): watchdog(spawn-liveness)·heal-worker·cleanup-terminal(reaper)·cleanup-issue·cleanup-loop
            · Linear ledger·빌드: linear-move·linear-states · build-loop
            · notify-bot.mjs  Telegram 원격 브리지 (loopctl bot) · loops-mcp.mjs  봇 에이전트용 제어 MCP 서버(안전 면만)
dashboard-server.mjs / dashboard.html / loopctl
vendor/     Oat UI 정적 자산 oat.min.{css,js} (유일한 no-build 예외 · 핀 고정)
skills/create-loop/   create-loop 스킬 (install.sh가 ~/.claude/skills 로 symlink)
examples/   시작 템플릿 (placeholder)
loops/      (gitignore) 유저 loop 데이터: <id>/{config.json, mission.md, state/}
state/      (gitignore) 런타임
loops.env   (gitignore) 머신별 도구 경로 (install.sh 생성)
```

## 동작
`dispatch.sh`(cmux 패널) 가 각 loop의 스케줄대로 `orchestrator`(headless)를 발사 → orchestrator가 Linear ledger로 dedup하며 작업을 발굴, capacity만큼 `worker`(cmux 라이브 탭) fan-out → worker가 구현 → `/gbase:go`(polish+PR) → preview 검증 → **그 세션이 `/gbase:monitor`로 머지될 때까지 상주**하며 CI 실패·리뷰 코멘트를 바로 반영(무인 규칙: 모호하면 코멘트로 사람에게 표면화, **머지·approve·force-push는 안 함**). human-gate 이슈는 사람에게 남긴다. — 단 `delivery:"direct"` 루프(config.json)는 PR 대신 `prBase`로 직접 push하고 이슈를 바로 **Done**으로 옮긴다(In Review 없음). 어느 모드든 머지·force-push는 사람 게이트·금지 원칙을 그대로 유지한다.

> ⚠️ 경로는 `LOOPS_HOME`(스크립트 자기위치)·`loops.env`로 전부 동적. cmux/claude/gh/node가 다른 위치여도 `install.sh`가 맞춰준다. cmux 없는 환경은 미지원.
