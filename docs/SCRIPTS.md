# Scripts reference

All scripts are Windows PowerShell 5.1 and live in `skills/orchestrating-coding-agents/scripts/`. Run them with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <path>\<script>.ps1 [args]
```

Claude calls them for you; this page is for when you want to drive them yourself.

## dispatch.ps1

Start a task. Prints `VIEWER=...` and `RUN_DIR=<path>`, then returns (about 10 s).

| Parameter | Default | Meaning |
|---|---|---|
| `-Backend opencode\|agy` | required | Which agent |
| `-Dir` | required | Repository / working directory (absolute) |
| `-BriefFile` | required | File with the full task brief |
| `-Model` | **required** | Backend model id (`provider/model` for OpenCode, the id from `agy models`). Deliberately mandatory: the user chooses |
| `-Name` | `task` | Short name, used for the run folder, the session and the tab title |
| `-Slot` | `main` | Viewer slot within the project (viewers are already isolated per project dir); use different slots for parallel tasks in the same project |
| `-Resume` | off | Continue the backend's last session in `-Dir` |
| `-NoWindow` | off | Don't open/reuse a viewer tab |
| `-TimeoutMin` | `30` | Max minutes per turn (fractions allowed) |
| `-StallMin` | `10` | Max minutes without any output while a turn runs |
| `-IdleMin` | `15` | AGY: minutes the session stays open after a turn, waiting for follow-ups |
| `-Port` | `4096` | OpenCode server port |

`VIEWER=OK (opened)` / `OK (reused)` means the viewer tab is attached. Anything else says what failed; the task may still be running (OpenCode).

## wait.ps1

`wait.ps1 -RunDir <RUN_DIR> [-MaxMin 60]`: blocks until `done.json` exists and prints it. Run it in the background so you're notified when it exits.

## say.ps1

Talk to a running (or finished) agent.

```powershell
say.ps1 -RunDir <RUN_DIR> -Text "message"            # send and return
say.ps1 -RunDir <RUN_DIR> -Text "message" -Wait      # send, wait, print the reply
say.ps1 -RunDir <RUN_DIR> -Last                      # latest assistant message
say.ps1 -RunDir <RUN_DIR> -Abort                     # OpenCode: interrupt the turn. AGY: end the session
```

OpenCode works through the server API (also on finished sessions). AGY works while the worker is alive; a message sent mid-turn is queued by AGY. If the worker already exited you get `SESSION_ENDED`; re-dispatch with `-Resume`.

## peek.ps1

`peek.ps1 -RunDir <RUN_DIR> [-Lines 15]`: status line plus the last N condensed steps (tool calls, what the agent said). Use it instead of reading `out.log`.

## review.ps1

`review.ps1 -RunDir <RUN_DIR> [-Dir <repo>] [-Report <file>]`: commits since dispatch, files changed with counts, untracked files, simple red flags, the agent's report. Writes the complete diff (including new files) to `RUN_DIR\full.diff` and prints its path.

## models.ps1

`models.ps1 [-Backend both|opencode|agy]`: models each backend can use right now.

## preflight.ps1

Checks PowerShell, Windows Terminal, OpenCode (with models), AGY (signed in) and reminds you of the manual AGY permission rule. Exit code 1 if a required check fails.

## Internal

`worker.ps1` (runs one backend process with the watchdog), `viewer.ps1` (the persistent tab), `common.ps1` (shared helpers, e.g. locating `agy.exe` via `AGY_PATH`, the default install path, or `PATH`).

## Environment

| Variable | Use |
|---|---|
| `AGY_PATH` | Full path to `agy.exe` if it isn't at `%LOCALAPPDATA%\agy\bin\agy.exe` or on `PATH` |
