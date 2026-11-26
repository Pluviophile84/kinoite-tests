#!/usr/bin/python3 -I
"""Local protocol test for the E3 lab fixture (no systemd, single UID). Run: test_local.py PATH_TO_wm006a-e3
Covers the approval path and every rejection the VM run checks except cross-UID socket access."""
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

EXE = sys.argv[1]
ok = True


def check(name, cond, detail=""):
    global ok
    print(f"{'PASS' if cond else 'FAIL'} {name} {detail}".rstrip())
    ok = ok and cond


def start(tmp, op_uid, cu_uid, ttl, tag):
    ui, cu, st = (os.path.join(tmp, f"{tag}-{n}") for n in ("ui.sock", "custody.sock", "state"))
    p = subprocess.Popen([EXE, "signer-local", ui, cu, st, str(op_uid), str(cu_uid), str(ttl)],
                         stderr=subprocess.PIPE, text=True)
    for _ in range(50):
        if os.path.exists(cu):
            break
        time.sleep(0.05)
    return p, ui, cu, st


def call(path, line):
    r = subprocess.run([EXE, "client", path, line], capture_output=True, text=True)
    return r.stdout


me = os.getuid()
plan = "id=P-0001 from=LAB-001 to=LAB-002 amount=5 unit=TESTUNIT memo=synthetic"
with tempfile.TemporaryDirectory() as tmp:
    p, ui, cu, st = start(tmp, me, me, 2, "a")
    r = call(ui, f"PROPOSE {plan}"); m = re.match(r"REVISION P-0001 1 (sha256:[0-9a-f]{64})", r)
    check("propose", bool(m), r.strip()); d1 = m.group(1)
    check("same-content-same-revision", call(ui, f"PROPOSE {plan}").startswith("REVISION P-0001 1 "))
    check("bad-plan-rejected", call(ui, "PROPOSE id=P-0001 from=LAB-001 to=LAB-001 amount=5 unit=TESTUNIT memo=x") == "ERR PLAN\n")
    check("approve-on-ui-rejected", call(ui, "APPROVE P-0001 1 x y") == "ERR REQUEST\n")
    scr = call(cu, "SCREEN P-0001"); c = re.search(r"challenge:\s+(\S+)", scr).group(1)
    check("screen-shows-revision-digest", "revision: 1" in scr and d1 in scr, "")
    check("approve-valid", call(cu, f"APPROVE P-0001 1 {d1} {c}") == f"APPROVED P-0001 rev=1 digest={d1}\n")
    check("replay-rejected", call(cu, f"APPROVE P-0001 1 {d1} {c}") == "ERR REPLAY\n")
    check("one-record", os.listdir(os.path.join(st, "approvals")) == ["P-0001-r1.txt"])
    check("record-inert", open(os.path.join(st, "approvals", "P-0001-r1.txt")).read().startswith("inert=true synthetic=true"))
    # concurrent replay
    call(ui, f"PROPOSE {plan.replace('P-0001', 'P-0002')}")
    scr = call(cu, "SCREEN P-0002"); c = re.search(r"challenge:\s+(\S+)", scr).group(1); d2 = re.search(r"digest:\s+(\S+)", scr).group(1)
    res = []
    ts = [threading.Thread(target=lambda: res.append(call(cu, f"APPROVE P-0002 1 {d2} {c}"))) for _ in range(2)]
    [t.start() for t in ts]; [t.join() for t in ts]
    check("concurrent-replay-one-wins", sorted(x.split()[0] + " " + x.split()[1] for x in res) == ["APPROVED P-0002", "ERR REPLAY"], str(res))
    # changed revision
    call(ui, f"PROPOSE {plan.replace('P-0001', 'P-0003')}")
    scr = call(cu, "SCREEN P-0003"); c = re.search(r"challenge:\s+(\S+)", scr).group(1); d3 = re.search(r"digest:\s+(\S+)", scr).group(1)
    r2 = call(ui, f"PROPOSE {plan.replace('P-0001', 'P-0003').replace('amount=5', 'amount=6')}")
    check("changed-content-new-revision", r2.startswith("REVISION P-0003 2 "), r2.strip())
    check("stale-revision-rejected", call(cu, f"APPROVE P-0003 1 {d3} {c}") == "ERR STALE_REVISION\n")
    scr = call(cu, "SCREEN P-0003"); c = re.search(r"challenge:\s+(\S+)", scr).group(1)
    check("modified-field-binding-rejected", call(cu, f"APPROVE P-0003 2 {d3} {c}") == "ERR BINDING\n")
    # expiry
    call(ui, f"PROPOSE {plan.replace('P-0001', 'P-0004')}")
    scr = call(cu, "SCREEN P-0004"); c = re.search(r"challenge:\s+(\S+)", scr).group(1); d4 = re.search(r"digest:\s+(\S+)", scr).group(1)
    time.sleep(3)
    check("expired-rejected", call(cu, f"APPROVE P-0004 1 {d4} {c}") == "ERR EXPIRED\n")
    check("unknown-challenge-rejected", call(cu, f"APPROVE P-0004 1 {d4} {c.split('.')[0]}.00") == "ERR UNKNOWN_CHALLENGE\n")
    # restart
    call(ui, f"PROPOSE {plan.replace('P-0001', 'P-0005')}")
    scr = call(cu, "SCREEN P-0005"); c = re.search(r"challenge:\s+(\S+)", scr).group(1); d5 = re.search(r"digest:\s+(\S+)", scr).group(1)
    p.terminate(); p.wait(); [os.unlink(x) for x in (ui, cu)]
    p, ui, cu, st = start(tmp, me, me, 2, "a")
    check("pre-restart-challenge-rejected", call(cu, f"APPROVE P-0005 1 {d5} {c}") == "ERR STALE_GENERATION\n")
    check("post-restart-plan-reproposed", call(ui, f"PROPOSE {plan.replace('P-0001', 'P-0005')}") == f"REVISION P-0005 1 {d5}\n")
    c = re.search(r"challenge:\s+(\S+)", call(cu, "SCREEN P-0005")).group(1)
    check("post-restart-fresh-challenge-approves", call(cu, f"APPROVE P-0005 1 {d5} {c}") == f"APPROVED P-0005 rev=1 digest={d5}\n")
    check("post-restart-fresh-challenge-replay-rejected", call(cu, f"APPROVE P-0005 1 {d5} {c}") == "ERR REPLAY\n")
    check("records-only-valid-approvals", sorted(os.listdir(os.path.join(st, "approvals"))) == ["P-0001-r1.txt", "P-0002-r1.txt", "P-0005-r1.txt"])
    p.terminate(); p.wait()
    # peer UID check: custody socket bound to a different UID
    p, ui, cu, st = start(tmp, me, me + 1, 2, "b")
    call(ui, f"PROPOSE {plan}")
    check("wrong-custody-uid-rejected", call(cu, "SCREEN P-0001") == "ERR PEER\n")
    p.terminate(); p.wait()
    p, ui, cu, st = start(tmp, me + 1, me, 2, "c")
    check("wrong-operator-uid-rejected", call(ui, f"PROPOSE {plan}") == "ERR PEER\n")
    big = call(ui, "PROPOSE " + "x" * 600)   # refused: either ERR REQUEST or a reset before the reply
    check("oversized-line-rejected", big in ("ERR REQUEST\n", "recv errno=104\n"), big.strip())
    check("still-serving-after-oversize", call(ui, f"PROPOSE {plan}") == "ERR PEER\n")
    p.terminate(); p.wait()
print("RESULT", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
