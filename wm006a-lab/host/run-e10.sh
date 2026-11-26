#!/usr/bin/env bash
# E10 scheduler lifecycle in one disposable Kinoite VM, driven by real events:
# session lock/switch/logout and GUI close/crash (preserve), signer failure, expiry, clock jump,
# Stop, reboot and suspend (disarm + key cleared, checked by a root-only memory probe).
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
VM="$REPO_ROOT/scripts/host/vm.sh"
QMP="python3 $REPO_ROOT/wm006a-lab/host/gui.py qmp"
ART="$WORK/wm006a-artifacts"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
HR="$EVD/host-results.tsv"; : > "$HR"
hres() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" | tee -a "$HR"; }
phase() { log "=== guest phase $* ==="; "$VM" ssh "sudo bash ~/wm006a-lab/guest/run.sh $*" 2>&1 | tee -a "$EVD/guest-output.log"; }
g() { "$VM" ssh "sudo bash ~/wm006a-lab/guest/gui-helper.sh $*" 2>&1; }
collect() { "$VM" ssh 'sudo chown -R tester: /var/tmp/wm006a-lab' 2>/dev/null
            rm -rf "$EVD/guest"; "$VM" scp-from /var/tmp/wm006a-lab "$EVD/guest" 2>/dev/null; }

qemu-img snapshot -c clean "$DISK" && hres PASS boundary clean-disk-snapshot "$(qemu-img snapshot -l "$DISK" | tail -n1)"
export VM_EXTRA_ARGS="-global ICH9-LPC.disable_s3=0 -device virtio-tablet-pci -device virtio-keyboard-pci -qmp unix:$WORK/qmp.sock,server,nowait"
"$VM" start || { hres FAIL boundary vm-start "qemu failed"; exit 0; }
tr '\0' ' ' < "/proc/$(cat "$PIDF")/cmdline" > "$EVD/qemu-cmdline.txt"
"$VM" wait-ssh 1200 || { hres FAIL boundary first-boot "no SSH"; exit 0; }
stage="$WORK/wm006a-stage"; rm -rf "$stage"; mkdir -p "$stage/ws/native/target/release"
cp -r "$REPO_ROOT/wm006a/systemd" "$REPO_ROOT/wm006a/tests" "$stage/ws/"
cp "$ART/wm006a-native" "$stage/ws/native/target/release/"
cp "$ART/wm006a-native.sha256" "$stage/"
cp -r "$REPO_ROOT/wm006a-lab/guest" "$REPO_ROOT/wm006a-lab/e10" "$stage/"
"$VM" ssh 'rm -rf ~/wm006a-lab'; "$VM" scp-to "$stage" wm006a-lab

phase 00-boundary
phase 01-setup
phase e10 install
phase e10 roles

# Real graphical session for the synthetic operator (needed for lock, switch and logout).
login=$(g login); echo "$login" > "$EVD/e10-login.txt"
[[ "$login" == session* ]] && hres PASS e10-session operator-plasma-session "$login" || hres BLOCKED e10-session operator-plasma-session "$login"
sleep 10
phase e10 session
phase e10 signer-failure
phase e10 expiry
phase e10 clock-jump
phase e10 stop

# Reboot: key must be zeroized under the delay inhibitor before shutdown; boot starts disarmed.
phase e10 pre-reboot
b0=$("$VM" boot-id)
if "$VM" reboot; then hres PASS e10-reboot rebooted "boot ${b0:0:8} -> $("$VM" boot-id | cut -c1-8)"; phase e10 post-reboot
else hres FAIL e10-reboot rebooted "VM did not come back"; fi

# Suspend to RAM and wake from the host.
collect
phase e10 pre-suspend
phase e10 suspend-now
state=""; for _ in $(seq 40); do sleep 2; state=$($QMP query-status 2>/dev/null); grep -q '"suspended"' <<<"$state" && break; done
echo "qmp status while waiting: $state" >> "$EVD/e10-suspend-host.txt"
if grep -q '"suspended"' <<<"$state"; then
  hres PASS e10-post-suspend guest-entered-suspend "QEMU reports guest status suspended (ACPI S3)"
  sleep 8; $QMP system_wakeup >> "$EVD/e10-suspend-host.txt" 2>&1
  if "$VM" wait-ssh 300; then
    hres PASS e10-post-suspend guest-resumed "woken from the host with system_wakeup; SSH back"
    phase e10 post-suspend
  else
    hres FAIL e10-post-suspend guest-resumed "no SSH after system_wakeup"
    phase e10 suspend-blocked guest-did-not-resume
  fi
else
  hres BLOCKED e10-post-suspend guest-entered-suspend "guest never reached suspended state: $state"
  phase e10 suspend-blocked guest-did-not-enter-suspend
fi
phase e10 hibernate
phase e10 final

hres SKIP scope app-internal-events "vault-lock, engine-failure, cancel, network-down and gateway-failed have no real component in the VM; covered by the offline E10 model"
hres SKIP scope physical-host-sleep "lid, firmware S3 on real hardware and physical-host memory examination are separate tests"
collect || hres FAIL host fetch-results "could not copy guest results"
"$VM" ssh 'sudo journalctl -b --no-pager -o short-precise' > "$EVD/guest-journal-last-boot.log" 2>&1
"$VM" stop
exit 0
