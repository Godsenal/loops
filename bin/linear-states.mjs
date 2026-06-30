#!/usr/bin/env node
// Linear 프로젝트의 모든 이슈 상태를 출력한다(의존성 0, Node 내장 https).
// usage: linear-states.mjs <projectId>   (env: LINEAR_API_KEY)
// 출력: 한 줄에 "<identifier>\t<statusType>"  (statusType: backlog|unstarted|started|completed|canceled|triage)
// 키 없거나 실패하면 빈 출력 + 비0 종료 — 호출자(cleanup-terminal.sh)가 폴백 신호로 진행한다.
import https from 'node:https';
const projectId = process.argv[2];
const key = process.env.LINEAR_API_KEY || '';
if (!projectId || !key) { process.exit(1); }

const query = `query($id:String!){ project(id:$id){ issues(first:250){ nodes{ identifier state{ type } } } } }`;
const body = JSON.stringify({ query, variables: { id: projectId } });
const req = https.request('https://api.linear.app/graphql', {
  method: 'POST',
  headers: { 'content-type': 'application/json', authorization: key, 'content-length': Buffer.byteLength(body) },
  timeout: 15000,
}, (res) => {
  let d = ''; res.on('data', c => d += c); res.on('end', () => {
    try {
      const j = JSON.parse(d);
      const nodes = j?.data?.project?.issues?.nodes;
      if (!Array.isArray(nodes)) process.exit(1);
      for (const n of nodes) if (n.identifier) process.stdout.write(n.identifier + '\t' + (n.state?.type || '') + '\n');
    } catch { process.exit(1); }
  });
});
req.on('error', () => process.exit(1));
req.on('timeout', () => { req.destroy(); process.exit(1); });
req.end(body);
