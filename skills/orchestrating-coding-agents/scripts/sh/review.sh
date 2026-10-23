#!/bin/bash
# Compact review of what an agent changed, plus the COMPLETE diff saved to a file.
#   review -RunDir <RUN_DIR> [-Dir <repo>] [-Report <report file>]
RunDir=; Dir=; Report=
while [ $# -gt 0 ]; do
  case "$1" in
    -RunDir) RunDir=$2; shift 2 ;;
    -Dir) Dir=$2; shift 2 ;;
    -Report) Report=$2; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 1 ;;
  esac
done
[ -n "$RunDir" ] || { echo "-RunDir is required" >&2; exit 1; }
if [ -z "$Dir" ] && [ -f "$RunDir/target-dir" ]; then Dir=$(tr -d '\r\n' < "$RunDir/target-dir"); fi
[ -n "$Dir" ] || { echo "give -Dir (repo path)" >&2; exit 1; }
base=; if [ -f "$RunDir/base-commit" ]; then base=$(tr -d ' \r\n' < "$RunDir/base-commit"); fi
full=$RunDir/full.diff
G() { git -c core.safecrlf=false -C "$Dir" "$@" 2>/dev/null; }
if [ "$(G rev-parse --is-inside-work-tree)" != true ]; then
  here=$(cd "$(dirname "$0")" && pwd)
  if [ ! -f "$RunDir/snapshot.txt" ]; then echo "Not a git repo: $Dir, and this run has no file snapshot. Inspect files directly."; exit 0; fi
  echo "== Not a git repo: comparing $Dir against the file list taken at dispatch (A=added M=modified D=deleted)"
  changes=$(perl "$here/snap.pl" diff "$Dir" "$RunDir/snapshot.txt")
  if [ -z "$changes" ]; then echo '(no file changes)'; else printf '%s\n' "$changes" | head -200; n=$(printf '%s\n' "$changes" | wc -l | tr -d ' '); [ "$n" -gt 200 ] && echo "... and $((n-200)) more"; fi
  {
    printf '%s\n' "$changes" | while IFS=$'\t' read -r k p; do
      [ -n "$p" ] || continue
      f=$Dir/$p
      if [ "$k" = D ]; then echo "# deleted: $p"
      elif [ -L "$f" ]; then echo "# (skipped: $p - symlink)"
      elif [ -f "$f" ] && [ "$(wc -c < "$f")" -lt 204800 ]; then printf '# %s: %s\n' "$k" "$p"; sed 's/^/+/' "$f"
      else echo "# (skipped: $p - binary or >200KB)"; fi
    done
  } > "$full"
  echo; echo "== Contents of added/modified files (no git history, so not a real diff): $full"
  if [ -f "$RunDir/last-response.txt" ]; then echo; echo "== Agent's last reply (first 40 lines)"; head -40 "$RunDir/last-response.txt"; fi
  exit 0
fi
if [ -z "$base" ]; then
  base=HEAD
  echo "(no base commit recorded for this run; comparing against current HEAD = uncommitted changes only)"
fi

echo "== Commits by the agent since dispatch ($base..HEAD)"
c=$(G log --oneline "$base..HEAD")
if [ -n "$c" ]; then echo "$c"; else echo '(none)'; fi
echo
echo "== Files changed (vs $(printf '%.8s' "$base"), incl. uncommitted)"
G diff --stat=100 "$base"
untracked=$(G ls-files --others --exclude-standard)
if [ -n "$untracked" ]; then
  echo
  echo "Untracked (new, not yet added):"
  echo "$untracked" | sed 's/^/  ?? /'
fi

{
  G diff "$base"
  printf '%s\n' "$untracked" | while IFS= read -r u; do
    [ -n "$u" ] || continue
    p=$Dir/$u
    if [ -L "$p" ]; then
      echo "# (skipped untracked: $u - symlink to $(readlink "$p"))"
    elif [ -f "$p" ] && [ "$(wc -c < "$p")" -lt 204800 ]; then
      printf 'diff --git a/%s b/%s\nnew file\n--- /dev/null\n+++ b/%s\n' "$u" "$u" "$u"
      sed 's/^/+/' "$p"
    else
      echo "# (skipped untracked: $u - directory, binary or >200KB)"
    fi
  done
} > "$full"
echo
echo "== Full diff: $full  ($(wc -l < "$full" | tr -d ' ') lines). Read it (or git -C \"$Dir\" diff $base -- <file>) if anything above looks wrong."

flags=
if G diff --name-only "$base" | grep -Eq '(^|/)(\.env|.*secret.*|.*credential.*)'; then flags="touches env/secret-looking files"; fi
if G log --format=%s "$base..HEAD" | grep -q push; then flags="${flags:+$flags; }a commit message mentions push"; fi
echo
echo "== Red flags: ${flags:-none found by the script (still read the diff for logic errors)}"
if [ -n "$Report" ] && [ -f "$Report" ]; then
  echo; echo "== Agent report ($Report), first 40 lines"; head -40 "$Report"
elif [ -f "$RunDir/last-response.txt" ]; then
  echo; echo "== Agent's last reply (first 40 lines)"; head -40 "$RunDir/last-response.txt"
fi
exit 0
