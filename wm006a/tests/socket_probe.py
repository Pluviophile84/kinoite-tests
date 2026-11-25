#!/usr/bin/env python3
"""Fixed-message and denial probes for the 006A synthetic lab endpoints."""
import argparse
import errno
from pathlib import Path
import socket
import sys

DENIED = {errno.EACCES, errno.EPERM}
SERVER_CLOSE = {errno.EPIPE, errno.ECONNRESET}


def exchange(path, message, expected):
    if path.parent.parent.name != "wm006a" and not path.name.endswith(".sock"):
        raise ValueError("expected a synthetic lab socket path")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(4)
        try:
            client.connect(str(path))
        except OSError as error:
            print(f"connect errno={error.errno}")
            return expected == "dac" and error.errno in DENIED
        try:
            client.sendall(message.encode("ascii").replace(b"\\n", b"\n"))
            client.shutdown(socket.SHUT_WR)
            response = bytearray()
            while len(response) <= 32:
                part = client.recv(33 - len(response))
                if not part:
                    break
                response.extend(part)
        except OSError as error:
            print(f"peer closed errno={error.errno}")
            return expected == "peer" and error.errno in SERVER_CLOSE
        # Never print arbitrary bytes returned by a misconfigured fixture.
        if expected == "peer":
            print(f"peer returned {len(response)} byte(s)")
            return not response
        accepted = response == expected.encode("ascii").replace(b"\\n", b"\n")
        print(f"fixed reply matched={accepted}")
        return accepted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("message")
    parser.add_argument("expected")
    args = parser.parse_args()
    sys.exit(not exchange(args.path, args.message, args.expected))


if __name__ == "__main__":
    main()
