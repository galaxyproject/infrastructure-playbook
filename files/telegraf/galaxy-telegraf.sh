#!/bin/bash
set -euo pipefail


function gunicorn_memory_high() {
    for f in /sys/fs/cgroup/system.slice/system-galaxy\\x2dmain\\x2dgunicorn.slice/galaxy-main-gunicorn\@*.service; do
        i=$(basename "$f" .service)
        i=${i#*@}
        grep ^high "${f}/memory.events" | awk '{print "gunicorn_memory_high,gunicorn='$i' value=" $2}'
    done
}


function handler_memory_high() {
    for f in /sys/fs/cgroup/system.slice/system-galaxy\\x2dmain\\x2dhandler.slice/galaxy-main-handler\@*.service; do
        i=$(basename "$f" .service)
        i=${i#*@}
        grep ^high "${f}/memory.events" | awk '{print "handler_memory_high,handler='$i' value=" $2}'
    done
    grep ^high /sys/fs/cgroup/system.slice/galaxy-main-workflow_scheduler.service/memory.events | awk '{print "handler_memory_high,handler=workflow_scheduler value=" $2}'
}


if [[ -z ${1:-} ]]; then
    echo "$0: usage: galaxy-telegraf <function>"
    exit 1
fi

"$1"
