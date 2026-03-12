#!/usr/bin/env python3
"""Simple piped log rotator. Reads stdin, writes to a log file, rotates when it exceeds a size threshold."""
import gzip
import os
import shutil
import sys

DEFAULT_MAX_BYTES = 50 * 1024 * 1024
DEFAULT_MAX_BACKUPS = 10


def rotate(log_path, max_backups):
    # Remove the oldest backup if it exists
    oldest_gz = f"{log_path}.{max_backups}.gz"
    if os.path.exists(oldest_gz):
        os.remove(oldest_gz)

    # Shift .gz files up
    for i in range(max_backups - 1, 1, -1):
        src = f"{log_path}.{i}.gz"
        dst = f"{log_path}.{i + 1}.gz"
        if os.path.exists(src):
            os.rename(src, dst)

    # Compress .1 to .2.gz
    dot1 = f"{log_path}.1"
    if os.path.exists(dot1):
        with open(dot1, 'rb') as f_in, gzip.open(f"{log_path}.2.gz", 'wb') as f_out:
            shutil.copyfileobj(f_in, f_out)
        os.remove(dot1)

    # Rotate current to .1 (uncompressed, like delaycompress)
    if os.path.exists(log_path):
        os.rename(log_path, dot1)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <logfile> [max_bytes] [max_backups]", file=sys.stderr)
        sys.exit(1)

    log_path = sys.argv[1]
    max_bytes = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAX_BYTES
    max_backups = int(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_MAX_BACKUPS

    f = open(log_path, 'a')
    size = os.fstat(f.fileno()).st_size

    for line in sys.stdin:
        if size >= max_bytes:
            f.close()
            rotate(log_path, max_backups)
            f = open(log_path, 'a')
            size = 0
        f.write(line)
        f.flush()
        size += len(line.encode('utf-8', errors='replace'))


if __name__ == '__main__':
    main()
