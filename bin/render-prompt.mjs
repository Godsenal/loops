#!/usr/bin/env node
// 루프의 base 프롬프트 + mission + config 값을 합쳐 최종 프롬프트를 stdout으로.
// usage: render-prompt.mjs <loop-id> [orchestrator|worker|verifier|validator|retro]
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { loadLoopConfig } from './loop-config.mjs';
const ROOT = process.env.LOOPS_HOME || dirname(dirname(fileURLToPath(import.meta.url)));
const [, , loopId, which = 'orchestrator'] = process.argv;
if (!loopId) { console.error('usage: render-prompt.mjs <loop-id> [orchestrator|worker|verifier|validator|retro]'); process.exit(1); }
// 제품(product) 상속 머지 포함 — 선언된 product.json이 없으면 여기서 throw(비0 종료)로 run이 loud하게 실패한다.
const cfg = loadLoopConfig(ROOT, loopId);
let tpl = readFileSync(`${ROOT}/bin/${which}-base.md`, 'utf8');
const prBase = cfg.prBase || 'develop';
const delivery = cfg.delivery || 'pr';   // 'pr'(기본, PR만) | 'direct'(PR 없이 base에 직접 push)
const vars = {
  LOOP_ID: cfg.id, LOOP_NAME: cfg.name, EMOJI: cfg.emoji || '🔁',
  REPO: cfg.repo, BASE_REF: cfg.baseRef || 'origin/develop',
  LINEAR_PROJECT_ID: cfg.linearProjectId || '',
  MAX_WORKERS: String(cfg.maxWorkers || 2),
  BACKLOG_TARGET: String(cfg.backlogTarget || 5),
  STATE_DIR: `${ROOT}/loops/${loopId}/state`,
  ORCH_WORKTREE: cfg.orchestratorWorktree || '',
  BRANCH_PREFIX: cfg.branchPrefix || `loop-${loopId}`,
  SPAWN_WORKER: `${ROOT}/bin/spawn-worker.sh ${loopId}`,
  REWORK_WORKER: `${ROOT}/bin/rework-worker.sh ${loopId}`,
};
if (which === 'orchestrator' || which === 'retro' || which === 'validator') {
  let mission = '';
  try { mission = readFileSync(`${ROOT}/loops/${loopId}/mission.md`, 'utf8'); } catch {}
  vars.MISSION = mission.trim() || '(mission.md 비어있음 — 이 루프의 임무를 정의하세요)';
}
// 사람 소유 제품 방향(loops/<id>/vision.md) → 발굴·검증·회고의 정렬/기각 기준. 없으면 빈 문자열(블록 통째 생략).
// mission(무엇을 어떻게 찾나)과 분리된 이유: retro가 mission을 못 건드리는 불변을 지키면서 방향은 공유하기 위함.
let vision = '';
try { vision = readFileSync(`${ROOT}/loops/${loopId}/vision.md`, 'utf8').trim(); } catch {}
vars.VISION = vision
  ? `\n────────── VISION (제품 방향 — 사람 소유, 제안·발굴의 정렬/기각 기준) ──────────\n${vision}\n──────────────────────────────────────────────────────────────\n`
  : '';
// retro가 축적한 교훈(state/learnings.md) → 오케스트레이터(발굴 기준)·워커(구현 기준)·검증자(validator, 회의적 재검증 기준)에 주입. 없으면 토큰이 통째로 사라진다.
let learnings = '';
try { learnings = readFileSync(`${ROOT}/loops/${loopId}/state/learnings.md`, 'utf8').trim(); } catch {}
vars.LEARNINGS = learnings
  ? `\n────────── LEARNINGS (retro가 이 루프의 실제 성과에서 추출한 교훈 — 발굴·구현 시 반영하라) ──────────\n${learnings}\n──────────────────────────────────────────────────────────────\n`
  : '';

// 하나의 Linear 프로젝트를 라벨로 나눠 여러 루프가 공유할 때(config linearLabel, 예: bug / feature-request).
// 비면 블록 통째 생략 = 프로젝트 전체 담당(기존 단독-프로젝트 루프 동작 그대로, 하위호환).
vars.LINEAR_LABEL = cfg.linearLabel || '';
vars.LINEAR_LABEL_NOTE = cfg.linearLabel
  ? `\n⚠️ **라벨 스코프 — 이 루프는 공유 Linear 프로젝트에서 \`${cfg.linearLabel}\` 라벨이 붙은 이슈만 담당한다.** 다른 라벨의 이슈는(다른 루프가 처리) **네 소관이 아니다** — 조회 결과에서 제외하고, 상태변경·코멘트·fan-out 어느 것도 하지 마라.\n  - **모든 Linear 조회**(STEP 1 In Review/In Progress, STEP 2 dedup 검색, STEP 3 Backlog 선택)에 이 라벨 필터를 건다. in-flight·cap 계산도 이 라벨 이슈만 센다.\n  - **STEP 2에서 새로 만드는 이슈에는 반드시 \`${cfg.linearLabel}\` 라벨을 부여**한다 — 안 붙이면 다른 루프도 못 보고 너도 다음 run(빈 컨텍스트)에서 못 본다.\n  - **STEP 4 snapshot·run-log**도 이 라벨 이슈만 집계한다.\n`
  : '';

// 변경 반영 방식(worker 절차 4~ / orchestrator 안내). 기본 'pr'은 기존 동작 그대로, 'direct'는 base에 직접 push.
// ⚠️ 주입 문자열 안의 base는 실제 값(prBase)으로 박는다 — replace는 1패스라 {{토큰}}은 재처리되지 않음.
const VERIFY_STEP = cfg.verify === true ? `
6.5 **검증자 스폰**: 쉘 실행 \`${ROOT}/bin/spawn-verifier.sh ${loopId} <배정 이슈 ID>\` — 너와 별개의 fresh-context 검증자가 이 PR을 이슈의 수용 기준으로 채점해 verdict를 PR/Linear에 코멘트한다. 완료를 기다리지 않는다.` : '';
const WORKER_DELIVERY_PR = `4. **\`/gbase:go --no-review\` 실행** — polish + 브랜치/커밋/PR 생성(+ CI/preview 링크). base=\`${prBase}\`, 일반 PR, 본문에 \`Linear: <ISSUE-URL>\`.
   - \`--no-review\` 필수: monitor의 self-review 패스는 AskUserQuestion 게이트라 무인 탭에서 영원히 블록된다 — checker 역할은 verifier 몫.
   - go가 마지막에 monitor로 넘어가는 건 그대로 두되, **장기 감시에 들어가기 전에 절차 5~6.5를 먼저 끝낸다.**
   - 무거운 install은 가능하면 생략(정적 분석 충분시). 정밀 검증은 PR의 **CI가 게이트**.
5. **프리뷰 테스트**: PR/CI 봇 preview URL을 찾아 WebFetch로 변경이 실제 반영됐는지 검증. 없으면 기록.
6. **Linear 이슈를 In Review**로 + PR 링크 + preview 결과 코멘트.${VERIFY_STEP}
7. **상주 감시 — 머지는 여전히 사람 게이트**: \`/gbase:monitor\` 감시를 PR이 MERGED/CLOSED 될 때까지 유지하며 CI 실패·리뷰 코멘트를 이 세션에서 바로 반영한다. 단, 이 탭은 무인이므로 **아래 규칙이 스킬 지침보다 우선한다**:
   - **머지/승인(approve)/클로즈 금지.** force-push·\`--force-with-lease\` **절대 금지** — 스킬의 rebase 기반 충돌 자동 해소는 쓰지 않는다. \`git merge origin/${prBase}\`(non-force push)로 풀리는 명백한 충돌(락파일 등)만 해소하고, 그 외 충돌은 PR 코멘트로 표면화만 한다.
   - **AskUserQuestion 금지** — 스킬이 "ask the user"를 요구하는 모든 상황(모호한 리뷰 코멘트·설계 판단·위험한 충돌)은 PR 답글 + Linear 코멘트 "🚧 사람 판단 필요: <요약>"으로 표면화하고, 그 항목은 건드리지 않은 채 감시를 계속한다.
   - **자동 반영 허용 범위**는 스킬의 auto-apply 기준 그대로: 기계적으로 명백한 CI fix, 기계적·명시적 리뷰 코멘트, verifier ❌ 지적 중 명백한 것. 전부 non-force push + 반영 답글.
   - **정지 조건**: MERGED/CLOSED → 1줄 요약 남기고 정지(탭·worktree 정리는 엔진 몫). 스킬의 하드스톱(같은 체크 2회 연속 실패 등) → Linear에 사유 코멘트 후 정지(이후는 엔진의 rework/오케스트레이터가 인계).
   - 이 탭의 **타이틀을 바꾸지 않는다** — 🛠/↩ 타이틀이 엔진(watchdog·rework dedup·리퍼)의 생존 신호다.`;
const WORKER_DELIVERY_DIRECT = `4. **품질 다듬기**: \`/gbase:polish\` 로 현재 diff를 정리(deslop + 구조 단순화).
5. **커밋 → \`${prBase}\` 직접 push** (⚠️ 이 루프는 PR을 열지 않는다 — 변경을 바로 \`${prBase}\`에 반영한다):
   - 변경을 의미단위로 커밋. 메시지에 \`Linear: <ISSUE-URL>\`.
   - \`git fetch origin && git rebase origin/${prBase}\` — base가 움직였으면 그 위로 재정렬. 충돌 나면 **멈추고** 이슈에 "🚧 충돌로 직접 push 실패: <사유>" 코멘트 + 상태 Backlog 복귀 후 정지. **force-push 절대 금지.**
   - \`git push origin HEAD:${prBase}\` (non-force). 거부되면 위 fetch/rebase 후 **1회만** 재시도, 그래도 안 되면 멈추고 코멘트 + Backlog 복귀.
6. **Linear 이슈를 Done**으로 옮기고 push된 커밋 SHA·요약을 코멘트.
7. 정지. (worktree/탭은 resume용으로 남는다.)`;
const DELIVERY_NOTE_DIRECT = `- ⚠️ **이 루프는 PR을 열지 않는다 (delivery=direct).** worker가 변경을 \`${prBase}\`에 직접 push하고 이슈를 바로 **Done**으로 옮긴다 → **In Review 상태가 없다.** STEP 1의 PR 추적 대상이 없고, in-flight는 사실상 (In Progress 수)만이다. STEP 1에서는 죽은 In Progress(worker 탭 없음)만 Backlog로 되돌리면 된다(단 아래 STEP 1의 liveness.json escalated 예외는 그대로 적용 — 워치독이 포기한 stuck 이슈는 그대로 둔다).`;
vars.WORKER_DELIVERY = delivery === 'direct' ? WORKER_DELIVERY_DIRECT : WORKER_DELIVERY_PR;
vars.DELIVERY_NOTE = delivery === 'direct' ? DELIVERY_NOTE_DIRECT : '';

process.stdout.write(tpl.replace(/\{\{(\w+)\}\}/g, (_, k) => (vars[k] != null ? vars[k] : `{{${k}}}`)));
