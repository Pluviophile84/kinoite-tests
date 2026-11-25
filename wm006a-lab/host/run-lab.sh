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

  if [[ $have_gui -eq 1 ]]; then
    launch_and_render() {  # launch_and_render SHOTNAME -> 0 if the roster UI is on screen
      g launch >/dev/null
      if $GUI wait-text "Test local IPC" 90 "$1" > "$EVD/gui-$1.txt" 2>&1; then echo default; return 0; fi
      # Software-rendered VMs sometimes need WebKit's DMA-BUF renderer off; recorded if used.
      g launch WEBKIT_DISABLE_DMABUF_RENDERER=1 >/dev/null
      $GUI wait-text "Test local IPC" 90 "$1-fallback" >> "$EVD/gui-$1.txt" 2>&1 && { echo WEBKIT_DISABLE_DMABUF_RENDERER=1; return 0; }
      return 1
    }
    # (a) Negative control: endpoint absent -> visible error.
    g sockets-stop > "$EVD/gui-control.txt"
    if mode=$(launch_and_render 10-launch-no-endpoint); then
      hres PASS gui flatpak-app-launches "roster rendered (renderer: $mode)"
      $GUI wait-text "LAB-100" 5 11-roster-row100 >/dev/null 2>&1 || $GUI wait-text "LAB-001" 5 11-roster-row1 >/dev/null 2>&1 \
        && hres PASS gui roster-visible "fictional LAB-0xx rows on screen" || hres WARN gui roster-visible "row IDs not read by OCR"
      $GUI click-text "Test local IPC" 12-click-no-endpoint >> "$EVD/gui-control.txt" 2>&1
      $GUI wait-text "IPC unavailable" 20 13-error-no-endpoint >> "$EVD/gui-control.txt" 2>&1 \
        && hres PASS gui endpoint-absent-visible-error "'Local IPC unavailable' shown" \
        || hres FAIL gui endpoint-absent-visible-error "$(tail -n1 "$EVD/gui-control.txt")"
      g quit >/dev/null
      # (b) Positive: sockets listening, signer and gateway stopped, so only the click can start them.
      g sockets-start >/dev/null; g services-stop >/dev/null
      before=$(g now); state0=$(g state)
      if launch_and_render 20-launch-with-endpoint >/dev/null; then
        $GUI click-text "Test local IPC" 21-click >> "$EVD/gui-roundtrip.txt" 2>&1
        if $GUI wait-text "gateway replied" 20 22-reply >> "$EVD/gui-roundtrip.txt" 2>&1; then
          hres PASS gui flatpak-app-reaches-signer "'Signer and gateway replied.' shown"
        else hres FAIL gui flatpak-app-reaches-signer "$(tail -n1 "$EVD/gui-roundtrip.txt")"; fi
        state1=$(g state); since=$(sed -n 's/.*signer_since=\([0-9]*\).*/\1/p' <<<"$state1")
        echo "before_us=$before state0=[$state0] state1=[$state1]" >> "$EVD/gui-roundtrip.txt"
        [[ -n "$since" && "$since" -gt "$before" ]] && grep -q 'wm006a-gateway.service=active' <<<"$state1" \
          && hres PASS gui signer-activated-by-gui-request "signer and gateway were stopped before the click and socket-activated after it" \
          || hres FAIL gui signer-activated-by-gui-request "$state1"
        # (c) Reconnection after the admin restarts the UI socket and signer.
        g restart-ui >> "$EVD/gui-reconnect.txt"; sleep 3
        $GUI click-text "Test local IPC" 30-click-after-restart >> "$EVD/gui-reconnect.txt" 2>&1
        $GUI wait-text "gateway replied" 20 31-reply-after-restart >> "$EVD/gui-reconnect.txt" 2>&1 \
          && hres PASS gui reconnect-after-socket-restart "reply after restarting wm006a-ui.socket + signer" \
          || hres FAIL gui reconnect-after-socket-restart "$(tail -n1 "$EVD/gui-reconnect.txt")"
      else hres FAIL gui flatpak-app-reaches-signer "app did not render on second launch"; fi
      g quit >/dev/null
    else
      hres FAIL gui flatpak-app-launches "roster never appeared on screen: $(tail -n1 "$EVD/gui-10-launch-no-endpoint.txt")"
      for c in endpoint-absent-visible-error flatpak-app-reaches-signer reconnect-after-socket-restart; do hres BLOCKED gui "$c" "app did not render"; done
    fi
    g applog > "$EVD/gui-app-journal.txt"
  else
    for c in flatpak-app-launches flatpak-app-reaches-signer reconnect-after-socket-restart; do hres BLOCKED gui "$c" "no graphical session"; done
  fi
else
  for c in flatpak-install flatpak-sandbox-checks flatpak-app-launches flatpak-app-reaches-signer; do hres BLOCKED flatpak "$c" "bundle was not built"; done
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
