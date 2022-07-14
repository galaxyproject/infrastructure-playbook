#!/bin/bash
#set -xv
set -euo pipefail

FIX_LINKS=true

REPO='singularity.galaxyproject.org'
ROOT="/cvmfs/${REPO}"
SUBSET=
FROM=
SOURCE=
SOURCE_ROOT='singularity@depot.galaxyproject.org:/srv/nginx/depot.galaxyproject.org/root/singularity/'
TAG_PREFIX=
TAG_PREFIX_ROOT='update'
MUTEX="${HOME}/.updaterepo.lock"
MUTEX_ACQUIRED=false

RSYNC_SSH_OPTS="-o ControlMaster=auto -o ControlPersist=60s -o KbdInteractiveAuthentication=no -o PreferredAuthentications=gssapi-with-mic,gssapi-keyex,hostbased,publickey -o PasswordAuthentication=no -o ConnectTimeout=10 -o ControlPath=${HOME}/makerepo-ssh-control"
RSYNC_OPTS="-e 'ssh ${RSYNC_SSH_OPTS}'"

CHANGELOG=

DRY_RUN=false
TRANSACTION_OPEN=false

umask 022

# FIXME:-s and -f are mutually exclusive
while getopts ":f:s:nri" opt; do
    case "$opt" in
        s)
            SUBSET="$OPTARG"
            TAG_PREFIX="-subset-${SUBSET}"
            ;;
        f)
            FROM="--files-from=${OPTARG} --no-relative"
            SOURCE_ROOT="singularity@depot.galaxyproject.org:/"
            TAG_PREFIX="-files-from-${OPTARG}"
            ;;
        n)
            DRY_RUN=true
            ;;
        r)
            RSYNC_OPTS=
            SOURCE_ROOT='rsync://depot.galaxyproject.org/singularity/'
            #SOURCE_ROOT='rsync://it01.pulsar.galaxyproject.eu:12000/singularity/all/'
            ;;
        i)
            TAG_PREFIX_ROOT='initial'
            ;;
        *)
            echo "usage: $0 [-s subset-prefix] [-n (dry run)] [-r (use rsyncd)] [-t sleep seconds]"
            exit 1
            ;;
    esac
done

if [ -n "$SUBSET" ]; then
    SOURCE="${SOURCE_ROOT}${SUBSET}*"
else
    SOURCE="$SOURCE_ROOT"
fi

TAG_PREFIX="${TAG_PREFIX_ROOT}${TAG_PREFIX}"

function trap_handler() {
    { set +x; } 2>/dev/null
    $TRANSACTION_OPEN && abort_transaction
    [ -n "$CHANGELOG" ] && log_exec rm -f "$CHANGELOG"
    $MUTEX_ACQUIRED && { rmdir "$MUTEX"; log_debug "Cleared $MUTEX"; }
    return 0
}
trap "trap_handler" SIGTERM SIGINT ERR EXIT


function log() {
    [ -t 0 ] && echo -e '\033[1;32m#' "$@" '\033[0m' || echo '#' "$@"
}


function log_warning() {
    [ -t 0 ] && echo -e '\033[1;33mWARNING:' "$@" '\033[0m' || echo 'WARNING:' "$@"
}


function log_error() {
    [ -t 0 ] && echo -e '\033[1;31mERROR:' "$@" '\033[0m' || echo 'ERROR:' "$@"
}


function log_debug() {
    echo "####" "$@"
}


function log_exec() {
    local rc
    set -x
    "$@"
    { rc=$?; set +x; } 2>/dev/null
}


function begin_transaction() {
    local rc
    log "Opening transaction on $REPO"
    log_exec cvmfs_server transaction "$REPO" || {
        log_warning "Opening transaction failed, attempting to abort first";
        abort_transaction;
        log_warning "Retrying transaction on $REPO";
        log_exec cvmfs_server transaction "$REPO"
    }
    TRANSACTION_OPEN=true
}


function abort_transaction() {
    log "Aborting transaction on $REPO"
    log_exec cvmfs_server abort -f "$REPO"
    TRANSACTION_OPEN=false
}


function publish_transaction() {
    local log_message="$1"
    local command_prefix=
    local tag="${TAG_PREFIX}"
    log "Publishing transaction on $REPO"
    if [ "$TAG_PREFIX_ROOT" != 'initial' ]; then
        tag="${tag}-$(date --iso-8601=seconds --utc | sed 's/+0000/Z/')"
    fi
    $DRY_RUN && command_prefix=echo
    log_exec $command_prefix cvmfs_server publish -a "$tag" -m "$log_message" "${REPO}"
    $DRY_RUN && abort_transaction
    TRANSACTION_OPEN=false
}


function detect_changes() {
    log "Checking for changes"
    output=$(log_exec rsync -dtL --out-format='%o %n' --exclude '.*' --delete --dry-run $RSYNC_OPTS $FROM "$SOURCE" "${ROOT}/all")
    if [ -n "$output" ]; then
        log "New/removed images found on depot, sync will proceed"
        return 0
    else
        log "No new/removed images found on depot, sync will be skipped"
        return 1
    fi
    
}


function mirror() {
    log "Beginning rsync"
    log_exec rsync -dtLvP --exclude='.*' --delete $RSYNC_OPTS $FROM "$SOURCE" "${ROOT}/all"
    log "Finished rsync"
}


function mirror_for_links() {
    CHANGELOG=$(mktemp -t updaterepo-XXXXXX)
    log_debug "Writing rsync output to ${CHANGELOG}"

    log "Beginning rsync"
    log_exec rsync -dtL --out-format='%o %n' --exclude='.*' --delete $RSYNC_OPTS $FROM "$SOURCE" "${ROOT}/all" | tee "$CHANGELOG"
    log "Finished rsync"
}


# TODO: make this something that can be run separate from the rsync
function fix_links() {
    local op file hash message
    local updated=0 removed=0

    while read op file; do
        [ "${file:(-1):1}" != '/' ] || continue  # should only be updated dirmtime
    	hash="${file:0:1}/${file:1:1}"
    	case $op in
          recv)
            chmod 0644 "${ROOT}/all/${file}"
            log_exec mkdir -p "${ROOT}/${hash}"
            if [ -h "${ROOT}/${hash}/${file}" ]; then
                log_warning "Clobbering existing symlink: ${ROOT}/${hash}/${file}"
                ls -l "${ROOT}/${hash}/${file}"
                log_exec ln -sf "../../all/${file}" "${ROOT}/${hash}/${file}"
            else
                log_exec ln -s "../../all/${file}" "${ROOT}/${hash}/${file}"
            fi
            log_exec touch -ch -r "${ROOT}/all/${file}" "${ROOT}/${hash}/${file}"
            log "Updated (${ROOT}/${hash}/${file} ->) ${ROOT}/all/${file}"
            ((updated++)) || true
            ;;
          del.)
            log_exec rm -f "${ROOT}/${hash}/${file}"
            log_exec rmdir "${ROOT}/${hash}" 2>/dev/null || true
            log "Removed (${ROOT}/${hash}/${file} ->) ${ROOT}/all/${file}"
            ((removed++)) || true
            ;;
          *)
            log_error "Unknown operation on ${file}: ${op}"
            exit 1
            ;;
        esac
    done < "$CHANGELOG"

    if [ $updated -gt 0 -o $removed -gt 0 ]; then
        message="$updated created or updated, $removed removed" 
        log "Publishing update: $message"
        publish_transaction "$message"
    else
        log "No changes to publish, aborting transaction"
        abort_transaction
    fi
}


function updaterepo() {
    log "Begin $(date)"
    if detect_changes; then
        begin_transaction
        if $FIX_LINKS; then
            mirror_for_links
            fix_links
        else
            mirror
        fi
    fi
    log "End $(date)"
    return 0
}


function main() {
    if mkdir "$MUTEX"; then
        MUTEX_ACQUIRED=true
        log_debug "Acquired $MUTEX"
        updaterepo
        return $?
    fi
}


main
