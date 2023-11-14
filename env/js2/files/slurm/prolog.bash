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
ORIG_SIZE_FILENAME='.galaxy_mount_orig_size'
ORIG_SIZE_PATHNAME="${MOUNTPOINT}/${ORIG_SIZE_FILENAME}"

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
free_bytes=-1

data=''
[ -e "$MOUNTPOINT" ] && {
    data=$(df -P "$MOUNTPOINT" | awk -v "mtpt=$MOUNTPOINT" '$6 == mtpt {print $2 ":" $4}') || {
        echo "unable to get total/free space for \"${MOUNTPOINT}\""
        exit 1
    }
}

[ -z "$data" ] && {
    echo "unable to find mountpoint \"${MOUNTPOINT}\" using df"
    exit 1
}

IFS=':' read -r total_bytes free_bytes <<< "$data" || {
    echo "unable to split total/free bytes"
    exit 1

}

# 512 because POSIXLY_CORRECT=1
total_bytes=$((total_bytes * 512))
free_bytes=$((free_bytes * 512))


##
## space needed on MOUNTPOINT in bytes
##
needed_bytes=$(convert_to_bytes "$NEEDED_SIZE")

if [ $free_bytes -ge $needed_bytes ]; then
    # no MOUNTPOINT resizing needed
    exit 0
fi

##
## new size for MOUNTPOINT in bytes, rounded up to the nearest gb
##
new_total_bytes=$((total_bytes + needed_bytes - free_bytes))
new_total_bytes=$(($(((new_total_bytes + 1073741823) / 1073741824)) * 1073741824))


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
## get mount options for MOUNTPOINT
##
# https://www.kernel.org/doc/html/latest/filesystems/proc.html
options=$(awk -v "mtpt=$MOUNTPOINT" '
            $2 == mtpt {
                print tolower($4)
            }' /proc/self/mounts) || {
                echo "unable to find mountpoint \"${MOUNTPOINT}\" in /proc/self/mounts"
            }

# https://www.kernel.org/doc/html/latest/filesystems/tmpfs.html
IFS=',' read -ra OPTS <<< "$options" || {
    echo "unable to split mount options: \"${options}\""
    exit 1
}

size=''
nr_blocks=''

for opt in "${OPTS[@]}"; do
    option="${opt%%=*}"
    value="${opt##*=}"

    if [ "$option" = 'size' ]; then
        size="$value"
    elif [ "$option" = 'nr_blocks' ]; then
        nr_blocks="$value"
    fi
done

if [ \( -z "$size" \) -a \( -z "$nr_blocks" \) ]; then
    size='50%'
elif [ -n "$size" ]; then
    size=$(convert_to_bytes "$size")
elif [ -n "$nr_blocks" ]; then
    page_size=$(getconf PAGE_SIZE) || {
        echo "unable to get PAGE_SIZE from getconf"
        exit 1
    }
    # The same as size, but in blocks of PAGE_SIZE.
    size=$(convert_to_bytes "$nr_blocks")
    size=$((size * page_size))
fi

# save original size for epilog
echo "$size" > "${ORIG_SIZE_PATHNAME}" || {
    echo "unable to save original size of \"${MOUNTPOINT}\""
    exit 1
}

##
## try to remount MOUNTPPOINT
##
mount -o "remount,size=${new_total_bytes}" "${MOUNTPOINT}" || {
    echo "unable to resize \"${MOUNTPOINT}\""
    exit 1
}

exit 0
