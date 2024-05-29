#!/usr/bin/env python3
#
# Perform sanoid snapshot from an authorized_keys command. Avoids passing any flags to sanoid and controlling the config
# locationsnapshot. In python to just exec the arg and avoid any shell trickery.
#
import os
import subprocess
import sys

try:
    arg = os.environ["SSH_ORIGINAL_COMMAND"]
except KeyError:
    print("No value for $SSH_ORIGINAL_COMMAND", file=sys.stderr)
    sys.exit(1)

assert " " not in arg, "Invalid argument"
assert ".." not in arg, "Invalid argument"
assert "/" not in arg, "Invalid argument"

home = os.path.expanduser("~")
config_dir = f"/etc/sanoid/{arg}"

assert os.path.exists(f"{config_dir}/sanoid.conf"), "Config not found"

subprocess.check_call(
    [
        "/opt/sanoid/bin/sanoid",
        f"--configdir={config_dir}",
        f"--cache-dir={home}/sanoid/var/cache",
        f"--run-dir={home}/sanoid/var/run",
        "--take-snapshots"
    ],
    env={
        "TZ": "UTC",
        "PATH": "/opt/sanoid/bin:/opt/local/sbin:/opt/local/bin:/usr/sbin:/usr/bin:/sbin",
    },
)
