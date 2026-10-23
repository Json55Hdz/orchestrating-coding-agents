#!/bin/bash
# Persistent viewer window. Stays open between tasks; dispatch.sh feeds it instead of opening new windows.
#   opencode: re-attaches the REAL TUI (`opencode attach -s <session>`) whenever a new task is pointed at it.
#   agy:      runs queued workers inline, so the window shows the REAL agy process output.
here=$(cd "$(dirname "$0")" && pwd); . "$here/common.sh"
Backend=; Slot=main; Url=http://127.0.0.1:4096
while [ $# -gt 0 ]; do
  case "$1" in
    -Backend) Backend=$2; shift 2 ;;
    -Slot) Slot=$2; shift 2 ;;
    -Url) Url=$2; shift 2 ;;
    *) shift ;;
  esac
done
slots=$(runs_root)/slots
key=$Backend-$Slot
alive=$slots/$key.alive; cur=$slots/$key.cur; queue=$slots/$key.queue
mkdir -p "$queue"
printf '\033]0;[%s] %s  (persistent viewer)\007' "$Backend" "$Slot"
echo $$ > "$alive"
trap 'rm -f "$alive"' EXIT

if [ "$Backend" = opencode ]; then
  seen=; [ -f "$cur" ] && seen=$(cat "$cur")   # ignore a stale pointer from a dead viewer
  child=; announced=0
  echo "Viewer ready ($key). Waiting for the next task..."
  while true; do
    if [ -f "$cur" ]; then
      raw=$(cat "$cur")
      if [ -n "$raw" ] && [ "$raw" != "$seen" ]; then
        seen=$raw
        [ -n "$child" ] && kill -0 "$child" 2>/dev/null && stop_tree "$child"
        sess=$(printf '%s\n' "$raw" | sed -n 1p); tdir=$(printf '%s\n' "$raw" | sed -n 2p)
        clear
        opencode attach "$Url" --dir "$tdir" -s "$sess" &
        child=$!; announced=0
      fi
    fi
    if [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null && [ $announced = 0 ]; then
      clear; echo "TUI closed. Waiting for the next task..."; announced=1
    fi
    sleep 0.7
  done
else
  echo "Viewer ready ($key). Waiting for the next task..."
  while true; do
    job=$(ls "$queue"/*.job 2>/dev/null | sort | head -1)
    if [ -z "$job" ]; then sleep 0.7; continue; fi
    wargs=()
    while IFS= read -r l; do wargs[${#wargs[@]}]=$l; done < "$job"
    rm -f "$job"
    clear
    perl "$here/worker.pl" "${wargs[@]}" || echo "worker crashed"
    echo
    echo "Waiting for the next task..."
  done
fi
