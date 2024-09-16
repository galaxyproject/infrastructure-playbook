#!/usr/bin/env bash

set -o posix
set -o nounset
set -o errexit
set -o pipefail

# /usr/bin/awk
# /usr/bin/df
# /usr/bin/flock
# /usr/bin/getconf
# /usr/bin/mount

# arguments
EXPECTED_JOB_PARTITION='resize-shm'
MOUNTPOINT='/dev/shm'
NEEDED_SIZE='470g'

export POSIXLY_CORRECT=1
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 0022


convert_to_bytes () {
    local size="$1"
    local new_size="${size:0:-1}"
    local last_char="${size: -1}"
    local multiplier

    case "$last_char" in
        [0-9]|%)
            multiplier=1
            ;;
        k)
            multiplier=1024
            ;;
        m)
            multiplier=1048576
            ;;
        g)
            multiplier=1073741824
            ;;
        *)
            multiplier=-1
            ;;
    esac

    if [ "$multiplier" = '-1' ]; then
        echo "unable to parse size: \"${size}\""
        exit 1
    elif [ "$multiplier" = '1' ]; then
        :
    else
        size=$((new_size * multiplier))
    fi

    echo "$size"
}


##
## exit if SLURM_JOB_PARTITION is not set / does not equal EXPECTED_JOB_PARTITION
##
[ "${SLURM_JOB_PARTITION:-}" != "$EXPECTED_JOB_PARTITION" ] && exit 0


##
## make sure only one copy of this script is running
##
exec 9< "$0"
flock -en 9 || exit 0


##
## get total space and free space on MOUNTPOINT in bytes
##
total_bytes=-1

[ -e "$MOUNTPOINT" ] && {
    total_bytes=$(df -P "$MOUNTPOINT" | awk -v "mtpt=$MOUNTPOINT" '$6 == mtpt {print $2}') || {
        echo "unable to get total space for \"${MOUNTPOINT}\""
        exit 1
    }
}

[ "$total_bytes" = "-1" ] && {
    echo "unable to find mountpoint \"${MOUNTPOINT}\" using df"
    exit 1
}

# 512 because POSIXLY_CORRECT=1
total_bytes=$((total_bytes * 512))


##
## space needed on MOUNTPOINT in bytes
##
needed_bytes=$(convert_to_bytes "$NEEDED_SIZE")

if [ $total_bytes -ge $needed_bytes ]; then
    exit 0
fi


##
## new size for MOUNTPOINT in bytes, rounded up to the nearest gb
##
new_total_bytes=$(($(((needed_bytes + 1073741823) / 1073741824)) * 1073741824))


##
## total memory on system in bytes
##
memory_total_bytes=$(awk '$1 == "MemTotal:" {print $2 * 1024}' /proc/meminfo) || {
    echo "unable to get total memory from /proc/meminfo"
    exit 1
}

if [ $new_total_bytes -ge $memory_total_bytes ]; then
    echo "not enough memory for a \"${NEEDED_SIZE}\" size \"${MOUNTPOINT}\""
    exit 1
fi


##
## try to remount MOUNTPPOINT
##
mount -o "remount,size=${new_total_bytes}" "${MOUNTPOINT}" || {
    echo "unable to resize \"${MOUNTPOINT}\""
    exit 1
}

exit 0
