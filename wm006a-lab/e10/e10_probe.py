#!/usr/bin/python3 -I
"""Root-only memory probe for the E10 lab daemon. Never prints key bytes.

  e10_probe.py capture PID ADDR LABEL   read KEY_LEN bytes at ADDR into STORE/LABEL (0600, complemented)
  e10_probe.py scan PID LABEL           count occurrences of the captured key (and each half) in every
                                        readable mapping of PID; report whether ADDR now holds zeros
  e10_probe.py files LABEL... -- PATH...  search files/dirs (and the journal) for any captured key
"""
import hashlib
import os
import re
import subprocess
import sys

KEY_LEN = 32
# Durable root-only store (survives reboot). Stored as the bitwise complement of the key, so the
# raw key and its hex form never appear on disk and the disk/journal search stays meaningful.
STORE = "/var/lib/wm006a-lab-e10-probe"


def regions(pid):
    for line in open(f"/proc/{pid}/maps"):
        m = re.match(r"([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \S+\s*(.*)", line)
        if m and m.group(3)[0] == "r" and m.group(4) not in ("[vvar]", "[vsyscall]", "[vvar_vclock]"):
            yield int(m.group(1), 16), int(m.group(2), 16), m.group(4)


def read(pid, addr, n):
    with open(f"/proc/{pid}/mem", "rb", buffering=0) as f:
        f.seek(addr)
        return f.read(n)


def load(label):
    with open(os.path.join(STORE, label), "rb") as f:
        data = f.read()
    addr, key = int.from_bytes(data[:8], "little"), bytes(b ^ 0xFF for b in data[8:])
    return addr, key


def main():
    cmd = sys.argv[1]
    if cmd == "capture":
        pid, addr, label = int(sys.argv[2]), int(sys.argv[3], 16), sys.argv[4]
        key = read(pid, addr, KEY_LEN)
        os.makedirs(STORE, mode=0o700, exist_ok=True)
        fd = os.open(os.path.join(STORE, label), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, addr.to_bytes(8, "little") + bytes(b ^ 0xFF for b in key))
        os.close(fd)
        print(f"captured label={label} nonzero={any(key)} sha256={hashlib.sha256(key).hexdigest()[:16]}")
        sys.exit(0 if any(key) else 1)
    if cmd == "scan":
        pid, label = int(sys.argv[2]), sys.argv[3]
        addr, key = load(label)
        full = half1 = half2 = scanned = 0
        where = set()
        for start, end, name in regions(pid):
            try:
                blob = read(pid, start, end - start)
            except OSError:
                continue
            scanned += len(blob)
            c = blob.count(key)
            full += c
            half1 += blob.count(key[:16])
            half2 += blob.count(key[16:])
            if c:
                where.add(name or "anon")
        try:
            at = read(pid, addr, KEY_LEN)
            slot = "zero" if not any(at) else ("key" if at == key else "other")
        except OSError:
            slot = "unmapped"
        print(f"label={label} full={full} half1={half1} half2={half2} slot={slot} "
              f"scanned_mib={scanned / 2**20:.1f} where={','.join(sorted(where)) or '-'}")
        return
    if cmd == "files":
        sep = sys.argv.index("--")
        keys = [load(lbl)[1] for lbl in sys.argv[2:sep]]
        hits = []
        for root in sys.argv[sep + 1:]:
            for dirpath, _, names in os.walk(root) if os.path.isdir(root) else [(os.path.dirname(root), [], [os.path.basename(root)])]:
                for n in names:
                    p = os.path.join(dirpath, n)
                    try:
                        if not os.path.isfile(p) or os.path.islink(p) or os.path.getsize(p) > 256 * 2**20:
                            continue
                        blob = open(p, "rb").read()
                    except OSError:
                        continue
                    for k in keys:
                        if k in blob or k.hex().encode() in blob:
                            hits.append(p)
        journal = subprocess.run(["journalctl", "-o", "export", "--no-pager"], capture_output=True).stdout
        jhits = sum(1 for k in keys if k in journal or k.hex().encode() in journal)
        print(f"keys={len(keys)} file_hits={len(hits)} journal_hits={jhits} {' '.join(hits[:5])}")
        sys.exit(0 if not hits and not jhits else 1)


if __name__ == "__main__":
    main()
