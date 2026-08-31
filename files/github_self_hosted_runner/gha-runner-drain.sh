#!/usr/bin/env bash
# Take a runner VM out of service without interrupting a job, then wait for it to be safely stopped. Installed at
# /opt/custom/sbin/gha-runner-drain. Run it before destroying or rebuilding a runner VM:
#
#     svcadm disable -st site/gha-runner-cycle
#     gha-runner-drain obrien-test
#
# Deregistering rather than watching-and-stopping is what makes this race-free. GitHub refuses to delete a runner
# that is executing a job, so the delete only succeeds at a moment when the runner is idle -- and once it succeeds,
# GitHub will not assign it another job. The guest notices its session is gone, run.sh returns, and gha-runner-boot.sh
# powers the VM off on its own, which is the same clean path a finished job takes.
#
# Disable the cycle service first, or it will roll the VM back and start it again while this is working.

set -uo pipefail

# SMF starts this with a minimal environment, so nothing here may depend on an interactive root's PATH. If curl
# cannot find a CA bundle -- the global zone's /etc is a ramdisk, so one installed there does not survive a platform
# upgrade -- set CURL_CA_BUNDLE in the conf to a path under /opt.
PATH=/usr/bin:/usr/sbin:/smartdc/bin:/opt/tools/bin:/opt/tools/sbin
export PATH

CONF="${GHA_RUNNER_CYCLE_CONF:-/opt/custom/etc/gha-runner-cycle.conf}"
STATE_DIR="${GHA_RUNNER_CYCLE_STATE:-/opt/custom/var/gha-runner-cycle}"
# Longer than any workflow timeout, since a drain requested during a deploy legitimately waits for it to finish.
DRAIN_TIMEOUT="${GHA_RUNNER_DRAIN_TIMEOUT:-14400}"
# How long to wait for the guest to power itself off after deregistration before stopping it from here.
POWEROFF_GRACE="${GHA_RUNNER_DRAIN_POWEROFF_GRACE:-300}"
POLL_INTERVAL="${GHA_RUNNER_DRAIN_POLL:-15}"

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [gha-runner-drain] $*"; }
err() { log "ERROR: $*" >&2; }

usage() { echo "usage: ${0##*/} <vm-alias-or-uuid>" >&2; exit 2; }

[ $# -eq 1 ] || usage
vm="$1"
case "$vm" in ''|*[!A-Za-z0-9._-]*) err "invalid VM alias or uuid: '${vm}'"; exit 2 ;; esac

# shellcheck source=/dev/null
[ -r "$CONF" ] || { err "no config at ${CONF}"; exit 1; }
. "$CONF"

# curl's compiled-in CA bundle path does not exist in the global zone, and the environment that supplies one is only
# root's interactive shell -- which SMF does not give us. Fall back to the pkgsrc bundle, which is on the persistent
# pool. The conf can override this by exporting CURL_CA_BUNDLE itself.
if [ -z "${CURL_CA_BUNDLE:-}" ]; then
    for bundle in /opt/tools/etc/openssl/certs/ca-certificates.crt /opt/local/etc/openssl/certs/ca-certificates.crt; do
        [ -r "$bundle" ] || continue
        export CURL_CA_BUNDLE="$bundle"
        break
    done
fi

: "${GITHUB_ORG:?not set in ${CONF}}"
: "${GITHUB_TOKEN_FILE:?not set in ${CONF}}"
[ -r "$GITHUB_TOKEN_FILE" ] || { err "cannot read ${GITHUB_TOKEN_FILE}"; exit 1; }

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [[ "$vm" =~ $UUID_RE ]]; then
    uuid="$vm"
else
    uuids="$(vmadm lookup alias="$vm" 2>/dev/null || true)"
    count="$(printf '%s' "$uuids" | grep -c . || true)"
    case "$count" in
        0) err "no VM with alias '${vm}'"; exit 1 ;;
        1) uuid="$uuids" ;;
        *) err "alias '${vm}' matches ${count} VMs, refusing to guess: $(printf '%s' "$uuids" | tr '\n' ' ')"; exit 1 ;;
    esac
fi

vm_state() { vmadm list -H -o state "uuid=${uuid}" 2>/dev/null; }

wait_for_stopped() {
    local deadline=$1 state
    while [ "$(date +%s)" -lt "$deadline" ]; do
        state="$(vm_state)"
        [ "$state" = stopped ] && return 0
        sleep "$POLL_INTERVAL"
    done
    return 1
}

state="$(vm_state)"
case "$state" in
    '') err "no such VM: ${vm} (${uuid})"; exit 1 ;;
    stopped) log "${vm} (${uuid}) is already stopped"; exit 0 ;;
    running) ;;
    *) err "${vm} is ${state}, not draining it"; exit 1 ;;
esac

runner_id="$(cat "${STATE_DIR}/${vm}.runner_id" 2>/dev/null || true)"
if [ -z "$runner_id" ]; then
    # Nothing registered by us, so there is no job to protect and nothing to deregister.
    log "${vm} has no recorded runner id, stopping it directly"
    vmadm stop "$uuid" || { err "could not stop ${uuid}"; exit 1; }
    wait_for_stopped "$(( $(date +%s) + POWEROFF_GRACE ))" || { err "${vm} did not stop"; exit 1; }
    log "${vm} is stopped"
    exit 0
fi

log "waiting for runner ${runner_id} on ${vm} to be idle, then deregistering it"
deadline=$(( $(date +%s) + DRAIN_TIMEOUT ))
deregistered=false
while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(vm_state)" = stopped ]; then
        log "${vm} stopped on its own while waiting"
        deregistered=true
        break
    fi

    http_code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $(cat "$GITHUB_TOKEN_FILE")" \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/${runner_id}" 2>/dev/null)" || http_code=000

    case "$http_code" in
        204) log "runner ${runner_id} deregistered"; deregistered=true; break ;;
        404) log "runner ${runner_id} is already gone"; deregistered=true; break ;;
        422) log "runner ${runner_id} is busy with a job, waiting" ;;
        *)   err "DELETE of runner ${runner_id} returned HTTP ${http_code}, retrying" ;;
    esac
    sleep "$POLL_INTERVAL"
done

if ! $deregistered; then
    err "gave up after ${DRAIN_TIMEOUT}s waiting for runner ${runner_id} to go idle"
    exit 1
fi
rm -f "${STATE_DIR}/${vm}.runner_id"

# A deregistered runner exits and the guest powers itself off. Stop it from here only if that does not happen, which
# means the guest was not running a runner in the first place.
if wait_for_stopped "$(( $(date +%s) + POWEROFF_GRACE ))"; then
    log "${vm} (${uuid}) is stopped and safe to destroy"
    exit 0
fi

log "${vm} did not power off within ${POWEROFF_GRACE}s, stopping it"
vmadm stop "$uuid" || err "could not stop ${uuid}"
if wait_for_stopped "$(( $(date +%s) + POWEROFF_GRACE ))"; then
    log "${vm} (${uuid}) is stopped and safe to destroy"
    exit 0
fi

err "${vm} is still not stopped; not forcing, investigate before destroying it"
exit 1
