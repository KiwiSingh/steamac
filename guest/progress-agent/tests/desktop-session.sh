#!/bin/sh
# Exercise the real agent without X11 or a running Steam client. Desktop mode
# must report readiness/focus and continue heartbeats, even on first boot.
set -eu
bin=${1:?usage: desktop-session.sh <agent>}
tmp=$(mktemp -d)
pid=
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
touch "$tmp/port"
FX_PROGRESS_PORT="$tmp/port" FX_PROGRESS_FORCE=1 GAMESCOPE_SESSION_TARGET=plasma-session.target \
    "$bin" >"$tmp/log" 2>&1 &
pid=$!
sleep 3
kill "$pid"
wait "$pid"
pid=
grep -qx 'ready' "$tmp/port"
grep -qx 'focus desktop' "$tmp/port"
grep -q '^alive ' "$tmp/port"
if grep -Eq '^stage |^focus steam|^focus game' "$tmp/port"; then
    cat "$tmp/port" >&2
    exit 1
fi
echo '[progress-agent] desktop readiness, focus and heartbeat integration passed'
