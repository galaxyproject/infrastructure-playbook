#!/usr/bin/env python3
#
# Perform sanoid prune on a list of sanoid config directories.
#
import os
import shlex
import subprocess
import sys

for dirname in os.listdir("/etc/sanoid"):
    if dirname.startswith(".") or dirname.startswith("_"):
        continue
    config_dir = f"/etc/sanoid/{dirname}"
    assert os.path.exists(f"{config_dir}/sanoid.conf"), "Config not found"

    command = [
        "/opt/sanoid/bin/sanoid",
        f"--configdir={config_dir}",
        "--prune-snapshots"
    ]

    if "--verbose" in sys.argv:
        command.append("--verbose")
        print(f"DEBUG: {shlex.join(command)}")

    subprocess.check_call(
        command,
        env={
            "TZ": "UTC",
            "PATH": "/opt/sanoid/bin:/opt/local/sbin:/opt/local/bin:/usr/sbin:/usr/bin:/sbin",
        },
    )
