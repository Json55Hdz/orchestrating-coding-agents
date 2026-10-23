#!/bin/bash
# Checks everything the skill needs on this machine and says what to fix. Safe to run any time.
here=$(cd "$(dirname "$0")" && pwd); . "$here/common.sh"
ok=1
check() {
  if [ "$2" = 1 ]; then printf '\033[32m[ OK ]\033[0m %s\n' "$1"
  else printf '\033[31m[FAIL]\033[0m %s\n       -> %s\n' "$1" "$3"; ok=0; fi
}
yn() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

check "bash ${BASH_VERSION%%(*}" 1 ''
check 'perl with JSON::PP, HTTP::Tiny, IO::Select (core modules)' "$(yn perl -MJSON::PP -MHTTP::Tiny -MIO::Select -e1)" 'Install perl (macOS has it built in; Linux: apt install perl).'
check 'git on PATH' "$(yn have git)" 'Install git.'
check 'curl on PATH' "$(yn have curl)" 'Install curl.'
if [ "$(uname -s)" = Darwin ]; then
  check 'osascript (opens the viewer in Terminal.app)' "$(yn have osascript)" 'osascript ships with macOS. Without it use dispatch -NoWindow.'
else
  t=
  for x in x-terminal-emulator gnome-terminal konsole xfce4-terminal kitty alacritty xterm; do
    if have $x; then t=$x; break; fi
  done
  d=0; if [ -n "$t" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then d=1; fi
  check 'A terminal emulator and a display ($DISPLAY / $WAYLAND_DISPLAY), used for the viewer window' $d 'Install a terminal (gnome-terminal, konsole, xterm...) or run headless: dispatch -NoWindow, then peek.'
fi
if have opencode; then
  check 'OpenCode CLI (opencode on PATH)' 1 ''
  m=$(opencode models 2>&1 | grep '/')
  if [ -n "$m" ]; then r=1; else r=0; fi
  check 'OpenCode has at least one model available' $r 'Authenticate a provider: opencode providers login'
else
  check 'OpenCode CLI (opencode on PATH)' 0 'npm i -g opencode-ai   (or see opencode.ai), then run: opencode providers login'
fi
agy=$(resolve_agy)
if [ -n "$agy" ]; then r=1; else r=0; fi
check 'AGY / Antigravity CLI (agy)' $r 'Install the Antigravity CLI, or set AGY_PATH to the agy binary. Only needed if you will use AGY.'
if [ -n "$agy" ]; then
  m=$("$agy" models 2>&1 | grep -v '^Fetching' | grep -v '^[[:space:]]*$')
  case "$m" in ''|*[Ee]rror*|*login*|*auth*) r=0 ;; *) r=1 ;; esac
  check 'AGY signed in and listing models' $r 'Run agy once interactively and sign in.'
fi
echo
printf '\033[33mManual step (cannot be automated): unattended AGY needs this permission rule in Claude Code,\n  Bash(agy --dangerously-skip-permissions:*)    add it with /permissions or in settings.json yourself.\033[0m\n'
if [ $ok = 1 ]; then printf '\n\033[32mAll required checks passed.\033[0m\n'; else exit 1; fi
