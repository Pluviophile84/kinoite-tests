#!/usr/bin/env bash
# Boot a fresh Kinoite VM and run the 006A lab phases:
#   boundary -> setup -> E2 isolation (signer/gateway round trip first) -> Flatpak install ->
#   Flatpak sandbox checks -> real Flatpak app in a Plasma session reaching the signer.
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
VM="$REPO_ROOT/scripts/host/vm.sh"
GUI="python3 $REPO_ROOT/wm006a-lab/host/gui.py"
ART="$WORK/wm006a-artifacts"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
HR="$EVD/host-results.tsv"; : > "$HR"
hres() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" | tee -a "$HR"; }
g() { "$VM" ssh "sudo bash ~/wm006a-lab/guest/gui-helper.sh $*" 2>&1; }
phase() { log "=== guest phase $1 ==="; "$VM" ssh "sudo bash ~/wm006a-lab/guest/run.sh $1" 2>&1 | tee -a "$EVD/guest-output.log"; }

# Disposable disk with a clean (offline) snapshot, no shared folders, agents or passthrough.
qemu-img snapshot -c clean "$DISK" && hres PASS boundary clean-disk-snapshot "$(qemu-img snapshot -l "$DISK" | tail -n1)"
export VM_EXTRA_ARGS="-device virtio-tablet-pci -device virtio-keyboard-pci -qmp unix:$WORK/qmp.sock,server,nowait"
"$VM" start || { hres FAIL boundary vm-start "qemu failed"; exit 0; }
cmdline=$(tr '\0' ' ' < "/proc/$(cat "$PIDF")/cmdline"); echo "$cmdline" > "$EVD/qemu-cmdline.txt"
if grep -Eq -- '-virtfs|-fsdev|vhost-user-fs|usb-host|spicevmc|vdagent|-chardev|vfio|-spice' <<<"$cmdline"; then
  hres FAIL boundary hypervisor-config "sharing/passthrough option present"
else hres PASS boundary hypervisor-config "no shared folders, clipboard/agent channels, USB or PCI passthrough; user-mode NAT, SSH on 127.0.0.1 only"; fi
"$VM" wait-ssh 1200 || { hres FAIL boundary first-boot "no SSH"; exit 0; }
fwd=$("$VM" ssh 'echo ${SSH_AUTH_SOCK:-none}')
[[ "$fwd" == none ]] && hres PASS boundary no-credential-forwarding "no SSH agent forwarded" || hres FAIL boundary no-credential-forwarding "$fwd"

# Stage the 006A directory exactly as the procedure expects (systemd/, tests/, native/target/release/).
stage="$WORK/wm006a-stage"; rm -rf "$stage"; mkdir -p "$stage/ws/native/target/release"
cp -r "$REPO_ROOT/wm006a/systemd" "$REPO_ROOT/wm006a/tests" "$stage/ws/"
cp "$ART/wm006a-native" "$stage/ws/native/target/release/"
cp "$ART/wm006a-native.sha256" "$stage/"
cp -r "$REPO_ROOT/wm006a-lab/guest" "$stage/"
[[ -f "$ART/org.sinteza.WalletManagerLab.flatpak" ]] && cp "$ART/org.sinteza.WalletManagerLab.flatpak" "$stage/"
"$VM" ssh 'rm -rf ~/wm006a-lab'; "$VM" scp-to "$stage" wm006a-lab

phase 00-boundary
phase 01-setup
phase 02-isolation

if [[ -f "$stage/org.sinteza.WalletManagerLab.flatpak" ]]; then
  phase 03-flatpak
  # ---- Graphical session for the synthetic operator ----
  login=$(g login); lrc=$?; echo "$login" > "$EVD/gui-login.txt"
  if [[ $lrc -eq 0 && "$login" == session* ]]; then
    hres PASS gui operator-plasma-session "$login"; have_gui=1
  else
    hres BLOCKED gui operator-plasma-session "$login"; have_gui=0
  fi
  sleep 20; $GUI shot 00-desktop >/dev/null 2>&1
  phase 04-sandbox

  GUI_REQ="flatpak-app-launches baseline-roundtrip endpoint-absent-visible-error restore-socket-signer-stopped fresh-success-after-restore new-signer-activation same-window-throughout gui-selinux-labels"
  if [[ $have_gui -eq 1 ]]; then
    gl="$EVD/gui-sequence.txt"; : > "$gl"
    st() { g state | tee -a "$gl"; }                       # one line of key=value pairs
    gv() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<" $2"; }    # gv KEY STATE_LINE
    step() { printf '\n## %s\n' "$*" >> "$gl"; }
    launch_and_render() {
      g launch >> "$gl"
      if $GUI wait-text "Test local IPC" 90 "$1" >> "$gl" 2>&1; then echo default; return 0; fi
      g launch WEBKIT_DISABLE_DMABUF_RENDERER=1 >> "$gl"   # software-rendered VM fallback, recorded
      $GUI wait-text "Test local IPC" 90 "$1-fallback" >> "$gl" 2>&1 && { echo WEBKIT_DISABLE_DMABUF_RENDERER=1; return 0; }
      return 1
    }
    # One Flatpak window for the whole sequence. Start: sockets listening, signer/gateway stopped.
    g sockets-start >> "$gl"; g services-stop >> "$gl"
    step "S1 launch the Flatpak app once"
    if mode=$(launch_and_render 10-launch); then
      s1=$(st); app_pid=$(gv app_pid "$s1"); app_inv=$(gv app_inv "$s1")
      hres PASS gui flatpak-app-launches "roster rendered (renderer: $mode), app pid $app_pid"
      { $GUI wait-text "LAB-100" 5 11-roster >/dev/null 2>&1 || $GUI wait-text "LAB-001" 5 11-roster >/dev/null 2>&1; } \
        && hres PASS gui roster-visible "fictional LAB-0xx rows on screen" || hres WARN gui roster-visible "row IDs not read by OCR"
      same_window() { local now; now=$(st); [[ "$(gv app_pid "$now")" == "$app_pid" && "$(gv app_inv "$now")" == "$app_inv" && "$(gv app_active "$now")" == active ]]; }
      ok_window=1

      step "S2 baseline click with the endpoint present"
      $GUI click-text "Test local IPC" 20-click-baseline >> "$gl" 2>&1
      if $GUI wait-text "gateway replied" 20 21-reply-baseline >> "$gl" 2>&1; then
        s2=$(st); inv1=$(gv signer_inv "$s2")
        hres PASS gui baseline-roundtrip "reply shown; signer activation $inv1"
      else hres FAIL gui baseline-roundtrip "$(tail -n1 "$gl")"; s2=$(st); inv1=$(gv signer_inv "$s2"); fi
      same_window || ok_window=0

      step "S3 stop the endpoint, click in the same window"
      g sockets-stop >> "$gl"; s3=$(st)
      if [[ "$(gv ui_sock "$s3")" == absent ]]; then
        $GUI click-text "Test local IPC" 30-click-no-endpoint >> "$gl" 2>&1
        if $GUI wait-text "IPC unavailable" 20 31-error-no-endpoint >> "$gl" 2>&1 \
           && $GUI absent-text "gateway replied" 32-error-check >> "$gl" 2>&1; then
          hres PASS gui endpoint-absent-visible-error "'Local IPC unavailable' shown, success text gone"
        else hres FAIL gui endpoint-absent-visible-error "$(tail -n1 "$gl")"; fi
      else hres FAIL gui endpoint-absent-visible-error "socket still present after stop: $s3"; fi
      same_window || ok_window=0

      step "S4 restore the socket with the signer stopped, click again"
      g sockets-start >> "$gl"; s4=$(st)
      if [[ "$(gv ui_sock "$s4")" == socket && "$(gv signer_active "$s4")" == inactive && "$(gv ui_socket "$s4")" == active ]]; then
        hres PASS gui restore-socket-signer-stopped "ui socket listening, signer inactive before the click"
      else hres FAIL gui restore-socket-signer-stopped "$s4"; fi
      $GUI absent-text "gateway replied" 40-before-restore-click >> "$gl" 2>&1; pre_clean=$?
      before=$(g now)
      $GUI click-text "Test local IPC" 41-click-after-restore >> "$gl" 2>&1
      if [[ $pre_clean -eq 0 ]] && $GUI wait-text "gateway replied" 20 42-reply-after-restore >> "$gl" 2>&1; then
        hres PASS gui fresh-success-after-restore "screen showed no success before the click; 'Signer and gateway replied.' after it"
      else hres FAIL gui fresh-success-after-restore "pre_clean=$pre_clean $(tail -n1 "$gl")"; fi
      s5=$(st); inv2=$(gv signer_inv "$s5"); since2=$(gv signer_since "$s5")
      if [[ "$(gv signer_active "$s5")" == active && -n "$inv2" && "$inv2" != "$inv1" && "${since2:-0}" -gt "$before" && "$(gv gateway_active "$s5")" == active ]]; then
        hres PASS gui new-signer-activation "new invocation $inv2 (was $inv1), activated after the click"
      else hres FAIL gui new-signer-activation "inv1=$inv1 state=$s5 before_us=$before"; fi
      same_window || ok_window=0
      [[ $ok_window -eq 1 ]] && hres PASS gui same-window-throughout "one app process ($app_pid) and unit invocation for S1-S4" \
        || hres FAIL gui same-window-throughout "app process or invocation changed; see gui-sequence.txt"

      lbl_s=$(gv signer_label "$s5"); lbl_g=$(gv gateway_label "$s5")
      [[ "$lbl_s" == *:*:*:* && "$lbl_g" == *:*:*:* ]] && hres PASS gui gui-selinux-labels "signer=$lbl_s gateway=$lbl_g" \
        || hres FAIL gui gui-selinux-labels "signer=$lbl_s gateway=$lbl_g"
      g quit >> "$gl"
    else
      hres FAIL gui flatpak-app-launches "roster never appeared on screen: $(tail -n1 "$gl")"
      for c in ${GUI_REQ#flatpak-app-launches }; do hres BLOCKED gui "$c" "app did not render"; done
    fi
    g applog > "$EVD/gui-app-journal.txt"
  else
    for c in $GUI_REQ; do hres BLOCKED gui "$c" "no graphical session"; done
  fi
else
  for c in flatpak-install flatpak-sandbox-checks flatpak-app-launches; do hres BLOCKED flatpak "$c" "bundle was not built"; done
fi

# Not in this run's scope (recorded so nothing is silently omitted).
hres SKIP scope development-guest-boundary "second guest not created in this run"
hres SKIP scope e1-upgrade-rollback "not requested in this run"
hres SKIP scope e3-approval-experiment "not requested in this run"
hres SKIP scope launch-measurements "not requested in this run"

"$VM" ssh 'sudo chown -R tester: /var/tmp/wm006a-lab' 2>/dev/null
rm -rf "$EVD/guest"; "$VM" scp-from /var/tmp/wm006a-lab "$EVD/guest" 2>/dev/null || hres FAIL host fetch-results "could not copy guest results"
"$VM" ssh 'sudo journalctl -b --no-pager -o short-precise' > "$EVD/guest-journal.log" 2>&1
"$VM" stop
exit 0
