#!/bin/sh
# OS-aware launcher: run.sh <script-name> [args...]   e.g. run.sh dispatch -Backend agy ...
# Windows (Git Bash) -> Windows PowerShell 5.1 (scripts/*.ps1).
# macOS/Linux        -> bash + perl (scripts/sh/*), nothing to install.
d=$(cd "$(dirname "$0")" && pwd)
s=$1; shift
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$d/$s.ps1")" "$@" ;;
  *)
    if [ -f "$d/sh/$s.sh" ]; then exec bash "$d/sh/$s.sh" "$@"; fi
    if [ -f "$d/sh/$s.pl" ]; then exec perl "$d/sh/$s.pl" "$@"; fi
    echo "unknown script: $s" >&2; exit 2 ;;
esac
