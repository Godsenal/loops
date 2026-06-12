#!/usr/bin/env node
// 루프의 base 프롬프트 + mission + config 값을 합쳐 최종 프롬프트를 stdout으로.
// usage: render-prompt.mjs <loop-id> [orchestrator|worker]
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
const ROOT = process.env.LOOPS_HOME || dirname(dirname(fileURLToPath(import.meta.url)));
const [, , loopId, which = 'orchestrator'] = process.argv;
if (!loopId) { console.error('usage: render-prompt.mjs <loop-id> [orchestrator|worker]'); process.exit(1); }
const cfg = JSON.parse(readFileSync(`${ROOT}/loops/${loopId}/config.json`, 'utf8'));
let tpl = readFileSync(`${ROOT}/bin/${which}-base.md`, 'utf8');
const vars = {
  LOOP_ID: cfg.id, LOOP_NAME: cfg.name, EMOJI: cfg.emoji || '🔁',
  REPO: cfg.repo, BASE_REF: cfg.baseRef || 'origin/develop', PR_BASE: cfg.prBase || 'develop',
  LINEAR_PROJECT_ID: cfg.linearProjectId || '', LINEAR_PROJECT_URL: cfg.linearProjectUrl || '',
  MAX_WORKERS: String(cfg.maxWorkers || 2),
  BACKLOG_TARGET: String(cfg.backlogTarget || 5),
  STATE_DIR: `${ROOT}/loops/${loopId}/state`,
  ORCH_WORKTREE: cfg.orchestratorWorktree || '',
  WORKTREE_PREFIX: cfg.worktreePrefix || '',
  SPAWN_WORKER: `${ROOT}/bin/spawn-worker.sh ${loopId}`,
};
if (which === 'orchestrator') {
  let mission = '';
  try { mission = readFileSync(`${ROOT}/loops/${loopId}/mission.md`, 'utf8'); } catch {}
  vars.MISSION = mission.trim() || '(mission.md 비어있음 — 이 루프의 임무를 정의하세요)';
}
process.stdout.write(tpl.replace(/\{\{(\w+)\}\}/g, (_, k) => (vars[k] != null ? vars[k] : `{{${k}}}`)));
