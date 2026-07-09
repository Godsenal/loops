# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Loops** — a multi-loop autonomous-agent platform. Each "loop" is a recurring, headless Claude Code agent for one domain (SEO, dead-code cleanup, webview refactor, …). A loop's **orchestrator** discovers work and fans it out; **workers** each implement one item and open a PR. **Humans merge** — the engine never merges, deploys, or force-pushes.

The engine is shared; a loop differs only in its `mission.md` (what to find, how) and `config.json` (repo / Linear / schedule / concurrency).

There is **no build, test, or lint step**. The engine is **zero dependencies** — `zsh` scripts + Node built-ins (`http`, `child_process`, `fs`); don't go looking for `package.json`, a test runner, or CI for this repo; there is none. **One exception, dashboard UI only:** the dashboard vendors [Oat UI](https://oat.ink) (MIT, ~10KB) as pinned static assets in `vendor/oat.min.{css,js}` — served by `dashboard-server.mjs` at `/vendor/*` and loaded by `dashboard.html`. **This is still no-build** (edit `dashboard.html` → refresh; no bundler, no `npm install`, `dashboard-server.mjs` stays Node-builtin-only). To bump Oat, re-`curl` a pinned version from `unpkg.com/@knadh/oat@<ver>/` into `vendor/` (Oat is sub-v1 — pin, don't float).

## Hard prerequisite: cmux

The platform is built on **cmux** (a terminal with socket control). The dispatcher and dashboard run *inside cmux panels*, and workers spawn as *live cmux tabs*. Non-cmux environments are unsupported. `claude`, `gh`, `node`, `git` must also be present.

## Commands

```sh
./install.sh                 # detect tools → write loops.env, ~/.loops-home, symlink create-loop skill
./loopctl dashboard          # dashboard at http://localhost:8422 (opens a cmux panel)
./loopctl start              # start the global dispatcher (cmux panel)
./loopctl stop|pause|resume|status
./loopctl run-now <loop-id>  # fire one orchestrator cycle for a loop immediately
```

There are no unit tests. To exercise a change, run a single orchestrator cycle directly:

```sh
LOOP_MODE=full ./bin/run-once.sh <loop-id>      # full cycle (headless claude -p), logs → loops/<id>/state/run.log
LOOP_MODE=reconcile ./bin/run-once.sh <loop-id> # only merge-cleanup + snapshot (fast)
node ./bin/render-prompt.mjs <loop-id> orchestrator   # inspect the rendered prompt without running it
```

`LOOP_MODE` is `full` (default) | `audit_only` (skip fan-out) | `reconcile` (only STEP 1 merge-cleanup + STEP 4 snapshot).

## Architecture

The runtime is a chain of processes, each launched in a fresh/empty context. **All cross-run continuity lives in the Linear ledger, not in memory.**

```
dispatch.sh (cmux panel, loops while-true)
  └─ per enabled loop, on schedule → spawn-orchestrator.sh <id>   (FOREGROUND — must keep cmux socket access)
       └─ run-once.sh <id>   (claude -p <rendered orchestrator prompt>, headless, in the loop's orchestrator worktree)
            └─ orchestrator fans out → spawn-worker.sh <id> <issue>   (one per Backlog item, up to cap)
                 └─ new cmux tab runs worker-run.sh → claude <rendered worker prompt>   (live TUI, dedicated worktree+branch)
                      └─ worker implements 1 issue → /gbase:go (polish+PR) → preview check → STOP (no merge)
```

- **`bin/_common.sh`** — sourced by every script. Derives `LOOPS_HOME` from its own location (`bin/`'s grandparent) and sources `loops.env`. This is why the repo works wherever it's cloned: paths are dynamic, never hardcoded.
- **`bin/render-prompt.mjs`** — the templating core. Combines `bin/{orchestrator,worker}-base.md` (the shared engine logic) + the loop's `mission.md` + `config.json` values, substituting `{{VAR}}` tokens. Editing engine behavior = editing the `-base.md` files, not the per-loop files.
- **`dashboard-server.mjs`** — dependency-free Node HTTP server. `GET /api/status` aggregates each loop's `state/snapshot.json` + live cmux tabs + a 60s background `gh pr view` cache. `POST /api/control` dispatches actions (`start`, `run-now`, `reconcile`, `resolve-gate`, `start-issue`, `toggle-enabled`, `set-schedule`, `build-loop`, `create-loop`, `save-mission`, `save-config`, …) by shelling out to the same `bin/` scripts and `cmux`/`gh`. It also serves pinned static assets at `/vendor/*` (filename-whitelisted) — currently Oat UI. `dashboard.html` is the single-file UI: bespoke telemetry layout (sidebar/gauge/LED-dot/feed/cards) on top of **Oat UI** components (buttons, inputs, `.badge`, `role=alert`, `<ot-dropdown>` menus, native-title tooltips). The whole telemetry palette (dark + light via `data-theme`) is mapped onto Oat's CSS variables, so Oat components inherit the console look. Global controls (dispatcher start/pause/stop/logs + workspace settings) live in the `⚙️ 디스패처` `<ot-dropdown>`; per-loop `⚙️ 설정` vs global `워크스페이스 설정` (Linear key, Telegram bot) are separate modals.
- **`bin/notify-bot.mjs`** — optional Telegram remote bridge (zero-dep, `node:https`). One process, two loops: polls `GET /api/status` and diffs to **push** human-gate/PR/CI/cycle-error alerts to the owner's phone; long-polls Telegram `getUpdates` for **inbound** button taps / message replies / slash commands, mapping each to a `POST /api/control`. It is a full remote control, not just alerts: an interactive `/menu` (inline keyboards) navigates dispatcher→loops→tasks and exposes nearly every dashboard action — global `start`/`stop`/`pause`/`resume`/`awake`, per-loop `run-now`/`reconcile`/`loop-pause`/`toggle-enabled`, per-issue `resolve-gate`/`cancel-issue`/`cleanup-issue` — plus slash fallbacks (`/status` lists active In Progress/In Review tasks). Free-text messages that aren't slash commands or gate replies now run a **real agent**: `claude` headless (`-p`, capable model via `LOOPS_BOT_AGENT_MODEL`, default Sonnet) whose **only** toolset is the Loops control MCP server (`bin/loops-mcp.mjs`, a zero-dep stdio JSON-RPC server that thinly relays `/api/status`·`/api/session`·`/api/control` over 127.0.0.1). The agent multi-steps on its own — e.g. "seo에 'OG태그 누락 점검' 태스크 추가하고 바로 작업 시작해" → `get_status` → `create_issue{start:true}`; "요즘 CI 왜 깨져? 원인 보고 고칠 태스크 만들어" → `get_run_log`/`get_worker_screen` → several `create_issue`. `create-issue` (new `/api/control` action) creates a Linear Backlog issue in the loop's project via `issueCreate`, and with `start:true` immediately spawns a worker (mirrors dashboard `start-issue`); task-add follows the user's literal words (add-only vs add+start). The bot passes the MCP config **inline** (`--mcp-config <json>`), with `--strict-mcp-config` (ignore the user's global MCP servers) and `--disallowedTools Bash Edit Write NotebookEdit …` so the agent **cannot merge/deploy/force-push** — that's enforced structurally (no such tool exists), not by prompt. **The destructive actions `cancel_issue`/`cleanup_issue` are deliberately absent from the agent's toolset** — the agent proposes and points the user to the existing 2-tap confirm buttons / `/cancel`; it never cancels or cleans up on its own. The MCP server relays only the dashboard HTTP surface — it does **not** touch cmux — so the engine is unchanged. Auth = `TELEGRAM_CHAT_ID` lock (auto-paired on first message); token in `loops.env` (`TELEGRAM_BOT_TOKEN`, a preserved key). Launched via `loopctl bot` **or** the dashboard ⚙️ (token field + ▶ 봇 시작, backed by control actions `set-telegram`/`bot-start`/`bot-stop`; `GET /api/status` exposes `telegram:{configured,paired,running}` booleans only, never the token). **The bot never merges/deploys/force-pushes** — the destructive actions it exposes are `cancel-issue`/`cleanup-issue` (two-tap confirm); `resolve-gate` only relays the human's decision to the worker. Merging stays a human action.

## A loop's anatomy

`loops/<id>/` (gitignored — user data) contains:
- `config.json` — schema: `id, name, emoji, repo, baseRef (origin/develop), prBase (develop), branchPrefix, orchestratorWorktree, worktreePrefix, linearProjectId, linearProjectUrl, maxWorkers, backlogTarget, schedule{startAt,intervalSec}, enabled`. See `examples/*/config.json`.
- `mission.md` — injected as `{{MISSION}}` into the orchestrator prompt; defines *what work to discover and how* (the only domain-specific logic).
- `state/` — runtime: `snapshot.json` (dashboard reads this — orchestrator writes it in STEP 4), `runs.jsonl` (append-only event feed), `run.log`, `next_fire`, `decisions/<ISSUE>.md` (human-gate resolutions), `PAUSED`.

The Linear project **is** the state machine (dedup across runs): `Backlog → In Progress → In Review → Done/Canceled`. A "run log" tracking issue per loop gets one comment per cycle.

## Conventions that matter when editing

- **Never merge / deploy / force-push** from engine code or prompts. Workers open PRs only; merging is the human gate. Preserve this in any prompt or script change. **Exception (opt-in):** a loop with `"delivery": "direct"` in its `config.json` makes its workers push straight to `prBase` (non-force, rebase-then-push, stop on conflict) instead of opening a PR — used for personal/no-reviewer repos like the `loops-improve` self-improvement loop. Default (no `delivery` field) = `"pr"` = the safe PR flow. `render-prompt.mjs` swaps the worker's step 4–7 (`{{WORKER_DELIVERY}}`) and an orchestrator note (`{{DELIVERY_NOTE}}`) based on this flag. **force-push stays banned in both modes.**
- **No silent fallback.** Both base prompts forbid `?? default`, swallowed catches, and guessing — fix root cause. The target repos enforce this via their own CLAUDE.md/AGENTS.md (which workers/orchestrators must obey, since cwd is the *target* repo's worktree, not this one).
- **`spawn-orchestrator.sh` must stay foreground** (the caller backgrounds it). Detaching loses cmux socket access, so workers can't spawn — hence the repeated "FOREGROUND / cmux 안에서 실행" warnings.
- **PR URLs come only from `gh pr view --json url`** — never construct `org/repo` URLs by hand (origin may be a GitHub mirror).
- Concurrency: `in-flight = (In Progress) + (In Review)`; cap = `min(maxWorkers, LOOP_MAX_WORKERS)`. Per-loop run lock is a `/tmp/loop-<id>.lockdir` mkdir.
- **human-gate**: an issue whose body says "human-gate" is *not* implemented by a worker — it surfaces to the dashboard (🔴) for a human decision, which is written to `state/decisions/<ISSUE>.md` and injected back into the worker as an authoritative override on the next spawn.
- **Terminal-state cleanup.** Once an issue reaches a terminal state — `Done` (PR merged) or `Canceled` (PR closed / user discarded) — its cmux tab + git worktree + branch are removed automatically. This runs deterministically in `bin/run-once.sh` *after* the headless orchestrator (every cycle, all `LOOP_MODE`s) via `bin/cleanup-issue.sh <loop> <issue>` — idempotent, matches the cmux tab by title (`🛠/↩ <loop> <issue>`), gated on the worktree dir actually existing. The same helper backs the dashboard `cancel-issue` ("🗑 버리기") and a per-issue "🧹 정리" button; `bin/cleanup-loop.sh` (dashboard `delete-loop` and `loopctl cleanup <loop>`) sweeps a whole loop. **In-progress worktrees (In Progress / In Review) are still preserved** so a user can `claude --resume` them; the LLM prompts never do this cleanup (deterministic shell only); **force-push / merge / deploy stay banned.** The orchestrator always rebuilds its own worktree from `baseRef` (never the user's working tree).
- **Liveness & stall recovery is deterministic, keyed on Linear (not the stale snapshot).** Two shell loops run in `dispatch.sh` every ≤60s (both skip a loop while its `/tmp/loop-<id>.lockdir` is held, so they never race an orchestrator run):
  - **`bin/watchdog.sh`** — the in-flight set is **Linear `started`** (always fresh; the old code keyed on existing-worktrees + hourly `snapshot.json`, which missed no-worktree ghosts and lagged a full cycle). A cmux tab **auto-closes when its `--command` exits**, so "no tab" reliably means "claude exited." Per `started` issue: *live tab* → `cmux read-screen` hash; if the screen is frozen ≥ `LOOP_WEDGE_SEC` (300s) it's **`wedged`** (surfaced only — never auto-killed, to avoid killing a slow-but-fine worker). *No tab* → if a branch **open PR** exists (pr-mode) it's In Review (done, awaiting human merge → leave it); else it's a dead In Progress — if a **worktree remains** (progress) → `bin/heal-worker.sh` resumes it in place (grace → `LOOP_HEAL_MAX` attempts → `escalated`), if **no worktree** it's a ghost the watchdog does **not** re-spawn (would bypass the cap).
  - **`bin/cleanup-terminal.sh` (the reaper)** — beyond terminal cleanup, when Linear is fresh it also (4) reverts **no-worktree `started` ghosts → Backlog** via `bin/linear-move.mjs` (a ghost pins `in-flight` so `capacity = cap − in-flight` goes ≤0 and the orchestrator stops spawning — this is the usual "loop silently stops"; reverting frees the slot so the orchestrator re-spawns within cap), and (5) reclaims **Backlog-issue worktree litter** (dead worker reverted to Backlog, no live tab/PR) via `cleanup-issue.sh`. Both gated on live Linear + no open PR; `escalated` issues are vetoed. **Backlog moves are not merge/cancel — the no-merge rule is intact.**
  - The dashboard reads `state/liveness.json` and surfaces `stuck` (escalated), `wedged`, and `healing`. The orchestrator prompt now **defers** dead-worker handling to these loops (LLM is a rare backstop), so it no longer races them.

## Adding a loop

Prefer the **`create-loop` skill** (or dashboard "+ 새 loop" → `bin/build-loop.sh`), which follows `bin/loop-builder.md`: it creates a Linear project, writes `mission.md` + `config.json` under `loops/<id>/`, and leaves it `enabled:false` for human review. Manual path: copy an `examples/<...>/` dir to `loops/<id>/` and fill in repo / Linear IDs / worktree paths.
