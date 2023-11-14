#!/usr/bin/env bash

set -o posix
set -o nounset
set -o errexit
set -o pipefail

# /usr/bin/flock
# /usr/bin/rm
# /usr/bin/mount

# arguments
EXPECTED_JOB_PARTITION='resize-shm'
MOUNTPOINT='/dev/shm'
CLEANUP_DIR="${MOUNTPOINT}/gxdb"
ORIG_SIZE_FILENAME='.galaxy_mount_orig_size'
ORIG_SIZE_PATHNAME="${MOUNTPOINT}/${ORIG_SIZE_FILENAME}"

export POSIXLY_CORRECT=1
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 0022


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
## get original size of MOUNTPOINT
##
read -r size < "$ORIG_SIZE_PATHNAME" || {
    echo "unable to get original sixe for \"${MOUNTPOINT}\""
    exit 1
}

##
## cleanup data
##
rm -rf "${CLEANUP_DIR}" || {
    echo "unable to cleanup \"${CLEANUP_DIR}\""
    exit 1
}


##
## try to remount MOUNTPPOINT
##
mount -o "remount,size=${size}" "${MOUNTPOINT}" || {
    echo "unable to resize \"${MOUNTPOINT}\""
    exit 1
}

##
## cleanup original size file
##
rm -f "${ORIG_SIZE_PATHNAME}" || {
    echo "unable to remove \"${ORIG_SIZE_PATHNAME}\""
    exit 1
}

exit 0
