#!/bin/bash
# One-call dispatch of a task to OpenCode or AGY with a REAL, PERSISTENT visible window (macOS/Linux twin of dispatch.ps1).
#   OpenCode: shared headless `opencode serve` does the work; a persistent viewer shows the real TUI
#             (`opencode attach -s <session>`) and re-attaches itself for each new task.
#   AGY:      no server/attach exists, so a persistent viewer runs the worker inline (the real process output, live).
# Viewers are scoped per project dir. Use -Slot <name> for a second concurrent viewer within the same project.
# Prints RUN_DIR=...; completion signal is <RUN_DIR>/done.json (see wait.sh).
here=$(cd "$(dirname "$0")" && pwd); . "$here/common.sh"

Backend=; Dir=; BriefFile=; Name=task; Slot=main; Model=; Resume=0; NoWindow=0; RestartServer=0
TimeoutMin=30; StallMin=10; IdleMin=15; Port=
while [ $# -gt 0 ]; do
  case "$1" in
    -Backend) Backend=$2; shift 2 ;;
    -Dir) Dir=$2; shift 2 ;;
    -BriefFile) BriefFile=$2; shift 2 ;;
    -Name) Name=$2; shift 2 ;;
    -Slot) Slot=$2; shift 2 ;;
    -Model) Model=$2; shift 2 ;;
    -Resume) Resume=1; shift ;;
    -NoWindow) NoWindow=1; shift ;;
    -RestartServer) RestartServer=1; shift ;;
    -TimeoutMin) TimeoutMin=$2; shift 2 ;;
    -StallMin) StallMin=$2; shift 2 ;;
    -IdleMin) IdleMin=$2; shift 2 ;;
    -Port) Port=$2; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
if [ -n "$Port" ]; then
  case "$Port" in *[!0-9]*) die "-Port must be a number between 1 and 65535" ;; esac
  [ "$Port" -ge 1 ] && [ "$Port" -le 65535 ] || die "-Port must be a number between 1 and 65535"
fi
[ -n "$Model" ] || die "-Model is required. Run scripts/run.sh models, list the models to the user and ask which to use (see SKILL.md > Model selection). Never pick one yourself."
case "$Backend" in opencode|agy) ;; *) die "-Backend must be opencode or agy" ;; esac
[ -n "$Dir" ] && [ -n "$BriefFile" ] || die "-Dir and -BriefFile are required"
Dir=$(cd "$Dir" && pwd -P) || die "bad -Dir"
BriefFile=$(cd "$(dirname "$BriefFile")" && pwd -P)/$(basename "$BriefFile")
[ -f "$BriefFile" ] || die "brief file not found: $BriefFile"
command -v perl >/dev/null 2>&1 || die "perl is required"

safe=$(printf '%s' "$Name" | tr -c 'A-Za-z0-9_-' '_')
runs=$(runs_root) || exit 1
run=$runs/$safe-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
cp "$BriefFile" "$run/brief.md"
brief=$run/brief.md
printf '%s\n' "$Dir" > "$run/target-dir"
if bc=$(git -C "$Dir" rev-parse HEAD 2>/dev/null) && [ -n "$bc" ]; then
  printf '%s\n' "$bc" > "$run/base-commit"   # lets review diff against the pre-dispatch state
else
  perl "$here/snap.pl" snap "$Dir" "$run/snapshot.txt" 2>/dev/null   # no git: review compares against this file list
fi
prompt="Your full task brief is in the file $brief . Read it first, then do exactly what it says. Report in the format it asks for."
url=http://127.0.0.1:${Port:-4096}   # OpenCode resolves its own per-user port below
slots=$runs/slots
leaf=$(printf '%s' "$(basename "$Dir")" | tr -c 'A-Za-z0-9_-' '_')
h6=$(printf '%s' "$Dir" | tr 'A-Z' 'a-z' | sha6)
Slot=$leaf-$h6-$Slot       # viewers are per project: two projects never share (and hijack) a viewer
key=$Backend-$Slot
mkdir -p "$slots"

wargs=(-RunDir "$run" -Backend "$Backend" -Dir "$Dir" -Prompt "$prompt" -Title "$Name" -TimeoutMin "$TimeoutMin" -StallMin "$StallMin" -IdleMin "$IdleMin" -Model "$Model")
[ $Resume = 1 ] && wargs[${#wargs[@]}]=-Resume

viewer_alive() {
  local f=$slots/$key.alive pid
  [ -f "$f" ] || return 1
  pid=$(cat "$f"); kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -q 'viewer.sh'
}

# Sets VIEWER to reused | opened | failed
ensure_viewer() {
  VIEWER=failed
  if viewer_alive; then VIEWER=reused; return; fi
  rm -f "$slots/$key.alive"
  local cmd=(bash "$here/viewer.sh" -Backend "$Backend" -Slot "$Slot" -Url "$url") title="$Backend:$Slot" term x
  if [ "$(uname -s)" = Darwin ]; then
    local sh as
    sh=$(printf '%q ' "${cmd[@]}")
    as=${sh//\\/\\\\}; as=${as//\"/\\\"}
    osascript -e 'tell application "Terminal" to activate' -e "tell application \"Terminal\" to do script \"$as\"" >/dev/null 2>&1 </dev/null
  else
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return
    for x in x-terminal-emulator gnome-terminal konsole xfce4-terminal kitty alacritty xterm; do
      if command -v $x >/dev/null 2>&1; then term=$x; break; fi
    done
    [ -n "$term" ] || return
    case "$term" in
      gnome-terminal) start_detached "$slots/$key.term.out" "$slots/$key.term.err" gnome-terminal "--title=$title" -- "${cmd[@]}" ;;
      xfce4-terminal) start_detached "$slots/$key.term.out" "$slots/$key.term.err" xfce4-terminal --title "$title" -x "${cmd[@]}" ;;
      kitty)          start_detached "$slots/$key.term.out" "$slots/$key.term.err" kitty --title "$title" "${cmd[@]}" ;;
      *)              start_detached "$slots/$key.term.out" "$slots/$key.term.err" "$term" -e "${cmd[@]}" ;;
    esac
  fi
  local i=0
  while [ $i -lt 40 ]; do viewer_alive && { VIEWER=opened; return; }; sleep 0.5; i=$((i+1)); done
}

# true when opencode itself, its login or its config changed after the recorded server started (the server would answer with old models/accounts)
server_stale() {
  local f oc
  oc=$(command -v opencode 2>/dev/null)
  for f in "$oc" "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json" "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc"; do
    [ -n "$f" ] && [ -e "$f" ] && [ "$f" -nt "$1" ] && return 0
  done
  return 1
}
server_wait() { local i=0; while [ $i -lt 30 ]; do server_up && return; sleep 0.5; i=$((i+1)); done; }
server_up() {
  local c
  c=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$url/" 2>/dev/null)
  [ -n "$c" ] && [ "$c" != 000 ]
}

if [ "$Backend" = opencode ]; then
  command -v opencode >/dev/null 2>&1 || die "opencode not found on PATH. Install it (npm i -g opencode-ai)."
  command -v curl >/dev/null 2>&1 || die "curl is required"
  # The server is ours alone: a random port recorded in the private runs dir, reused only while the process we
  # started is alive. An explicit -Port keeps the old behaviour (reuse whatever answers there).
  if [ -z "$Port" ]; then
    portf=$runs/server.port; pidf=$runs/server.pid
    spid=; sport=
    [ -f "$pidf" ] && spid=$(cat "$pidf"); [ -f "$portf" ] && sport=$(cat "$portf")
    if [ -n "$spid" ] && [ $RestartServer = 0 ] && ! server_stale "$pidf" && [ -n "$sport" ] && kill -0 "$spid" 2>/dev/null \
       && ps -p "$spid" -o args= 2>/dev/null | grep -Eq "opencode serve --port $sport( |$)" && listener_owned "$spid" "$sport"; then
      Port=$sport
    else
      if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null && { [ $RestartServer = 1 ] || server_stale "$pidf"; }; then
        if [ $RestartServer = 1 ]; then why=requested; else why="opencode, its login or its config changed since the server started"; fi
        echo "NOTE: restarting the opencode server ($why); tasks still running on the old one are interrupted"
        stop_tree "$spid"
      fi
      rm -f "$pidf" "$portf"   # stale or unverifiable record: never trust it
      Port=$(pick_port); [ -n "$Port" ] || die "could not find a free port"
      url=http://127.0.0.1:$Port
      start_detached "$run/server.log" "$run/server.err" opencode serve --port "$Port"
      printf '%s\n' "$LAST_PID" > "$pidf"; printf '%s\n' "$Port" > "$portf"
      server_wait
      if ! listener_owned "$LAST_PID" "$Port"; then
        stop_tree "$LAST_PID"; rm -f "$pidf" "$portf"
        die "port $Port is held by a process that is not our opencode server; refusing to use it (retry)"
      fi
    fi
    url=http://127.0.0.1:$Port
  elif ! server_up; then
    start_detached "$run/server.log" "$run/server.err" opencode serve --port "$Port"
  fi
  server_wait
  server_up || die "opencode serve did not come up on $url (see $run/server.log)"
  printf '%s\n' "$Port" > "$run/port"
  wargs+=(-Url "$url")
  sid=
  if [ $Resume = 0 ]; then   # create the session up front: the viewer knows its id from second zero
    body=$(perl -MJSON::PP -e 'print encode_json({title => $ARGV[0]})' "$Name")
    resp=$(curl -s -m 15 -X POST "$url/session?directory=$(urlenc "$Dir")" -H 'Content-Type: application/json' -d "$body")
    sid=$(printf '%s' "$resp" | json_get id)
    [ -n "$sid" ] && wargs+=(-SessionId "$sid")
  fi
  start_detached "$run/worker.stdout" "$run/worker.stderr" perl "$here/worker.pl" "${wargs[@]}"
  i=0
  while [ -z "$sid" ] && [ $i -lt 150 ]; do
    if [ -f "$run/out.log" ]; then
      sid=$(grep -o '"sessionID" *: *"ses_[A-Za-z0-9]*"' "$run/out.log" | head -1 | sed 's/.*"\(ses_[A-Za-z0-9]*\)"/\1/')
    fi
    [ -z "$sid" ] && sleep 0.5
    i=$((i+1))
  done
  [ -n "$sid" ] && printf '%s\n' "$sid" > "$run/session"
  if [ $NoWindow = 0 ]; then
    if [ -z "$sid" ]; then
      echo "VIEWER=SKIPPED (no session id yet; check $run/out.log)"
    else
      ensure_viewer
      if [ "$VIEWER" = failed ]; then
        echo "VIEWER=FAILED (viewer window did not start; task still runs - see $run/out.log)"
      else
        printf '%s\n%s\n%s\n%s\n%s\n' "$sid" "$Dir" "$run" "$(date +%s)" "$url" > "$slots/$key.cur.tmp"
        mv -f "$slots/$key.cur.tmp" "$slots/$key.cur"
        sleep 4
        if cmdline_running ' attach ' "$sid"; then echo "VIEWER=OK ($VIEWER)"
        else echo "VIEWER=NOT_ATTACHED ($VIEWER; check the viewer window)"; fi
      fi
    fi
  fi
else
  if [ $NoWindow = 1 ]; then
    start_detached "$run/worker.stdout" "$run/worker.stderr" perl "$here/worker.pl" "${wargs[@]}"
  else
    ensure_viewer
    if [ "$VIEWER" = failed ]; then
      echo "VIEWER=FAILED (viewer window did not start; nothing was run - use -NoWindow or retry)"
    else
      jq=$slots/$key.queue
      mkdir -p "$jq"
      wargs+=(-QueueDir "$jq")
      printf '%s\n' "${wargs[@]}" > "$run/job.tmp"
      mv -f "$run/job.tmp" "$jq/$(date +%Y%m%d%H%M%S)-$safe.job"
      i=0; while [ ! -e "$run/started" ] && [ $i -lt 30 ]; do sleep 0.5; i=$((i+1)); done
      if [ -e "$run/started" ]; then echo "VIEWER=OK ($VIEWER)"
      else echo "VIEWER=NOT_STARTED ($VIEWER; viewer busy with an earlier job? it will run when free - queue: $jq)"; fi
    fi
  fi
fi
echo "RUN_DIR=$run"
