---
name: orchestrating-coding-agents
description: Use when a coding task needs real implementation, test runs, or verification loops and delegating it to an external CLI coding agent (OpenCode, AGY/Antigravity CLI, or another tool with a print/run mode) would save the current session's token budget — long test suites, mechanical fixes, multi-round PR-review responses, or any grind work where you'd rather stay the architect/reviewer than burn your own context on the doing.
---

# Orchestrating Coding Agents

## Overview

You (Claude) plan, review, and gate risky actions. An external CLI agent (OpenCode or AGY) does the file edits, test runs and investigation in its own process on its own token budget; only its final report touches your context. Use `superpowers:brainstorming` / `writing-plans` / `subagent-driven-development` for the parts needing YOUR judgment — this skill replaces only the *implementer*.

`<SKILL_DIR>` below means the folder containing this SKILL.md (the base directory shown when the skill loads); substitute its absolute path. First time on a machine, or if anything fails to launch: run `<SKILL_DIR>\scripts\preflight.ps1` and relay what it reports.

**Dispatch always goes through `scripts/dispatch.ps1`.** Do not hand-roll `Start-Process`/quoting/tail windows: that is what used to hang, garble prompts and fail to open windows. The scripts give you, every time:

- the brief passed as a **file** (no quoting bugs, no backtick/`$` expansion),
- a **real visible window** (see table) — verified, it reports `VIEWER=OK` or says it failed,
- a **watchdog** (hard timeout + no-output stall detection, kills the whole process tree),
- a single **completion signal**: `<RUN_DIR>\done.json` with `status` = `DONE | FAILED | STALLED | TIMEOUT`.

| | OpenCode | AGY (Antigravity CLI) |
|---|---|---|
| What does the work | shared headless `opencode serve` (port 4096, survives window crashes) | one long-lived `agy --print` process in stream-json mode, owned by the worker |
| What the window shows | the **real OpenCode TUI** (`opencode attach -s <session>`): diffs, tools, reasoning live | a **live readable feed of agy's real event stream** (tool calls, streamed text, turn result, tokens). NOT agy's TUI: agy has no server/attach, and a TUI can't be driven from outside (confirmed by search + Gemini) |
| If the window dies/hangs | task keeps running; reattach with `opencode attach http://127.0.0.1:4096 -s <session>` | task stops with the window; resume with `-Resume` |
| Talk to it | `scripts/say.ps1` any time, incl. finished sessions | `scripts/say.ps1` while the worker lives (during a turn: queued until it ends; after a turn: idle up to 15 min, or until another job is queued) |
| Completion signal | `done.json` once | `done.json` rewritten at the end of **every turn** (has `turn`, `tokens`, `conversation`, `lastResponse`) |
| Models | `opencode models` | `agy models` |

**Viewer tabs are persistent and reused.** Each backend has one long-lived tab (`opencode:main` / `agy:main`) in a Windows Terminal window named `agents`. `dispatch.ps1` opens it only if it isn't alive (`VIEWER=OK (opened)`), otherwise it feeds the open one (`VIEWER=OK (reused)`): OpenCode's tab re-attaches the TUI to the new session, AGY's tab runs the new job inline (jobs queue if it's busy). Use `-Slot <name>` for a second concurrent tab when running tasks in parallel. If the user closes the tab, the next dispatch reopens it. Don't type into OpenCode's tab; it's a view.

## Model selection — always ask the user, every new task

Never choose a model yourself, and never rely on a default: `dispatch.ps1` refuses to run without `-Model`. Before the first dispatch of each task:

1. Run `powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\models.ps1"` (add `-Backend opencode|agy` if only one will be used). It queries OpenCode and AGY for what is authenticated right now.
2. Show the user the lists (both backends, as returned), then ask which model to use with `AskUserQuestion`: one question per backend that will be used. The tool allows at most 4 options, so offer the 3–4 most sensible ones from the list (e.g. a cheap/fast tier for mechanical grind, a stronger one for judgment calls) and let "Other" carry any model from the full list. Recommend one, first, labeled "(Recommended)".
3. Pass the chosen id as `-Model` (OpenCode `provider/model`, AGY the id from the left column).

Follow-ups on the same task (`say.ps1`, `-Resume`) keep that model, so don't re-ask. A new, separate task asks again.

## Dispatch

1. Write the brief to a file (below).
2. Run dispatch (Bash tool, foreground — it returns in ~10 s):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\dispatch.ps1" `
  -Backend opencode|agy -Dir "<abs repo path>" -BriefFile "<abs brief path>" -Name "<short-name>" `
  -Model "<chosen by the user>" [-Slot main] [-Resume] [-NoWindow] [-TimeoutMin 30] [-StallMin 10]
```

   Output: `VIEWER=OK|...` and `RUN_DIR=<path>`. If `VIEWER` is not OK, tell the user plainly; the task may still be running (OpenCode) — check `RUN_DIR\out.log`.
3. Wait for completion with a **background** call (`run_in_background: true`), which notifies you when it exits:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\wait.ps1" -RunDir "<RUN_DIR>" -MaxMin 60
```

4. Read `done.json`, then **Verify** (below). `STALLED`/`TIMEOUT`/`FAILED`: inspect the tail of `RUN_DIR\out.log`, then re-dispatch the same `-Name`/`-Dir` with `-Resume` and a brief saying "continue: finish the remaining steps". Don't wait silently past the watchdog and don't restart from scratch (resume keeps the agent's progress).

Parallel tasks: dispatch several with different `-Name`s **and different `-Slot`s** (one viewer per slot; same slot = AGY jobs queue, OpenCode's viewer follows the latest). Rules below.

Tune `-StallMin` up (20+) for AGY tasks with slow builds/test suites — AGY print mode emits little while a long command runs.

## Pairing with superpowers

This skill replaces only the *implementer*; superpowers keeps the judgment steps (they stay with Claude):
- `writing-plans` → each plan task becomes one brief file (paste the task text, add repo/branch/test commands/boundaries below). Dispatch tasks in plan order; parallel only if truly disjoint.
- `subagent-driven-development` → the implementer is OpenCode/AGY instead of an in-process subagent. The spec-compliance and code-quality reviews can also be dispatched to an external agent (read-only brief: "review, don't edit"); Claude only arbitrates their verdicts.
- TDD → put "follow test-driven-development: failing test first, then minimal fix" in the brief when the task is a feature or bugfix.
- `verification-before-completion` → run `review.ps1` and the tests yourself before accepting any DONE. `requesting-code-review` after a batch of tasks. `finishing-a-development-branch` for merge/push decisions (still user-gated).

## Talking to a running agent (OpenCode and AGY)

Like `SendMessage` to a subagent: the message goes to the live session (OpenCode via its server, AGY via the worker's stdin), and the viewer tab shows it and the reply in real time. Use it to steer, answer a question, add scope, or interrupt, instead of waiting for it to finish and re-dispatching.

```powershell
$say = "<SKILL_DIR>\scripts\say.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $say -RunDir "<RUN_DIR>" -Text "also cover the empty-string case"   # fire and forget
powershell -NoProfile -ExecutionPolicy Bypass -File $say -RunDir "<RUN_DIR>" -Text "what did you change so far?" -Wait   # prints its reply
powershell -NoProfile -ExecutionPolicy Bypass -File $say -RunDir "<RUN_DIR>" -Last                                       # peek at its latest message
powershell -NoProfile -ExecutionPolicy Bypass -File $say -RunDir "<RUN_DIR>" -Abort                                      # interrupt the current turn
```

OpenCode also works on finished sessions (new turn, full context), replacing `-Resume` there. AGY: `say.ps1` deletes `done.json` when it sends, so a waiter sees the new turn's result; if the worker already exited it prints `SESSION_ENDED` — then re-dispatch with `-Resume` (same `-Dir`/`-Name`). `-Abort` on AGY ends the session (no per-turn interrupt). Messages are instructions to an agent, so the same Verify and boundary rules apply.

## The brief (cold-start prompt)

The agent shares none of your context. Write a file containing, densely:
1. Exact repo path and branch it should be on
2. What is verified real vs. what to investigate (state your verdict; don't make it re-derive or re-litigate)
3. Exact fix instructions with file:line pointers
4. Exact test commands incl. env gotchas (e.g. "use `.venv/Scripts/python.exe`, not bare `python`")
5. Boundary: **"No pushes/merges/deploys — report back and wait."**
6. Where to write the full report, and the short contract back: Status (DONE|BLOCKED|NEEDS_CONTEXT) / files changed / one-line test summary / concerns / report path
7. Per-command backgrounding rule: long-running servers (`npm run dev`, `vite`, watchers) must be started detached and only checked for clean startup; finite commands (lint, `tsc --noEmit`, build, tests) run in the foreground. State both halves if a dev server is involved.
8. Parallel dispatch only: "`git add` only the exact files named in this brief — never `git add .`/`-A`/wildcards."

Since the brief is a file, you can paste code, backticks and `${}` freely — no escaping needed.

Example:
```
Repo: C:\fake\repo, branch main. Verified real: POST /signup accepts any string as
email. Fix: src/routes/signup.js ~line 45, add RFC5322-ish validation, 400 on failure.
Test: npm test (foreground), add one invalid and one valid email case. No pushes/merges/
deploys - report back and wait. Write full report to signup-fix-report.md, then reply:
Status (DONE|BLOCKED|NEEDS_CONTEXT) / files changed / one-line test summary / concerns / report path.
```

## Checking progress without burning tokens

**Never read `RUN_DIR\out.log` directly** (raw JSON events, easily hundreds of KB). Use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\peek.ps1" -RunDir "<RUN_DIR>" [-Lines 15]
```

It prints the status line (RUNNING / DONE / STALLED, tokens, seconds since last output) and the last N condensed steps (tool calls, what the agent said). Use it when a run seems slow or a watchdog status arrives.

## Verify — Never Trust the Report

Treat every "DONE" as an unverified claim. Start with the compact review, which also saves the COMPLETE diff to a file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\review.ps1" -RunDir "<RUN_DIR>" [-Report "<agent report path>"]
```

It lists commits the agent made since dispatch, files changed with +/- counts, untracked files, simple red flags, and the agent's report. The full diff is in `RUN_DIR\full.diff`: **read it (or `git diff <base> -- <file>`) whenever the summary leaves any doubt**, and always for logic-heavy or risky files. The summary is for deciding where to look, not a substitute for looking. Don't take "N tests pass" as proof the right thing was tested. If it says a review finding is wrong, check yourself before dismissing — and vice versa. Delegates have both fixed real bugs a brief introduced and wrongly dismissed correct findings.

## Blocks and Questions

If it ends BLOCKED/with a question, answer with `say.ps1` (OpenCode) or dispatch again with `-Resume` (AGY; same `-Dir`, same `-Name`) plus the missing context. If you can answer from context you already have (naming, which pattern to follow, fixture contents), answer directly — don't bounce it through the user. Escalate only for product/business decisions, risky actions (push/merge/deploy), or things you can't verify.

`-Resume` continues the *last* session for that backend/dir. If two unrelated tasks ran in the same repo, resume the right one by hand: OpenCode `opencode run --attach <url> -s <ses_id> ...` (id is in `RUN_DIR\session`; `opencode session list`), AGY `agy --conversation <id>`.

## Parallel Dispatch of Independent Tasks

Safe for tasks whose files are genuinely disjoint (separate OS processes). But "disjoint" means everything the task touches, not just its main deliverable (confirmed live: 9 parallel tasks each appending to the same two locale JSON files caused misattributed commits, and one agent's `git add .` swept up another's uncommitted files, leaving that task's commit empty).
- Every parallel brief must say `git add` only its own named files (item 8 above).
- Route shared-file writes (locale keys, registries, barrel exports) through a final sequential integration task. If impractical, accept misattributed commits and verify the shared file's end state directly (valid JSON, no duplicate keys within the same object — check per object, not a flat grep).
- Afterwards, check `git log --stat` over the whole range before assuming commit boundaries map 1:1 to tasks.

## Risky Actions Stay With You

Push, merge and deploy: confirm with the user first, review the diff yourself, then either do it or explicitly authorize the agent in that one dispatch. "No push" in the brief is not a substitute for checking `git log`/`git diff` before you push what it built.

## Tool Notes and Gotchas

- **Why no more interactive/`--prompt` seeding:** `opencode [project] --prompt` and `agy -i` run ONE turn then wait for a human forever — a real dispatch stalled that way. Unattended work uses `run --attach` / `--print` only (which `dispatch.ps1` does). Run the interactive forms by hand only when the user is at the keyboard.
- **OpenCode:** `run --attach` talks to the shared server, so a crashed TUI window never kills a task. Server log: `<first RUN_DIR>\server.log`. To stop the server: `Get-CimInstance Win32_Process | ? CommandLine -match 'opencode.*serve' | % { taskkill /PID $_.ProcessId /T /F }`. `--auto` auto-approves everything not explicitly denied; it grants no rights the brief doesn't.
- **AGY:** needs the user-owned permission rule `Bash(agy --dangerously-skip-permissions:*)` (add via `/permissions`; you cannot grant it yourself and must not try to route around the classifier or edit `settings.json` to self-grant). Until it exists, the dispatch is refused. The worker runs `agy --print "" --input-format stream-json --output-format stream-json` and sends the brief as the first stream message; later messages come from `say.ps1`. AGY ignores the OS cwd, so the scripts always pass `--add-dir` (repo and run dir) plus `--project <name> --new-project`; the brief path in the prompt is absolute. Verify results against the real target folder, never `~/.gemini/antigravity-cli/scratch`. Stall/timeout are per turn (`-StallMin`, `-TimeoutMin`); `-IdleMin` (default 15) is how long the session stays open after a turn. AGY has no server/attach and its interactive TUI can't be driven from outside; `--remote-control` only opens a Google-cloud web tunnel for interactive sessions (not `--print`). To inspect a finished conversation in the real TUI by hand: `agy --conversation <id>` (id is in `done.json`); don't open it while a worker is writing to the same conversation.
- **`antigravity-ide`** is a different binary (VS-Code-fork IDE), unvalidated for this pattern; use `agy`.
- **Other CLIs:** check `<tool> --help`; if there is no scriptable run mode it doesn't fit.
- **Windows quoting:** the scripts handle it. If you must call a CLI by hand from PowerShell 5.1, pass long prompts via a file, never inline.
- Verified live: happy paths, follow-up messages, AGY `STALLED` (killed the whole tree, no orphans). Not yet exercised: `TIMEOUT`, AGY idle-exit, OpenCode `STALLED`. `-StallMin`/`-TimeoutMin`/`-IdleMin` accept fractions (e.g. 0.5) for testing. If one misbehaves, fix `scripts/worker.ps1`.
