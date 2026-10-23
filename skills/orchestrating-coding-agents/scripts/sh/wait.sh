#!/bin/bash
# Blocks until <RunDir>/done.json exists, then prints it. Use with run_in_background.
RunDir=; MaxMin=60
while [ $# -gt 0 ]; do
  case "$1" in
    -RunDir) RunDir=$2; shift 2 ;;
    -MaxMin) MaxMin=$2; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 1 ;;
  esac
done
[ -n "$RunDir" ] || { echo "-RunDir is required" >&2; exit 1; }
deadline=$(( $(date +%s) + $(awk "BEGIN{print int($MaxMin*60)}") ))
while [ ! -e "$RunDir/done.json" ]; do
  if [ "$(date +%s)" -gt "$deadline" ]; then echo '{"status":"WAIT_EXPIRED"}'; exit 2; fi
  sleep 3
done
cat "$RunDir/done.json"
