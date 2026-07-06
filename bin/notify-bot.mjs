#!/usr/bin/env node
// Loops — Telegram 원격 알림·제어 브리지. 의존성 0 (Node 내장 http/https).
// 밖(Telegram) ↔ 안(대시보드 127.0.0.1:PORT /api/status·/api/control)을 잇는 다리.
//   · 아웃바운드: /api/status 를 주기적으로 diff → human-gate/PR/CI/사이클오류를 폰으로 push
//   · 인바운드: getUpdates long-poll → 버튼 탭·답장·슬래시 명령 → /api/control
// cmux 소켓은 쓰지 않는다(HTTP만). 모든 제어는 서버가 대신 수행 → 엔진 변경 0.
// 안전 불변식: 봇은 merge/deploy/force-push 하지 않는다. 노출 파괴적 액션은 cancel/cleanup뿐이며 2탭 확인.
import http from 'node:http';
import https from 'node:https';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const ROOT = process.env.LOOPS_HOME || dirname(dirname(fileURLToPath(import.meta.url)));
function loadEnv() { const e = {}; try { for (const l of readFileSync(`${ROOT}/loops.env`, 'utf8').split('\n')) { const m = l.match(/^\s*([A-Z_]+)\s*=\s*(.*)$/); if (m) e[m[1]] = m[2].trim().replace(/^["']|["']$/g, ''); } } catch {} return e; }
const ENV = loadEnv();
const PORT = +(ENV.LOOPS_PORT || process.env.LOOPS_PORT || 8422);
const TOKEN = ENV.TELEGRAM_BOT_TOKEN || process.env.TELEGRAM_BOT_TOKEN || '';
let CHAT = ENV.TELEGRAM_CHAT_ID || process.env.TELEGRAM_CHAT_ID || '';   // 런타임 갱신(페어링) → loops.env 영속화
const NOTIFY_FILE = `${ROOT}/state/notify.json`;
const POLL_SEC = +(ENV.LOOPS_BOT_POLL_SEC || process.env.LOOPS_BOT_POLL_SEC || 45);
const CLAUDE_BIN = ENV.CLAUDE_BIN || process.env.CLAUDE_BIN || 'claude';   // 자연어 이해에 쓰는 두뇌 (플랫폼 전제 도구)
const BOT_MODEL = ENV.LOOPS_BOT_MODEL || process.env.LOOPS_BOT_MODEL || 'claude-haiku-4-5-20251001';   // 라우팅용 — 빠른 모델

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const readJSON = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
// loops.env 의 키를 갱신-또는-추가(dashboard-server.setEnvVar 와 동일 규칙). preserved 키라 재설치에도 보존됨.
function setEnvVar(k, v) { const p = `${ROOT}/loops.env`; let t = ''; try { t = readFileSync(p, 'utf8'); } catch {} const ln = `${k}=${v}`; const re = new RegExp('^' + k + '=.*$', 'm'); t = re.test(t) ? t.replace(re, ln) : (t.replace(/\n?$/, '\n') + ln + '\n'); writeFileSync(p, t); }
const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// ── notify.json: 이미 보낸 신호(seen) + 답장용 pending(msgId→{loop,issue}) 영속 ──
function loadNotify() { return readJSON(NOTIFY_FILE) || { seen: {}, pending: {} }; }
function saveNotify(n) { try { writeFileSync(NOTIFY_FILE, JSON.stringify(n, null, 2)); } catch (e) { log('notify.json 저장 실패:', e.message); } }
// 대시보드에서 볼 수 있게 주고받은 로그를 state/bot-log.jsonl 에 append (최근 200줄 유지). dir: 'in'=사용자→봇, 'out'=봇→사용자.
const BOTLOG_FILE = `${ROOT}/state/bot-log.jsonl`;
function botlog(dir, text) {
  try {
    let lines = []; try { lines = readFileSync(BOTLOG_FILE, 'utf8').split('\n').filter(Boolean); } catch {}
    lines.push(JSON.stringify({ ts: Math.floor(Date.now() / 1000), dir, text: String(text).slice(0, 300) }));
    if (lines.length > 200) lines = lines.slice(-200);
    writeFileSync(BOTLOG_FILE, lines.join('\n') + '\n');
  } catch (e) { log('bot-log 저장 실패:', e.message); }
}

// ── Telegram Bot API (node:https, zero-dep) ──
function tg(method, body) {
  return new Promise((resolve) => {
    const data = Buffer.from(JSON.stringify(body || {}));
    const req = https.request(`https://api.telegram.org/bot${TOKEN}/${method}`,
      { method: 'POST', headers: { 'content-type': 'application/json', 'content-length': data.length }, timeout: 40000 },
      (res) => { let b = ''; res.on('data', c => b += c); res.on('end', () => { let j = null; try { j = JSON.parse(b); } catch {} resolve(j); }); });
    req.on('error', (e) => { log('tg', method, 'err:', e.message); resolve(null); });
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.write(data); req.end();
  });
}
const send = (text, keyboard) => tg('sendMessage', { chat_id: CHAT, text, parse_mode: 'HTML', disable_web_page_preview: true, ...(keyboard ? { reply_markup: { inline_keyboard: keyboard } } : {}) });
const answerCb = (id, text) => tg('answerCallbackQuery', { callback_query_id: id, ...(text ? { text } : {}) });
const editMarkup = (mid, keyboard) => tg('editMessageReplyMarkup', { chat_id: CHAT, message_id: mid, reply_markup: { inline_keyboard: keyboard } });
const editText = (mid, text, keyboard) => tg('editMessageText', { chat_id: CHAT, message_id: mid, text, parse_mode: 'HTML', disable_web_page_preview: true, ...(keyboard ? { reply_markup: { inline_keyboard: keyboard } } : {}) });

// ── 로컬 대시보드 HTTP (127.0.0.1 → basic-auth 자동 통과) ──
function api(method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body ? Buffer.from(JSON.stringify(body)) : null;
    const req = http.request({ host: '127.0.0.1', port: PORT, path, method, timeout: 15000, headers: data ? { 'content-type': 'application/json', 'content-length': data.length } : {} },
      (res) => { let b = ''; res.on('data', c => b += c); res.on('end', () => { try { resolve(JSON.parse(b)); } catch { resolve(null); } }); });
    req.on('error', reject); req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    if (data) req.write(data); req.end();
  });
}
const getStatus = () => api('GET', '/api/status');
const ctrl = (action, params) => api('POST', '/api/control', { action, ...params });

// ── 신호 → 사람이 읽을 문구/이모지 ──
const ATT = {
  'human-gate': { emoji: '🔴', label: '사람 판단 필요' },
  'merge-ready': { emoji: '🟢', label: '리뷰 승인 · 머지 준비 (GitHub에서 머지)' },
  'ci-failed': { emoji: '❌', label: 'CI 실패' },
  'changes': { emoji: '✍️', label: '변경 요청됨' },
  'pr-closed': { emoji: '🚪', label: 'PR 닫힘 (정리 대상)' },
  'stuck': { emoji: '🧟', label: '워커 멈춤 — 자가복구 실패 (재시도/버리기 필요)' },
};
const STATE_EMOJI = { 'In Progress': '🔨', 'In Review': '👀', 'Backlog': '📋', 'Done': '✅', 'Canceled': '🚫' };

// 한 (loop,issue,attention) → 알림 메시지 {text, keyboard}
function messageFor(loop, issue, att) {
  const head = `${loop.emoji} <b>${esc(loop.name)}</b>`;
  const line = `${ATT[att].emoji} <b>${esc(issue.id)}</b> ${esc(issue.title)}`;
  const kb = [];
  if (att === 'human-gate') {
    const ask = issue.gate && issue.gate.ask ? `\n⚖️ ${esc(issue.gate.ask)}` : '';
    kb.push([{ text: '✅ 그대로 진행', callback_data: `ok|${loop.id}|${issue.id}` }, { text: '🗑 취소', callback_data: `cxl|${loop.id}|${issue.id}` }]);
    if (issue.url) kb.push([{ text: '🔗 이슈', url: issue.url }]);
    return { text: `${head}\n${line}${ask}\n\n💬 이 메시지에 <b>답장</b>으로 결정을 적어 보내면 그대로 워커에 전달됩니다.`, keyboard: kb };
  }
  if (att === 'pr-closed') kb.push([{ text: '🧹 정리', callback_data: `cln|${loop.id}|${issue.id}` }]);
  if (att === 'stuck') kb.push([{ text: '↻ 재시도', callback_data: `heal|${loop.id}|${issue.id}` }, { text: '🗑 버리기', callback_data: `cxl|${loop.id}|${issue.id}` }]);
  if (issue.pr) kb.push([{ text: '🔗 PR 열기', url: issue.pr }]);
  else if (issue.url) kb.push([{ text: '🔗 이슈', url: issue.url }]);
  return { text: `${head}\n${line}\n${ATT[att].emoji} ${ATT[att].label}`, keyboard: kb.length ? kb : null };
}

// ── 아웃바운드: /api/status diff → 새 신호만 push ──
let seeded = existsSync(NOTIFY_FILE);   // notify.json 이미 있으면 diff, 없으면 첫 폴링은 조용히 시드(과거분 폭탄 방지)
async function pollStatus() {
  if (!CHAT) return;   // 페어링 전엔 diff/시드 안 함 — 안 그러면 미전송 신호를 seen 처리해 페어링 후 놓친다
  let st; try { st = await getStatus(); } catch (e) { log('대시보드 미응답(스킵):', e.message); return; }
  if (!st || !Array.isArray(st.loops)) return;
  const n = loadNotify();
  const cur = {};   // 이번에 살아있는 신호 키 집합
  const fresh = [];
  for (const loop of st.loops) {
    for (const issue of (loop.issues || [])) {
      if (!issue.attention || !ATT[issue.attention]) continue;
      const key = `${loop.id}|${issue.id}|${issue.attention}`;
      cur[key] = true;
      if (!n.seen[key]) fresh.push({ loop, issue, att: issue.attention, key });
    }
    if (loop.lastRun && loop.lastRun.exit && loop.lastRun.exit !== 0) {
      const key = `${loop.id}||run-error@${loop.lastRun.ts || 0}`;
      cur[key] = true;
      if (!n.seen[key]) fresh.push({ loop, att: 'run-error', key });
    }
  }
  n.seen = cur;   // 사라진 신호는 seen에서 제거 → 재발생 시 다시 알림
  if (!seeded) { seeded = true; saveNotify(n); log(`시드 완료 — 현재 신호 ${Object.keys(cur).length}개는 알림 없이 봄 처리`); return; }
  for (const f of fresh) {
    if (f.att === 'run-error') { await send(`${f.loop.emoji} <b>${esc(f.loop.name)}</b>\n⚠️ 오케스트레이터 사이클 오류 (exit ${f.loop.lastRun.exit}) — 대시보드에서 run.log 확인`); botlog('out', `⚠️ ${f.loop.id} 사이클오류 exit ${f.loop.lastRun.exit}`); continue; }
    const m = messageFor(f.loop, f.issue, f.att);
    botlog('out', `🔔 ${ATT[f.att].emoji} ${f.issue.id} ${f.att} (${f.loop.id})`);
    const r = await send(m.text, m.keyboard);
    const mid = r && r.ok && r.result && r.result.message_id;
    if (mid && f.att === 'human-gate') { n.pending[mid] = { loop: f.loop.id, issue: f.issue.id }; }
  }
  // pending 맵이 너무 커지지 않게 최근 50개만 유지
  const keys = Object.keys(n.pending); if (keys.length > 50) for (const k of keys.slice(0, keys.length - 50)) delete n.pending[k];
  saveNotify(n);
  if (fresh.length) log(`알림 ${fresh.length}건 발송`);
}

// ── 인터랙티브 메뉴: 탭만으로 전 loop·태스크·제어 ──
// 루트: 디스패처/awake 전역 제어 + 루프 목록 버튼
async function menuView() {
  const st = await getStatus().catch(() => null);
  if (!st) return { text: '⚠️ 대시보드 미응답 — loopctl dashboard 확인', keyboard: [[{ text: '🔄 다시', callback_data: 'menu' }]] };
  const d = st.dispatcher;
  const head = `🕹 <b>Loops 컨트롤</b>\n디스패처: ${d.running ? (d.paused ? '⏸ 일시정지' : '● 실행중') : '○ 정지'} · 잠자기방지 ${st.awake ? '☕ ON' : 'off'}`;
  const kb = [];
  kb.push(d.running ? [{ text: d.paused ? '▶ 재개' : '⏸ 일시정지', callback_data: d.paused ? 'g-resume' : 'g-pause' }, { text: '⏹ 중지', callback_data: 'g-stop' }] : [{ text: '▶ 디스패처 시작', callback_data: 'g-start' }]);
  kb.push([{ text: st.awake ? '☕ 잠자기방지 끄기' : '☕ 잠자기방지 켜기', callback_data: st.awake ? 'g-awakeoff' : 'g-awakeon' }]);
  for (const l of st.loops) { const a = l.issues.filter(i => i.attention).length; const ip = l.counts['In Progress'] + l.counts['In Review']; kb.push([{ text: `${l.emoji} ${l.name}${a ? ` 🔴${a}` : ''}${ip ? ` · ${ip}건` : ''}${l.paused ? ' ⏸' : (l.enabled ? '' : ' (off)')}`, callback_data: `L|${l.id}` }]); }
  kb.push([{ text: '🔄 새로고침', callback_data: 'menu' }]);
  return { text: head + '\n\n루프를 눌러 상세·제어 →', keyboard: kb };
}
// 루프 상세: counts + run-now/reconcile/pause/enable + 작업 보기
async function loopView(id) {
  const st = await getStatus().catch(() => null); const l = (st?.loops || []).find(x => x.id === id);
  if (!l) return { text: '루프 없음', keyboard: [[{ text: '◀ 메뉴', callback_data: 'menu' }]] };
  const c = l.counts;
  const text = `${l.emoji} <b>${esc(l.name)}</b> ${l.paused ? '⏸ 정지' : (l.enabled ? '' : '(off)')}\n📋 ${c.Backlog} · 🔨 ${c['In Progress']} · 👀 ${c['In Review']} · ✅ ${c.Done}${l.attentionCount ? `\n🔴 주의 ${l.attentionCount}건` : ''}`;
  const kb = [
    [{ text: '⚡ 실행', callback_data: `runnow|${id}` }, { text: '🧹 PR정리', callback_data: `recon|${id}` }],
    [{ text: l.paused ? '▶ 재개' : '⏸ 정지', callback_data: (l.paused ? 'lresume' : 'lpause') + '|' + id }, { text: l.enabled ? '🔀 끄기' : '🔀 켜기', callback_data: `enable|${id}` }],
    [{ text: '📋 작업 보기', callback_data: `T|${id}` }],
    [{ text: '◀ 메뉴', callback_data: 'menu' }],
  ];
  return { text, keyboard: kb };
}
// 작업 목록: 진행 중(In Progress/In Review) + 주의 이슈를 각각 액션 버튼과 함께 보냄
async function sendTasks(id) {
  const st = await getStatus().catch(() => null); const l = (st?.loops || []).find(x => x.id === id);
  if (!l) return send('루프 없음');
  const act = l.issues.filter(i => i.state === 'In Progress' || i.state === 'In Review' || i.attention);
  if (!act.length) return send(`${l.emoji} ${esc(l.name)} — 진행 중 작업 없음`);
  await send(`${l.emoji} <b>${esc(l.name)}</b> — 진행 중 ${act.length}건`);
  const n = loadNotify();
  for (const i of act) {
    const em = STATE_EMOJI[i.state] || '•';
    const kb = [];
    if (i.attention === 'human-gate') kb.push([{ text: '✅ 진행', callback_data: `ok|${id}|${i.id}` }, { text: '🗑 취소', callback_data: `cxl|${id}|${i.id}` }]);
    else kb.push([{ text: '🗑 취소', callback_data: `cxl|${id}|${i.id}` }, { text: '🧹 정리', callback_data: `cln|${id}|${i.id}` }]);
    if (i.pr) kb.push([{ text: '🔗 PR', url: i.pr }]); else if (i.url) kb.push([{ text: '🔗 이슈', url: i.url }]);
    const att = i.attention ? `\n${ATT[i.attention]?.emoji || '⚠️'} ${ATT[i.attention]?.label || i.attention}${i.gate?.ask ? ' — ' + esc(i.gate.ask) : ''}` : '';
    const r = await send(`${em} <b>${esc(i.id)}</b> ${esc(i.title)}${att}`, kb);
    const mid = r && r.ok && r.result && r.result.message_id;
    if (mid && i.attention === 'human-gate') n.pending[mid] = { loop: id, issue: i.id };
  }
  saveNotify(n);
}

// ── issue id → 그 이슈가 속한 loop id 찾기 ──
async function loopOfIssue(issueId) {
  const st = await getStatus().catch(() => null);
  const want = String(issueId).toUpperCase();
  for (const loop of (st?.loops || [])) for (const i of (loop.issues || [])) if (String(i.id).toUpperCase() === want) return { loopId: loop.id, issue: i };
  return null;
}

// ── 인바운드: 버튼 탭 ──
async function onCallback(cb) {
  const [act, loop, issue] = String(cb.data || '').split('|');
  const reply = (t) => answerCb(cb.id, t);
  const mid = cb.message && cb.message.message_id;
  // 내비게이션 (메시지를 그 자리에서 갱신)
  if (act === 'menu') { const v = await menuView(); await editText(mid, v.text, v.keyboard); return reply(); }
  if (act === 'L') { const v = await loopView(loop); await editText(mid, v.text, v.keyboard); return reply(); }
  if (act === 'T') { await reply(); return sendTasks(loop); }
  // 전역 디스패처·잠자기방지 → 실행 후 메뉴 갱신
  if (act[0] === 'g' && act[1] === '-') {
    const map = { 'g-start': 'start', 'g-pause': 'pause', 'g-resume': 'resume', 'g-stop': 'stop', 'g-awakeon': 'awake-on', 'g-awakeoff': 'awake-off' };
    const r = await ctrl(map[act], {}); await reply(r && r.ok ? '완료' : (r?.out || '실패'));
    const v = await menuView(); return editText(mid, v.text, v.keyboard);
  }
  // 루프 단위 액션 → 실행 후 루프 상세 갱신
  if (['runnow', 'recon', 'lpause', 'lresume', 'enable'].includes(act)) {
    const map = { runnow: 'run-now', recon: 'reconcile', lpause: 'loop-pause', lresume: 'loop-resume', enable: 'toggle-enabled' };
    const r = await ctrl(map[act], { loop }); await reply(r && r.ok ? '완료' : (r?.out || '실패'));
    const v = await loopView(loop); return editText(mid, v.text, v.keyboard);
  }
  if (act === 'nop') return reply('취소됨');
  if (act === 'ok') { const r = await ctrl('resolve-gate', { loop, issue, decision: '✅ 승인 — 이슈 계획대로 그대로 진행하라. (텔레그램에서 승인됨)' }); return reply(r && r.ok ? `${issue} 진행` : (r?.out || '실패')); }
  if (act === 'heal') { const r = await ctrl('heal-issue', { loop, issue }); return reply(r && r.ok ? `${issue} 재시도` : (r?.out || '실패')); }
  // 파괴적 액션: 1탭 → 확인 버튼으로 교체, 2탭(C) → 실행
  if (act === 'cxl') { await editMarkup(cb.message.message_id, [[{ text: '⚠️ 정말 취소?', callback_data: `cxlC|${loop}|${issue}` }, { text: '아니오', callback_data: 'nop' }]]); return reply(); }
  if (act === 'cln') { await editMarkup(cb.message.message_id, [[{ text: '⚠️ 정말 정리?', callback_data: `clnC|${loop}|${issue}` }, { text: '아니오', callback_data: 'nop' }]]); return reply(); }
  if (act === 'cxlC') { const r = await ctrl('cancel-issue', { loop, issue }); await editMarkup(cb.message.message_id, [[{ text: `🗑 ${issue} 취소됨`, callback_data: 'nop' }]]); return reply(r && r.ok ? '취소됨' : (r?.out || '실패')); }
  if (act === 'clnC') { const r = await ctrl('cleanup-issue', { loop, issue }); await editMarkup(cb.message.message_id, [[{ text: `🧹 ${issue} 정리됨`, callback_data: 'nop' }]]); return reply(r && r.ok ? '정리됨' : (r?.out || '실패')); }
  return reply('알 수 없는 동작');
}

// ── 자연어 채팅: "GOD-8 그냥 진행해", "지금 뭐 돌아가?" 같은 말 → claude로 의도 파악 → 액션 ──
function claudeRun(prompt) {
  return new Promise((resolve) => {
    execFile(CLAUDE_BIN, ['-p', prompt, '--model', BOT_MODEL, '--dangerously-skip-permissions'], { timeout: 60000, maxBuffer: 1 << 20 }, (err, stdout) => {
      if (err) log('claude 실패:', err.message);
      resolve(stdout || '');
    });
  });
}
function parseDecision(raw) { let s = String(raw || '').trim().replace(/^```(?:json)?/i, '').replace(/```$/, '').trim(); const a = s.indexOf('{'), b = s.lastIndexOf('}'); if (a < 0 || b < 0) return null; try { return JSON.parse(s.slice(a, b + 1)); } catch { return null; } }
function statusContext(st) {
  if (!st) return '(대시보드 미응답)';
  const L = [`디스패처: ${st.dispatcher.running ? (st.dispatcher.paused ? '일시정지' : '실행중') : '정지'} · 잠자기방지 ${st.awake ? 'ON' : 'off'}`];
  for (const l of st.loops) {
    const c = l.counts;
    L.push(`- loop id="${l.id}" 이름="${l.name}"${l.enabled ? '' : ' (비활성)'}${l.paused ? ' (일시정지)' : ''} [Backlog ${c.Backlog}, InProgress ${c['In Progress']}, InReview ${c['In Review']}, Done ${c.Done}]`);
    for (const i of l.issues.filter(x => x.state === 'In Progress' || x.state === 'In Review' || x.attention))
      L.push(`    · issue id="${i.id}" state="${i.state}" "${i.title}"${i.attention ? ` [주의:${i.attention}${i.gate?.ask ? ' — ' + i.gate.ask : ''}]` : ''}`);
  }
  return L.join('\n');
}
const NL_SYSTEM = `너는 "Loops"(자율 에이전트 플랫폼)의 텔레그램 원격 비서다. 사용자가 한국어로 편하게 말한다. 아래 현재 상태를 참고해 **딱 하나의 JSON**으로만 답하라. 코드펜스·설명 문장 금지, JSON만.

가능한 action.name:
- 없음(질문/상태요약만): action 생략
- "run-now"{loop} 루프 1사이클 실행 · "reconcile"{loop} PR정리
- "loop-pause"{loop} · "loop-resume"{loop} · "toggle-enabled"{loop} 루프 켜기/끄기
- "resolve-gate"{loop,issue,decision} human-gate에 사람 결정 전달(decision=워커에 줄 지시문)
- "cancel-issue"{loop,issue} 이슈취소(파괴적) · "cleanup-issue"{loop,issue} 리소스정리(파괴적)
- "start"/"stop"/"pause"/"resume" 전역 디스패처 · "awake-on"/"awake-off" 잠자기방지

규칙: loop/issue는 반드시 위 상태의 실제 id를 사용. 어느 걸 말하는지 모호하면 action 없이 reply로 되물어라. reply는 짧고 친근한 한국어.
출력: {"reply":"...","action":{"name":"...","loop":"...","issue":"...","decision":"..."}} (action 없으면 {"reply":"..."})`;
const NL_DESTRUCTIVE = { 'cancel-issue': 'cxlC', 'cleanup-issue': 'clnC' };
async function onNaturalLanguage(text) {
  if (!existsSync(CLAUDE_BIN) && CLAUDE_BIN.includes('/')) { const v = await menuView(); return send('자연어 이해엔 claude 실행파일이 필요해요. 우선 메뉴로:', v.keyboard); }
  tg('sendChatAction', { chat_id: CHAT, action: 'typing' });
  const st = await getStatus().catch(() => null);
  const j = parseDecision(await claudeRun(`${NL_SYSTEM}\n\n=== 현재 상태 ===\n${statusContext(st)}\n\n=== 사용자 ===\n${text}`));
  if (!j) { botlog('out', '(자연어 해석 실패)'); const v = await menuView(); return send('무슨 말인지 잘 못 알아들었어요 😅 메뉴로 해볼까요?', v.keyboard); }
  const act = j.action && j.action.name; const reply = j.reply || '';
  if (!act) { botlog('out', reply); return send(esc(reply) || '음, 다시 말해줄래요?'); }
  // 파괴적 액션은 자연어로 바로 실행하지 않고 확인 버튼(기존 cxlC/clnC 핸들러 재사용)
  if (NL_DESTRUCTIVE[act]) {
    botlog('out', `${reply} [확인대기: ${act} ${j.action.issue}]`);
    return send(esc(reply), [[{ text: '⚠️ 확인', callback_data: `${NL_DESTRUCTIVE[act]}|${j.action.loop}|${j.action.issue}` }, { text: '아니오', callback_data: 'nop' }]]);
  }
  const params = {}; for (const k of ['loop', 'issue', 'decision']) if (j.action[k]) params[k] = j.action[k];
  const r = await ctrl(act, params);
  botlog('out', `${reply} → ${act} ${r && r.ok ? 'ok' : '실패'}`);
  return send(`${esc(reply)}\n${r && r.ok ? '✅ ' + esc(r.out || '') : '⚠️ ' + esc(r?.out || '실패')}`);
}

// ── 인바운드: 슬래시 명령 ──
async function onCommand(text) {
  const [cmd, ...rest] = text.trim().split(/\s+/);
  const arg = rest.join(' ');
  switch (cmd) {
    case '/start': case '/menu': { const v = await menuView(); return send(v.text, v.keyboard); }
    case '/help':
      return send([
        '<b>Loops 원격 제어</b>',
        '/menu — 🕹 탭으로 전부 제어(루프·작업·디스패처)',
        '/status — 전 loop + 진행 중 작업 요약',
        '/gates — 열린 human-gate',
        '/resolve &lt;ISSUE&gt; &lt;결정&gt; · /cancel &lt;ISSUE&gt; · /cleanup &lt;ISSUE&gt;',
        '/runnow &lt;loop&gt; · /reconcile &lt;loop&gt; · /enable &lt;loop&gt;',
        '/pause &lt;loop&gt; · /resume &lt;loop&gt;',
        '/dispatcher &lt;start|stop|pause|resume&gt; · /awake &lt;on|off&gt;',
        '',
        '💬 <b>그냥 말로 해도 됩니다</b> — "지금 뭐 돌아가?", "GOD-8 그냥 진행해", "myapp 한번 돌려", "그거 취소해" 처럼. 탭이 편하면 <b>/menu</b>. 게이트 알림엔 <b>답장</b>으로 결정.',
      ].join('\n'));
    case '/status': {
      const st = await getStatus().catch(() => null);
      if (!st) return send('⚠️ 대시보드 미응답 — loopctl dashboard 확인');
      const lines = [`🕹 dispatcher: ${st.dispatcher.running ? (st.dispatcher.paused ? '⏸ paused' : '● running') : '○ stopped'} · awake ${st.awake ? '☕' : 'off'}`];
      for (const l of st.loops) {
        const c = l.counts;
        lines.push(`\n${l.emoji} <b>${esc(l.name)}</b> ${l.paused ? '⏸' : (l.enabled ? '' : '(off)')}`);
        lines.push(`  📋 ${c.Backlog} · 🔨 ${c['In Progress']} · 👀 ${c['In Review']} · ✅ ${c.Done}`);
        // 진행 중(In Progress/In Review) + 주의 이슈를 실제로 나열
        for (const i of l.issues.filter(x => x.state === 'In Progress' || x.state === 'In Review' || x.attention))
          lines.push(`  ${STATE_EMOJI[i.state] || '•'} ${esc(i.id)} ${esc(i.title)}${i.attention ? ` ${ATT[i.attention]?.emoji || '⚠️'}` : ''}`);
      }
      lines.push('\n🕹 /menu 로 탭 제어');
      return send(lines.join('\n'));
    }
    case '/gates': {
      const st = await getStatus().catch(() => null);
      if (!st) return send('⚠️ 대시보드 미응답');
      let any = false;
      for (const l of st.loops) for (const i of l.issues) if (i.attention === 'human-gate') {
        any = true; const m = messageFor(l, i, 'human-gate'); const r = await send(m.text, m.keyboard);
        const mid = r && r.ok && r.result && r.result.message_id;
        if (mid) { const n = loadNotify(); n.pending[mid] = { loop: l.id, issue: i.id }; saveNotify(n); }
      }
      return any ? null : send('열린 human-gate 없음 ✅');
    }
    case '/resolve': {
      const [issue, ...d] = rest; const decision = d.join(' ').trim();
      if (!issue || !decision) return send('사용법: /resolve &lt;ISSUE&gt; &lt;결정 내용&gt;');
      const hit = await loopOfIssue(issue); if (!hit) return send(`${esc(issue)} 못 찾음`);
      const r = await ctrl('resolve-gate', { loop: hit.loopId, issue: hit.issue.id, decision });
      return send(r && r.ok ? `⚖️ ${hit.issue.id} 결정 전달 + 워커 시작` : `실패: ${esc(r?.out || '')}`);
    }
    case '/cancel': case '/cleanup': {
      if (!arg) return send(`사용법: ${cmd} &lt;ISSUE&gt;`);
      const hit = await loopOfIssue(arg); if (!hit) return send(`${esc(arg)} 못 찾음`);
      const action = cmd === '/cancel' ? 'cancel-issue' : 'cleanup-issue';
      const r = await ctrl(action, { loop: hit.loopId, issue: hit.issue.id });
      return send(r && r.ok ? `${cmd === '/cancel' ? '🗑' : '🧹'} ${hit.issue.id} 완료` : `실패: ${esc(r?.out || '')}`);
    }
    case '/runnow': case '/pause': case '/resume': case '/reconcile': case '/enable': {
      if (!arg) return send(`사용법: ${cmd} &lt;loop-id&gt;`);
      const action = { '/runnow': 'run-now', '/pause': 'loop-pause', '/resume': 'loop-resume', '/reconcile': 'reconcile', '/enable': 'toggle-enabled' }[cmd];
      const r = await ctrl(action, { loop: arg });
      return send(r && r.ok ? `${cmd} ${esc(arg)} ✅ ${esc(r.out || '')}` : `실패: ${esc(r?.out || '')}`);
    }
    case '/dispatcher': {
      const sub = (rest[0] || '').toLowerCase();
      if (!['start', 'stop', 'pause', 'resume'].includes(sub)) return send('사용법: /dispatcher &lt;start|stop|pause|resume&gt;');
      const r = await ctrl(sub, {});
      return send(r && r.ok ? `🕹 dispatcher ${sub} ✅` : `실패: ${esc(r?.out || '')}`);
    }
    case '/awake': {
      const sub = (rest[0] || '').toLowerCase();
      if (!['on', 'off'].includes(sub)) return send('사용법: /awake &lt;on|off&gt;');
      const r = await ctrl(sub === 'on' ? 'awake-on' : 'awake-off', {});
      return send(r && r.ok ? `☕ 잠자기방지 ${sub} ✅` : `실패: ${esc(r?.out || '')}`);
    }
    default: { const v = await menuView(); return send(v.text, v.keyboard); }
  }
}

// ── 인바운드: 게이트 알림에 대한 답장 → 그 이슈의 결정으로 ──
async function onReply(msg) {
  const mid = msg.reply_to_message.message_id;
  const n = loadNotify(); const p = n.pending[mid];
  if (!p) return send('이 메시지는 게이트 알림이 아니거나 오래돼 매핑이 없어요. /resolve &lt;ISSUE&gt; &lt;결정&gt; 을 쓰세요.');
  const r = await ctrl('resolve-gate', { loop: p.loop, issue: p.issue, decision: msg.text });
  return send(r && r.ok ? `⚖️ ${p.issue} 결정 전달 + 워커 시작` : `실패: ${esc(r?.out || '')}`);
}

// ── 인바운드 루프: getUpdates long-poll ──
let offset = 0;
async function pollUpdates() {
  const r = await tg('getUpdates', { timeout: 30, offset, allowed_updates: ['message', 'callback_query'] });
  if (!r || !r.ok) return;
  for (const u of r.result) {
    offset = u.update_id + 1;
    try { await handleUpdate(u); } catch (e) { log('update 처리 오류:', e.message); }
  }
}
async function handleUpdate(u) {
  const chatId = u.callback_query ? u.callback_query.message?.chat?.id : u.message?.chat?.id;
  // 페어링: chat-id 미설정이면 첫 메시지의 chat을 캡처·영속화
  if (!CHAT) {
    if (u.message && chatId != null) { CHAT = String(chatId); setEnvVar('TELEGRAM_CHAT_ID', CHAT); log('페어링 완료 → chat', CHAT); await send('✅ 연결됨! 이제 이 대화로 알림이 오고, 여기서 전부 제어할 수 있어요.\n💬 그냥 말로 하세요 — "지금 뭐 돌아가?", "GOD-8 진행해". 탭이 편하면 🕹 /menu. (/help)'); }
    return;
  }
  // chat-id 잠금(인증): 등록된 chat 외의 요청은 무시
  if (String(chatId) !== String(CHAT)) { if (u.callback_query) answerCb(u.callback_query.id, '권한 없음'); return; }
  if (u.callback_query) { botlog('in', '👆 ' + u.callback_query.data); return onCallback(u.callback_query); }
  const msg = u.message; if (!msg || typeof msg.text !== 'string') return;
  botlog('in', (msg.reply_to_message ? '↩ ' : '') + msg.text);
  if (msg.reply_to_message) return onReply(msg);
  if (msg.text.startsWith('/')) return onCommand(msg.text);
  return onNaturalLanguage(msg.text);   // 그냥 말로 → claude가 의도 파악해 실행 (게이트 알림엔 답장으로 결정)
}

async function updatesForever() { for (;;) { try { await pollUpdates(); } catch (e) { log('getUpdates 오류:', e.message); await new Promise(r => setTimeout(r, 3000)); } } }

// ── 부팅 ──
async function main() {
  if (!TOKEN) {
    console.error([
      '❌ TELEGRAM_BOT_TOKEN 없음.',
      '  1) 텔레그램에서 @BotFather → /newbot → 토큰 복사',
      `  2) loops.env 에 추가:  TELEGRAM_BOT_TOKEN=<토큰>`,
      '  3) loopctl bot 재실행 → 새 봇에게 아무 메시지 전송 (chat-id 자동 페어링)',
    ].join('\n'));
    process.exit(1);
  }
  const me = await tg('getMe', {});
  if (!me || !me.ok) { console.error('❌ 봇 토큰이 유효하지 않음 (getMe 실패). loops.env 의 TELEGRAM_BOT_TOKEN 확인.'); process.exit(1); }
  log(`🤖 @${me.result.username} 기동 · 대시보드 127.0.0.1:${PORT} · 폴링 ${POLL_SEC}s`);
  // 재시작 시 밀린 업데이트는 버리고 이후 것만 처리(오래된 명령 재실행 방지) — 페어링 대기 메시지는 이후 새로 옴
  const drain = await tg('getUpdates', { timeout: 0, offset: -1 });
  if (drain && drain.ok && drain.result.length) offset = drain.result[drain.result.length - 1].update_id + 1;
  if (!CHAT) log('⏳ 페어링 대기 — 텔레그램에서 이 봇에게 아무 메시지나 보내세요.');
  else send('🔄 봇 재시작 — 알림·제어 재개').catch(() => {});
  updatesForever();
  await pollStatus();
  setInterval(() => { pollStatus().catch(e => log('poll 오류:', e.message)); }, POLL_SEC * 1000);
}
main();
