#!/usr/bin/env bash
##
## This file is maintained by Ansible - CHANGES WILL BE OVERWRITTEN
##
set -e
#set -xv

MUTEX='/var/run/zfs-prunesnaps.pid'

base=$(basename $0)
USAGE1="usage:
  $base [-nv] [-r hours] [-d days] [-w weeks] [-m months] [-y years] dataset...
  $base -h"
USAGE="$USAGE1

Prune ZFS snapshots

Options:
    -h      print this help message and exit
    -n      no changes (dry run)
    -l      log to syslog
    -v      print keeps/prunes to stdout (-vv for debug output)
    -r <n>  number of hours to keep hourly snapshots for
    -d <n>  number of days to keep daily snapshots for
    -w <n>  number of weeks to keep weekly snapshots for
    -m <n>  number of months to keep monthly snapshots for
    -y <n>  number of years to keep yearly snapshots for

The time period options (-r, -d, -w, -m, -y) are processed in order from shortest period to longest.

The time periods are additive, for example, '-r 6 -d 4 -w 2' will keep about 18.5 days worth of snapshots.

Any snapshot older than those matched by the period options will be pruned, this behavior can be changed by setting a period option to '-1', which means \"keep snapshots at this period forever\".

Prune time is calculated from the time of the newest snapshot for the given dataset, so if you stop snapshotting, $base will never remove more snapshots when run with the same options.

Examples:
  Keep 48 hours worth of hourly snapshots, 14 days worth of daily snapshots, 8 weeks worth of weekly snapshots, and monthly snapshots forever, of tank/important:
  # $base -r 48 -d 14 -w 8 -m -1 tank/important

  Keep 30 days worth of daily snapshots, 26 weeks worth of weekly snapshots, and delete all older snapshots of tank/stuff:
  # $base -d 30 -w 26 tank/stuff

  Delete all snapshots of tank/scratch and tank/scratch2:
  # $base -r0 tank/scratch tank/scratch2"

: ${PRUNESNAPSRC:="/etc/zfs-prunesnaps/zfs-prunesnaps.conf"}

DATASETS=()
DRYRUN=0
LOGGER=0
FACILITY=daemon
VERBOSE=0
FLAGS=(r d w m y)
typeset -A PRUNE SECONDS
for f in ${FLAGS[@]}; do
    PRUNE[$f]=0
done
SECONDS[r]=$(( 60 * 60 ))
SECONDS[d]=$(( 60 * 60 * 24 ))
SECONDS[w]=$(( 60 * 60 * 24 * 7 ))
SECONDS[m]=$(( 60 * 60 * 24 * 31 ))  # monthish
SECONDS[y]=$(( 60 * 60 * 24 * 365 ))

ZFS_GET='check_output zfs get -H -o name name "$dataset"'
ZFS_LIST='check_output zfs list -Hp -t snapshot -o name,creation -S creation'
ZFS_DESTROY='check_output zfs destroy $snap'
# useful for testing
#ZFS_GET='true'
#ZFS_LIST='cat snaps'
#ZFS_DESTROY='cp snaps _snaps; grep -v $snap _snaps > snaps'

# always work in UTC, affects the output of zfs commands
export TZ=UTC


function get_mutex() {
    if [ -f "$MUTEX" ]; then
        pid="$(cat $MUTEX)"
        if ! ps -p $pid >/dev/null; then
            log warning "removing stale pid file $MUTEX"
        else
            log err "another process is still running: $pid"
            exit 1
        fi
    fi
    echo $$ > $MUTEX
}

function output() {
    level=$1; shift
    if [ $LOGGER -eq 0 ]; then
        echo "$*"
    else
        logger -i -p${FACILITY}.${level} -t$base -- "$*"
    fi
}

function log() {
    level=$1; shift
    if [ $LOGGER -eq 0 ]; then
        echo "$(echo $level: | tr a-z A-Z) $*" >&2
    else
        output $level "$@"
    fi
}

function checkarr() {
    # requires bash >= 4.3
    typeset -n t="$1"
    [ "${#t[@]}" -gt 0 ] || { log err "required array variable \$$1 is empty"; return 1; }
}

function isintorempty() {
    # if the value referenced by the var *name* passed in $1 is:
    #   an integer: return 0
    #   empty: return 1
    #   not an integer: return 2
    [ -n "${!1}" ] || return 1
    [ "${!1}" -eq "${!1}" ] 2>/dev/null || { rc=$?; [ $rc -ne 2 ] || { log err "invalid non-integer value for ${2:-"\$$1"}: ${!1}"; }; return $rc; }
    return 0
}

function isint() {
    if isintorempty $1 $2; then
        return 0
    else
        [ $? -ne 1 ] || log err "${2:-"\$$1"} value cannot be empty string"
        return 1
    fi
}

function check_output() {
    [ $VERBOSE -ge 2 ] && set -x
    "$@" || { exit $?; } 2>/dev/null
    { set +x; } 2>/dev/null  # not necessary if we're always called in a subshell
}

function readrc() {
    [ ! -f "$PRUNESNAPSRC" ] || . "${PRUNESNAPSRC}"
}

function setopts() {
    local exit=
    while getopts ':hnlvr:d:w:m:y:' opt; do
        case $opt in
            h)
                echo "$USAGE" | fmt -$(tput cols) -st
                exit 0
                ;;
            n)
                DRYRUN=1
                ;;
            l)
                LOGGER=1
                ;;
            v)
                VERBOSE=$((VERBOSE + 1))
                ;;
            r|d|w|m|y)
                PRUNE[$opt]="$OPTARG"
                isint OPTARG "-$opt" || exit=2
                ;;
            :)
                echo "ERROR: missing option argument for -$OPTARG" >&2
                exit=2
                ;;
            \?)
                echo "ERROR: invalid option: -$OPTARG" >&2
                exit=2
                ;;
        esac
    done
    shift "$((OPTIND - 1))"
    _DATASETS=("$@")
    [ -z "$_DATASETS" ] || DATASETS=("${_DATASETS[@]}")
    checkarr DATASETS || exit=2
    [ -z "$exit" ] || { echo "$USAGE1"; exit $exit; } >&2
}

function validate_opts() {
    # turn everything in to seconds
    for period in ${FLAGS[@]}; do
        PRUNE[$period]=$((PRUNE[$period] * ${SECONDS[$period]}))
    done
    for dataset in $DATASETS; do
        for period in ${FLAGS[@]}; do
            [ -z "${PRUNE[${dataset}-${period}]}" ] || PRUNE[${dataset}-${period}]=$((PRUNE[${dataset}-${period}] * ${SECONDS[$period]}))
        done
    done
}

function validate_datasets() {
    # ensure datasets exist
    local exit=
    for dataset in "${DATASETS[@]}"; do
        # subshell so we can check all datasets before exiting
        (eval $ZFS_GET >/dev/null) || exit=2
    done
    [ -z "$exit" ] || { log err "invalid dataset name(s)"; exit $exit; }
}

function setsnaps() {
    # collect snapshot list
    local snap creation name snapname varname
    log debug "collecting snapshot list"
    while read snap creation || { [ "$snap" -eq 0 ] && break || exit $snap; }; do
        #echo -n 
        # read exits 1 on the unterminated single field printf
        name=${snap%@*}
        snapname=${snap#*@}
        varname=${name//[\/-]/_}
        typeset -n snaps="SNAPS_${varname}"
        typeset -n times="TIMES_${varname}"
        [ ${#snaps[@]} -ne 0 ] || snaps=()
        [ ${#times[@]} -ne 0 ] || times=()
        snaps+=("$snapname")
        times+=("$creation")
        # < <((check_output ...); printf $?) doesn't work because of set -e
    done < <(($ZFS_LIST) && printf 0 || printf $?)
    log debug "found ${#snaps[@]} snapshots"
}


function calculate_prune() {
    # determine what should be pruned
    local dataset="$1"
    local varname=${dataset//[\/-]/_}
    local i=0
    typeset -n snaps="SNAPS_${varname}"
    typeset -n times="TIMES_${varname}"
    typeset -n ops="OPS_${varname}"
    typeset -n prunect="PRUNECT_${varname}"
    local offset="${times[0]}"
    local last=$((offset + 60 * 60))
    local prune=
    prunect=0
    ops=()
    for period in ${FLAGS[@]}; do
        last=$((last / SECONDS[$period]))
        for (( ; i < ${#snaps[@]}; i++ )); do
            floor=$((times[$i] / SECONDS[$period]))
            [ -n "${PRUNE[${dataset}-${period}]}" ] && prune=${PRUNE[${dataset}-${period}]} || prune=${PRUNE[$period]}
            if [ "${prune}" -ge 0 -a $((offset - ${times[$i]})) -ge ${prune} ]; then
                # reset to epoch seconds for next step
                last="$((floor * SECONDS[$period]))"
                offset="${times[$i]}"
                break;
            elif [ "$last" == "$floor" ]; then
                ops[$i]='-'
                prunect=$((prunect + 1))
            else
                ops[$i]='+'
            fi
            last="$floor"
        done
    done
    # run out the rest of the snapshots if all steps are exhausted
    for (( ; i < ${#snaps[@]}; i++ )); do
        ops[$i]='-'
    done

}

function calculate_prunes() {
    for d in "${DATASETS[@]}"; do
        calculate_prune "$d"
    done
}

function prune() {
    # prune (or report on what would be pruned)
    local i j
    local c=0
    local dataset="$1"
    local varname=${dataset//[\/-]/_}
    typeset -n snaps="SNAPS_${varname}"
    typeset -n times="TIMES_${varname}"
    typeset -n ops="OPS_${varname}"
    typeset -n prunect="PRUNECT_${varname}"
    log info "pruning $prunect of ${#snaps[@]} snapshots of $dataset"
    for (( i=0 ; i < ${#snaps[@]} ; i++ )); do
        op="${ops[$i]}"
        snap="${dataset}@${snaps[$i]}"
        [ "$op" != '+' ] || [ $VERBOSE -gt 0 ] && output info "$op $snap"
        [ "$op" == '-' ] && [ $DRYRUN -eq 0 ] && eval $ZFS_DESTROY
    done
    log info "finished pruning $dataset"
}

function prunes() {
    for d in "${DATASETS[@]}"; do
        prune "$d"
    done
}

readrc
setopts "$@"
validate_opts
validate_datasets
setsnaps
calculate_prunes
get_mutex
prunes
rm $MUTEX
