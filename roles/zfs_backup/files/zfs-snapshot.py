#!/usr/bin/env python3
#
# Perform zfs snapshot from an authorized_keys command, restricted to a subset of datasets. Avoids passing any flags
# to zfs snapshot. In python to just exec the arg and avoid any shell trickery.
#
import os
import subprocess
import sys

try:
    root = sys.argv[1]
except IndexError:
    print(f"usage: {sys.argv[0]} ROOT", file=sys.stderr)
    sys.exit(1)

try:
    arg = os.environ["SSH_ORIGINAL_COMMAND"]
except KeyError:
    print("No value for $SSH_ORIGINAL_COMMAND", file=sys.stderr)
    sys.exit(1)

assert " " not in arg, "Invalid argument"

subprocess.check_call(["/usr/sbin/zfs", "snapshot", f"{root.rstrip('/')}/{arg.lstrip('/')}"])
