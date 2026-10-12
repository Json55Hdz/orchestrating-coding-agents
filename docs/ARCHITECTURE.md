# Architecture

## The idea

Claude plans, reviews and gates risky actions. An external CLI coding agent does the edits, test runs and investigation **in its own process on its own token budget**. Only a short report and a compact diff summary reach Claude's context. The same principle as forking a subagent to keep noise out of context, applied across a process boundary.

## Moving parts

```
Claude Code ──(Bash tool)──► dispatch.ps1 ──► creates RUN_DIR in %TEMP%\agent-runs\<name>-<timestamp>\
                                  │
                                  ├─ OpenCode: ensure `opencode serve` ─► POST /session ─► hidden worker.ps1
                                  │                                        (opencode run --attach -s <id>)
                                  │             persistent viewer tab ──► opencode attach -s <id>   (real TUI)
                                  │
                                  └─ AGY:      queue a job ─► persistent viewer tab runs worker.ps1 inline
                                                (agy --print "" --input-format/--output-format stream-json,
                                                 stdin kept open for follow-ups)

wait.ps1 ◄── done.json       say.ps1 ──► OpenCode HTTP API  |  AGY inbox\ ─► worker ─► agy stdin
peek.ps1 / review.ps1 ◄── out.log, git          agent-runs-band mod ◄── reads RUN_DIRs
```

### Run directory

Everything about one dispatch lives in `%TEMP%\agent-runs\<name>-<yyyyMMdd>-<HHmmss>\`:

| File | Meaning |
|---|---|
| `brief.md` | The task brief (passed to the agent **as a file**, never inline: no quoting bugs) |
| `out.log` | Raw output of the backend (JSON events). **Never read it directly**: use `peek.ps1` |
| `done.json` | Completion signal. `status`: `DONE` `FAILED` `STALLED` `TIMEOUT`. AGY rewrites it at the end of every turn (`turn`, `tokens`, `conversation`, `lastResponse`) |
| `session` | OpenCode session id |
| `inbox\` | AGY only: files dropped by `say.ps1`, forwarded to the agent's stdin |
| `worker.pid`, `pid` | Worker process and agent process ids (used by the mod and by `say -Abort`) |
| `base-commit`, `target-dir` | Git HEAD at dispatch and the repo path, so `review.ps1` can diff against the pre-dispatch state |
| `full.diff` | Written by `review.ps1`: the complete diff, read on demand |
| `last-response.txt` | AGY: the last turn's reply |

`%TEMP%\agent-runs\slots\` holds the persistent-viewer state (`<backend>-<slot>.alive|cur|queue`).

## Design decisions (and the failures behind them)

- **Headless one-shot, never the interactive shape, for unattended work.** `opencode --prompt` and `agy -i` run **one** turn then wait for a human forever; a real dispatch stalled that way. The scripts only use `run --attach` / `--print`.
- **The brief is a file.** Inline prompts with backticks, `$`, `${}` or parentheses were silently garbled by the shell/PowerShell parsers.
- **OpenCode work lives in a server, not in a window.** `opencode serve` owns the session; the viewer is just `opencode attach`. A crashed or closed tab never kills a task, and the session id is created up front through the API so the viewer can attach immediately (waiting for the first JSON event was racy).
- **AGY has no server or attach**, and its interactive TUI cannot be driven from outside. So the worker owns one long-lived `agy --print` process in `stream-json` mode with stdin open: the first message is the brief, follow-ups arrive through the inbox, and each `result` event is an exact end-of-turn signal with token usage. The viewer renders those events in a readable form. It is a faithful view of AGY's real event stream, **not** AGY's TUI.
- **AGY ignores the OS working directory.** The worker always passes `--add-dir <repo>` and `--add-dir <RUN_DIR>`, plus `--project <name> --new-project`, and absolute paths in the prompt.
- **A watchdog on everything.** Per-turn timeout and "no output for N minutes" detection, killing the whole process tree (the npm shim spawns children). It exists because a hung agent looks identical to a working one from outside.
- **Persistent viewer tabs.** One long-lived PowerShell per backend/slot in a Windows Terminal window named `agents`; dispatch opens it only when no live one exists and otherwise just points it at the new task.
- **Claude never trusts a report.** `review.ps1` gives a compact summary and saves the full diff; the skill tells Claude to read it whenever the summary leaves doubt.

## The mod

`hooks/register.tsx` draws a band above the prompt (`ui.render` on `AbovePrompt`) from the run directories, polling every 3 s. For runs without `done.json` it checks `worker.pid` against `tasklist`, so a run whose window was closed shows as `closed` instead of `running`, and a folder that never started is hidden. A toast fires when a run reaches a final state. It reads only `%TEMP%` and runs `tasklist`; it writes nothing.

## Adding another backend (Codex, etc.)

A backend is four things. To add one, extend `worker.ps1` (command line + event rendering), `dispatch.ps1` (viewer behaviour), `say.ps1` and `models.ps1`:

| Needed | OpenCode | AGY | What a new backend must offer |
|---|---|---|---|
| Headless run with auto-approve, a target dir, a model | `run --attach --auto --dir -m` | `--print --dangerously-skip-permissions --add-dir --model` | a non-interactive mode that **ends the process when done** |
| A completion signal | process exit | `result` event per turn | exit code or a final event |
| Follow-up messages | HTTP `prompt_async` | stream-json stdin | stdin protocol, HTTP API, or "resume the last session" |
| A way to watch | `attach` (real TUI) | event feed | any, at worst a live feed of its JSON events |
| Model listing | `opencode models` | `agy models` | a command, or a fixed list |

Candidates and what is known (**not verified here**, check each CLI's `--help`):

- **Codex CLI**: has a non-interactive `codex exec` with JSONL output and a resume command; it would fit the AGY-style "worker owns the process, render the event stream" model, with follow-ups via resume. Not installed on the author's machine, so untested.
- **OpenRouter** is a model gateway, not a coding agent. OpenCode already supports it as a provider (`opencode providers login`), so its models appear in `models.ps1` today with no code changes.
- Anything with a print/run mode that exits when finished fits the pattern; anything IDE-only does not.

Pull requests adding a backend are welcome; see [CONTRIBUTING.md](../CONTRIBUTING.md).
