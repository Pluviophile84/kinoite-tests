#!/usr/bin/python3
"""Local test of the E3 console agent through a pseudo-terminal against a local E3 signer.
Usage: test_console_local.py DIR   (DIR holds wm006a-e3 and wm006a-e3-console)"""
import hashlib, os, pty, re, subprocess, sys, tempfile, time
D = sys.argv[1]; ok = True
def check(n, c, d=""):
    global ok; print(f"{'PASS' if c else 'FAIL'} {n} {d}".rstrip()); ok = ok and c
tmp = tempfile.mkdtemp(); me = os.getuid()
ui, cu, st, out = (os.path.join(tmp, x) for x in ("ui", "cu", "st", "out")); os.mkdir(out)
sig = subprocess.Popen([os.path.join(D, "wm006a-e3"), "signer-local", ui, cu, st, str(me), str(me), "3"], stderr=subprocess.DEVNULL)
while not os.path.exists(cu): time.sleep(0.05)
def propose(pid, amount=5):
    return subprocess.run([os.path.join(D, "wm006a-e3"), "client", ui, f"PROPOSE id={pid} from=LAB-001 to=LAB-002 amount={amount} unit=TESTUNIT memo=synthetic"], capture_output=True, text=True).stdout
def run_agent(plan, answer, active_same=True, wait=0.0, before=None):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(WM006A_E3_CUSTODY=cu, RUNTIME_DIRECTORY=out, WM006A_ACTIVE_VT_FILE=os.path.join(tmp, "active"))
        open(os.path.join(tmp, "active"), "w").write((os.path.basename(os.ttyname(0)) if active_same else "tty1") + "\n")
        os.execv(os.path.join(D, "wm006a-e3-console"), ["wm006a-e3-console", plan])
    buf = b""
    while b"press Enter: " not in buf: buf += os.read(fd, 4096)
    screen = buf.decode()
    code = re.search(r"CONFIRMATION CODE: (\d{6})", screen).group(1)
    if before: before()
    time.sleep(wait)
    os.write(fd, ((code if answer == "code" else answer) + "\n").encode())
    try:
        while True:
            b = os.read(fd, 4096)
            if not b: break
            buf += b
    except OSError: pass
    os.waitpid(pid, 0)
    return screen, code, open(os.path.join(out, f"result-{plan}")).read()
propose("P-0001")
s, c, r = run_agent("P-0001", "code")
check("screen-shows-plan-revision-digest", "P-0001" in s and "revision: 1" in s and "digest:" in s)
check("challenge-not-displayed", "challenge:" not in s)
check("approved-with-code-on-active-vt", "result=approved:rev=1" in r, r.strip())
check("result-has-no-code", c not in r)
propose("P-0002"); s, c, r = run_agent("P-0002", "wrong")
check("wrong-code-rejected", "rejected:phrase-mismatch" in r, r.strip())
propose("P-0003"); s, c, r = run_agent("P-0003", "code", active_same=False)
check("inactive-vt-rejected", "rejected:inactive-vt" in r, r.strip())
propose("P-0004"); s, c, r = run_agent("P-0004", "code", wait=4)
check("expired-rejected", "rejected:ERR_EXPIRED" in r, r.strip())
propose("P-0005"); s, c, r = run_agent("P-0005", "code", before=lambda: propose("P-0005", 6))
check("changed-revision-rejected", "rejected:ERR_STALE_REVISION" in r, r.strip())
s, c, r = run_agent("P-0005", "code")
check("new-revision-surfaced-and-approved", "revision: 2" in s and "move 6 TESTUNIT" in s and "result=approved:rev=2" in r, r.strip())
check("records-only-approved", sorted(os.listdir(os.path.join(st, "approvals"))) == ["P-0001-r1.txt", "P-0005-r2.txt"])
sig.terminate()
print("RESULT", "PASS" if ok else "FAIL"); sys.exit(0 if ok else 1)
