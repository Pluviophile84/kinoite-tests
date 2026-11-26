#!/usr/bin/env bash
# Boot-activation check (baseline + enabled) and the guest portion of E3 in one disposable VM.
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
VM="$REPO_ROOT/scripts/host/vm.sh"
ART="$WORK/wm006a-artifacts"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
HR="$EVD/host-results.tsv"; : > "$HR"
hres() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" | tee -a "$HR"; }
phase() { log "=== guest phase $* ==="; "$VM" ssh "sudo bash ~/wm006a-lab/guest/run.sh $*" 2>&1 | tee -a "$EVD/guest-output.log"; }
reboot_check() {
  local b0 b1; b0=$("$VM" boot-id)
  if "$VM" reboot; then b1=$("$VM" boot-id); hres PASS "$1" rebooted "boot ${b0:0:8} -> ${b1:0:8}"; return 0; fi
  hres FAIL "$1" rebooted "VM did not come back"; return 1
}

qemu-img snapshot -c clean "$DISK" && hres PASS boundary clean-disk-snapshot "$(qemu-img snapshot -l "$DISK" | tail -n1)"
"$VM" start || { hres FAIL boundary vm-start "qemu failed"; exit 0; }
tr '\0' ' ' < "/proc/$(cat "$PIDF")/cmdline" > "$EVD/qemu-cmdline.txt"
"$VM" wait-ssh 1200 || { hres FAIL boundary first-boot "no SSH"; exit 0; }
stage="$WORK/wm006a-stage"; rm -rf "$stage"; mkdir -p "$stage/ws/native/target/release"
cp -r "$REPO_ROOT/wm006a/systemd" "$REPO_ROOT/wm006a/tests" "$stage/ws/"
cp "$ART/wm006a-native" "$stage/ws/native/target/release/"
cp "$ART/wm006a-native.sha256" "$stage/"
cp -r "$REPO_ROOT/wm006a-lab/guest" "$REPO_ROOT/wm006a-lab/e3" "$stage/"
"$VM" ssh 'rm -rf ~/wm006a-lab'; "$VM" scp-to "$stage" wm006a-lab

phase 00-boundary
phase 01-setup
phase e3-install

# Boot-activation check: as reviewed (nothing enabled), then with sockets.target.wants links.
if reboot_check boot-baseline; then phase boot-check baseline; fi
phase boot-check enable
if reboot_check boot-enabled; then phase boot-check enabled; fi

# E3 guest portion (sockets are listening from boot).
phase e3

hres SKIP scope physical-console-trust "separate test: physical keyboard routing, secure switching, devices, host console rights, real KDE behaviour"
hres SKIP scope e3-human-dialog-and-vt "separate test: fake guest dialog with a synthetic phrase, seat/VT provenance, input injection"
"$VM" ssh 'sudo chown -R tester: /var/tmp/wm006a-lab' 2>/dev/null
rm -rf "$EVD/guest"; "$VM" scp-from /var/tmp/wm006a-lab "$EVD/guest" 2>/dev/null || hres FAIL host fetch-results "could not copy guest results"
"$VM" ssh 'sudo journalctl -b --no-pager -o short-precise' > "$EVD/guest-journal-last-boot.log" 2>&1
"$VM" stop
exit 0
