# Guest-side view of the VM boundary (VM-EXPERIMENTS.md preamble). The host side records the
# QEMU command line and the clean disk snapshot separately.
virt=$(systemd-detect-virt --vm 2>&1)
[[ "$virt" == kvm ]] && pass "detect-virt-vm" "$virt (one signal only, see host QEMU record)" || fail "detect-virt-vm" "$virt"
shared=$(findmnt -rn -t 9p,virtiofs,nfs,nfs4,cifs,fuse.sshfs -o TARGET,FSTYPE 2>&1)
[[ -z "$shared" ]] && pass "no-host-folder-mounts" "no 9p/virtiofs/network mounts" || fail "no-host-folder-mounts" "$shared"
ports=$(ls /dev/virtio-ports 2>/dev/null; ls /sys/class/virtio-ports 2>/dev/null)
[[ -z "$ports" ]] && pass "no-agent-channels" "no virtio-serial ports (no clipboard/guest-agent channel)" || fail "no-agent-channels" "$ports"
agents=$(pgrep -a -f 'spice-vdagent|qemu-ga|vmtoolsd' 2>/dev/null)
[[ -z "$agents" ]] && pass "no-guest-agents-running" "none" || fail "no-guest-agents-running" "$agents"
usb=$(ls /sys/bus/usb/devices 2>/dev/null | grep -v '^usb' | tr '\n' ' ')
[[ -z "$usb" ]] && pass "no-usb-devices" "no USB devices attached" || fail "no-usb-devices" "$usb"
evidence boundary.txt systemd-detect-virt --vm
evidence boundary.txt findmnt -rn -o TARGET,SOURCE,FSTYPE
evidence boundary.txt lspci -nn
evidence boundary.txt getenforce
