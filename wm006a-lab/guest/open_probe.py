#!/usr/bin/env python3
"""Open a path read-only and report only the errno. Exit 0 = denied (EACCES/EPERM),
2 = not visible (ENOENT/ESRCH), 1 = the open succeeded (probe fails), 3 = other error."""
import errno
import os
import sys

path = sys.argv[1]
try:
    fd = os.open(path, os.O_RDONLY)
except OSError as error:
    print(f"errno={errno.errorcode.get(error.errno, error.errno)}")
    if error.errno in (errno.EACCES, errno.EPERM):
        sys.exit(0)
    sys.exit(2 if error.errno in (errno.ENOENT, errno.ESRCH) else 3)
os.close(fd)
print("opened")
sys.exit(1)
