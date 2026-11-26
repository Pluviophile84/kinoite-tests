#!/usr/bin/python3
"""Local checks for the E10 lab daemon's key handling and policy (run as root; no systemd needed).
Usage: test_local.py DIR_WITH_wm006a-e10_AND_e10_probe.py"""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import time

D = sys.argv[1]
ok = True


def check(name, cond, detail=""):
    global ok
    print(f"{'PASS' if cond else 'FAIL'} {name} {detail}".rstrip())
    ok = ok and cond


def mod():
    loader = importlib.machinery.SourceFileLoader("wm006a_e10", os.path.join(D, "wm006a-e10"))
    spec = importlib.util.spec_from_loader("wm006a_e10", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


# 1. Key page + probe: a child holds a key exactly like the daemon does.
child = subprocess.Popen([sys.executable, "-c", f"""
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader('m', {os.path.join(D, 'wm006a-e10')!r})
spec = importlib.util.spec_from_loader('m', loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
k = m.Key(); k.load(); print(hex(k.addr), flush=True)
sys.stdin.readline(); k.zeroize(); print('zeroized', flush=True)
sys.stdin.readline()
"""], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
addr = child.stdout.readline().strip()
probe = [sys.executable, os.path.join(D, "e10_probe.py")]
r = subprocess.run(probe + ["capture", str(child.pid), addr, "local"], capture_output=True, text=True).stdout
check("probe-captures-key", "nonzero=True" in r, r.strip())
r = subprocess.run(probe + ["scan", str(child.pid), "local"], capture_output=True, text=True).stdout
check("key-present-exactly-once", "full=1 " in r and "slot=key" in r, r.strip())
child.stdin.write("\n"); child.stdin.flush(); child.stdout.readline()
r = subprocess.run(probe + ["scan", str(child.pid), "local"], capture_output=True, text=True).stdout
check("key-gone-after-zeroize", "full=0 half1=0 half2=0 slot=zero" in r, r.strip())
child.stdin.write("\n"); child.stdin.flush(); child.wait()

# 2. Policy with the OS calls stubbed.
m = mod()


class S(m.Scheduler):
    def take_inhibitor(self): pass
    def release_inhibitor(self): pass
    signer = ("active", "inv-1")
    swaps = []
    def signer_state(self): return self.signer
    def disk_swap(self): return self.swaps


s = S(1000, 1001)
check("starts-disarmed", s.state == "disarmed" and s.reason == "start")
check("treasury-refused", s.arm("treasury").startswith("ERR ROLE"))
check("watch-only-refused", s.arm("watch-only").startswith("ERR ROLE"))
s.swaps = ["/var/swapfile"]
check("disk-swap-refused", s.arm("operational").startswith("ERR HIBERNATION_TARGET"))
s.swaps = []
r = s.arm("operational"); e1 = r.split("grant=")[1].split()[0]
check("arm-operational", r.startswith("ARMED") and s.key.loaded, r)
for ev in ("Session.Lock ()", "Session.Unlock ()", "Manager.SessionRemoved ('2', objectpath '/x')",
           "org.freedesktop.login1.Seat ActiveSession"):
    s.logind(ev)
check("session-events-preserve", s.state == "armed" and s.key.loaded)
check("dispatch-ok", s.dispatch(e1, "r1").startswith("DISPATCHED"))
check("dispatch-replay-rejected", s.dispatch(e1, "r1") == "REJECT seen")
check("dispatch-spacing", s.dispatch(e1, "r2") == "REJECT spacing")
s.signer = ("inactive", "inv-1"); s.tick()
check("signer-failure-disarms", s.state == "disarmed" and s.reason == "signer-failure" and not s.key.loaded)
check("old-epoch-rejected", s.dispatch(e1, "r3").startswith("REJECT"))
s.signer = ("active", "inv-2")
r = s.arm("operational"); e2 = r.split("grant=")[1].split()[0]
check("explicit-rearm", r.startswith("ARMED") and e2 != e1)
s.logind("org.freedesktop.login1.Manager.PrepareForSleep (true,)")
check("sleep-disarms", s.state == "disarmed" and s.reason == "sleep" and not s.key.loaded)
s.arm("operational"); s.logind("org.freedesktop.login1.Manager.PrepareForShutdown (true,)")
check("shutdown-disarms", s.reason == "shutdown" and not s.key.loaded)
s.arm("operational"); s.offset -= 3600; s.tick()
check("clock-jump-pauses", s.state == "paused" and s.reason == "clock-jump")
check("paused-dispatch-rejected", s.dispatch(s.grant(), "r9").startswith("REJECT state=paused"))
s.arm("operational"); s.until = time.monotonic() - 1; s.tick()
check("expiry-disarms", s.reason == "expiry" and not s.key.loaded)
# A restarted daemon reuses epoch numbers; the instance part of the grant must keep them apart.
a = S(1000, 1001); old = a.arm("operational").split("grant=")[1].split()[0]
b = S(1000, 1001); new = b.arm("operational").split("grant=")[1].split()[0]
check("restart-reuses-epoch-number", old.split(".")[1] == new.split(".")[1] == "1", f"{old} vs {new}")
check("old-instance-grant-rejected", b.dispatch(old, "x1") == "REJECT instance")
check("fresh-instance-grant-succeeds", b.dispatch(new, "x1").startswith("DISPATCHED"))
check("keys-created-counted", b.keys_created == 1 and s.keys_created >= 5, f"{s.keys_created}")
import shutil; shutil.rmtree("/var/lib/wm006a-lab-e10-probe", ignore_errors=True)
print("RESULT", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
