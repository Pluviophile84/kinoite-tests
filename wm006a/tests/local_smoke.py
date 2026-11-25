#!/usr/bin/env python3
"""Run under the current UID with synthetic files in one temporary directory."""
import argparse
import errno
import os
import socket
from pathlib import Path
import stat
import statistics
import subprocess
import sys
import tempfile
import time

from socket_probe import exchange


def await_ready(process, path, label):
    for _ in range(200):
        if process.poll() is not None:
            raise RuntimeError(f"{label} exited before readiness")
        if path.exists():
            return
        time.sleep(0.01)
    raise RuntimeError(f"{label} did not become ready")


def rss_kib(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        return None
    return None


def run(binary):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM):
            pass
    except OSError as error:
        if error.errno not in (errno.EPERM, errno.EACCES, errno.EAFNOSUPPORT):
            raise
        print(f"BLOCKED: creating AF_UNIX stream socket returned errno={error.errno}")
        sys.exit(77)
    with tempfile.TemporaryDirectory(prefix="wm006a-") as directory:
        base = Path(directory)
        state = base / "state"
        state.mkdir(mode=0o700)
        ui, custody, gateway = (base / f"{role}.sock" for role in ("ui", "custody", "gateway"))
        uid = os.getuid()
        signer_log, gateway_log = (base / f"{role}.log" for role in ("signer", "gateway"))
        start = time.monotonic()
        with signer_log.open("wb") as signer_output, gateway_log.open("wb") as gateway_output:
            broker = subprocess.Popen([binary, "local-gateway", gateway, str(uid)], stderr=gateway_output)
            signer = subprocess.Popen(
                [binary, "local-signer", ui, custody, gateway, state, str(uid), str(uid + 1)],
                stderr=signer_output,
            )
            try:
                marker = state / "marker"
                await_ready(broker, gateway, "gateway")
                await_ready(signer, marker, "signer")
                assert exchange(ui, "UI_PING\\n", "OK UI+GATEWAY\\n")
                print(f"Local startup to first reply (includes polling): {(time.monotonic() - start) * 1000:.1f} ms")
                assert exchange(ui, "UNKNOWN\\n", "ERR REQUEST\\n")
                assert exchange(ui, "UI_PING\\ntrailing", "ERR REQUEST\\n")
                assert exchange(ui, "Z" * 33, "ERR REQUEST\\n")
                assert exchange(gateway, "UI_PING\\n", "ERR REQUEST\\n")
                assert exchange(custody, "CUSTODY_PING\\n", "peer")
                assert b"peer UID rejected" in signer_log.read_bytes()
                latencies = []
                for _ in range(30):
                    before = time.monotonic_ns()
                    assert exchange(ui, "UI_PING\\n", "OK UI+GATEWAY\\n")
                    latencies.append((time.monotonic_ns() - before) / 1_000_000)
                print(f"Local 30 replies: median {statistics.median(latencies):.3f} ms, p95 {sorted(latencies)[28]:.3f} ms")
                assert stat.S_IMODE(marker.stat().st_mode) == 0o600
                assert stat.S_IMODE(state.stat().st_mode) == 0o700
                fixture = marker.read_bytes()
                assert fixture.startswith(b"WM006A_TEST:") and len(fixture) == len(b"WM006A_TEST:") + 48
                assert all(fixture not in log.read_bytes() for log in (signer_log, gateway_log))
                print("Synthetic marker format/modes and ordinary log redaction: PASS")
                print(f"Signer's idle RSS: {rss_kib(signer.pid)} KiB; gateway's idle RSS: {rss_kib(broker.pid)} KiB")
                broker.terminate()
                broker.wait(timeout=5)
                assert exchange(ui, "UI_PING\\n", "ERR UNAVAILABLE\\n")
                print("Disabled gateway surfaced as unavailable: PASS")
            finally:
                for process in (signer, broker):
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
        # A fresh run allows the custody endpoint under the matching test UID.
        ui.unlink()
        custody.unlink()
        marker.unlink()
        with signer_log.open("wb") as signer_output:
            signer = subprocess.Popen(
                [binary, "local-signer", ui, custody, gateway, state, str(uid), str(uid)],
                stderr=signer_output,
            )
            try:
                await_ready(signer, marker, "signer")
                assert exchange(custody, "CUSTODY_PING\\n", "OK CUSTODY\\n")
                assert exchange(ui, "CUSTODY_PING\\n", "ERR REQUEST\\n")
                assert marker.read_bytes() != fixture
                print("Custody routing and fresh restart marker: PASS")
            finally:
                signer.terminate()
                signer.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    run(parser.parse_args().binary.resolve())
