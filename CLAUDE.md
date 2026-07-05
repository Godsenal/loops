# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Loops** — a multi-loop autonomous-agent platform. Each "loop" is a recurring, headless Claude Code agent for one domain (SEO, dead-code cleanup, webview refactor, …). A loop's **orchestrator** discovers work and fans it out; **workers** each implement one item and open a PR. **Humans merge** — the engine never merges, deploys, or force-pushes.

The engine is shared; a loop differs only in its `mission.md` (what to find, how) and `config.json` (repo / Linear / schedule / concurrency).

There is **no build, test, or lint step** and **zero dependencies** — everything is `zsh` scripts + Node built-ins (`http`, `child_process`, `fs`). Don't go looking for `package.json`, a test runner, or CI for this repo; there is none.

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
- **`dashboard-server.mjs`** — dependency-free Node HTTP server. `GET /api/status` aggregates each loop's `state/snapshot.json` + live cmux tabs + a 60s background `gh pr view` cache. `POST /api/control` dispatches actions (`start`, `run-now`, `reconcile`, `resolve-gate`, `start-issue`, `toggle-enabled`, `set-schedule`, `build-loop`, `create-loop`, `save-mission`, `save-config`, …) by shelling out to the same `bin/` scripts and `cmux`/`gh`. `dashboard.html` is the single-file UI.
- **`bin/notify-bot.mjs`** — optional Telegram remote bridge (zero-dep, `node:https`). One process, two loops: polls `GET /api/status` and diffs to **push** human-gate/PR/CI/cycle-error alerts to the owner's phone; long-polls Telegram `getUpdates` for **inbound** button taps / message replies / slash commands, mapping each to a `POST /api/control`. It is a full remote control, not just alerts: an interactive `/menu` (inline keyboards) navigates dispatcher→loops→tasks and exposes nearly every dashboard action — global `start`/`stop`/`pause`/`resume`/`awake`, per-loop `run-now`/`reconcile`/`loop-pause`/`toggle-enabled`, per-issue `resolve-gate`/`cancel-issue`/`cleanup-issue` — plus slash fallbacks (`/status` lists active In Progress/In Review tasks). Free-text messages that aren't slash commands or gate replies are routed through `claude` (headless `-p`, fast model via `LOOPS_BOT_MODEL`, default Haiku) with the live `/api/status` as context → the model returns a strict JSON `{reply, action}` mapped to a `/api/control` call, so the user can just say "run myapp" or "cancel GOD-8" in natural language; destructive actions it infers are still gated behind a confirm tap. Does **not** touch cmux — every action goes through the dashboard server, so the engine is unchanged. Auth = `TELEGRAM_CHAT_ID` lock (auto-paired on first message); token in `loops.env` (`TELEGRAM_BOT_TOKEN`, a preserved key). Launched via `loopctl bot` **or** the dashboard ⚙️ (token field + ▶ 봇 시작, backed by control actions `set-telegram`/`bot-start`/`bot-stop`; `GET /api/status` exposes `telegram:{configured,paired,running}` booleans only, never the token). **The bot never merges/deploys/force-pushes** — the destructive actions it exposes are `cancel-issue`/`cleanup-issue` (two-tap confirm); `resolve-gate` only relays the human's decision to the worker. Merging stays a human action.

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

## Adding a loop

Prefer the **`create-loop` skill** (or dashboard "+ 새 loop" → `bin/build-loop.sh`), which follows `bin/loop-builder.md`: it creates a Linear project, writes `mission.md` + `config.json` under `loops/<id>/`, and leaves it `enabled:false` for human review. Manual path: copy an `examples/<...>/` dir to `loops/<id>/` and fill in repo / Linear IDs / worktree paths.
