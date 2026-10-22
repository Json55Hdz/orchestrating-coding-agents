#!/bin/sh
# OS-aware launcher: run.sh <script-name> [args...]   e.g. run.sh dispatch -Backend agy ...
# Windows (Git Bash) -> Windows PowerShell 5.1; macOS/Linux -> PowerShell 7 (pwsh).
d=$(cd "$(dirname "$0")" && pwd)
s=$1; shift
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$d/$s.ps1")" "$@" ;;
  *)
    command -v pwsh >/dev/null 2>&1 || { echo "PowerShell 7 (pwsh) is required: brew install --cask powershell (macOS) or https://aka.ms/powershell (Linux)" >&2; exit 127; }
    exec pwsh -NoProfile -File "$d/$s.ps1" "$@" ;;
esac
