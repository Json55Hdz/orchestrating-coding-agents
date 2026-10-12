# Changelog

## 0.1.1 (2026-10-12)

- Fix: persistent viewers are now scoped per project dir, so two projects no longer share (and hijack) the same OpenCode/AGY viewer.
- Fix: mod `agent-runs-band` shows only the runs of the current session's project.

## 0.1.0 (2026-10-12)

First public version.

- Skill: delegate work to OpenCode or AGY; brief-as-file dispatch; mandatory model choice by the user; verification discipline; superpowers pairing.
- Persistent, reused viewer tabs in Windows Terminal (OpenCode real TUI via `attach`; AGY live event feed).
- `say.ps1`: message a live agent on both backends.
- Watchdog: per-turn timeout, stall detection, process-tree kill, `done.json` for every outcome.
- `peek.ps1`, `review.ps1` (compact summary + full diff on disk), `models.ps1`, `preflight.ps1`.
- Mod `agent-runs-band`: status band above the prompt with toasts, aware of closed windows.
- Verified on Windows 11 with OpenCode 1.18.x and AGY; see the README for what is not yet exercised.
