#!/bin/bash
# Lists the models both backends can actually use right now (authenticated), for the pre-dispatch question.
here=$(cd "$(dirname "$0")" && pwd); . "$here/common.sh"
Backend=both
while [ $# -gt 0 ]; do
  case "$1" in
    -Backend) Backend=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$Backend" != agy ]; then
  echo '=== OPENCODE (pass as provider/model) ==='
  if command -v opencode >/dev/null 2>&1; then { m=$(opencode models --refresh 2>&1 | grep '/'); [ -n "$m" ] || m=$(opencode models 2>&1 | grep '/'); printf '%s\n' "$m"; }; else echo '(opencode not installed)'; fi
fi
if [ "$Backend" != opencode ]; then
  [ "$Backend" = both ] && echo
  echo '=== AGY (pass the id on the left) ==='
  agy=$(resolve_agy)
  if [ -n "$agy" ]; then "$agy" models 2>&1 | grep -v '^Fetching'; else echo '(agy not installed)'; fi
fi
exit 0
