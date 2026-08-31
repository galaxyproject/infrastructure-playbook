#!/usr/bin/env bash
# Guest boot script: claim this boot's just-in-time runner registration, run exactly one job, then power off so the
# hypervisor can roll the disk back. Installed at /usr/local/sbin/gha-runner-boot.sh and started by
# gha-runner.service.
#
# Everything this script learns has to reach the hypervisor through metadata, because the disk is rolled back before
# anyone can read a log off it and the journal is volatile besides.

set -uo pipefail

RUNNER_DIR="${RUNNER_DIR:-/data/build/actions-runner}"
RUNNER_USER="${RUNNER_USER:-build}"
RUNNER_HOME="${RUNNER_HOME:-/data/build}"
JOB_STARTED_HOOK="${JOB_STARTED_HOOK:-/data/actions-runner-hooks/usegalaxy-tools-job-started.sh}"
# Root-only, on tmpfs: the runner's output can name the repository and workflow, and this is written before the
# rollback that would otherwise clean it up.
RUNNER_LOG=/run/gha-runner-boot.log
# How much of the runner's output to hand back through metadata on failure.
ERROR_TAIL_BYTES=1500

log() { echo "[gha-runner-boot] $*"; }

# Powering off is the only correct ending: the hypervisor cycles on a stopped VM, and its backoff is what stops a VM
# that cannot boot from spinning against the GitHub API. Set the runner-debug metadata key to keep a broken guest up
# long enough to log into.
finish() {
    local rc="$1" msg="${2:-}"

    if [ -n "$msg" ]; then
        log "$msg"
        /usr/sbin/mdata-put runner-error "$msg" || log "WARNING: could not record error"
    fi
    /usr/sbin/mdata-put runner-exit-code "$rc" || log "WARNING: could not record exit code"

    if [ -n "$(/usr/sbin/mdata-get runner-debug 2>/dev/null)" ]; then
        log "runner-debug is set, staying up instead of powering off"
        exit "$rc"
    fi
    systemctl poweroff
}

# Fail on the specific thing that is wrong rather than letting the shell report a generic 127 from further down.
[ -d "$RUNNER_DIR" ] || finish 65 "runner directory ${RUNNER_DIR} does not exist"
[ -x "${RUNNER_DIR}/run.sh" ] || finish 65 "no executable ${RUNNER_DIR}/run.sh"
id "$RUNNER_USER" >/dev/null 2>&1 || finish 66 "no such user: ${RUNNER_USER}"
command -v runuser >/dev/null 2>&1 || finish 67 "runuser is not on root's PATH"
# The runner fails a job outright if the hook it is told to run does not exist, which costs a job and reports as an
# opaque "Set up runner" failure. Refuse the boot instead.
[ -x "$JOB_STARTED_HOOK" ] || finish 68 "no executable job-started hook at ${JOB_STARTED_HOOK}"

jitconfig="$(/usr/sbin/mdata-get jitconfig 2>/dev/null)" || jitconfig=''
if [ -z "$jitconfig" ]; then
    finish 64 "no jitconfig in metadata"
fi

# Consume the registration before any job code exists. The runner user reaches root through the docker group, so
# leaving it in metadata would leave it readable for the life of the job.
/usr/sbin/mdata-delete jitconfig || log "WARNING: could not delete jitconfig from metadata"

# Set here rather than in the runner's .env so this holds however the runner is invoked.
export SCRATCH_ROOT=/data/actions-runner/scratch
export CVMFS_CACHE_ROOT=/data/actions-runner/cvmfs-cache
export ACTIONS_RUNNER_HOOK_JOB_STARTED="$JOB_STARTED_HOOK"
export RUNNER_EPHEMERAL_HOST=true
# Report a runner GitHub refuses to admit as exit 7 rather than 0, so a runner baked too old to be accepted
# shows up in runner-exit-code instead of cycling forever looking healthy.
export ACTIONS_RUNNER_RETURN_VERSION_DEPRECATED_EXIT_CODE=1

log "starting ephemeral runner"
umask 077
runuser -u "$RUNNER_USER" -- env \
    HOME="$RUNNER_HOME" \
    SCRATCH_ROOT="$SCRATCH_ROOT" \
    CVMFS_CACHE_ROOT="$CVMFS_CACHE_ROOT" \
    ACTIONS_RUNNER_HOOK_JOB_STARTED="$ACTIONS_RUNNER_HOOK_JOB_STARTED" \
    RUNNER_EPHEMERAL_HOST="$RUNNER_EPHEMERAL_HOST" \
    ACTIONS_RUNNER_RETURN_VERSION_DEPRECATED_EXIT_CODE="$ACTIONS_RUNNER_RETURN_VERSION_DEPRECATED_EXIT_CODE" \
    "${RUNNER_DIR}/run.sh" --jitconfig "$jitconfig" 2>&1 | tee "$RUNNER_LOG"
rc="${PIPESTATUS[0]}"

if [ "$rc" != 0 ]; then
    # Flattened to one line: this ends up in a metadata value and then in a single hypervisor log line.
    finish "$rc" "runner exited ${rc}: $(tail -c "$ERROR_TAIL_BYTES" "$RUNNER_LOG" | tr -d '\000' | tr '\n' ';')"
fi
finish "$rc"
