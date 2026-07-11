#!/usr/bin/env node
// `claude -p --output-format json` 출력(1 JSON)을 두 갈래로 분리한다:
//   ① stdout ← result 텍스트 (호출자가 run.log에 append — 기존의 사람이 읽는 로그를 보존)
//   ② loops/<id>/state/costs.jsonl ← 1줄 append: {ts,kind,mode,usd,durMs,turns,tokens:{in,out,cacheRead,cacheWrite}}
// JSON 파싱 실패(타임아웃으로 잘림·래퍼가 json 미지원 등)면 원문을 그대로 stdout에 흘리고 경고를 크게 남긴다
// — 비용 기록만 빠질 뿐 run 로그는 잃지 않고, 실패를 조용히 삼키지 않는다.
// usage: record-cost.mjs <loop-id> <json-file> <kind> [mode]
import { readFileSync, appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
const ROOT = process.env.LOOPS_HOME || dirname(dirname(fileURLToPath(import.meta.url)));
const [, , loopId, file, kind = 'cycle', mode = ''] = process.argv;
if (!loopId || !file) { console.error('usage: record-cost.mjs <loop-id> <json-file> <kind> [mode]'); process.exit(1); }
let raw = '';
try { raw = readFileSync(file, 'utf8'); } catch (e) { console.error(`⚠️ cost capture 실패: 출력 파일 없음(${file}) — ${e.message}`); process.exit(0); }
let j;
try { j = JSON.parse(raw); } catch {
  process.stdout.write(raw);
  console.error(`\n⚠️ cost capture 실패: claude 출력이 JSON이 아님(타임아웃으로 잘렸거나 claudeCmd 래퍼가 --output-format json 미지원) — 비용 미기록, 로그는 원문 그대로.`);
  process.exit(0);
}
process.stdout.write(String(j.result ?? ''));
const u = j.usage || {};
const rec = {
  ts: Math.floor(Date.now() / 1000), kind, ...(mode ? { mode } : {}),
  usd: j.total_cost_usd ?? null, durMs: j.duration_ms ?? null, turns: j.num_turns ?? null,
  tokens: { in: u.input_tokens ?? 0, out: u.output_tokens ?? 0, cacheRead: u.cache_read_input_tokens ?? 0, cacheWrite: u.cache_creation_input_tokens ?? 0 },
};
appendFileSync(`${ROOT}/loops/${loopId}/state/costs.jsonl`, JSON.stringify(rec) + '\n');
