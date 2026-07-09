#!/usr/bin/env node
// Loops 플랫폼 대시보드 — 멀티 루프 관리 UI + 제어. 의존성 0 (Node 내장 http).
// ⚠️ cmux 패널 안에서 실행해야 함(제어가 cmux 소켓 접근). loopctl dashboard 로 띄움.
import http from 'node:http';
import https from 'node:https';
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync } from 'node:fs';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const ROOT = process.env.LOOPS_HOME || dirname(fileURLToPath(import.meta.url));
function loadEnv() { const e = {}; try { for (const l of readFileSync(`${ROOT}/loops.env`, 'utf8').split('\n')) { const m = l.match(/^\s*([A-Z_]+)\s*=\s*(.*)$/); if (m) e[m[1]] = m[2].trim().replace(/^["']|["']$/g, ''); } } catch {} return e; }
const ENV = loadEnv();
const LOOPS = `${ROOT}/loops`;
const GSTATE = `${ROOT}/state`;
const CMUX = ENV.CMUX_BIN || process.env.CMUX_BIN || 'cmux';
const GH = ENV.GH_BIN || process.env.GH_BIN || 'gh';
const CMUX_BUNDLE = ENV.CMUX_BUNDLE_ID || process.env.CMUX_BUNDLE_ID || 'com.cmuxterm.app';
const WORKTREE_BASE = ENV.WORKTREE_BASE || process.env.WORKTREE_BASE || `${process.env.HOME}/LTH`;
const PORT = +(ENV.LOOPS_PORT || process.env.LOOPS_PORT || 8422);
const GPID = `${GSTATE}/dispatcher.pid`;
const GPAUSED = `${GSTATE}/PAUSED`;
const GAWAKE = `${GSTATE}/awake.pid`;   // caffeinate 프로세스 pid (잠자기 방지 토글)

const readText = (p) => { try { return readFileSync(p, 'utf8'); } catch { return ''; } };
const readJSON = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
const pidAlive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const slugOf = (id) => String(id).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-+$/, '');
let LINEAR_KEY = ENV.LINEAR_API_KEY || process.env.LINEAR_API_KEY || '';   // 런타임 보유 — UI에서 즉시 갱신, loops.env에 영속화. status는 boolean만 노출.
function setEnvVar(k, v) { const p = `${ROOT}/loops.env`; let t = readText(p); const ln = `${k}=${v}`; const re = new RegExp('^' + k + '=.*$', 'm'); t = re.test(t) ? t.replace(re, ln) : (t.replace(/\n?$/, '\n') + ln + '\n'); writeFileSync(p, t); }

function listLoopIds() { try { return readdirSync(LOOPS).filter(d => existsSync(`${LOOPS}/${d}/config.json`)); } catch { return []; } }
function tabsAll() {
  try {
    return execFileSync(CMUX, ['list-workspaces'], { encoding: 'utf8', timeout: 4000 })
      .split('\n').map(l => { const m = l.match(/workspace:\d+/); const title = l.replace(/^\s*\*?\s*workspace:\d+\s*/, '').trim(); return m ? { ref: m[0], title } : null; })
      .filter(Boolean);
  } catch { return []; }
}
function globalDispatcher() {
  const t = readText(GPID).trim(); const pid = t ? +t : null; const running = pid ? pidAlive(pid) : false;
  return { running, paused: existsSync(GPAUSED), pid: running ? pid : null };
}
// caffeinate(잠자기 방지) 살아있는 pid 또는 null. detached로 떠서 대시보드 서버 재시작과 무관하게 유지된다.
function awakeStatus() { const t = readText(GAWAKE).trim(); const pid = t ? +t : null; return pid && pidAlive(pid) ? pid : null; }
// Telegram 브리지(notify-bot) 상태 — 토큰/chat은 loops.env를 live로 다시 읽어 페어링을 즉시 반영, running은 pgrep. 비밀값은 노출 안 하고 boolean만.
function botRunning() { try { execFileSync('/usr/bin/pgrep', ['-f', `${ROOT}/bin/notify-bot.mjs`], { timeout: 2000 }); return true; } catch { return false; } }
function telegramStatus() { const e = loadEnv(); return { configured: !!(e.TELEGRAM_BOT_TOKEN || ''), paired: !!(e.TELEGRAM_CHAT_ID || ''), running: botRunning() }; }
function feedOf(st) { return readText(`${st}/runs.jsonl`).trim().split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean); }

// PR 상태 캐시 — 이슈 브랜치(branchPrefix/slug)로 라이브 조회. 60초마다 백그라운드 갱신(status 요청을 막지 않음).
// snapshot.json(orchestrator가 시간당 1회 기록)에 의존하지 않으므로, worker가 방금 연 PR·방금 닫힌/머지된 PR도 즉시 반영된다.
// repo당 `gh pr list` 1회 → headRefName으로 우리 브랜치만 매칭. (PR URL은 gh가 돌려준 j.url만 신뢰 — origin이 mirror일 수 있음)
const prByBranch = {};
function branchOf(cfg, lid, id) { return `${cfg.branchPrefix || ('loop-' + lid)}/${slugOf(id)}`; }
function prDataFromJson(j) {
  const ch = j.statusCheckRollup || [];
  const ciFail = ch.filter(c => ['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'STARTUP_FAILURE'].includes(c.conclusion)).length;
  const ciPend = ch.filter(c => c.status && c.status !== 'COMPLETED').length;
  const ciPass = ch.filter(c => c.conclusion === 'SUCCESS').length;
  const cs = ciFail ? 'fail' : (ciPend ? 'pending' : 'pass');
  let att = null;
  if (j.state === 'OPEN') { if (cs === 'fail') att = 'ci-failed'; else if (j.reviewDecision === 'APPROVED') att = 'merge-ready'; else if (j.reviewDecision === 'CHANGES_REQUESTED') att = 'changes'; }
  else if (j.state === 'CLOSED' && !j.mergedAt) att = 'pr-closed';
  return { url: j.url, merged: !!j.mergedAt, state: j.state, review: j.reviewDecision, checks: cs, ci: { pass: ciPass, fail: ciFail, pending: ciPend }, reviewCount: (j.reviews || []).length, commentCount: (j.comments || []).length, attention: att };
}
function refreshPRs() {
  const byRepo = {};   // repo 경로 → 우리가 관심있는 브랜치 Set
  for (const lid of listLoopIds()) {
    const cfg = readJSON(cfgPath(lid)) || {}; const repo = cfg.repo; if (!repo) continue;
    const snap = readJSON(`${LOOPS}/${lid}/state/snapshot.json`);
    (byRepo[repo] ||= new Set());
    (snap?.issues || []).forEach(i => byRepo[repo].add(branchOf(cfg, lid, i.id)));
  }
  for (const [repo, branches] of Object.entries(byRepo)) {
    if (!branches.size) continue;
    // ⚠️ reviews/comments 필드는 제외 — coderabbit 등이 다는 거대 코멘트 본문이 섞여 200건이면 응답이 수 MB → execFile 기본 maxBuffer(1MB) 초과로 통째 실패한다. reviewDecision으로 충분. maxBuffer도 여유있게.
    execFile(GH, ['pr', 'list', '--state', 'all', '--limit', '200', '--json', 'url,state,mergedAt,headRefName,statusCheckRollup,reviewDecision'], { cwd: repo, timeout: 20000, maxBuffer: 32 * 1024 * 1024 }, (e, so) => {
      if (e) return; try {
        const seen = new Set();   // gh는 최신순 → 브랜치별 첫(=최신) PR만 채택(reopen 대비)
        for (const j of JSON.parse(so)) {
          if (!branches.has(j.headRefName) || seen.has(j.headRefName)) continue;
          seen.add(j.headRefName); prByBranch[j.headRefName] = prDataFromJson(j);
        }
      } catch {}
    });
  }
}

function loopStatus(lid, allTabs) {
  const dir = `${LOOPS}/${lid}`, st = `${dir}/state`;
  const cfg = readJSON(`${dir}/config.json`) || {};
  const snap = readJSON(`${st}/snapshot.json`);
  const f = feedOf(st);
  const order = { 'In Progress': 0, 'In Review': 1, 'Backlog': 2, 'Done': 3, 'Canceled': 4 };
  const tabByIssue = {};
  // 🛠=fresh worker, ↩=resume/heal 탭 둘 다 "살아있는 worker"로 인식 (안 하면 heal된 ↩ 탭을 죽은 걸로 오판해 워치독이 무한 재기동).
  for (const t of allTabs) { const m = (t.title || '').match(new RegExp('(?:🛠|↩)\\s*' + lid + '\\s+(\\S+)')); if (m) tabByIssue[m[1].toUpperCase()] = t.ref; }
  const liveness = readJSON(`${st}/liveness.json`) || {};   // watchdog.sh가 쓰는 spawn-liveness 상태 {issue:{attempts,escalated,...}}
  const issues = (snap?.issues || []).map(i => {
    const live = prByBranch[branchOf(cfg, lid, i.id)] || null;
    const ws = tabByIssue[i.id] || null, alive = !!ws;
    const lv = liveness[i.id] || null;
    const stuck = !!(lv && lv.escalated);                      // 워치독이 자가복구 N회 실패로 포기 → 사람 필요
    const wedged = !!(lv && lv.wedged && alive);               // 탭은 살아있으나 화면이 WEDGE_SEC 이상 정지 = 멈춘 claude → 사람 확인(자동 kill 안 함)
    const healing = !!(lv && lv.attempts > 0 && !lv.escalated && !alive);  // 자가복구 진행중(조용, 경보 아님)
    const gateResolved = i.flag === 'human-gate' && existsSync(`${st}/decisions/${i.id}.md`);
    // 표시 상태 = 라이브 신호(PR + 탭) 우선. snapshot은 시간당 1회라 뒤처지므로 보조로만.
    let state = i.state, working = false;
    if (live && live.merged) state = 'Done';
    else if (live && live.state === 'OPEN') state = 'In Review';
    else if (live && live.state === 'CLOSED') state = (i.state === 'Done' || i.state === 'Canceled') ? i.state : 'In Review';  // 닫힘=정리 대상 → In Review 버킷 + pr-closed 플래그로 표시
    else if (!live && alive && i.state !== 'Done' && i.state !== 'Canceled') { state = 'In Progress'; working = true; }  // PR 아직 없고 탭 살아있음 = 진짜 작업중
    // 박제 감지: snapshot은 In Progress인데 라이브 탭도 PR도 없음 = 죽었거나 완료 후 탭이 닫힌 worker (이미 계산된 alive/live만 조합, 신규 IO 없음). direct 모드는 PR이 상시 null이라 특히 필요.
    const stalled = i.state === 'In Progress' && !alive && !live;
    return {
      ...i, state, snapState: i.state, pr: (live && live.url) || i.pr || null,
      workspace: ws, alive, working, stalled, hasWorktree: existsSync(`${cfg.worktreePrefix || ''}-${slugOf(i.id)}`),
      merged: live ? live.merged : undefined, prState: live ? live.state : undefined, checks: live ? live.checks : undefined,
      ci: live ? live.ci : undefined, review: live ? live.review : undefined, reviewCount: live ? live.reviewCount : undefined,
      commentCount: live ? live.commentCount : undefined, gateResolved,
      stuck, wedged, healing, healAttempts: lv ? (lv.attempts || 0) : 0,
      // attention 우선순위: escalate된 stuck(강경) > wedged(멈춘 claude) > 워치독 독립 baseline stalled(단 자가복구중이면 억제). healing은 경보 아님(칩만).
      attention: (live ? live.attention : null) || (i.flag === 'human-gate' && !gateResolved ? 'human-gate' : null) || (stuck ? 'stuck' : null) || (wedged ? 'wedged' : null) || (stalled && !healing ? 'stalled-worker' : null),
    };
  }).sort((a, b) => (order[a.state] ?? 9) - (order[b.state] ?? 9));
  // counts는 파생 상태로 재계산 → 사이드바/카운트가 카드와 일치 (snap.counts는 시간당 1회라 뒤처짐).
  const counts = { Backlog: 0, 'In Progress': 0, 'In Review': 0, Done: 0, Canceled: 0 };
  for (const i of issues) if (counts[i.state] != null) counts[i.state]++;
  const lastExit = readText(`${st}/.last_run_exit`).trim();
  const lastRun = lastExit !== '' ? { exit: +lastExit, ts: +readText(`${st}/.last_run_done`).trim() || null } : null;
  const nextFile = readText(`${st}/next_fire`).trim();
  const gd = globalDispatcher();
  const nextTs = (gd.running && !existsSync(`${st}/PAUSED`) && cfg.enabled !== false && nextFile) ? +nextFile : null;
  return {
    id: lid, name: cfg.name || lid, emoji: cfg.emoji || '🔁', enabled: cfg.enabled !== false,
    repo: cfg.repo || '', linearProjectUrl: cfg.linearProjectUrl || '', maxWorkers: cfg.maxWorkers || 2,
    delivery: cfg.delivery || 'pr',
    schedule: cfg.schedule || { intervalSec: 3600, startAt: null }, paused: existsSync(`${st}/PAUSED`),
    nextTs, lastRun, counts, issues, feed: f.slice(-40).reverse(),
    attentionCount: issues.filter(i => i.attention).length,
    // "정리 필요" = Linear(snapshot)는 아직 In Review인데 PR은 이미 머지/닫힘 → reconcile 유도
    mergedInReview: issues.filter(i => i.snapState === 'In Review' && i.merged).length,
    closedInReview: issues.filter(i => i.snapState === 'In Review' && i.prState === 'CLOSED' && !i.merged).length,
    orchRunning: existsSync(`/tmp/loop-${lid}.lockdir`),
  };
}
function status() {
  const allTabs = tabsAll();
  return { now: Math.floor(Date.now() / 1000), dispatcher: globalDispatcher(), awake: !!awakeStatus(), linearKey: !!LINEAR_KEY, telegram: telegramStatus(), loops: listLoopIds().map(l => loopStatus(l, allTabs)) };
}

function sh(cmd, args) { return new Promise(r => execFile(cmd, args, { timeout: 12000 }, (e, so, se) => r({ ok: !e, out: (so || '') + (se || '') }))); }
function activateCmux() { try { execFile('osascript', ['-e', `tell application id "${CMUX_BUNDLE}" to activate`], () => {}); } catch {} }
function reorderBottom(ref) { try { const n = execFileSync(CMUX, ['list-workspaces'], { encoding: 'utf8', timeout: 4000 }).split('\n').filter(l => /workspace:\d+/.test(l)).length; execFile(CMUX, ['reorder-workspace', '--workspace', ref, '--index', String(n)], () => {}); } catch {} }
function cfgPath(lid) { return `${LOOPS}/${lid}/config.json`; }
function worktreeOf(lid, id) { const cfg = readJSON(cfgPath(lid)) || {}; return `${cfg.worktreePrefix || ''}-${slugOf(id)}`; }
function clearNextFire(lid) { try { execFile('/bin/rm', ['-f', `${LOOPS}/${lid}/state/next_fire`], () => {}); } catch {} }

// Linear GraphQL (Node 내장 https, 의존성 0). LINEAR_API_KEY=loops.env. 이슈 버리기(→Canceled)용.
function linearGQL(query, variables) {
  return new Promise((resolve, reject) => {
    const key = LINEAR_KEY;
    if (!key) return reject(new Error('LINEAR_API_KEY 없음 — 설정 ⚙️ 에서 Linear 키를 입력하세요'));
    const body = JSON.stringify({ query, variables });
    const req = https.request('https://api.linear.app/graphql', { method: 'POST', headers: { 'content-type': 'application/json', authorization: key, 'content-length': Buffer.byteLength(body) }, timeout: 15000 }, (res) => {
      let d = ''; res.on('data', c => d += c); res.on('end', () => { try { const j = JSON.parse(d); if (j.errors) return reject(new Error(j.errors.map(e => e.message).join('; '))); resolve(j.data); } catch (e) { reject(e); } });
    });
    req.on('error', reject); req.on('timeout', () => req.destroy(new Error('linear timeout')));
    req.end(body);
  });
}

async function control(a, p) {
  const lid = p.loop;
  switch (a) {
    case 'start': {
      // ▶ = "켜기": 이미 running이면 PAUSED를 해제(=resume)한다. running+paused일 때 ▶가 no-op으로 보이던 함정 제거.
      const gd = globalDispatcher();
      if (gd.running) { if (gd.paused) { await sh('/bin/rm', ['-f', GPAUSED]); return { ok: true, out: 'resumed (paused 해제)' }; } return { ok: true, out: 'already running' }; }
      const r = await sh(CMUX, ['new-workspace', '--cwd', ROOT, '--command', `${ROOT}/bin/dispatch.sh`]);
      const m = (r.out || '').match(/workspace:\d+/); if (m) { await sh(CMUX, ['rename-workspace', '--workspace', m[0], '🔁 loops dispatcher']); reorderBottom(m[0]); }
      return r;
    }
    case 'stop': { const pid = globalDispatcher().pid; if (pid) { try { process.kill(pid, 'SIGTERM'); } catch {} setTimeout(() => { try { if (pidAlive(pid)) process.kill(pid, 'SIGKILL'); } catch {} }, 1500); } execFile('/usr/bin/pkill', ['-f', `${ROOT}/bin/dispatch.sh`], () => {}); return { ok: true, out: 'stopped' }; }
    case 'pause': return sh('/usr/bin/touch', [GPAUSED]);
    case 'resume': return sh('/bin/rm', ['-f', GPAUSED]);
    case 'awake-on': {
      if (awakeStatus()) return { ok: true, out: '이미 잠자기 방지 중' };
      // caffeinate -i: idle 시스템 슬립 차단. detached+unref → 요청/서버 재시작과 무관하게 살아있고, awake-off에서 kill.
      const c = spawn('/usr/bin/caffeinate', ['-i'], { stdio: 'ignore', detached: true }); c.unref();
      if (!c.pid) return { ok: false, out: 'caffeinate 실행 실패' };
      try { writeFileSync(GAWAKE, String(c.pid)); } catch (e) { return { ok: false, out: '' + e }; }
      return { ok: true, out: '☕ 잠자기 방지 ON (idle 슬립 차단 — 뚜껑 닫기 잠자기는 막지 못함)' };
    }
    case 'awake-off': {
      const pid = awakeStatus(); if (pid) { try { process.kill(pid, 'SIGTERM'); } catch {} }
      execFile('/bin/rm', ['-f', GAWAKE], () => {});
      return { ok: true, out: '잠자기 방지 OFF' };
    }
    case 'run-now': { if (!lid) return { ok: false, out: 'no loop' }; if (existsSync(`/tmp/loop-${lid}.lockdir`)) return { ok: false, out: '⏳ 이미 orchestrator 실행 중입니다 — 끝난 뒤 다시 누르세요 (버튼이 "실행 중·로그"로 바뀌면 끝난 겁니다).' }; spawn(`${ROOT}/bin/spawn-orchestrator.sh`, [lid], { stdio: 'ignore' }); return { ok: true, out: lid + ' 사이클 발사' }; }
    case 'reconcile': { if (!lid) return { ok: false, out: 'no loop' }; if (existsSync(`/tmp/loop-${lid}.lockdir`)) return { ok: false, out: '⏳ orchestrator 실행 중이라 지금은 못 합니다. 현재 run이 끝나면 다음 run이 머지/닫힘 PR을 자동 정리합니다 (급하면 끝난 뒤 다시 누르세요).' }; spawn(`${ROOT}/bin/spawn-orchestrator.sh`, [lid, 'reconcile'], { stdio: 'ignore' }); return { ok: true, out: lid + ' PR 정리 중… (머지→Done, 닫힘→Canceled, ~1분)' }; }
    case 'resolve-gate': {
      if (!lid || !p.issue) return { ok: false, out: 'no loop/issue' };
      const decision = (p.decision || '').trim();
      if (!decision) return { ok: false, out: '결정 내용이 비어있음' };
      const ddir = `${LOOPS}/${lid}/state/decisions`;
      try { mkdirSync(ddir, { recursive: true }); writeFileSync(`${ddir}/${p.issue}.md`, decision); }
      catch (e) { return { ok: false, out: '결정 저장 실패: ' + e }; }
      spawn(`${ROOT}/bin/spawn-worker.sh`, [lid, p.issue], { stdio: 'ignore' }); setTimeout(activateCmux, 8000);
      return { ok: true, out: p.issue + ' 결정 저장 + 워커 시작 (human-gate 해제)' };
    }
    case 'loop-pause': { if (!lid) return { ok: false }; return sh('/usr/bin/touch', [`${LOOPS}/${lid}/state/PAUSED`]); }
    case 'loop-resume': { if (!lid) return { ok: false }; return sh('/bin/rm', ['-f', `${LOOPS}/${lid}/state/PAUSED`]); }
    case 'toggle-enabled': {
      if (!lid) return { ok: false }; const cfg = readJSON(cfgPath(lid)); if (!cfg) return { ok: false, out: 'no config' };
      cfg.enabled = !(cfg.enabled !== false); writeFileSync(cfgPath(lid), JSON.stringify(cfg, null, 2));
      return { ok: true, out: lid + ' enabled=' + cfg.enabled };
    }
    case 'set-schedule': {
      if (!lid) return { ok: false }; const cfg = readJSON(cfgPath(lid)); if (!cfg) return { ok: false };
      cfg.schedule = cfg.schedule || {};
      if (p.intervalMin != null) cfg.schedule.intervalSec = Math.max(60, Math.round(+p.intervalMin * 60));
      if (p.startAt !== undefined) cfg.schedule.startAt = p.startAt || null;
      writeFileSync(cfgPath(lid), JSON.stringify(cfg, null, 2));
      clearNextFire(lid);
      return { ok: true, out: 'schedule 저장' };
    }
    case 'focus': { if (!p.workspace) return { ok: false }; const r = await sh(CMUX, ['select-workspace', '--workspace', p.workspace]); activateCmux(); return r; }
    case 'open-issue': {
      if (!lid || !p.issue) return { ok: false, out: 'no loop/issue' };
      const t = tabsAll().find(t => new RegExp('🛠\\s*' + lid + '\\s+' + p.issue, 'i').test(t.title));
      if (t) { const r = await sh(CMUX, ['select-workspace', '--workspace', t.ref]); activateCmux(); return r; }
      const wt = worktreeOf(lid, p.issue);
      if (!existsSync(wt)) return { ok: false, out: 'worktree 없음(정리됨)' };
      const r = await sh(CMUX, ['new-workspace', '--cwd', wt, '--command', 'claude --resume']);
      const m = (r.out || '').match(/workspace:\d+/); if (m) { await sh(CMUX, ['rename-workspace', '--workspace', m[0], '↩ ' + lid + ' ' + p.issue]); reorderBottom(m[0]); }
      activateCmux(); return r;
    }
    case 'start-issue': { if (!lid || !p.issue) return { ok: false }; spawn(`${ROOT}/bin/spawn-worker.sh`, [lid, p.issue], { stdio: 'ignore' }); setTimeout(activateCmux, 8000); return { ok: true, out: p.issue + ' worker 시작 중...' }; }
    case 'heal-issue': {   // stuck 이슈 수동 재시도: liveness 카운터 리셋(escalated 해제) + worktree 보존 재기동.
      if (!lid || !p.issue) return { ok: false };
      try { const lp = `${LOOPS}/${lid}/state/liveness.json`; const lo = readJSON(lp) || {}; delete lo[p.issue]; writeFileSync(lp, JSON.stringify(lo)); } catch {}
      spawn(`${ROOT}/bin/heal-worker.sh`, [lid, p.issue], { stdio: 'ignore' }); setTimeout(activateCmux, 8000);
      return { ok: true, out: p.issue + ' 재시도 중… (자가복구 카운터 리셋)' };
    }
    case 'close-tab': { if (!p.workspace) return { ok: false, out: 'no workspace' }; return sh(CMUX, ['close-workspace', '--workspace', p.workspace]); }
    case 'cleanup-issue': { if (!lid || !p.issue) return { ok: false, out: 'no issue' }; spawn(`${ROOT}/bin/cleanup-issue.sh`, [lid, p.issue], { stdio: 'ignore' }); return { ok: true, out: p.issue + ' 정리 중… (탭·worktree·브랜치 제거)' }; }
    case 'cancel-issue': {   // 이슈 버리기: Linear → Canceled + 세션 탭·worktree·브랜치 정리. snapshot 패치로 보드 즉시 반영.
      if (!lid || !p.issue) return { ok: false, out: 'no issue' };
      try {
        const q = await linearGQL(`query($id:String!){ issue(id:$id){ id team { states { nodes { id type } } } } }`, { id: p.issue });
        const iss = q && q.issue; if (!iss) return { ok: false, out: p.issue + ' Linear에서 못 찾음' };
        const st = ((iss.team && iss.team.states && iss.team.states.nodes) || []).find(s => s.type === 'canceled');
        if (!st) return { ok: false, out: '팀에 Canceled 상태가 없음' };
        const m = await linearGQL(`mutation($id:String!,$s:String!){ issueUpdate(id:$id, input:{stateId:$s}){ success } }`, { id: iss.id, s: st.id });
        if (!(m && m.issueUpdate && m.issueUpdate.success)) return { ok: false, out: 'Linear 업데이트 실패' };
      } catch (e) { return { ok: false, out: 'Linear: ' + e.message }; }
      try { const sp = `${LOOPS}/${lid}/state/snapshot.json`; const snap = readJSON(sp); if (snap && Array.isArray(snap.issues)) { const it = snap.issues.find(x => x.id === p.issue); if (it) { it.state = 'Canceled'; writeFileSync(sp, JSON.stringify(snap, null, 2)); } } } catch {}
      try { await sh(`${ROOT}/bin/cleanup-issue.sh`, [lid, p.issue]); } catch {}   // 탭 닫기 + worktree·브랜치 제거(제목으로 매칭하므로 ref 불필요)
      return { ok: true, out: p.issue + ' → Canceled · 세션 탭·worktree 정리' };
    }
    case 'create-issue': {   // Linear 이슈 생성 → 루프의 project Backlog. start:true 면 즉시 워커 spawn. (텔레그램 에이전트/향후 대시보드 "+태스크"용)
      if (!lid) return { ok: false, out: 'no loop' };
      const cfg = readJSON(cfgPath(lid)); if (!cfg) return { ok: false, out: 'no config' };
      const pid = cfg.linearProjectId; if (!pid) return { ok: false, out: lid + ' config에 linearProjectId 없음' };
      const title = (p.title || '').trim(); if (!title) return { ok: false, out: 'title 필요' };
      let iss;
      try {
        // project → team + backlog 상태(최저 position). linear-move.mjs와 동일 패턴.
        const q = await linearGQL(`query($pid:String!){ project(id:$pid){ teams(first:1){ nodes{ id states(first:50){ nodes{ id type position } } } } } }`, { pid });
        const team = q?.project?.teams?.nodes?.[0];
        if (!team) return { ok: false, out: 'project의 team을 못 찾음' };
        const bl = (team.states?.nodes || []).filter(s => s.type === 'backlog').sort((a, b) => a.position - b.position)[0];
        const input = { teamId: team.id, projectId: pid, title, description: p.description || '', ...(bl ? { stateId: bl.id } : {}) };
        const m = await linearGQL(`mutation($in:IssueCreateInput!){ issueCreate(input:$in){ success issue{ id identifier url } } }`, { in: input });
        iss = m?.issueCreate?.issue;
        if (!(m?.issueCreate?.success && iss)) return { ok: false, out: 'Linear issueCreate 실패' };
      } catch (e) { return { ok: false, out: 'Linear: ' + e.message }; }
      if (p.start) { spawn(`${ROOT}/bin/spawn-worker.sh`, [lid, iss.identifier], { stdio: 'ignore' }); setTimeout(activateCmux, 8000); }
      return { ok: true, out: `${iss.identifier} 생성${p.start ? ' + 워커 시작' : ' (Backlog)'}`, identifier: iss.identifier, url: iss.url };
    }
    case 'set-linear-key': {   // UI에서 Linear 개인키 입력 → 런타임 즉시 적용 + loops.env 영속화 (값은 어디에도 되돌려주지 않음)
      const key = (p.key || '').trim();
      if (!key) return { ok: false, out: '키가 비었음' };
      LINEAR_KEY = key;
      try { setEnvVar('LINEAR_API_KEY', key); } catch (e) { return { ok: false, out: 'loops.env 저장 실패: ' + e.message }; }
      return { ok: true, out: 'Linear 키 저장됨 (즉시 적용 · 재시작 불필요)' };
    }
    case 'set-telegram': {   // UI에서 Telegram 봇 토큰 입력 → loops.env 영속화 (값은 되돌려주지 않음). chat-id는 봇이 첫 메시지에서 자동 페어링.
      const token = (p.token || '').trim();
      if (!token) return { ok: false, out: '토큰이 비었음' };
      try { setEnvVar('TELEGRAM_BOT_TOKEN', token); } catch (e) { return { ok: false, out: 'loops.env 저장 실패: ' + e.message }; }
      return { ok: true, out: '봇 토큰 저장됨 — "봇 시작" 후 텔레그램에서 봇에게 아무 메시지를 보내면 페어링됩니다.' };
    }
    case 'bot-start': {   // Telegram 브리지를 cmux 패널로 기동 (dashboard/dispatcher와 동일 방식). 봇은 /api/status·/api/control만 호출 — merge/deploy/force-push 없음.
      if (botRunning()) return { ok: true, out: '봇 이미 실행 중' };
      if (!loadEnv().TELEGRAM_BOT_TOKEN) return { ok: false, out: '먼저 봇 토큰을 저장하세요.' };
      const r = await sh(CMUX, ['new-workspace', '--cwd', ROOT, '--command', `node --watch ${ROOT}/bin/notify-bot.mjs`]);
      const m = (r.out || '').match(/workspace:\d+/); if (m) { await sh(CMUX, ['rename-workspace', '--workspace', m[0], '🤖 loops bot']); reorderBottom(m[0]); }
      return { ok: true, out: '🤖 봇 시작 (cmux 패널) — 페어링 안 됐으면 텔레그램에서 봇에게 메시지 보내세요' };
    }
    case 'bot-stop': { execFile('/usr/bin/pkill', ['-f', `${ROOT}/bin/notify-bot.mjs`], () => {}); return { ok: true, out: '봇 중지' }; }
    case 'save-mission': { if (!lid) return { ok: false }; try { writeFileSync(`${LOOPS}/${lid}/mission.md`, p.content || ''); return { ok: true, out: 'mission 저장' }; } catch (e) { return { ok: false, out: '' + e }; } }
    case 'save-config': {
      if (!lid) return { ok: false }; const cfg = readJSON(cfgPath(lid)) || {};
      for (const k of ['name', 'emoji', 'repo', 'linearProjectId', 'linearProjectUrl', 'orchestratorWorktree', 'worktreePrefix', 'branchPrefix', 'baseRef', 'prBase', 'claudeCmd']) if (p[k] !== undefined) cfg[k] = p[k];
      if (p.maxWorkers != null) cfg.maxWorkers = Math.max(1, +p.maxWorkers);
      if (p.backlogTarget != null) cfg.backlogTarget = Math.max(1, +p.backlogTarget);
      writeFileSync(cfgPath(lid), JSON.stringify(cfg, null, 2)); return { ok: true, out: 'config 저장' };
    }
    case 'save-config-raw': {
      if (!lid) return { ok: false }; let obj = p.config;
      if (typeof obj === 'string') { try { obj = JSON.parse(obj); } catch (e) { return { ok: false, out: 'JSON 파싱 실패: ' + e.message }; } }
      if (!obj || obj.id !== lid) return { ok: false, out: 'id 불일치/누락 — id는 "' + lid + '" 여야 함' };
      writeFileSync(cfgPath(lid), JSON.stringify(obj, null, 2));
      clearNextFire(lid);
      return { ok: true, out: 'config 저장됨' };
    }
    case 'delete-loop': {
      const id = slugOf(lid || ''); if (!id) return { ok: false, out: 'no loop' };
      const dir = `${LOOPS}/${id}`; if (!dir.startsWith(LOOPS + '/') || !existsSync(dir)) return { ok: false, out: '경로 오류/없음' };
      try { execFileSync(`${ROOT}/bin/cleanup-loop.sh`, [id], { timeout: 60000 }); } catch {}   // rm 전에 worktree·탭 정리(config 살아있는 동안)
      execFile('/bin/rm', ['-rf', dir], () => {}); return { ok: true, out: id + ' loop 삭제됨 (worktree·탭 정리 · Linear는 보존)' };
    }
    case 'build-loop': {
      const desc = p.description; if (!desc) return { ok: false, out: '설명 필요' };
      const b64 = Buffer.from(String(desc), 'utf8').toString('base64');
      const r = await sh(CMUX, ['new-workspace', '--cwd', ROOT, '--command', `${ROOT}/bin/build-loop.sh ${b64}`]);
      const m = (r.out || '').match(/workspace:\d+/); if (m) { await sh(CMUX, ['rename-workspace', '--workspace', m[0], '🤖 loop builder']); reorderBottom(m[0]); }
      activateCmux(); return { ok: true, out: '🤖 루프 빌더 시작 — 새 탭에서 진행을 보세요. 완료되면 사이드바에 loop가 뜹니다.' };
    }
    case 'create-loop': {
      const id = slugOf(p.id || ''); if (!id) return { ok: false, out: 'id 필요' };
      if (existsSync(`${LOOPS}/${id}`)) return { ok: false, out: '이미 존재: ' + id };
      mkdirSync(`${LOOPS}/${id}/state`, { recursive: true });
      const cfg = {
        id, name: p.name || id, emoji: p.emoji || '🔁', repo: p.repo || '',
        baseRef: p.baseRef || 'origin/develop', prBase: p.prBase || 'develop', branchPrefix: 'loop-' + id,
        orchestratorWorktree: p.orchestratorWorktree || `${WORKTREE_BASE}/loop-${id}`,
        worktreePrefix: p.worktreePrefix || `${WORKTREE_BASE}/loop-${id}`,
        linearProjectId: p.linearProjectId || '', linearProjectUrl: p.linearProjectUrl || '',
        maxWorkers: +p.maxWorkers || 2, schedule: { startAt: p.startAt || null, intervalSec: Math.max(60, Math.round((+p.intervalMin || 120) * 60)) }, enabled: false,
      };
      writeFileSync(cfgPath(id), JSON.stringify(cfg, null, 2));
      writeFileSync(`${LOOPS}/${id}/mission.md`, p.mission || '(이 루프의 임무를 정의하세요)');
      return { ok: true, out: 'loop 생성: ' + id + ' (enabled=false, 켜려면 toggle)' };
    }
    default: return { ok: false, out: 'unknown: ' + a };
  }
}

function sessionText(u) {
  if (u.searchParams.get('bot')) {   // Telegram 봇이 주고받은 로그 (state/bot-log.jsonl) — 사람이 읽게 포맷
    const lines = readText(`${GSTATE}/bot-log.jsonl`).split('\n').filter(Boolean).slice(-300);
    if (!lines.length) return '(봇 로그 없음 — Telegram 봇이 아직 주고받은 기록이 없습니다. loops.env에 토큰 저장 후 "봇 시작")';
    return lines.map(l => { try { const e = JSON.parse(l); const t = new Date(e.ts * 1000).toLocaleTimeString(); return `${t}  ${e.dir === 'in' ? '▸ 나 ' : '◂ 봇 '} ${e.text}`; } catch { return l; } }).join('\n');
  }
  if (u.searchParams.get('ref')) { try { return execFileSync(CMUX, ['read-screen', '--workspace', u.searchParams.get('ref'), '--lines', '300'], { encoding: 'utf8', timeout: 5000 }); } catch (e) { return '(read-screen 실패)'; } }
  if (u.searchParams.get('dispatcher')) return readText(`${GSTATE}/dispatcher.log`).split('\n').slice(-300).join('\n');
  const lid = u.searchParams.get('loop'); if (lid) return readText(`${LOOPS}/${lid}/state/run.log`).split('\n').slice(-300).join('\n');
  return '(no ref/loop)';
}
function promptText(u) { const lid = u.searchParams.get('loop'); if (!lid) return ''; return readText(`${LOOPS}/${lid}/mission.md`); }

// 원격 노출 인증 게이트: 프록시(터널) 경유 요청에만 Basic auth 요구. 로컬 직접(127.0.0.1, XFF 없음)은 무인증이라 cmux 패널 사용은 그대로.
// LOOPS_REMOTE_AUTH="user:pass" (loops.env). 미설정이면 게이트 비활성 = 로컬 전용 기본 동작 유지.
const REMOTE_AUTH = ENV.LOOPS_REMOTE_AUTH || process.env.LOOPS_REMOTE_AUTH || '';
function viaProxy(req) { return !!(req.headers['x-forwarded-for'] || req.headers['cf-connecting-ip'] || req.headers['x-forwarded-host']); }
function authOK(req) {
  if (!REMOTE_AUTH) return true;     // 토큰 미설정 → 게이트 없음
  if (!viaProxy(req)) return true;   // 로컬 직접 접속 → 신뢰 (터널은 항상 XFF를 붙임)
  const m = /^Basic (.+)$/.exec(req.headers.authorization || '');
  if (!m) return false;
  try { return Buffer.from(m[1], 'base64').toString() === REMOTE_AUTH; } catch { return false; }
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://localhost');
  if (!authOK(req)) { res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="loops dashboard"', 'content-type': 'text/plain; charset=utf-8' }); res.end('인증 필요'); return; }
  // HTML은 요청마다 fresh 읽기 → dashboard.html 편집 시 새로고침만 하면 즉시 반영 (서버 재시작 불필요)
  if (req.method === 'GET' && u.pathname === '/') { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(readText(`${ROOT}/dashboard.html`) || '<h1>dashboard.html 없음</h1>'); return; }
  // 벤더링된 정적 에셋(Oat UI 등) — 무빌드. 파일명 화이트리스트로 경로 탈출 차단.
  if (req.method === 'GET' && u.pathname.startsWith('/vendor/')) { const name = u.pathname.slice(8); if (!/^[a-zA-Z0-9._-]+$/.test(name)) { res.writeHead(400); res.end('bad'); return; } const body = readText(`${ROOT}/vendor/${name}`); if (!body) { res.writeHead(404); res.end('not found'); return; } const ct = name.endsWith('.css') ? 'text/css; charset=utf-8' : name.endsWith('.js') ? 'text/javascript; charset=utf-8' : 'application/octet-stream'; res.writeHead(200, { 'content-type': ct, 'cache-control': 'max-age=3600' }); res.end(body); return; }
  if (req.method === 'GET' && u.pathname === '/api/status') { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(status())); return; }
  if (req.method === 'GET' && u.pathname === '/api/session') { res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' }); res.end(sessionText(u)); return; }
  if (req.method === 'GET' && u.pathname === '/api/mission') { res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' }); res.end(promptText(u)); return; }
  if (req.method === 'GET' && u.pathname === '/api/config') { const lid = u.searchParams.get('loop'); res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(readJSON(cfgPath(lid)) || {}, null, 2)); return; }
  if (req.method === 'POST' && u.pathname === '/api/control') {
    let b = ''; req.on('data', d => b += d); req.on('end', async () => { let p = {}; try { p = JSON.parse(b || '{}'); } catch {} const r = await control(p.action, p); res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(r)); }); return;
  }
  res.writeHead(404); res.end('not found');
});
server.listen(PORT, '127.0.0.1', () => console.log(`Loops dashboard → http://localhost:${PORT}`));
refreshPRs(); setInterval(refreshPRs, 60000);
