#!/usr/bin/env bash
# Run gha-runner-cycle.sh forever, one cycle at a time. Installed at /opt/custom/sbin/gha-runner-cycle-loop.sh and
# started by svc:/site/gha-runner-cycle:default.
#
# This exists because SmartOS does not deliver illumos' periodic restarter and the global zone's crontab lives on the
# ramdisk, so a cron entry would be lost at every platform upgrade -- silently, since a hypervisor that stops cycling
# looks exactly like one with nothing to do.

set -uo pipefail

CYCLE="${GHA_RUNNER_CYCLE:-/opt/custom/sbin/gha-runner-cycle.sh}"
# Seconds between cycles: environment wins, then the SMF property, then the default. Tuning it is
#   svccfg -s gha-runner-cycle setprop application/interval = 60 && svcadm refresh/restart gha-runner-cycle
INTERVAL="${GHA_RUNNER_CYCLE_INTERVAL:-}"
if [ -z "$INTERVAL" ] && [ -n "${SMF_FMRI:-}" ]; then
    INTERVAL="$(svcprop -p application/interval "$SMF_FMRI" 2>/dev/null || true)"
fi
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=120 ;; esac
LOG="${GHA_RUNNER_CYCLE_LOG:-/opt/custom/var/log/gha-runner-cycle.log}"
LOG_MAX_BYTES="${GHA_RUNNER_CYCLE_LOG_MAX_BYTES:-10485760}"
LOCK_DIR="/var/run/gha-runner-cycle.lock"

mkdir -p "$(dirname "$LOG")"

# Nothing else runs the cycle script, so a lock present at startup is a leftover from a cycle that was killed rather
# than one still running. Without this, one SIGKILL would wedge cycling until the next reboot.
rmdir "$LOCK_DIR" 2>/dev/null && echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [loop] removed stale lock" >> "$LOG"

rotate_log() {
    local size
    size="$(ls -l "$LOG" 2>/dev/null | awk '{print $5}')"
    [ -n "$size" ] || return 0
    [ "$size" -gt "$LOG_MAX_BYTES" ] || return 0
    mv -f "$LOG" "${LOG}.0"
}

trap 'exit 0' TERM INT

while :; do
    rotate_log
    "$CYCLE" >> "$LOG" 2>&1
    sleep "$INTERVAL" &
    wait $!
done
