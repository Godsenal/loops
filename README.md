# Loops

**한 줄 mission만 주면, 주기적으로 도는 자율 Claude Code 에이전트를 여러 개 돌리는 플랫폼.**

각 "loop"은 자기 도메인(SEO 강화 / dead-code 정리 / 버그 처리 / 웹뷰 리팩토링 …)의 작업을 스스로 발굴하고, worker가 1건씩 구현해 PR을 연다. **머지는 사람이 한다** — 엔진은 절대 merge·deploy·force-push 하지 않는다.

엔진은 공통이고, loop끼리는 `mission.md`(무엇을·어떻게 발굴할지)와 `config.json`(repo·Linear·스케줄·동시성)만 다르다.

```
        ┌─────────────────────────  당신은 여기만  ─────────────────────────┐
        │  mission 작성 · 🔴 human-gate 판단 · PR 리뷰 · 머지                  │
        └───────────────────────────────────────────────────────────────────┘
                                        │
   dispatcher ──(스케줄)──▶ orchestrator ──(발굴·fan-out)──▶ worker ──▶ PR
   (cmux 패널)              (헤드리스)      Linear ledger로 dedup   (cmux 라이브 탭)
        ▲                                                              │
        └──────────  watchdog·reaper·supervisor 자가복구  ◀────────────┘
```

- **여러 loop** — 엔진은 하나, mission만 다르게 여러 도메인을 동시에.
- **AI 빌더** — "웹뷰 리팩토링 루프 만들어줘" 한 줄 → Claude가 mission·Linear 프로젝트·config 자동 구성.
- **대시보드**(localhost) — loop·이슈·세션·스케줄·🔴개입필요를 한눈에, mission/config 편집, 생성·삭제.
- **폰에서 전부** — Telegram 봇(자연어 제어) + Tailscale 원격 대시보드(PWA·웹푸시).
- **자가복구** — 멈춘 worker·죽은 엔진을 ≤60초에 결정론적으로 되살린다.
- **의존성 0** — `zsh` + Node 빌트인. 빌드·테스트·`npm install` 없음(대시보드 UI의 Oat CSS 1개만 vendored).

---

## 전제

**macOS**. `./install.sh`가 아래 도구를 점검하고, 없으면 brew 설치를 제안한다(`loopctl doctor`로 언제든 재점검).

| 도구 | 용도 | 설치 |
|---|---|---|
| **cmux** | worker 탭 spawn·대시보드 패널 (하드 전제) | `brew install --cask cmux` |
| **claude** | worker·orchestrator 본체 | cmux 번들 포함 / `curl -fsSL https://claude.ai/install.sh \| bash` |
| **gh** | PR 조회·생성 | `brew install gh` |
| **node** | 대시보드·프롬프트 렌더 | `brew install node` |
| **git** | worktree | `xcode-select --install` |

작업 대상 repo는 git worktree를 쓰므로 git repo여야 한다. **cmux 없는 환경은 미지원** — 디스패처·대시보드는 cmux 패널에서 돌고, worker는 cmux 탭으로 뜬다.

## 설치

```sh
git clone <this-repo> ~/loops      # 위치 자유
cd ~/loops
./install.sh                       # 전제도구 점검·설치 → loops.env 생성, 스킬·loopctl 전역 등록
loopctl doctor                     # 설치·설정·런타임 점검
loopctl dashboard                  # 대시보드 (cmux 패널)
loopctl start                      # 디스패처 시작
```

`install.sh`는 `loopctl`을 `~/.local/bin`에 심볼릭한다 → **어느 디렉토리에서나** `loopctl …` 실행(앞에 `./` 불필요). Linear API 키는 대시보드 **⚙️ 설정**에서 입력하면 `loops.env`(gitignore)에 저장된다 — 백로그 발굴·정리 신호에 필요. (선택) `loops.env`의 `DEFAULT_REPO`에 기본 repo 절대경로를 넣으면 AI 빌더가 편하다.

## 30초 개념

- **loop** = 하나의 도메인을 맡는 자율 에이전트. `loops/<id>/`에 `mission.md` + `config.json`이 전부.
- **orchestrator** = loop의 두뇌. 스케줄마다 헤드리스로 떠서 Linear에서 할 일을 발굴하고 worker를 뿌린다.
- **worker** = 실행자. 이슈 1건을 cmux 라이브 탭에서 구현 → `/gbase:go`(polish + PR) → PR이 머지·종료될 때까지 `/gbase:monitor`로 상주하며 CI 실패·리뷰 코멘트를 반영한다. **머지·approve·force-push는 안 한다.**
- **Linear 프로젝트 = 상태 기계.** 모든 run 간 연속성은 메모리가 아니라 Linear ledger에 산다: `Backlog → In Progress → In Review → Done/Canceled`. 그래서 매 run이 빈 컨텍스트에서 시작해도 중복 없이 이어진다.
- **human-gate** = 사람 판단이 필요한 이슈. worker가 구현하지 않고 대시보드에 🔴로 올라온다. 결정은 `state/decisions/<이슈>.md`에 기록돼 다음 worker에게 권위 있는 지시로 주입된다.

## loop 만들기

1. **AI 빌더 (권장)** — 대시보드 `+ 새 loop` → 한 줄 설명 → `Claude로 생성`. (또는 Claude Code 세션에서 "X 루프 만들어줘" — `create-loop` 스킬.) mission·Linear 프로젝트·config를 자동 생성한다.
2. **수동** — `examples/<...>/`를 `loops/<id>/`로 복사하고 `config.json`·`mission.md`를 채운다.

생성된 loop은 항상 **`enabled:false`** 로 시작한다 — 대시보드에서 mission을 검토하고 `켜기`. `examples/`에 `deadcode`(정리형)·`seo`(감사형)·`bug-drain`(드레인형) 시작 템플릿이 있다.

### `config.json` — 필수 필드

| 필드 | 의미 | 예시 |
|---|---|---|
| `id` | loop 식별자. `loops/<id>/` 디렉터리명과 일치. | `"deadcode"` |
| `repo` | 작업 대상 repo **절대경로** (git repo). | `"/path/to/app"` |
| `orchestratorWorktree` | orchestrator가 도는 worktree 절대경로. | `"/path/to/wt/loop-deadcode"` |
| `worktreePrefix` | worker worktree 경로 접두사(이슈별 `-<slug>` 부착). | `"/path/to/wt/loop-deadcode"` |
| `linearProjectId` | 작업 ledger로 쓰는 Linear 프로젝트 ID. | `"5d88…"` |

### `config.json` — 선택 필드

<details>
<summary><b>기본 동작</b> — 이름·스케줄·동시성·배포 방식</summary>

| 필드 | 의미 | 기본 |
|---|---|---|
| `name` / `emoji` | 대시보드 표시명·이모지. | `id` / `🔁` |
| `baseRef` / `prBase` | worktree·PR diff 기준 ref / 머지 대상 브랜치. | `origin/develop` / `develop` |
| `branchPrefix` | worker 브랜치 접두사. | `loop-<id>` |
| `linearProjectUrl` | 대시보드에서 여는 Linear URL. | 없음 |
| `maxWorkers` | 동시 worker 수 상한(capacity cap). | `2` |
| `backlogTarget` | 백로그가 이 값 **미만일 때만** 보충 발굴. | `5` |
| `schedule.intervalSec` | orchestrator 발사 주기(초, 최소 60). | `3600` |
| `schedule.startAt` | 최초 발사 시각 `"HH:MM"`. `null`=즉시. | `null` |
| `enabled` | `false`면 발사 안 함. 신규 loop은 `false`. | `true` |
| `claudeCmd` | claude 실행 커맨드(래퍼 허용, 아래 주). 헤드리스 인자는 엔진이 붙임. | `claude` |
| `delivery` | `"pr"`=PR만 열고 머지는 사람. `"direct"`=PR 없이 `prBase`에 직접 push 후 Done(리뷰어 없는 개인 repo용). **둘 다 force-push 금지.** | `"pr"` |

</details>

<details>
<summary><b>피드백 레이어</b> — 검증·심문·학습·비용 (전부 opt-in)</summary>

| 필드 | 의미 | 기본 |
|---|---|---|
| `verify` | PR 직후 **별도 fresh-context 검증자**(maker/checker 분리)가 수용 기준으로 채점 → verdict(✅/⚠️/❌)를 PR·Linear에 코멘트, ❌면 재작업 자동 트리거. 검증자는 Edit/Write가 **구조적으로 차단**됨(코드 못 고침). pr 모드 전용. | `false` |
| `validate` | 매 사이클 후 미판정 human-gate 제안마다 **제안 검증자**(🧪)가 근거를 실물 재현·심문(수요 진단·전제 도전·축소안 제시)해 판정(🟢/🟡/🔴)을 게이트 UI에 병기. 제안형(PM) 루프용 — 승인·기각은 여전히 사람. | `false` |
| `retro.everyCycles` | N 사이클마다 **retro run**이 머지·거절·리뷰·게이트 판례에서 교훈을 뽑아 `state/learnings.md` 갱신 → 다음 프롬프트에 주입. `mission.md`는 절대 안 건드림. | 없음 |
| `budget.dailyUsd` | 일일 비용 소프트 캡(USD). 오늘 헤드리스 사이클 합계가 캡 이상이면 다음 사이클만 skip(진행 중 worker는 유지), 자정 리셋. | 없음 |

</details>

<details>
<summary><b>반응성 & 스케일</b> — 이벤트 트리거·드레인·라벨·제품</summary>

| 필드 | 의미 | 기본 |
|---|---|---|
| `on.ciFailure` | `prBase`에 **새 CI 실패** 등장 시 interval 무시하고 즉시 발사. | `false` |
| `on.prReview` | 열린 PR에 **새 사람 리뷰** 제출 시 즉시 발사. | `false` |
| `on.linearNew` | Linear에 **새 Backlog 이슈** 등장 시 즉시 발사. | `false` |
| `drain` | **"쌓이면 계속, 비면 조용" 모드.** 발사가 값싼 Linear 체크로 게이트됨 — 드레인 가능 backlog>0 & in-flight<cap **또는** 발굴 주기(`drain.discoverySec`, 기본 600s) 도래일 때만 LLM 사이클, 아니면 스킵(idle 토큰비용 0). `intervalSec`을 짧게 + `on.linearNew`와 함께 쓰면 "빠르게 반응하되 idle 비용 0". | 없음 |
| `linearLabel` | **하나의 Linear 프로젝트를 라벨로 나눠 여러 루프가 공유**. 지정 시 조회·발굴·fan-out·정리가 이 라벨로 스코프되고 새 이슈에도 부착. 예: `"Feature"`=PM 루프, `"Bug"`=버그 루프. | 없음=전체 |
| `product` | 이 루프가 속한 **제품**(`products/<id>/product.json`) 링크 — `repo`·`baseRef`·`prBase`·`claudeCmd`·`linearProjectId`를 상속(루프 값 우선). [제품 계층](#제품-계층) 참고. | 없음 |

</details>

> **`claudeCmd` 래퍼 계약**: `claude` 자리에 래퍼를 넣을 수 있다(예: 멀티계정 라운드로빈 + 리밋 핸드오프 래퍼). 단 stdout을 오염시키면 안 된다 — 헤드리스 호출자는 `--output-format json`의 JSON을 정확히 1개 기대한다. 값을 소비하는 새 플래그를 엔진 claude 호출부에 추가하면 래퍼의 인자 파서도 맞춰야 한다.

### 제품 계층

**제품 1개 = Linear 프로젝트 1개 = 루프 여러 개**(예: PM 루프 + 버그 루프)로 묶는 상위 단위. `products/<id>/product.json`(gitignore)에 공통 설정을 두고 각 루프가 `"product": "<id>"`로 상속한다.

- **파티션** — 각 루프가 `linearLabel`로 프로젝트를 나눈다.
- **triage(상위 분류기)** — 사람이 라벨 없이 그냥 쌓은 이슈를 dispatcher가 ≤60s에 감지, 값싼 헤드리스 분류로 라벨을 붙인다(LLM은 라벨 *선택*만, 부착·거부는 결정론 스크립트). 붙는 순간 해당 라벨 루프의 `on.linearNew`가 잡아 즉시 착수 — "이슈만 쌓으면 알아서 분류돼 처리". 이슈당 3회 실패 시 "라벨 직접 지정" 코멘트 후 포기.

## 폰에서 전부

### Telegram 봇 — 자연어 원격 제어

컴퓨터 앞에 없어도 폰 하나로 활성 loop·진행 작업을 보고, human-gate·PR·CI 실패 push를 받고, 그 자리에서 결정·취소·재실행까지 된다.

**셋업**: 대시보드 ⚙️ → `🤖 Telegram 봇`에 [@BotFather](https://t.me/BotFather) 토큰 저장 → `▶ 봇 시작` (또는 `loops.env`에 `TELEGRAM_BOT_TOKEN=` 후 `loopctl bot`). 그다음 봇에게 **아무 메시지** → chat-id 자동 페어링.

**쓰는 법**: 그냥 말로. *"지금 뭐 돌아가?"*, *"myapp 한번 돌려"*, *"CI 왜 깨져? 원인 보고 고칠 태스크 만들어"* — 봇이 `claude` 헤드리스 에이전트로 의도를 파악해 여러 스텝을 밟는다. 에이전트의 도구는 Loops 제어 MCP뿐이라(`--disallowedTools`로 Bash/Edit/Write 차단) **구조적으로 merge·deploy·force-push가 불가능**하다. 파괴적 작업(취소·정리)은 봇이 직접 하지 않고 **확인 버튼**으로 되묻는다. 탭 UI(`/menu`)와 슬래시(`/status` `/gates` `/resolve` `/runnow` …)도 있다.

### Tailscale 원격 대시보드 + 웹푸시 (PWA)

봇이 아니라 **대시보드 UI 그대로**를 폰에서 쓰고 싶으면(같은 tailnet). `loopctl remote`(또는 대시보드 ⋯ → `📱 폰 원격 접속`)를 켜면 서버가 `tailscale cert`로 이 노드의 tailnet 정식 인증서를 받아 tailscale IP에 **HTTPS 리스너**를 연다. 모달의 QR을 폰으로 스캔 → **공유 → 홈 화면에 추가**로 앱처럼 설치. 대시보드는 모바일 반응형이라 폰에서 전부 조작된다.

- **웹푸시** — 홈화면 앱에서 `🔔 알림 켜기` → 루프가 사람을 기다리면(🔴 human-gate·rework-exhausted·CI 실패 등) **앱이 꺼져 있어도 폰이 울린다**. 탭하면 해당 루프로 딥링크. VAPID/암호화(RFC 8291/8292)는 `bin/webpush.mjs`에 **의존성 0**로 직접 구현.
- **범위** — `0.0.0.0`이 아니라 tailscale IP에만 바인딩 → **LAN·공개 인터넷 노출 없음**, 내 tailnet 기기에서만(TLS + WireGuard). 기존 `tailscale serve` 설정은 안 건드린다.
- **영속** — `loops.env`의 `LOOPS_REMOTE=1`(모달·CLI가 토글) → 다음 부팅에도 자동. 끄기 `loopctl remote off`.
- **비밀번호(선택)** — tailnet 자체가 사설 경계라 보통 불필요하지만, `LOOPS_REMOTE_AUTH="user:pass"`를 두면 비-loopback 요청에 Basic auth를 건다.
- **공개 터널** — tailnet 밖 노출이 필요하면 `loopctl remote cloudflare`(quick tunnel + basic-auth, `cloudflared` 필요).

## 신뢰성 — 자가복구

Loops는 사람이 안 보는 동안에도 계속 돌도록 설계됐다. 모든 복구는 **결정론적 shell**이고, 어디서도 merge·deploy·force-push하지 않는다(Backlog 이동·로컬 롤백만).

**멈춤·유령 자가복구 (≤60s).** `dispatch.sh`가 리퍼와 함께 두 루프를 돈다. in-flight 판정 기준은 항상 신선한 **Linear `started`**(stale snapshot에 의존 안 함).
- 죽었지만 worktree가 남은 worker → `heal-worker`가 그 자리에서 `claude --resume`.
- worktree 없이 Linear만 `started`인 **유령**(슬롯을 영구 점유해 "루프가 조용히 멈추는" 주범) → 리퍼가 Backlog로 되돌려 슬롯을 푼다.
- 탭은 살아있으나 화면이 5분+ 정지한 worker → **wedged**로 대시보드에 표면화(자동 kill은 안 함 — 느린 정상 worker 보호).
- N회 자가복구 실패 → 🧟 stuck으로 사람에게.

**엔진 자체의 셀프힐링.** 위 복구는 전부 `dispatch.sh` 안에 살아서 디스패처가 죽으면 다 멈춘다 — 그 단일 장애점을 세 겹이 막는다.
1. **supervisor** (`loopctl supervisor install`, launchd 60s) — 죽은 디스패처를 재기동하고, 디스패처는 자기 housekeeping으로 죽은 대시보드·봇을 재기동. `loopctl stop` 같은 **의도적 정지는 마커로 존중**.
2. **crash-loop 가드** — 10분 내 3회 죽으면, 직전 self-update가 원인으로 추정될 때 이전 커밋으로 **로컬 롤백**(force-push 아님), 아니면 30분 백오프 + 알림.
3. **incident-bridge** — 오케스트레이터 연속 실패·supervisor escalate/롤백을 **엔진 자가개선 루프의 Backlog 이슈**로 자동 발제 → worker가 고쳐 push → self-update → 디스패처 자가 재실행. "고장 → 자가 수정 → 자가 배포"가 닫힌다(핵심 실행경로 변경은 여전히 human-gate).

## CLI — `loopctl`

```
런타임   dashboard [remote]   대시보드 (http://localhost:8422, cmux 패널). remote → 폰 원격도 켬
         start | stop         전역 디스패처 시작 / 중지
         pause | resume       전역 일시정지 / 재개
         status               디스패처·루프 상태
         run-now <loop>       루프 1사이클 즉시 발사
         update               엔진을 origin 최신으로 갱신 (ff-only; 디스패처가 idle마다 자동으로도)

정리     worktrees <loop>         종료 이슈 잔여 worktree 진단 (읽기전용)
         cleanup <loop> [--dry]   종료(Done/Canceled) worktree·탭·브랜치 정리

점검     doctor                   전제도구·설정·런타임 헬스체크
         supervisor install|remove|status|run   프로세스 감독자(launchd) 등록

원격     bot                      Telegram 봇 (폰 push + 결정·취소·재실행)
         remote [tailscale|off|cloudflare]   폰 원격 대시보드 토글
```

종료 상태 이슈의 worktree·탭·브랜치는 매 orchestrator run마다 **자동 정리**된다(진행 중 worktree는 `claude --resume` 위해 보존).

## 구조

```
bin/          엔진(공통, 도메인 무관):
              · 코어 파이프라인   dispatch · run-once · spawn-orchestrator · spawn-worker · worker-run · render-prompt · _common(공통 source) · preflight
              · 프롬프트 템플릿   {orchestrator,worker,verifier,validator,retro}-base.md · loop-builder.md
              · 피드백 루프       rework-worker · spawn-verifier(+verifier-run) · spawn-validator(+validator-run) · event-poll · record-cost
              · 신뢰성/정리       watchdog · heal-worker · cleanup-terminal(reaper) · cleanup-issue · cleanup-loop · supervisor · incident-bridge
              · Linear ledger    linear-move · linear-states · linear-create · … · build-loop
              · 원격             notify-bot(Telegram) · loops-mcp(봇 에이전트용 제어 MCP) · webpush · tg-notify
dashboard-server.mjs · dashboard.html · loopctl
vendor/       Oat UI 정적 자산 (유일한 no-build 예외 · 핀 고정)
skills/create-loop/   create-loop 스킬 (install.sh가 ~/.claude/skills로 symlink)
examples/     시작 템플릿 (deadcode · seo · bug-drain)
docs/         설계 노트
loops/        (gitignore) 유저 loop 데이터: <id>/{config.json, mission.md, state/}
products/     (gitignore) 제품 계층 설정
state/        (gitignore) 런타임
loops.env     (gitignore) 머신별 도구 경로 (install.sh 생성)
```

경로는 `LOOPS_HOME`(스크립트 자기 위치)·`loops.env`로 전부 동적 — 어디에 clone해도, cmux/claude/gh/node가 어디 있어도 `install.sh`가 맞춰준다.

## 안전 불변식

> **엔진은 절대 merge / deploy / force-push 하지 않는다.** worker는 PR만 연다. 머지는 사람의 게이트.

이 불변은 프롬프트·스크립트 어디를 고쳐도 유지된다. 봇 에이전트·검증자는 `--disallowedTools`로 Edit/Write/Bash가 **구조적으로** 차단되고(프롬프트 규율이 아니라 도구 부재), self-update 롤백조차 로컬 브랜치 이동일 뿐 origin은 안 건드린다. 유일한 예외는 `delivery:"direct"` 루프(리뷰어 없는 개인 repo)로, PR 대신 `prBase`에 직접 push하지만 **force-push는 여전히 금지**다.

## 라이선스

[MIT](./LICENSE)

---

*엔지니어링 내부 문서(아키텍처·규약·편집 시 주의점)는 [`CLAUDE.md`](./CLAUDE.md)를 참고.*
