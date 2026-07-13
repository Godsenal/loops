# 서비스 팩토리 설계 — "좋은 서비스를 계속 만들어내는" 루프 시스템

> 상태: **M1·M2 구현됨** (2026-07-11). M1 = `{{VISION}}` 토큰 + vision.md(대시보드 ⚙️ 편집·pm-loop 분리 완료). M2 = validator 3종(`bin/{spawn-validator,validator-run}.sh`+`validator-base.md`, config `"validate": true`, run-once 결정론 스폰, 대시보드 🧪 배지·게이트 병기·Telegram 병기). M3부터 미착수.

## 0. 목표와 현재 갭

목표: **사람은 승인·머지·비전만 담당하고, 나머지 전 구간 — 기회 발굴 → 검증 → 스펙 → 구현 → 검수 → 관측 → 학습 — 이 루프로 도는 시스템.** 산출물은 "돌아가는 코드"가 아니라 "가치가 검증된 서비스"다.

현재 커버리지 (서비스 생애주기 8단계 기준):

```
발굴      검증      스펙/분해   구현      검수      출시      관측      학습
 ●         ○         ○          ●         ●         ●(사람)    ○         ◐
 PM루프    없음      없음       worker    verifier   머지게이트  없음     retro(리뷰어
 (아키타입B)                    +gbase:go  (verify)              취향까지만)
```

빈 곳이 정확히 "좋은"을 담보하는 단계들이다: **검증**(만들 가치가 있나), **스펙/분해**(에픽을 실행 단위로), **관측**(실제로 효과 있었나). 지금의 루프는 "그럴듯한 것을 만드는" 데까지만 자동이다.

## 1. 설계 원칙 — Loops × gstack 결합 규칙

두 시스템의 역할을 분리한다:

- **Loops 엔진 = 자율 레일.** 언제(스케줄·이벤트), 누가(orchestrator/worker/verifier), 어떤 권한으로(도구 차단·게이트), 무슨 상태에서(Linear ledger), 얼마나(예산·cap) 실행되는가. 치유·정리·비용도 여기.
- **gstack = 단계별 장인 기술(craft).** 아이디어 심문(office-hours), 다관점 리뷰+자동결정(autoplan), 스펙화(spec), QA(qa), 배포 후 감시(canary), 회고(retro), 품질 점수(health), 질문 캘리브레이션(plan-tune), 레포별 지식(gbrain). "무엇을 어떻게 잘 하는가."

**결합 규칙 (중요):** gstack 스킬은 대화형이다(AskUserQuestion 다수 — headless에서 BLOCK). 따라서:

1. **헤드리스 스테이지**(orchestrator·validator·measure·retro)는 gstack 스킬을 *호출하지 않는다*. 대신 그 스킬의 **방법론을 `-base.md`로 증류**한다. 선례: `verifier-base.md`가 리뷰 craft를 증류한 방식 그대로.
2. **라이브 TUI 스테이지**(worker 탭)만 스킬을 직접 호출한다. 선례: worker의 `/gbase:go`.
3. gstack은 **방법의 원천이지 런타임 의존성이 아니다** — 엔진의 zero-dep·headless-safe 불변을 지킨다.

**깨지 않는 불변:** ① 머지·배포·force-push는 영원히 사람 ② 상태 전이·정리·재시도는 결정론적 쉘(LLM은 판단과 생성만) ③ Linear가 유일한 cross-run ledger ④ zero-dep ⑤ mission.md는 사람 소유.

## 2. 파이프라인 — 서비스 생애주기를 루프 스테이지로

```
              ┌──────────────────────── 학습이 다음 발굴을 바꾼다 ────────────────────────┐
              ▼                                                                          │
 [0 발굴] → [1 검증] → (⚖️승인) → [2 스펙/분해] → [3 구현] → [4 검수] → (⚖️머지) → [6 관측] → [7 학습]
  PM/스튜디오   validator    사람        분해워커       worker      verifier     사람       measure     retro
  (있음)       (신설)                   (신설)         (있음)      (있음)                  (신설)      (확장)
```

| # | 스테이지 | gstack 원천 | 엔진 메커니즘 | 사람 개입 |
|---|---|---|---|---|
| 0 | 발굴 | — (아키타입 B로 이미 정립) | orchestrator STEP 2, human-gate 제안서 | 없음 |
| 1 | **검증** | **office-hours** (YC 진단·전제 도전·대안 생성) | **validator** — verifier 인프라 재사용 (§4) | 판정을 참고해 **승인/기각** |
| 2 | **스펙/분해** | **spec** (5-phase: 의도→정밀 스펙→이슈) | **분해 워커** — 에픽을 sub-issue로 (§5) | 없음 (선택: 스펙 게이트) |
| 3 | 구현 | gbase:go (이미 사용) | worker fan-out | 없음 |
| 4 | 검수 | qa (verifier가 이미 증류) | verifier `verify:true` | ❌→rework 자동 |
| 5 | 출시 | ship | **사람 머지** (+ CD는 레포 몫) | **머지** |
| 6 | **관측** | **canary** (베이스라인 대비 이상 감지) + health | **measure 모드** (§6) | 없음 (보고만) |
| 7 | 학습 | **retro** + plan-tune (게이트 캘리브레이션) | retro 모드 확장 (§7) | 피벗/폐기 승인 |

사람의 개입은 정확히 3곳: **제안 승인(⚖️), 머지, 피벗/폐기.** 전부 이미 있는 UX(대시보드 gate 모달·Telegram 버튼·GitHub)를 탄다.

## 3. 거버넌스 — 결정 라우팅 (autoplan 이식)

지금 엔진의 판단은 2단이다: 전부 자동 vs human-gate. autoplan의 **결정 3분류**를 엔진 규약으로 승격해 해상도를 높인다:

- **Mechanical** — 정답이 하나. 루프가 조용히 결정. (예: dedup, 수용기준 충족 판정)
- **Taste** — 합리적 이견 가능. 루프가 **결정하고 진행하되** `state/decisions-auto.jsonl`에 근거와 함께 기록, 대시보드·이슈 코멘트에 노출. 사람이 뒤집으면 그게 판례가 된다. (예: 두 구현 접근 중 선택, 제안 우선순위)
- **Premise / User-Challenge** — 전제(무엇을 만들까·왜)와 사용자가 정한 방향에 대한 반박. **절대 자동 결정 금지 → human-gate.** (예: 제안 승인, non-goal 위반 제안, 피벗/폐기)

결정 원칙(autoplan 6원칙을 이 플랫폼 맥락으로): ①완결성 ②blast radius 안은 다 고친다 ③실용(5초 결정) ④중복 금지—재사용 ⑤명시적>영리함 ⑥행동 편향. base 프롬프트 공통 블록으로 주입.

**게이트 캘리브레이션 (plan-tune 이식):** `decisions/*.md` 판례가 같은 유형으로 3회 쌓이면 retro가 "이 유형은 게이트 불필요 — 사람이 항상 X로 결정"을 learnings에 규칙화(이미 retro-base에 씨앗 있음). 반대로 Taste 결정이 사람에 의해 뒤집히면 그 유형을 게이트로 **승격**. 게이트는 고정이 아니라 학습되는 다이얼이다.

## 4. 검증 스테이지 — validator (office-hours 증류)

**목적:** 발굴 루프의 제안서가 사람 게이트에 도달하기 *전에*, 신선한 컨텍스트의 회의론자가 심문한다. 사람은 "제안 + 독립 검증 의견"을 보고 30초 결정한다.

- **인프라:** verifier를 그대로 복제-변형. `spawn-validator.sh` + `validator-run.sh` + `validator-base.md`, detached `-vd` worktree, 🧪 탭, **Edit/Write 구조적 차단**, Linear 상태 이동 금지(코멘트만). config `"validate": true` (제안형 루프에서만 의미).
- **트리거:** 결정론적 — orchestrator run 종료 후 `run-once.sh`가 "이번 run에 생성된 human-gate 제안 이슈"마다 spawn (verifier가 PR 후 뜨는 것과 동일 패턴).
- **validator-base.md에 증류할 것 (office-hours에서):**
  - YC 진단 원칙: 구체성만이 화폐다 / 관심≠수요(행동·돈·고장 시 항의가 수요) / **진짜 경쟁자는 현상유지**(스프레드시트+슬랙) / 좁게 먼저(wedge) / 데모 말고 관찰.
  - 전제 도전: 맞는 문제인가? 아무것도 안 하면? 기존 코드/기능이 이미 부분 해결하나? **배포·유통 경로가 슬라이스에 있나?**
  - 반사양(anti-sycophancy): 모든 답에 입장을 취하고, 입장을 바꿀 증거를 명시. "흥미롭네요" 금지.
  - 대안 생성 1개 의무: 같은 기회를 더 싸게 검증하는 축소안.
- **산출:** 판정(🟢 강화 / 🟡 조건부 — 축소안 제시 / 🔴 기각 권고) + 근거를 이슈 코멘트 + `state/validate/<ISSUE>.json`. 스냅샷의 `gate.ask`에 판정 요약이 병기되어 대시보드·Telegram 게이트 UI에 그대로 뜬다.
- (opt-in) **교차 모델 2차 의견** — office-hours Phase 3.5 패턴. codex CLI가 있으면 반대 심문 1회. config `"validate": {"crossModel": true}`.
  - ⚠️ **미구현 — L3 "M3부터 미착수" 범위의 미래 스펙.** 이 object 형태를 **실제 config에 복붙하지 말 것**: 현행 파서(`run-once.sh`·`spawn-validator.sh`)는 `validate`를 boolean으로만 읽어, `cfgval`가 object를 `"[object Object]"`로 반환 → `!= "true"` → **validation이 조용히 꺼진다**. 지금 유효한 형태는 `"validate": true`뿐이며, crossModel 도입 시 이 파싱도 함께 구현해야 한다.

## 5. 스펙/분해 스테이지 — 분해 워커 (spec 증류)

승인된 제안이 PR 1개 크기를 넘는 **에픽**일 때만 발동한다 (제안서의 [첫 슬라이스]가 이미 1-PR 크기면 기존 경로 그대로).

- 제안 이슈 본문에 `epic` 표시가 있으면, `resolve-gate` 후 spawn되는 워커가 **분해 모드**로 뜬다: 코드를 짜지 않고(Edit/Write 차단) spec의 5-phase를 증류한 스펙 문서를 작성 → Linear **sub-issue들**(각각 1-PR 크기, 수용기준 포함) 생성 → 정지.
- orchestrator 변경: STEP 3 fan-out이 sub-issue를 일반 Backlog처럼 집는다(이미 그렇게 동작 — parent만 제외 목록에 추가). STEP 1이 "모든 sub-issue Done → parent Done" 전이를 수행.
- Linear가 parent/sub를 네이티브 지원하므로 ledger 스키마 변경 없음.

## 6. 관측 스테이지 — measure 모드 (canary 증류)

**"머지됨"과 "효과 있음"을 분리한다** — 이 단계가 없으면 팩토리는 리뷰어 취향에만 수렴한다.

- `LOOP_MODE=measure`: dispatch가 주기 실행(예: 일 1회). 머지 후 N일(기본 7) 지난 Done 이슈 중 미관측 건에 대해, 이슈 본문의 **[성공지표]를 실제로 회수**: 계측 데이터가 있으면 그것, 없으면 제안서의 대리지표(예: dogfooding 시나리오 재수행 — canary의 베이스라인 비교 패턴). 결과를 `state/outcomes/<ISSUE>.json` (`{verdict: improved|flat|regressed|unmeasurable, evidence}`) + 이슈 코멘트.
- `unmeasurable`이 반복되면 그 자체가 신호 → "계측 추가" 제안을 발굴 lane에 피드백 (아키타입 B의 lane ⑤가 받는다).
- 대시보드: economics 옆에 outcome 집계(improved/flat/regressed 비율). Telegram: regressed만 푸시.

## 7. 지식층 (gbrain 이식) + 포트폴리오 수준

- **`vision.md` 신설** — mission(무엇을 어떻게 찾나) *위*의 문서: 타겟 유저·북극성·non-goals·수익모델 가설. **사람 소유**(retro가 못 건드림), `{{VISION}}`으로 orchestrator·validator·retro에 주입. 지금은 이게 mission 안에 섞여 있다(pm-loop) — 분리해야 retro가 mission을 안 건드리는 불변을 유지한 채 정렬 기준을 공유한다.
- **state/ 확장** (gbrain의 레포별 지식 구조를 루프별로): `validate/` `outcomes/` `decisions-auto.jsonl` 추가. 기존 `decisions/` `learnings.md` `verify/` 유지.
- **retro 입력 확장:** 기존(merged/closed·리뷰 코멘트·판례) + `outcomes/*`(실제 효과) + `decisions-auto.jsonl`(뒤집힌 Taste 결정). 이제 "머지됐지만 flat"인 발굴 유형을 중단시킬 수 있다.
- **포트폴리오 retro** (서비스가 2개 이상일 때): 월 1회, 서비스 횡단 — 어느 서비스에 슬롯·예산을 더/덜 줄지, **피벗/폐기 제안**(항상 human-gate). 산출은 각 루프의 vision.md *제안 diff*(적용은 사람).

## 8. 구현 로드맵 — 각 마일스톤 = PR 1~2개 크기, 독립 가치

| M | 내용 | 크기 | 수용 기준 |
|---|---|---|---|
| **M1** | `vision.md` + `{{VISION}}` 토큰 (render-prompt + 대시보드 ⚙️ 편집란) | S | pm-loop의 mission에서 제품방향을 vision.md로 분리, 렌더 확인 |
| **M2** | **validator** (spawn/run/base + `validate` config + gate.ask 병기) | M | PM 루프 제안 1건이 판정 코멘트를 달고 게이트에 도착 |
| **M3** | **measure 모드** (+outcomes/, 대시보드 outcome 집계) | M | 머지된 이슈 1건이 7일 후 verdict를 받음 |
| **M4** | retro 입력 확장 (outcomes + 뒤집힌 Taste) + 결정 3분류·6원칙 공통 블록 + `decisions-auto.jsonl` | M | learnings에 outcome 근거 교훈 1줄 이상 |
| **M5** | **분해 워커** + epic 인식 (parent/sub 전이) | M | 에픽 제안 1건이 sub-issue 3개로 분해→구현→parent Done |
| **M6** | 게이트 캘리브레이션 (판례→강등, 뒤집힘→승격) + 포트폴리오 retro | M | learnings에 게이트 규칙 1개 생성 |
| **M7** | **아키타입 C(스튜디오)** loop-builder 등록 + 첫 인스턴스 (ventures 모노레포 — 0→1 신규 서비스) | M | 스튜디오 루프가 첫 MVP 제안을 검증 통과시켜 게이트에 올림 |

순서 근거: M1·M2가 게이트 품질을 먼저 올리고(지금 당장 PM 루프가 켜져 있으므로), M3·M4가 "좋은"의 정의를 데이터로 바꾸고, M5가 에픽을 열고, M7이 비로소 신규 서비스를 연다. **M7을 먼저 하지 않는다** — 검증·관측 없는 스튜디오는 그럴듯한 쓰레기 공장이 된다.

## 9. 이 설계의 기각 기준 (self-applied)

- M2 후에도 사람이 게이트에서 validator 판정을 체감상 신뢰하지 않으면(판정과 반대로 결정하는 비율 >50%) → validator-base의 증류 품질 문제. office-hours 원문을 더 가져오거나 교차 모델을 기본화.
- M3에서 대리지표가 전부 `unmeasurable`이면 → 관측 설계가 앞섰다. 계측(lane ⑤)을 먼저 몇 건 머지시킨 뒤 재개.
- 루프당 일 비용이 budget 소프트캡을 상시 치면 → 스테이지 수를 줄이는 게 아니라 validator/measure의 모델을 저비용으로 (config `model` per-stage).
