#!/bin/bash
# Keeps the bridge daemon running: if it ever exits (crash, or the OS killing
# a background process to reclaim resources), restart it within a few
# seconds rather than leaving the bridge silently down. Restarts are logged
# separately from the daemon's own log so a crash-restart is visible without
# digging through per-job entries.
#
# IMPORTANT if you launch this from a boot-time mechanism (a systemd unit, an
# init script, a su/sudo wrapper that starts a fresh shell): that context does
# NOT inherit your interactive shell's PATH. BRIDGE_PYTHON_PATH below MUST be
# an absolute path in that case - a bare "python3" that only resolves because
# your interactive shell's PATH happens to include it will fail with "command
# not found" on every single boot, and this loop will retry that same failure
# forever, turning one missing binary into a silent, permanent crash-loop
# instead of an obvious one-line error. See the README's third design
# constraint for the full story - this is a real, confirmed failure mode, not
# a hypothetical one.
DAEMON="${BRIDGE_DAEMON_PATH:-/opt/bridge/bridge-daemon.py}"
PYTHON="${BRIDGE_PYTHON_PATH:-python3}"
CRASHLOG="${BRIDGE_CRASHLOG_PATH:-/var/log/bridge-daemon-restarts.log}"

while true; do
  "$PYTHON" "$DAEMON"
  rc=$?
  echo "$(date -Iseconds) daemon exited rc=$rc, restarting in 3s" >> "$CRASHLOG"
  sleep 3
done
