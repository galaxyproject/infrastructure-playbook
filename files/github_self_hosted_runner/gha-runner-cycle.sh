#!/usr/bin/env bash
# Cycle GitHub Actions runner VMs. Run from cron in the SmartOS global zone.
#
# A runner VM takes exactly one job and powers itself off. This script notices the stopped VM, rolls its disk back to
# a clean snapshot, registers a fresh ephemeral just-in-time runner with GitHub, hands the JIT config to the VM
# through its metadata, and boots it. The VM therefore starts every job from a known-good image and holds no
# credential capable of registering a runner: this script chooses the runner group, so a compromised test VM cannot
# join the publish group.

set -uo pipefail

# SMF starts this with a minimal environment, so nothing here may depend on an interactive root's PATH. If curl
# cannot find a CA bundle -- the global zone's /etc is a ramdisk, so one installed there does not survive a platform
# upgrade -- set CURL_CA_BUNDLE in the conf to a path under /opt.
PATH=/usr/bin:/usr/sbin:/smartdc/bin:/opt/tools/bin:/opt/tools/sbin
export PATH

CONF="${GHA_RUNNER_CYCLE_CONF:-/opt/custom/etc/gha-runner-cycle.conf}"
# On the persistent pool, not /var: the global zone root is a ramdisk, and state lost across a platform reboot
# means a running VM's runner id is gone and its health check silently stops happening.
STATE_DIR="${GHA_RUNNER_CYCLE_STATE:-/opt/custom/var/gha-runner-cycle}"
LOCK_DIR="${GHA_RUNNER_CYCLE_LOCK:-/var/run/gha-runner-cycle.lock}"

# Consecutive failed boots before this script gives up and leaves the VM stopped for a human.
MAX_FAILED_BOOTS=3
# A runner busy with one job for longer than this is wedged: the workflows cap out at 180 minutes, so GitHub will
# already have timed the job out and the runner should have reported and exited.
MAX_JOB_SECONDS=$((4 * 60 * 60))
# How long a VM may be up without its runner being online before it is considered wedged. Covers boot, and the
# seconds between a finished job deregistering its ephemeral runner and the guest completing its poweroff.
UNUSABLE_GRACE=600

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [gha-runner-cycle] $*"; }
err() { log "ERROR: $*" >&2; }

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
: "${RUNNERS:?not set in ${CONF}}"

[ -r "$GITHUB_TOKEN_FILE" ] || { err "cannot read ${GITHUB_TOKEN_FILE}"; exit 1; }

mkdir "$LOCK_DIR" 2>/dev/null || { log "another cycle is running, skipping"; exit 0; }
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
# Release the lock on a service stop too; the EXIT trap runs when these handlers exit.
trap 'exit 143' TERM INT
mkdir -p "$STATE_DIR"

# The conf names VMs by alias, because the UUID changes whenever the VM is rebuilt and the alias does not. A UUID is
# still accepted, for a conf that predates this or for a host with no useful alias.
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

resolve_uuid() {
    local vm="$1" uuids count
    if [[ "$vm" =~ $UUID_RE ]]; then
        printf '%s' "$vm"
        return 0
    fi
    uuids="$(vmadm lookup alias="$vm" 2>/dev/null || true)"
    count="$(printf '%s' "$uuids" | grep -c . || true)"
    case "$count" in
        0) err "no VM with alias '${vm}'"; return 1 ;;
        1) printf '%s' "$uuids"; return 0 ;;
        *) err "alias '${vm}' matches ${count} VMs, refusing to guess: $(printf '%s' "$uuids" | tr '\n' ' ')"; return 1 ;;
    esac
}

github_api_get() {
    local path="$1" response http_code
    response="$(curl -sS -w '\n%{http_code}' \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $(cat "$GITHUB_TOKEN_FILE")" \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com${path}")" || return 1
    http_code="$(printf '%s\n' "$response" | tail -1)"
    [ "$http_code" = 200 ] || return 1
    printf '%s\n' "$response" | sed '$d'
}

# 204 is success and 404 means it is already gone, which is the normal case: an ephemeral runner that completed a job
# deregisters itself.
github_api_delete() {
    local path="$1" http_code
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $(cat "$GITHUB_TOKEN_FILE")" \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com${path}")" || return 1
    case "$http_code" in
        204|404) return 0 ;;
        *) err "DELETE ${path} returned HTTP ${http_code}"; return 1 ;;
    esac
}

# A booted runner sits idle until a job arrives, which may be days away, so VM uptime says nothing about health. Ask
# GitHub instead. An idle runner is fine indefinitely; one busy past any possible job length, or not online at all
# while its VM is up, is wedged and will quietly swallow jobs until GitHub cancels them 24 hours later.
check_running_vm() {
    local key="$1" uuid="$2"
    local runner_id now runner status busy since

    runner_id="$(cat "${STATE_DIR}/${key}.runner_id" 2>/dev/null || true)"
    [ -n "$runner_id" ] || { log "${uuid} has no recorded runner id, skipping health check"; return 0; }

    now="$(date +%s)"
    runner="$(github_api_get "/orgs/${GITHUB_ORG}/actions/runners/${runner_id}" || true)"
    status="$(printf '%s' "$runner" | json status 2>/dev/null || true)"
    busy="$(printf '%s' "$runner" | json busy 2>/dev/null || true)"

    if [ "$status" != online ]; then
        since="$(cat "${STATE_DIR}/${key}.unusable_since" 2>/dev/null || true)"
        if [ -z "$since" ]; then
            since="$now"
            echo "$since" > "${STATE_DIR}/${key}.unusable_since"
        fi
        if [ $((now - since)) -gt "$UNUSABLE_GRACE" ]; then
            err "${uuid} is up but its runner has not been online for ${UNUSABLE_GRACE}s, forcing it down"
            vmadm stop "$uuid" -F || err "could not stop ${uuid}"
        fi
        return 0
    fi
    rm -f "${STATE_DIR}/${key}.unusable_since"

    if [ "$busy" != true ]; then
        # Idle is the healthy resting state, however long it lasts.
        rm -f "${STATE_DIR}/${key}.busy_since"
        return 0
    fi

    since="$(cat "${STATE_DIR}/${key}.busy_since" 2>/dev/null || true)"
    if [ -z "$since" ]; then
        since="$now"
        echo "$since" > "${STATE_DIR}/${key}.busy_since"
    fi
    if [ $((now - since)) -gt "$MAX_JOB_SECONDS" ]; then
        err "${uuid} has been busy with one job for over ${MAX_JOB_SECONDS}s, past every workflow timeout, forcing it down"
        vmadm stop "$uuid" -F || err "could not stop ${uuid}"
    fi
}

# Ask GitHub for a single-use registration for one ephemeral runner. Echoes the encoded JIT config, and records the
# runner id so check_running_vm can ask after its health later.
#
# The request body is assembled directly rather than with json(1): the version in the SmartOS global zone is too old
# for `-e` to build an object safely, and jq would not survive a platform upgrade. GitHub restricts runner names and
# labels to alphanumerics, '-', '_' and '.', so the values cannot contain anything JSON would need escaped -- but they
# come from a config file, so check that rather than trust it.
generate_jitconfig() {
    local name="$1" group_id="$2" labels="$3" key="$4"
    local labels_json body response http_code

    case "$name" in ''|*[!A-Za-z0-9._-]*) err "invalid runner name: '${name}'"; return 1 ;; esac
    case "$labels" in ''|*[!A-Za-z0-9._,-]*) err "invalid runner labels: '${labels}'"; return 1 ;; esac
    case "$group_id" in ''|*[!0-9]*) err "invalid runner_group_id: '${group_id}'"; return 1 ;; esac

    labels_json="$(
        IFS=,
        out=''
        for label in $labels; do out="${out:+${out},}\"${label}\""; done
        printf '%s' "$out"
    )"

    body="$(printf '{"name":"%s","runner_group_id":%s,"labels":[%s],"work_folder":"_work"}' \
        "$name" "$group_id" "$labels_json")"

    response="$(curl -sS -w '\n%{http_code}' -X POST \
        -H 'Accept: application/vnd.github+json' \
        -H "Authorization: Bearer $(cat "$GITHUB_TOKEN_FILE")" \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/generate-jitconfig" \
        -d "$body")" || { err "generate-jitconfig request failed"; return 1; }

    http_code="$(printf '%s\n' "$response" | tail -1)"
    response="$(printf '%s\n' "$response" | sed '$d')"
    [ "$http_code" = 201 ] || { err "generate-jitconfig returned HTTP ${http_code}: ${response}"; return 1; }

    printf '%s' "$response" | json runner.id > "${STATE_DIR}/${key}.runner_id"
    printf '%s' "$response" | json encoded_jit_config
}

# Consecutive-failed-boot counter, so a VM that cannot get through boot does not spin against the GitHub API.
failed_boots() { cat "${STATE_DIR}/${1}.failed_boots" 2>/dev/null || echo 0; }
set_failed_boots() { echo "$2" > "${STATE_DIR}/${1}.failed_boots"; }
boot_epoch() { cat "${STATE_DIR}/${1}.boot_epoch" 2>/dev/null || echo 0; }

cycle_vm() {
    local key="$1" uuid="$2" group_id="$3" labels="$4" name_prefix="$5" snapshot="$6"
    local dataset jitconfig exit_code error count metadata stale_runner_id

    log "${key} (${uuid}) is stopped, cycling it"

    count="$(failed_boots "$key")"
    if [ "$count" -ge "$MAX_FAILED_BOOTS" ]; then
        err "${uuid} has failed ${count} consecutive boots, leaving it stopped. Investigate, then clear ${STATE_DIR}/${key}.failed_boots"
        return 1
    fi

    # The guest records run.sh's exit status here before powering off; the disk itself is about to be discarded. Its
    # presence and value, not how long the VM was up, is what says whether a boot worked: a run that takes one quick
    # job is indistinguishable by duration from one that never got the runner started.
    metadata="$(vmadm get "$uuid" 2>/dev/null || true)"
    exit_code="$(printf '%s' "$metadata" | json customer_metadata.runner-exit-code)"
    error="$(printf '%s' "$metadata" | json customer_metadata.runner-error)"
    if [ "$(boot_epoch "$key")" -gt 0 ]; then
        if [ -z "$exit_code" ]; then
            count=$((count + 1))
            set_failed_boots "$key" "$count"
            err "${uuid} powered off without recording a runner exit code, so its last boot did not finish (${count}/${MAX_FAILED_BOOTS})"
        elif [ "$exit_code" != 0 ]; then
            count=$((count + 1))
            set_failed_boots "$key" "$count"
            err "${uuid} last runner exited ${exit_code} (${count}/${MAX_FAILED_BOOTS})${error:+: ${error}}"
        else
            log "${key} last runner exited 0"
            set_failed_boots "$key" 0
        fi
    fi

    dataset="$(vmadm get "$uuid" 2>/dev/null | json disks.0.zfs_filesystem)"
    [ -n "$dataset" ] || { err "cannot determine disk dataset for ${uuid}"; return 1; }

    zfs list -H -o name -t snapshot "${dataset}@${snapshot}" >/dev/null 2>&1 \
        || { err "snapshot ${dataset}@${snapshot} does not exist"; return 1; }

    # Never start a VM whose rollback failed: that is how a host quietly reverts to being persistent, which is the one
    # property this whole arrangement exists to prevent.
    zfs rollback -r "${dataset}@${snapshot}" \
        || { err "rollback of ${dataset}@${snapshot} failed, leaving ${uuid} stopped"; return 1; }
    log "${uuid} rolled back to ${dataset}@${snapshot}"

    # A boot that never took a job leaves its registration behind, because only completing a job makes an ephemeral
    # runner deregister itself. Reap it before minting a replacement, or every failed boot adds an offline entry to
    # the group that nothing will clear for 14 days.
    stale_runner_id="$(cat "${STATE_DIR}/${key}.runner_id" 2>/dev/null || true)"
    if [ -n "$stale_runner_id" ]; then
        github_api_delete "/orgs/${GITHUB_ORG}/actions/runners/${stale_runner_id}" \
            || err "could not remove previous runner ${stale_runner_id} for ${uuid}"
    fi

    jitconfig="$(generate_jitconfig "${name_prefix}-$(date +%s)" "$group_id" "$labels" "$key")" || return 1
    case "$jitconfig" in
        '') err "empty JIT config for ${uuid}"; return 1 ;;
        *[!A-Za-z0-9+/=]*) err "JIT config for ${uuid} is not the expected base64"; return 1 ;;
    esac

    printf '{"set_customer_metadata":{"jitconfig":"%s"},"remove_customer_metadata":["runner-exit-code","runner-error"]}' "$jitconfig" \
        | vmadm update "$uuid" \
        || { err "could not set metadata on ${uuid}"; return 1; }

    vmadm start "$uuid" || { err "could not start ${uuid}"; return 1; }
    date +%s > "${STATE_DIR}/${key}.boot_epoch"
    rm -f "${STATE_DIR}/${key}.busy_since" "${STATE_DIR}/${key}.unusable_since"
    log "${uuid} started with a fresh ephemeral runner in group ${group_id}"
}

for entry in $RUNNERS; do
    IFS=: read -r vm group_id labels name_prefix snapshot <<< "$entry"
    [ -n "${snapshot:-}" ] || snapshot=golden

    # State files are named for this, so it has to be filesystem-safe.
    case "$vm" in ''|*[!A-Za-z0-9._-]*) err "invalid VM alias or uuid: '${vm}'"; continue ;; esac
    key="$vm"

    uuid="$(resolve_uuid "$vm")" || continue

    # A rebuilt VM keeps its alias but gets a new UUID. All of the recorded state describes a machine that no longer
    # exists, so reap the old registration now rather than carrying it: left in place it would be health-checked
    # against the new VM, come back "not online", and start the grace timer toward force-stopping it.
    prev_uuid="$(cat "${STATE_DIR}/${key}.uuid" 2>/dev/null || true)"
    if [ -n "$prev_uuid" ] && [ "$prev_uuid" != "$uuid" ]; then
        log "${key} is now ${uuid}, was ${prev_uuid}; discarding the old VM's state"
        stale_runner_id="$(cat "${STATE_DIR}/${key}.runner_id" 2>/dev/null || true)"
        if [ -n "$stale_runner_id" ]; then
            github_api_delete "/orgs/${GITHUB_ORG}/actions/runners/${stale_runner_id}" \
                || err "could not remove runner ${stale_runner_id} left behind by ${prev_uuid}"
        fi
        rm -f "${STATE_DIR}/${key}.failed_boots" "${STATE_DIR}/${key}.boot_epoch" \
              "${STATE_DIR}/${key}.busy_since" "${STATE_DIR}/${key}.unusable_since" \
              "${STATE_DIR}/${key}.runner_id"
    fi
    printf '%s' "$uuid" > "${STATE_DIR}/${key}.uuid"

    state="$(vmadm list -H -o state "uuid=${uuid}" 2>/dev/null)"
    case "$state" in
        stopped)
            cycle_vm "$key" "$uuid" "$group_id" "$labels" "$name_prefix" "$snapshot"
            ;;
        running)
            check_running_vm "$key" "$uuid"
            ;;
        '')
            err "no such VM: ${key} (${uuid})"
            ;;
        *)
            log "${key} is ${state}, leaving it alone"
            ;;
    esac
done
