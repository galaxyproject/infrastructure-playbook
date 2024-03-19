#!/bin/bash
#set -xv
set -euo pipefail

FIX_LINKS=true

REPO='singularity.galaxyproject.org'
ROOT="/cvmfs/${REPO}"
SCRATCH_ROOT="/vols/vdb/scratch"
SUBSET=
FROM=
SOURCE=
SOURCE_ROOT='singularity@depot.galaxyproject.org:/srv/nginx/depot.galaxyproject.org/root/singularity/'
TAG_PREFIX=
TAG_PREFIX_ROOT='update'
MUTEX="${HOME}/.updaterepo.lock"
MUTEX_ACQUIRED=false

UNPACK=false

RSYNC_SSH_OPTS="-o ControlMaster=auto -o ControlPersist=60s -o KbdInteractiveAuthentication=no -o PreferredAuthentications=gssapi-with-mic,gssapi-keyex,hostbased,publickey -o PasswordAuthentication=no -o ConnectTimeout=10 -o ControlPath=${HOME}/makerepo-ssh-control"
RSYNC_OPTS="-e 'ssh ${RSYNC_SSH_OPTS}'"

CHANGELOG=
SCRATCH=

DRY_RUN=false
TRANSACTION_OPEN=false

umask 022

declare -A local_times remote_times
declare -a new_images updated_images

# FIXME:-s and -f are mutually exclusive
while getopts ":f:s:nriu" opt; do
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
            ;;
        i)
            TAG_PREFIX_ROOT='initial'
            ;;
        u)
            # pulling the actual image from http when converting is much simpler
            UNPACK=true
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
    [ -n "$SCRATCH" ] && log_exec rm -rf "$SCRATCH"
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
    local r=1
    if $UNPACK; then
        local image date time local_time remote_time
        log_debug "Collecting local modification times"
        pushd "${ROOT}/all" >/dev/null
            while read image date time; do
                local_times[$image]="${date}T${time%%.*}"
            done < <(log_exec ls -F1 --color=none | grep -v '/$' | sed 's/@$//' | xargs --no-run-if-empty stat -c '%n %y')
        popd >/dev/null
        # does not handle deletion, perhaps not neccesarry
        log_debug "Collecting remote modification times"
        while read image date; do
            date_arr=(${date//-/ })
            local_time="${local_times[$image]:-none}"
            remote_time="${date_arr[0]//\//-}T${date_arr[1]}"
            if [[ $local_time == 'none' ]]; then
                log_debug "$image: new!"
                new_images+=($image)
                remote_times[$image]="$remote_time"
                r=0
            elif [[ $local_time != $remote_time ]]; then
                log_debug "$image: update; local=$local_time, remote=$remote_time"
                updated_images+=($image)
                remote_times[$image]="$remote_time"
                r=0
            fi
        done < <(log_exec rsync -tL --out-format='%f %M' --exclude '.*' --dry-run $RSYNC_OPTS $FROM "$SOURCE" /fake/path/ | grep -v '^skipping')
        # wild, even in bash 5.1, ${#foo[@]} on an empty declared array yields "unbound variable"
        #[[ ${#remote_times[@]} -eq 0 ]] || r=0
    else
        output=$(log_exec rsync -dtL --out-format='%o %n' --exclude '.*' --delete --dry-run $RSYNC_OPTS $FROM "$SOURCE" "${ROOT}/all")
        [[ -z "$output" ]] || r=0
    fi
    if [[ $r -eq 0 ]]; then
        log "New/removed images found on depot, sync will proceed"
    else
        log "No new/removed images found on depot, sync will be skipped"
    fi
    return $r
    
}


function name_hash() {
    # always returns at least 2 levels, mulled-v2 and bioconductor will return 3. the first chracter must be
    # alphanumeric, if the second is not alphanumeric then it is replaced with an underscore.
    local image="$1"
    local recurse="${2:-true}"
    if $recurse; then
        case "$image" in
            mulled-v2-*)
                echo "mulled-v2/$(name_hash "${image/mulled-v2-/}" false)"
                return
                ;;
            bioconductor-*)
                echo "bioconductor/$(name_hash "${image/bioconductor-/}" false)"
                return
                ;;
        esac
    fi
    if [[ -z $image ]] || [[ ${image:0:1} =~ [^a-zA-Z0-9] ]]; then
        log_error "invalid image name: ${image}"
        exit 1
    elif [[ -z ${image:1:1} ]] || [[ ${image:1:1} =~ [^a-zA-Z0-9] ]]; then
        echo "${image:0:1}/_"
    else
        echo "${image:0:1}/${image:1:1}"
    fi
}


function mirror_unpacked() {
    local image hash
    SCRATCH=$(mktemp -d -p $SCRATCH_ROOT -t updaterepo-scratch-XXXXXX)
    export SINGULARITY_TMPDIR="$SCRATCH"
    # also rm -rf both paths first
    log "Cleaning contents of updated images"
    for image in "${updated_images[@]}"; do
        hash="$(name_hash "$image")"
        log_exec rm -rf "${ROOT}/${hash}/${image}"
        log_exec rm "${ROOT}/all/${image}"
    done
    log "Finished cleaning contents of updated images"
    log "Converting images"
    for image in "${updated_images[@]}" "${new_images[@]}"; do
        hash="$(name_hash "$image")"
        log_exec rsync -tLvP $RSYNC_OPTS "${SOURCE}/${image}" "${SCRATCH}"
        [ -d "${ROOT}/${hash}" ] || mkdir -p "${ROOT}/${hash}"
        log_exec singularity build --sandbox "${ROOT}/${hash}/${image}/" "${SCRATCH}/${image}"
        log_exec ln -s "../${hash}/${image}" "${ROOT}/all/${image}"
        log_exec touch --no-dereference --date="${remote_times[$image]}" "${ROOT}/all/${image}"
        log_exec rm -f "${SCRATCH}/${image}"
    done
    log "Finished converting images"
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
        # does not use name_hash for backwards compatibility, but if you ever used this again it probably should
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
        #begin_transaction
        if $UNPACK; then
            mirror_unpacked
        elif $FIX_LINKS; then
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
