#!/bin/bash
##
## This file is maintained by Ansible - CHANGES WILL BE OVERWRITTEN
##
set -euo pipefail

WORKSPACE_PARENT='/var/jenkins/workspace'


case "${JOB_NAME:-}" in
    usegalaxy-tools)
        if [ "${WORKSPACE:-}" != "${WORKSPACE_PARENT}/${JOB_NAME}" ]; then
            echo "ERROR: invalid \$WORKSPACE: ${WORKSPACE:-}"
            exit 1
        fi
        ;;
    *)
        echo "ERROR: invalid \$JOB_NAME: ${JOB_NAME:-}"
        exit 1
        ;;
esac

if [ -z "${BUILD_NUMBER:-}" ] || [ "${BUILD_NUMBER:-}" -ne "${BUILD_NUMBER:-}" ]; then
    echo "ERROR: invalid \$BUILD_NUMBER: ${BUILD_NUMBER:-}"
    exit 1
else
    MOUNT_PARENT="${WORKSPACE}/${BUILD_NUMBER}"
fi

case "$(basename "$0")" in
    jenkins-mount-overlayfs)
        mount -t overlay overlay \
            -o "lowerdir=${MOUNT_PARENT}/lower,upperdir=${MOUNT_PARENT}/upper,workdir=${MOUNT_PARENT}/work" \
            "${MOUNT_PARENT}/mount"
        ;;
    jenkins-umount-overlayfs)
        umount "${MOUNT_PARENT}/mount"
        ;;
    *)
        echo 'ERROR: must be called as `jenkins-mount-overlayfs` or `jenkins-umount-overlayfs`'
        exit 1
        ;;
esac

exit 0
