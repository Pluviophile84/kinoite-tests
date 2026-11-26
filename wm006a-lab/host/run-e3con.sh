#!/usr/bin/env bash
# E3 guest-console checks: approval on a signer-side agent on tty9 (custody identity), separate from
# the operator's Plasma session on tty1. The runner plays the console user: it switches VTs and
# types through the VM's virtual keyboard (QMP), and reads the screen. Synthetic plans only.
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
VM="$REPO_ROOT/scripts/host/vm.sh"
GUI="python3 $REPO_ROOT/wm006a-lab/host/gui.py"
ART="$WORK/wm006a-artifacts"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
HR="$EVD/host-results.tsv"; : > "$HR"
T="$EVD/e3con-transcript.txt"; : > "$T"
CODES="$EVD/.codes"; : > "$CODES"
hres() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" | tee -a "$HR"; }
phase() { log "=== guest phase $* ==="; "$VM" ssh "sudo bash ~/wm006a-lab/guest/run.sh $*" 2>&1 | tee -a "$EVD/guest-output.log"; }
c() { local r; r=$("$VM" ssh "sudo bash ~/wm006a-lab/guest/run.sh e3con $*" 2>&1); printf '[guest] %s -> %s\n' "$*" "$r" >> "$T"; echo "$r"; }
g() { "$VM" ssh "sudo bash ~/wm006a-lab/guest/gui-helper.sh $*" 2>&1; }
note() { printf '[host] %s\n' "$*" >> "$T"; }
to_vt() {  # to_vt N : switch with Ctrl+Alt+Fn on the virtual keyboard; fall back to root chvt (recorded)
  $GUI keys "ctrl-alt-f$1" >/dev/null; sleep 2
  local a; a=$(c vt)
  if [[ "$a" != "tty$1" ]]; then a=$(c chvt "$1"); note "Ctrl+Alt+F$1 did not switch; used root chvt -> $a"; echo "chvt"; else note "Ctrl+Alt+F$1 -> $a"; echo "keys"; fi
}
read_code() {  # read_code PLAN SHOT : screen on tty9 -> code (also saves a screenshot)
  $GUI shot "$2" >/dev/null 2>&1
  c screen > "$EVD/e3con-screen-$2.txt"; local code; code=$(c code)
  echo "$code" >> "$CODES"; echo "$code"
}
result() { c result "$1"; }
wait_result() { local r; for _ in $(seq 10); do r=$(result "$1"); [[ "$r" != pending* ]] && break; sleep 1; done; echo "$r"; }

qemu-img snapshot -c clean "$DISK" && hres PASS boundary clean-disk-snapshot "$(qemu-img snapshot -l "$DISK" | tail -n1)"
export VM_EXTRA_ARGS="-device virtio-tablet-pci -device virtio-keyboard-pci -qmp unix:$WORK/qmp.sock,server,nowait"
"$VM" start || { hres FAIL boundary vm-start "qemu failed"; exit 0; }
tr '\0' ' ' < "/proc/$(cat "$PIDF")/cmdline" > "$EVD/qemu-cmdline.txt"
"$VM" wait-ssh 1200 || { hres FAIL boundary first-boot "no SSH"; exit 0; }
stage="$WORK/wm006a-stage"; rm -rf "$stage"; mkdir -p "$stage/ws/native/target/release"
cp -r "$REPO_ROOT/wm006a/systemd" "$REPO_ROOT/wm006a/tests" "$stage/ws/"
cp "$ART/wm006a-native" "$stage/ws/native/target/release/"; cp "$ART/wm006a-native.sha256" "$stage/"
cp -r "$REPO_ROOT/wm006a-lab/guest" "$REPO_ROOT/wm006a-lab/e3" "$stage/"
"$VM" ssh 'rm -rf ~/wm006a-lab'; "$VM" scp-to "$stage" wm006a-lab
phase 00-boundary
phase 01-setup
phase e3-install
phase e3con install

# Two isolated guest sessions: operator Plasma on its VT, approval agent on tty9.
login=$(g login); echo "$login" > "$EVD/e3con-login.txt"
[[ "$login" == session* ]] && hres PASS e3con-console operator-plasma-session "$login" || hres BLOCKED e3con-console operator-plasma-session "$login"
sleep 10
op_vt=$(c vt); hres INFO e3con-console sessions-before "$(c seat)"

# C1  valid approval, after proving keystrokes typed on the operator's VT never reach tty9
c propose P-0001 >/dev/null; c start P-0001 >/dev/null
how=$(to_vt 9); code=$(read_code P-0001 c1-screen)
s=$(cat "$EVD/e3con-screen-c1-screen.txt")
grep -q 'P-0001' <<<"$s" && grep -q 'revision: 1' <<<"$s" && grep -q 'digest:' <<<"$s" && ! grep -q 'challenge:' <<<"$s" && [[ "$code" =~ ^[0-9]{6}$ ]] \
  && hres PASS e3con-c1 signer-screen-on-tty9 "plan P-0001, revision 1, digest and a 6-digit code shown on tty9 (switched by $how); raw challenge not displayed" \
  || hres FAIL e3con-c1 signer-screen-on-tty9 "$(tr '\n' ' ' <<<"$s" | cut -c1-200)"
to_vt "${op_vt#tty}" >/dev/null; [[ "$(c vt)" == "$op_vt" ]] || note "could not return to $op_vt"
$GUI type "$code" >/dev/null; sleep 3
r=$(result P-0001)
[[ "$r" == pending* ]] && hres PASS e3con-c1 other-vt-keystrokes-not-delivered "correct code typed while $op_vt (Plasma) was active; agent on tty9 received nothing: $r" \
  || hres FAIL e3con-c1 other-vt-keystrokes-not-delivered "$r"
to_vt 9 >/dev/null; seat_at=$(c seat)
$GUI type "$code" >/dev/null; r=$(wait_result P-0001); $GUI shot c1-after >/dev/null 2>&1
note "C1 seat/VT at approval: $seat_at | agent: $r"
[[ "$r" == *"result=approved:rev=1"* && "$r" == *"own_vt=tty9 active_vt=tty9"* ]] \
  && hres PASS e3con-c1 approved-on-active-agent-vt "$r" || hres FAIL e3con-c1 approved-on-active-agent-vt "$r"
hres INFO e3con-c1 seat-and-vt-during-approval "$seat_at"
# Negative checks once tty9 exists (vcs9/vcsa9 are only created when the VT is allocated).
phase e3con negatives

# C2  wrong code
c propose P-0002 >/dev/null; c start P-0002 >/dev/null; code=$(read_code P-0002 c2-screen)
wrong=000000; [[ "$code" == "$wrong" ]] && wrong=111111
$GUI type "$wrong" >/dev/null; r=$(wait_result P-0002)
[[ "$r" == *"rejected:phrase-mismatch"* ]] && hres PASS e3con-c2 wrong-code-rejected "$r" || hres FAIL e3con-c2 wrong-code-rejected "$r"

# C3  revision changed while the dialog is open; then the signer surfaces the new revision
c propose P-0003 >/dev/null; c start P-0003 >/dev/null; code=$(read_code P-0003 c3-screen-rev1)
c propose P-0003 6 >/dev/null
$GUI type "$code" >/dev/null; r=$(wait_result P-0003)
[[ "$r" == *"rejected:ERR_STALE_REVISION"* ]] && hres PASS e3con-c3 changed-revision-rejected "$r" || hres FAIL e3con-c3 changed-revision-rejected "$r"
c start P-0003 >/dev/null; code=$(read_code P-0003 c3-screen-rev2); s=$(cat "$EVD/e3con-screen-c3-screen-rev2.txt")
grep -q 'revision: 2' <<<"$s" && grep -q 'move 6 TESTUNIT' <<<"$s" && hres PASS e3con-c3 signer-surfaces-new-revision "tty9 now shows revision 2, amount 6" || hres FAIL e3con-c3 signer-surfaces-new-revision "$(tr '\n' ' ' <<<"$s" | cut -c1-200)"
$GUI type "$code" >/dev/null; r=$(wait_result P-0003)
[[ "$r" == *"result=approved:rev=2"* && "$r" == *"active_vt=tty9"* ]] && hres PASS e3con-c3 new-revision-approved "$r" || hres FAIL e3con-c3 new-revision-approved "$r"

# C4  expiry while the dialog is open
c propose P-0004 >/dev/null; c start P-0004 >/dev/null; code=$(read_code P-0004 c4-screen)
sleep 63; $GUI type "$code" >/dev/null; r=$(wait_result P-0004)
[[ "$r" == *"rejected:ERR_EXPIRED"* ]] && hres PASS e3con-c4 expired-rejected "$r" || hres FAIL e3con-c4 expired-rejected "$r"

# C5  guest-root input injection into tty9 while the operator's VT is active
to_vt "${op_vt#tty}" >/dev/null
c propose P-0005 >/dev/null; c start P-0005 >/dev/null
inj=$(c inject); r=$(wait_result P-0005)
note "C5 injection: $inj"
[[ "$r" == *"rejected:inactive-vt"* ]] && hres PASS e3con-c5 injected-input-on-inactive-vt-refused "$inj; $r" || hres FAIL e3con-c5 injected-input-on-inactive-vt-refused "$inj; $r"
c screen | grep -o 'CONFIRMATION CODE: [0-9]*' | awk '{print $3}' >> "$CODES"
hres INFO e3con-c5 guest-root-limit "guest root can read tty9 (/dev/vcs9) and inject with TIOCSTI; provenance stops it only while tty9 is inactive, so VT provenance does not defend against a compromised guest root"

# C6  operator's uinput (granted by the active-session uaccess ACL): can it reach the agent's VT?
to_vt "${op_vt#tty}" >/dev/null
c propose P-0006 >/dev/null; c start P-0006 >/dev/null
real=$(c code); echo "$real" >> "$CODES"; guess=999999; [[ "$real" == "$guess" ]] && guess=888888
v0=$(c vt); u=$(c uinput hold-switch-type "$guess"); v1=$(c vt); r=$(wait_result P-0006)
note "C6 operator held-descriptor attempt: $v0 -> $v1 | $(tr '\n' ' ' <<<"$u") | agent: $r"
hres INFO e3con-c6 operator-uinput-held-descriptor "active VT $v0 -> $v1; $(tr '\n' ';' <<<"$u")"
if [[ "$r" == pending* ]]; then
  hres PASS e3con-c6 operator-cannot-inject-into-agent-vt "operator's uinput keystrokes did not reach tty9: $r"
else
  hres FAIL e3con-c6 operator-cannot-inject-into-agent-vt "operator's uinput keyboard delivered a line to the approval VT while it was active: $r"
fi
hres INFO e3con-c6 code-confidentiality "the operator cannot read tty9 (vcs9/vcsa9 denied), so injected input cannot supply the right code; it can only submit guesses or stray input"

phase e3con final "$(xargs < "$CODES")"
hres BLOCKED e3con-physical physical-keyboard-routing "the VM receives input only through QEMU's virtual keyboard; routing from a physical keyboard to the active VT cannot be exercised here"
hres BLOCKED e3con-physical human-trust-check "no human: the runner reads the console buffer and types the code; whether a person recognizes trusted signer output before typing needs a physical-console test"
hres SKIP scope physical-console-other "secure attention/switching on real hardware, input devices, host remote-console rights and real KDE lock-screen behaviour are separate physical tests"
"$VM" ssh 'sudo chown -R tester: /var/tmp/wm006a-lab' 2>/dev/null
rm -rf "$EVD/guest"; "$VM" scp-from /var/tmp/wm006a-lab "$EVD/guest" 2>/dev/null || hres FAIL host fetch-results "could not copy guest results"
rm -f "$CODES"
"$VM" stop
exit 0
