# Troubleshooting

Start with `scripts\preflight.ps1`. It checks PowerShell, Windows Terminal, OpenCode, AGY and their sign-ins.

## `dispatch.ps1` says `-Model is required`
By design. Run `models.ps1`, pick a model, pass it with `-Model`. Claude asks you for it each time.

## `VIEWER=FAILED` / the viewer tab didn't open
The task may still be running (OpenCode). Read progress with `peek.ps1 -RunDir <RUN_DIR>`. Without Windows Terminal the viewer falls back to a plain console window; if neither opens, run with `-NoWindow` and use `peek.ps1`.

## `VIEWER=NOT_ATTACHED`
The viewer tab is up but hasn't attached yet (OpenCode was slow). Look at the `agents` window; it attaches when the session responds. Check `RUN_DIR\out.log` via `peek.ps1`.

## Status `STALLED`
No output for `-StallMin` minutes. The watchdog killed the process tree. Run `peek.ps1` to see the last step (often a command that never returns, like `find .` on a huge tree, or a dev server awaited in the foreground), then re-dispatch with `-Resume` and a brief that says what to avoid. Long builds or test suites need a larger `-StallMin`; AGY prints little while a command runs.

## Status `TIMEOUT`
A single turn exceeded `-TimeoutMin`. Same recovery as above, or raise the limit.

## `agy` is refused when Claude runs it
Claude Code blocks `--dangerously-skip-permissions` unless **you** added the rule `Bash(agy --dangerously-skip-permissions:*)` (via `/permissions` or `settings.json`). The plugin cannot and should not grant it itself.

## `agy.exe not found`
Install the Antigravity CLI or set the `AGY_PATH` environment variable to the full path of `agy.exe`.

## `SESSION_ENDED` from `say.ps1` (AGY)
The AGY worker exited (idle timeout, closed window, or it stalled). Re-dispatch the same `-Name`/`-Dir` with `-Resume`.

## The status band shows a run that isn't running
The band checks the worker process. An OpenCode task keeps running without its viewer tab (it lives in a hidden worker plus the server), so it is correctly shown as running; stop it with `say.ps1 -Abort`. A closed AGY tab shows as `closed`. Runs older than 3 hours are ignored.

## The band doesn't appear
Mods load when the plugin loads; run `/reload-plugins` or restart the session. Check `claude plugin validate <plugin dir>`.

## OpenCode server stuck or on another port
```powershell
Get-CimInstance Win32_Process | ? CommandLine -match 'opencode.*serve' | % { taskkill /PID $_.ProcessId /T /F }
```
The next dispatch starts a fresh one. Use `-Port` if 4096 is taken.

## Cleaning up
Run folders are in `%TEMP%\agent-runs\`; delete any you don't need. Don't delete `slots\` while viewers are open.
