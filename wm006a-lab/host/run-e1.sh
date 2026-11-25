#!/usr/bin/env bash
# E1 upgrade and rollback sequence (wm006a/VM-EXPERIMENTS.md) in one disposable Kinoite VM.
#   T0 baseline v1 / OS gen 1      T1 switch to v2        T2 switch back to v1
#   T3 reboot                      T4 rpm-ostree upgrade to OS gen 2 + reboot
#   T5 rpm-ostree rollback + reboot back to gen 1
# After every transition: guest record (deployment, link, hashes, units, sockets, three-identity
# IPC, running binary, persistence file) and a fresh round trip from the real Flatpak app.
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
VM="$REPO_ROOT/scripts/host/vm.sh"
GUI="python3 $REPO_ROOT/wm006a-lab/host/gui.py"
ART="$WORK/wm006a-artifacts"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
HR="$EVD/host-results.tsv"; : > "$HR"
hres() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" | tee -a "$HR"; }
g() { "$VM" ssh "sudo bash ~/wm006a-lab/guest/gui-helper.sh $*" 2>&1; }
phase() { log "=== guest phase $* ==="; "$VM" ssh "sudo bash ~/wm006a-lab/guest/run.sh $*" 2>&1 | tee -a "$EVD/guest-output.log"; }
gv() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<" $2"; }
V1=$(cut -c1-64 "$ART/wm006a-native.sha256"); V2=$(cut -c1-64 "$ART/wm006a-native-v2.sha256")
GL="$EVD/gui-e1.txt"; : > "$GL"

# Fresh Flatpak IPC round trip: sockets listening, signer stopped, app freshly launched, no success
# text before the click, success after it, from a new signer activation running the expected binary.
gui_fresh() {
  local tag="$1" ver="$2" want s0 s1 before mode
  [[ "$ver" == v1 ]] && want=$V1 || want=$V2
  printf '\n## %s (%s)\n' "$tag" "$ver" >> "$GL"
  local login; login=$(g login); echo "$login" >> "$GL"
  if [[ "$login" != session* ]]; then
    for c in gui-roundtrip gui-new-activation gui-active-binary; do hres BLOCKED "e1-$tag" "$c" "no graphical session: $login"; done
    return
  fi
  g sockets-start >> "$GL"; g services-stop >> "$GL"
  g launch >> "$GL"; mode=default
  if ! $GUI wait-text "Test local IPC" 90 "e1-$tag-launch" >> "$GL" 2>&1; then
    g launch WEBKIT_DISABLE_DMABUF_RENDERER=1 >> "$GL"; mode=WEBKIT_DISABLE_DMABUF_RENDERER=1
    if ! $GUI wait-text "Test local IPC" 90 "e1-$tag-launch-fallback" >> "$GL" 2>&1; then
      hres FAIL "e1-$tag" gui-roundtrip "app did not render"; hres BLOCKED "e1-$tag" gui-new-activation "app did not render"
      hres BLOCKED "e1-$tag" gui-active-binary "app did not render"; g quit >/dev/null; return
    fi
  fi
  s0=$(g state); echo "$s0" >> "$GL"
  $GUI absent-text "gateway replied" "e1-$tag-before" >> "$GL" 2>&1; local clean=$?
  before=$(g now)
  $GUI click-text "Test local IPC" "e1-$tag-click" >> "$GL" 2>&1
  if [[ $clean -eq 0 && "$(gv signer_active "$s0")" == inactive ]] && $GUI wait-text "gateway replied" 20 "e1-$tag-reply" >> "$GL" 2>&1; then
    hres PASS "e1-$tag" gui-roundtrip "fresh 'Signer and gateway replied.' from the Flatpak app (renderer: $mode)"
  else hres FAIL "e1-$tag" gui-roundtrip "clean=$clean signer_before=$(gv signer_active "$s0") $(tail -n1 "$GL")"; fi
  s1=$(g state); echo "$s1" >> "$GL"
  if [[ "$(gv signer_active "$s1")" == active && "$(gv signer_inv "$s1")" != "$(gv signer_inv "$s0")" && "$(gv signer_since "$s1")" -gt "$before" ]]; then
    hres PASS "e1-$tag" gui-new-activation "signer invocation $(gv signer_inv "$s1") started by the click"
  else hres FAIL "e1-$tag" gui-new-activation "$s1"; fi
  [[ "$(gv signer_exe "$s1")" == "$want" ]] && hres PASS "e1-$tag" gui-active-binary "running signer is $ver (${want:0:16}…)" \
    || hres FAIL "e1-$tag" gui-active-binary "running $(gv signer_exe "$s1"), expected $ver $want"
  g quit >> "$GL"
}
transition() {  # transition TAG VERSION GENERATION
  phase e1-record "$1" "$2" "$3"
  gui_fresh "$1" "$2"
}
reboot_check() {  # reboot_check TAG
  local b0 b1; b0=$("$VM" boot-id)
  if "$VM" reboot; then b1=$("$VM" boot-id); hres PASS "e1-$1" rebooted "boot ${b0:0:8} -> ${b1:0:8}"; return 0; fi
  hres FAIL "e1-$1" rebooted "VM did not come back"; return 1
}

# ---- Boot, setup (v1), Flatpak, E1 preparation ----
qemu-img snapshot -c clean "$DISK" && hres PASS boundary clean-disk-snapshot "$(qemu-img snapshot -l "$DISK" | tail -n1)"
export VM_EXTRA_ARGS="-device virtio-tablet-pci -device virtio-keyboard-pci -qmp unix:$WORK/qmp.sock,server,nowait"
"$VM" start || { hres FAIL boundary vm-start "qemu failed"; exit 0; }
tr '\0' ' ' < "/proc/$(cat "$PIDF")/cmdline" > "$EVD/qemu-cmdline.txt"
"$VM" wait-ssh 1200 || { hres FAIL boundary first-boot "no SSH"; exit 0; }
stage="$WORK/wm006a-stage"; rm -rf "$stage"; mkdir -p "$stage/ws/native/target/release"
cp -r "$REPO_ROOT/wm006a/systemd" "$REPO_ROOT/wm006a/tests" "$stage/ws/"
cp "$ART/wm006a-native" "$stage/ws/native/target/release/"
cp "$ART/wm006a-native.sha256" "$ART/wm006a-native-v2" "$ART/wm006a-native-v2.sha256" "$stage/"
cp -r "$REPO_ROOT/wm006a-lab/guest" "$stage/"
cp "$ART/org.sinteza.WalletManagerLab.flatpak" "$stage/" 2>/dev/null
"$VM" ssh 'rm -rf ~/wm006a-lab'; "$VM" scp-to "$stage" wm006a-lab
phase 00-boundary
phase 01-setup
phase 03-flatpak
phase e1-prepare

# ---- Transitions ----
transition T0-baseline v1 1

phase e1-switch v2 T1-switch-v2
transition T1-switch-v2 v2 1

phase e1-switch v1 T2-switch-back-v1
transition T2-switch-back-v1 v1 1

if reboot_check T3-reboot; then transition T3-reboot v1 1; fi

phase e1-os upgrade T4-os-upgrade
if reboot_check T4-os-upgrade; then
  phase e1-os verify-upgrade T4-os-upgrade
  transition T4-os-upgrade v1 2
fi

phase e1-os rollback T5-os-rollback
if reboot_check T5-os-rollback; then
  phase e1-os verify-rollback T5-os-rollback
  transition T5-os-rollback v1 1
fi

hres SKIP scope layout-probe-per-version "tests/layout.py is version-independent; it ran at build time"
hres SKIP scope e2-e3 "E2 ran in the validation workflow; E3 not requested"
"$VM" ssh 'sudo chown -R tester: /var/tmp/wm006a-lab' 2>/dev/null
rm -rf "$EVD/guest"; "$VM" scp-from /var/tmp/wm006a-lab "$EVD/guest" 2>/dev/null || hres FAIL host fetch-results "could not copy guest results"
"$VM" ssh 'sudo journalctl -b --no-pager -o short-precise' > "$EVD/guest-journal-last-boot.log" 2>&1
"$VM" stop
exit 0
