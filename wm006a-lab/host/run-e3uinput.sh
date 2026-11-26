#!/usr/bin/env bash
# Guest-only uinput policy for the E3 console: deny the operator write access to /dev/uinput, then,
# from a clean boot, verify the denial with Plasma active, after relogin and after reboot, and
# confirm console approval on tty9 still works. Synthetic plans only.
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
VM="$REPO_ROOT/scripts/host/vm.sh"
GUI="python3 $REPO_ROOT/wm006a-lab/host/gui.py"
ART="$WORK/wm006a-artifacts"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
HR="$EVD/host-results.tsv"; : > "$HR"
T="$EVD/uinput-transcript.txt"; : > "$T"
CODES="$EVD/.codes"; : > "$CODES"
hres() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" | tee -a "$HR"; }
phase() { log "=== guest phase $* ==="; "$VM" ssh "sudo bash ~/wm006a-lab/guest/run.sh $*" 2>&1 | tee -a "$EVD/guest-output.log"; }
c() { local r; r=$("$VM" ssh "sudo bash ~/wm006a-lab/guest/run.sh e3con $*" 2>&1); printf '[guest] %s -> %s\n' "$*" "$r" >> "$T"; echo "$r"; }
g() { "$VM" ssh "sudo bash ~/wm006a-lab/guest/gui-helper.sh $*" 2>&1; }
note() { printf '[host] %s\n' "$*" >> "$T"; }
to_vt() { $GUI keys "ctrl-alt-f$1" >/dev/null; sleep 2; local a; a=$(c vt)
          if [[ "$a" != "tty$1" ]]; then a=$(c chvt "$1"); note "Ctrl+Alt+F$1 did not switch; root chvt -> $a"; else note "Ctrl+Alt+F$1 -> $a"; fi; }
wait_result() { local r; for _ in $(seq 10); do r=$(c result "$1"); [[ "$r" != pending* ]] && break; sleep 1; done; echo "$r"; }
reboot_check() { local b0; b0=$("$VM" boot-id)
  if "$VM" reboot; then hres PASS "$1" rebooted "boot ${b0:0:8} -> $("$VM" boot-id | cut -c1-8)"; return 0; fi
  hres FAIL "$1" rebooted "VM did not come back"; return 1; }
login() {  # login SUITE : operator Plasma session (autologin); returns session line
  local l; l=$(g login); echo "$l" >> "$T"
  [[ "$l" == session* ]] && hres PASS "$1" operator-plasma-session "$l" || hres BLOCKED "$1" operator-plasma-session "$l"; sleep 8; }

# attack_then_approve SUITE PLAN : the original E3 attack (one operator process opens uinput while
# Plasma is active, switches VT, types into tty9) must now fail at open; then a normal console
# approval of the same plan on tty9 must succeed, with seat and VT recorded.
attack_then_approve() {
  local s="$1" plan="$2" atk="P-09${2: -2}" op_vt code guess u r seat_at
  # attack on its own plan, so a successful injection cannot use up the approval dialog
  op_vt=$(c vt); c propose "$atk" >/dev/null; c start "$atk" >/dev/null
  code=$(c code); echo "$code" >> "$CODES"; guess=999999; [[ "$code" == "$guess" ]] && guess=888888
  u=$(c uinput hold-switch-type "$guess"); sleep 2; r=$(c result "$atk"); note "$s attack: $(tr '\n' ' ' <<<"$u" | cut -c1-200) -> $r"
  if grep -Eq 'PermissionError|Errno 13' <<<"$u" && [[ "$r" == pending* && "$(c vt)" == "$op_vt" ]]; then
    hres PASS "$s" held-descriptor-attack-blocked "operator could not open /dev/uinput with Plasma active ($(grep -Eo 'Errno 13[^:]*' <<<"$u" | head -n1)); no VT switch, agent untouched: $r"
  else hres FAIL "$s" held-descriptor-attack-blocked "$(tr '\n' ' ' <<<"$u" | cut -c1-200) | vt=$(c vt) | $r"; fi
  "$VM" ssh "sudo systemctl stop wm006a-e3-console@$atk.service" 2>/dev/null
  to_vt "${op_vt#tty}"
  c propose "$plan" >/dev/null; c start "$plan" >/dev/null
  code=$(c code); echo "$code" >> "$CODES"
  to_vt 9; $GUI shot "$s-screen" >/dev/null 2>&1; c screen > "$EVD/$s-screen.txt"
  # keystrokes from the operator's VT must not reach tty9
  to_vt "${op_vt#tty}"; $GUI type "$code" >/dev/null; sleep 3; r=$(c result "$plan")
  [[ "$r" == pending* ]] && hres PASS "$s" other-vt-keystrokes-not-delivered "code typed on $op_vt; agent still waiting" || hres FAIL "$s" other-vt-keystrokes-not-delivered "$r"
  to_vt 9; seat_at=$(c seat); $GUI type "$code" >/dev/null; r=$(wait_result "$plan"); $GUI shot "$s-after" >/dev/null 2>&1
  note "$s seat/VT at approval: $seat_at | agent: $r"
  [[ "$r" == *"result=approved:rev=1"* && "$r" == *"own_vt=tty9 active_vt=tty9"* ]] && hres PASS "$s" console-approval-works "$r" || hres FAIL "$s" console-approval-works "$r"
  hres INFO "$s" seat-and-vt-during-approval "$seat_at"
  to_vt "${op_vt#tty}"
}

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
hres INFO e3con-original c6-unmitigated-finding "recorded FAIL, kept: run 45780146370 (commit c3bdb68) e3con-c6/operator-cannot-inject-into-agent-vt — operator uinput (uaccess) switched to tty9 and delivered a line to the approval agent"

# Policy before any operator login, then a clean boot with no operator session yet.
phase uinput-policy apply
if reboot_check uinput-clean-boot; then
  sess=$("$VM" ssh "loginctl list-sessions --no-legend | awk '\$3==\"lab_operator\"' | wc -l")
  [[ "$sess" == 0 ]] && hres PASS uinput-clean-boot no-operator-session-yet "no lab_operator session after the clean boot" || hres FAIL uinput-clean-boot no-operator-session-yet "$sess sessions"
  phase uinput-policy state clean-boot
fi
phase e3con install

# 1. Plasma active
login uinput-plasma-active
phase uinput-policy check plasma-active
attack_then_approve uinput-plasma-active P-0101

# 2. Relogin: end the session, log in again (new session)
old=$("$VM" ssh 'cat /var/tmp/wm006a-lab/uinput-session-plasma-active')
"$VM" ssh "sudo loginctl terminate-session $old"; sleep 6
login uinput-relogin
phase uinput-policy check relogin
new=$("$VM" ssh 'cat /var/tmp/wm006a-lab/uinput-session-relogin')
[[ -n "$new" && "$new" != "$old" ]] && hres PASS uinput-relogin new-session "session $old ended; new session $new" || hres FAIL uinput-relogin new-session "old=$old new=$new"

# 3. Reboot (autologin brings the operator back)
if reboot_check uinput-reboot; then
  phase e3con install
  login uinput-reboot
  phase uinput-policy check reboot
  attack_then_approve uinput-reboot P-0102
fi

phase uinput-policy final P-0101-r1.txt,P-0102-r1.txt "$(xargs < "$CODES")"
hres BLOCKED e3con-physical physical-keyboard-routing "the VM receives input only through QEMU's virtual keyboard; routing from a physical keyboard to the active VT cannot be exercised here"
hres BLOCKED e3con-physical human-trust-check "no human: the runner reads the console buffer and types the code; whether a person recognizes trusted signer output before typing needs a physical-console test"
"$VM" ssh 'sudo chown -R tester: /var/tmp/wm006a-lab' 2>/dev/null
rm -rf "$EVD/guest"; "$VM" scp-from /var/tmp/wm006a-lab "$EVD/guest" 2>/dev/null || hres FAIL host fetch-results "could not copy guest results"
rm -f "$CODES"
"$VM" stop
exit 0
