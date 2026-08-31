#!/usr/bin/env bash
# Runner job-started hook: verify the host is clean before a job runs, and on a persistent runner, make it so.
#
# The runner hosts are cycled between jobs: the VM powers off after one job and the hypervisor rolls its disk back to
# a clean snapshot before booting it again. When that is in effect, set RUNNER_EPHEMERAL_HOST=true and leftover state
# means the rollback did not happen. Failing the job is the right response, because the alternative is running it on a
# host still carrying whatever the previous job left behind.
#
# Without that flag the hook cleans up instead. A cancelled or timed-out Actions job is SIGKILLed, so the trap handler
# in .ci/github-actions.sh never runs and its CVMFS/fuse-overlayfs mounts survive into the next job, which then fails
# in mount_overlay.
#
# Install on the runner by pointing ACTIONS_RUNNER_HOOK_JOB_STARTED at a copy of this script; see
# docs/self-hosted-runner.md. It is deliberately a hook rather than a workflow step so that it also protects runs of
# workflows that know nothing about it.

set -uo pipefail

: ${SCRATCH_ROOT:=/data/actions-runner/scratch}
: ${RUNNER_EPHEMERAL_HOST:=false}

DOCKER_RUN_LABEL='org.galaxyproject.usegalaxy-tools.runner-managed=true'

log() {
    echo "[runner-job-started] $*"
}

# Detached containers survive if the job is forcibly terminated.
containers=()
if command -v docker >/dev/null 2>&1; then
    while read -r container_id; do
        [ -n "$container_id" ] && containers+=("$container_id")
    done < <(docker ps -aq --filter "label=${DOCKER_RUN_LABEL}" 2>/dev/null)
fi

# Deepest-first, so the overlayfs mount is unmounted before the CVMFS lower mount it is stacked on
mounts=()
while read -r mountpoint; do
    case "$mountpoint" in
        "${SCRATCH_ROOT}"/*) mounts+=("$mountpoint") ;;
    esac
done < <(findmnt -rno TARGET 2>/dev/null | sort -r)

run_dirs=()
for run_dir in "$SCRATCH_ROOT"/*; do
    [ -d "$run_dir" ] && run_dirs+=("$run_dir")
done

if [ "${#containers[@]}" -eq 0 ] && [ "${#mounts[@]}" -eq 0 ] && [ "${#run_dirs[@]}" -eq 0 ]; then
    log "host is clean"
    exit 0
fi

for container_id in "${containers[@]}"; do log "stale container: ${container_id}"; done
for mountpoint in "${mounts[@]}"; do log "stale mount: ${mountpoint}"; done
for run_dir in "${run_dirs[@]}"; do log "stale run dir: ${run_dir}"; done

if [ "$RUNNER_EPHEMERAL_HOST" = true ]; then
    log "ERROR: this host should have been rolled back to a clean snapshot before this job, but was not."
    log "ERROR: refusing to run. Check the hypervisor's runner cycle before restarting the job."
    exit 1
fi

for container_id in "${containers[@]}"; do
    log "Removing stale container: ${container_id}"
    docker rm -f "$container_id" || log "WARNING: could not remove container ${container_id}"
done

for mountpoint in "${mounts[@]}"; do
    log "Unmounting stale mount: ${mountpoint}"
    fusermount -u "$mountpoint" \
        || fusermount -u -z "$mountpoint" \
        || log "WARNING: could not unmount ${mountpoint}"
done

# Anything still mounted is left alone: a subsequent job gets a fresh $GITHUB_RUN_ID and so its own run dir, and the
# mount should be reapable on a later pass. Completed-job logs have already been uploaded, and cancelled jobs must not
# leave an overlay upper/work directory that a re-run could reuse.
for run_dir in "${run_dirs[@]}"; do
    if findmnt -rno TARGET 2>/dev/null | grep -q "^${run_dir}\(/\|$\)"; then
        log "Leaving ${run_dir}, still has a mount under it"
        continue
    fi
    log "Removing stale run dir: ${run_dir}"
    rm -rf "$run_dir" || log "WARNING: could not remove ${run_dir}"
done

exit 0
