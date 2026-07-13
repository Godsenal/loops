#!/usr/bin/env node
// Linear 프로젝트의 모든 이슈 상태를 출력한다(의존성 0, 공유 linearGql 헬퍼).
// usage: linear-states.mjs <projectId>   (env: LINEAR_API_KEY)
// 출력: 한 줄에 "<identifier>\t<statusType>"  (statusType: backlog|unstarted|started|completed|canceled|triage)
// 키 없거나 실패하면 빈 stdout + 비0 종료 — 호출자(cleanup-terminal.sh)가 폴백 신호로 진행한다.
// 실패(응답 이상·JSON 오류·네트워크·타임아웃)는 stderr에 원인 1줄을 남긴다 — stdout 계약·비0 종료는 불변.
import { linearGql } from './linear-gql.mjs';

const projectId = process.argv[2];
const key = process.env.LINEAR_API_KEY || '';
if (!projectId || !key) { process.exit(1); }

const query = `query($id:String!){ project(id:$id){ issues(first:250){ nodes{ identifier state{ type } } } } }`;

try {
  const d = await linearGql(query, { id: projectId }, key);   // j.errors·JSON·네트워크·타임아웃(15s)은 여기서 reject → catch
  const nodes = d?.project?.issues?.nodes;
  if (!Array.isArray(nodes)) { console.error('linear-states: 예상치 못한 응답'); process.exit(1); }
  for (const n of nodes) if (n.identifier) process.stdout.write(n.identifier + '\t' + (n.state?.type || '') + '\n');
} catch (e) { console.error(`linear-states: ${e.message}`); process.exit(1); }
