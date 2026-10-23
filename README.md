# orchestrating-coding-agents

> A [Claude Code](https://code.claude.com) plugin that lets Claude **delegate grind work** (implementation, long test loops, PR-review fixes) to an external CLI coding agent, [**OpenCode**](https://opencode.ai) or the **Antigravity CLI (AGY)**, so the heavy lifting runs on *their* token budget instead of Claude's. Claude stays the architect and reviewer.

Español: [README.es.md](README.es.md)

**Status:** `0.3.0`, early. Works end to end on Windows 11; macOS/Linux support is new and smoke-tested on Linux only (see [what is verified](#what-is-verified-and-what-is-not)). MIT licensed.

## What you get

| | |
|---|---|
| **A skill** (`orchestrating-coding-agents`) | Teaches Claude *when* and *how* to delegate: write a brief file, ask you which model to use, dispatch, wait, review the diff, and verify before trusting a "DONE". |
| **Real, persistent viewer windows** | One long-lived Windows Terminal tab per backend, reused by every dispatch. OpenCode shows its **real TUI** (`opencode attach`). AGY shows a live readable feed of its event stream. |
| **Talk to the agent mid-task** | `say.ps1` is the equivalent of `SendMessage` to a subagent, for both backends. |
| **A watchdog** | Hard timeout + no-output stall detection; kills the whole process tree; always ends with a `done.json` (`DONE`/`FAILED`/`STALLED`/`TIMEOUT`). No more silent hangs. |
| **Token-saving helpers** | `peek.ps1` (compact progress, never read the raw JSON log) and `review.ps1` (compact change summary + the *complete* diff saved to a file for on-demand reading). |
| **A mod** (`agent-runs-band`) | A band above the Claude Code prompt listing active and recent runs, with a toast when one finishes, stalls, or its window is closed. |

## Requirements

- **Windows 10/11**: Windows PowerShell 5.1 (built in) and Windows Terminal (`wt.exe`). **macOS / Linux**: nothing to install beyond what the OS ships (`bash`, `perl`, `curl`, `git`); the viewer opens in Terminal.app (macOS) or your terminal emulator (Linux), or run headless with `-NoWindow`. The plugin picks the right implementation by itself (`scripts/run.sh`). No Python, Node packages or PowerShell on macOS/Linux.
- At least one backend, signed in:
  - **OpenCode**: `npm i -g opencode-ai`, then `opencode providers login`
  - **AGY / Antigravity CLI**: install it and run `agy` once to sign in (set `AGY_PATH` if it is not at `%LOCALAPPDATA%\agy\bin\agy.exe` or on `PATH`; on macOS/Linux the default is `~/.local/bin/agy`)
- Claude Code with plugin support.

## Install

In a Claude Code session:

```
/plugin install orchestrating-coding-agents --marketplace Json55Hdz/orchestrating-coding-agents
```

Answer `y` to add the marketplace, then pick a scope. Then check your machine (Claude can run this for you, or run it yourself):

```powershell
sh <plugin-dir>/skills/orchestrating-coding-agents/scripts/run.sh preflight
```

**One manual step for unattended AGY runs.** AGY needs `--dangerously-skip-permissions` to work without prompts, and Claude Code rightly refuses to grant itself that. Add this rule yourself with `/permissions` (or in `settings.json`):

```
Bash(agy --dangerously-skip-permissions:*)
```

## Usage

Just ask Claude to delegate:

> "Have OpenCode fix these 12 failing tests and report back."

Claude will:

1. list the models both backends can use right now (`models.ps1`) and **ask you which to use**,
2. write a self-contained brief file and run `dispatch.ps1` (a viewer tab opens, or the open one is reused),
3. wait for `done.json` in the background,
4. run `review.ps1` and read the full diff where anything looks off, then run the tests itself before accepting the result.

You can watch the agent work in the viewer tab, and Claude (or you) can steer it:

```powershell
# OpenCode and AGY
say.ps1 -RunDir <RUN_DIR> -Text "also cover the empty-string case" -Wait
```

See [docs/SCRIPTS.md](docs/SCRIPTS.md) for every script and flag, [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it works, and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) when something misbehaves.

### Using it with superpowers

The skill replaces only the *implementer* role, so it composes with the [superpowers](https://github.com/obra/superpowers) workflow: each `writing-plans` task becomes a brief, `subagent-driven-development`'s implementer becomes OpenCode/AGY, and `verification-before-completion` / `requesting-code-review` stay with Claude. It does not require superpowers.

## OpenCode vs AGY

| | OpenCode | AGY |
|---|---|---|
| Does the work | shared headless `opencode serve` (survives window crashes) | one long-lived `agy --print` process (stream-json) owned by the worker |
| Viewer tab | the **real OpenCode TUI**, live | a readable live feed of AGY's real events (AGY has no server/attach, so its TUI can't be shown from outside) |
| Message it | any time, even finished sessions | while the worker lives (during a turn it queues; after a turn it idles up to 15 min) |
| Window closed | task keeps running | task stops; resume with `-Resume` |

## What is verified and what is not

Verified live on Windows 11 (OpenCode 1.18.x, AGY with Gemini models):

- dispatch → work → `done.json` on both backends, viewer tab opened and **reused**
- follow-up messages to a live session on both backends (AGY recalled earlier context)
- watchdog `STALLED` on AGY (killed the process tree, no orphans)
- compact `review.ps1` on a real git repo; mod validation and 3 automated tests

**Not yet exercised:** watchdog `TIMEOUT`, `STALLED` on OpenCode, AGY idle-exit, the viewer window on macOS and Linux with a display, and long real-world tasks (no token-savings measurement yet). Issues and PRs welcome.

## Safety notes

- Both backends run with auto-approve (`--auto` / `--dangerously-skip-permissions`) inside the target directory. Use it on repos you trust, keep work committed/backed up, and rely on the brief's boundary line (*no pushes/merges/deploys*). The skill instructs Claude to confirm with you before pushing anything the agent built.
- The scripts only write under `%TEMP%\agent-runs` (a private per-user dir on macOS/Linux: `$XDG_RUNTIME_DIR`, `$TMPDIR` or `~/.cache`) and the target directory. They never read or send credentials.
- Briefs and logs live in `%TEMP%\agent-runs\`; delete old run folders any time.

## Uninstall

```
/plugin uninstall orchestrating-coding-agents
```

To stop the shared OpenCode server: `Get-CimInstance Win32_Process | ? CommandLine -match 'opencode.*serve' | % { taskkill /PID $_.ProcessId /T /F }` (Windows) or `pkill -f 'opencode serve'` (macOS/Linux).

## License

[MIT](LICENSE) © 2026 Json55Hdz
