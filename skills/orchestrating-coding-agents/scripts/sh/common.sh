# Shared helpers, sourced by the bash scripts (macOS/Linux). Compatible with bash 3.2 (the macOS default).
die() { echo "$*" >&2; exit 1; }

# Per-user runs dir, never the shared /tmp (another local user could plant jobs there):
# $XDG_RUNTIME_DIR, else $TMPDIR (private on macOS; /tmp and /var/tmp ignored), else ~/.cache. Fails closed.
runs_root() {
  local t tmp r
  tmp=${TMPDIR:-}; tmp=${tmp%/}
  case "$tmp" in /tmp|/var/tmp) tmp= ;; esac
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then t=$XDG_RUNTIME_DIR; elif [ -n "$tmp" ]; then t=$tmp; else t=$HOME/.cache; fi
  t=${t%/}; r=$t/agent-runs
  if [ ! -e "$r" ] && [ ! -L "$r" ]; then
    mkdir -p "$t" && mkdir -m 700 "$r" || die "cannot create $r"
  fi
  if ! { test -d "$r" && ! test -L "$r" && test -O "$r" && chmod 700 "$r" && test -n "$(find "$r" -maxdepth 0 -perm 700)"; }; then
    die "$r is not a private directory owned by you (symlink, other owner or bad mode); refusing to use it. Remove it or set XDG_RUNTIME_DIR."
  fi
  printf '%s' "$r"
}

resolve_agy() {
  local c
  for c in "${AGY_PATH:-}" "$HOME/.local/bin/agy"; do
    if [ -n "$c" ] && [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  command -v agy 2>/dev/null
  return 0
}

# Kill a process and everything below it.
stop_tree() {
  local p=$1 k
  for k in $(pgrep -P "$p" 2>/dev/null); do stop_tree "$k"; done
  kill -9 "$p" 2>/dev/null
  return 0
}

# true when some process command line contains both fragments
cmdline_running() {
  ps -axo args= 2>/dev/null | grep -F -- "$1" | grep -F -- "$2" >/dev/null
}

# nohup + background: the child survives this script and never holds the caller's pipe open
start_detached() {
  local o=$1 e=$2
  shift 2
  nohup "$@" >"$o" 2>"$e" </dev/null &
  LAST_PID=$!
  disown 2>/dev/null
  return 0
}

# pid plus all its descendants
tree_pids() {
  local p=$1 k
  echo "$p"
  for k in $(pgrep -P "$p" 2>/dev/null); do tree_pids "$k"; done
}

# true when every process listening on the loopback port belongs to pid's tree (lsof, else ss; skipped if neither exists)
listener_owned() {
  local pid=$1 port=$2 lp mine x
  if command -v lsof >/dev/null 2>&1; then lp=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)
  elif command -v ss >/dev/null 2>&1; then lp=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2)
  else return 0; fi
  [ -n "$lp" ] || return 1
  mine=" $(tree_pids "$pid" | tr '\n' ' ') "
  for x in $lp; do
    case "$mine" in *" $x "*) ;; *) return 1 ;; esac
  done
  return 0
}

# a free random port on loopback (20000-59999)
pick_port() { perl -MIO::Socket::INET -e 'for (1..50) { my $p = 20000 + int(rand(40000)); my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => $p, ReuseAddr => 1) or next; print $p; exit }'; }
urlenc() { perl -e 'print join "", map { /[A-Za-z0-9_.~-]/ ? $_ : sprintf("%%%02X", ord) } split //, $ARGV[0]' "$1"; }
json_get() { JSON_KEY="$1" perl -MJSON::PP -0777 -ne 'my $j = eval { decode_json($_) } or exit; my $v = $j; for my $k (split /\./, $ENV{JSON_KEY}) { $v = ref $v eq "HASH" ? $v->{$k} : undef } print $v if defined $v'; }
sha6() { if command -v shasum >/dev/null 2>&1; then shasum -a 1 | cut -c1-6; else sha1sum | cut -c1-6; fi; }
