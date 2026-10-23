# Contributing

Thanks for helping. This plugin is small and has two implementations of the same scripts: Windows PowerShell 5.1 in `scripts/*.ps1`, and bash + perl for macOS/Linux in `scripts/sh/` (bash 3.2 compatible, core perl modules only). `scripts/run.sh` picks one by OS; a behaviour change must land in both. (The `.ps1` files still contain pwsh/Unix branches from an earlier iteration; `run.sh` no longer uses them.) keep it dependency-free (no Python, no npm packages at runtime).

## Layout

```
.claude-plugin/        plugin.json, marketplace.json
hooks/                 the mod (register.tsx) and its test
skills/orchestrating-coding-agents/
  SKILL.md             instructions Claude follows
  scripts/             PowerShell implementation
docs/                  architecture, scripts reference, troubleshooting
```

## Before opening a PR

1. `claude plugin validate .` must pass (manifest, marketplace and the mod).
2. `claude plugin test .` must pass if you touched the mod.
3. If you touched a script, run it for real: a tiny dispatch to each backend you changed, plus `say.ps1` and a stall test (`-StallMin 0.4` with a brief that sleeps) when you changed the worker. Say in the PR what you ran. Behaviour claims in `SKILL.md` and the README should match what you verified.
4. Keep `SKILL.md` accurate and short: it is loaded into Claude's context every time the skill runs.

## Adding a backend

See "Adding another backend" in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The bar: a non-interactive mode that exits when done, auto-approve, a target directory, and a way to list models.

## Style

PowerShell: quote every path, no `Start-Process -ArgumentList` with raw arrays (use the quoting helper), avoid aliases in scripts, never write secrets to the run folder. Prefer fixing a root cause over adding another retry.

## License

By contributing you agree your contribution is MIT licensed.
