# e2dev.sh target|dev : E2 development-boundary check (run as root in each guest).
#   target: the synthetic marker and lab socket paths must exist; no IP listener for the stubs.
#   dev:    the same paths must be absent, with no shared disk/mount, agent or vsock channel,
#           forwarded credential or network path to the target. Root in the dev guest is used
#           deliberately: it is the strongest position a compromised development guest has.
ROLE="$1"; SUITE="e2dev-$ROLE"
PATHS=(/run/wm006a/ui/sock /run/wm006a/custody/sock /run/wm006a/gateway/sock
       /var/lib/wm006a-signer/marker /var/opt/wm006a/current/bin/wm006a-native /etc/wm006a/peers)
CFG="$EV/e2dev-$ROLE-config.txt"; : > "$CFG"
rec() { { printf '$ %s\n' "$*"; "$@" 2>&1; printf '\n'; } >> "$CFG"; }

# ---- Configuration inventory (both guests) ----
rec hostnamectl
rec cat /etc/machine-id
rec lsblk -o NAME,SIZE,TYPE,SERIAL,MODEL,FSTYPE,UUID,MOUNTPOINTS
rec findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS
rec cat /proc/swaps
rec ip -br addr
rec ip route
rec ss -tulpnH
rec lspci -nn
rec ls -la /dev/virtio-ports /dev/vsock /sys/bus/usb/devices
rec bash -c 'env | grep -E "^(SSH_AUTH_SOCK|SSH_AGENT_PID|GPG_AGENT_INFO|KRB5CCNAME)=" || echo "no agent/credential variables in the admin environment"'

# ---- Boundary checks (both guests) ----
shared=$(findmnt -rn -t 9p,virtiofs,nfs,nfs4,cifs,smb3,fuse.sshfs,fuse.rclone -o TARGET,FSTYPE)
[[ -z "$shared" ]] && pass "no-shared-or-host-service-mounts" "no 9p/virtiofs/NFS/SMB/sshfs mounts" || fail "no-shared-or-host-service-mounts" "$shared"
disks=$(lsblk -dn -o NAME,TYPE,SIZE | awk '$2=="disk" && $1 !~ /^zram/')
[[ $(wc -l <<<"$disks") -eq 1 ]] && pass "single-own-disk" "$(xargs <<<"$disks")" || fail "single-own-disk" "$(tr '\n' ';' <<<"$disks")"
ports=$(ls /dev/virtio-ports 2>/dev/null); [[ -z "$ports" ]] && pass "no-agent-channels" "no virtio-serial ports" || fail "no-agent-channels" "$ports"
# /dev/vsock exists whenever the vsock core module is loaded, even with no transport; what matters
# is whether a virtio-vsock device (virtio ID 0x0013) exists and whether AF_VSOCK can reach anything.
rec bash -c 'ls -l /dev/vsock 2>&1; lsmod | grep -E "vsock|vmw_vsock|vhost" || echo "no vsock modules listed"; for d in /sys/bus/virtio/devices/*; do echo "$d $(cat $d/device)"; done'
vs=$(python3 -I - <<'PY'
import errno, fcntl, glob, socket, struct
ids = [open(f).read().strip() for f in glob.glob("/sys/bus/virtio/devices/*/device")]
dev = "0x0013" in ids
try:
    with open("/dev/vsock") as f:
        cid = struct.unpack("I", fcntl.ioctl(f, 0x7b9, b"\0" * 4))[0]
except OSError as e:
    cid = f"error:{errno.errorcode.get(e.errno, e.errno)}"
res = []
for peer in (2, 3):
    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM); s.settimeout(3)
        s.connect((peer, 22)); res.append(f"cid{peer}=CONNECTED")
    except OSError as e:
        res.append(f"cid{peer}={errno.errorcode.get(e.errno, e.errno) if e.errno else type(e).__name__}")
print(f"virtio_vsock_device={dev} local_cid={cid} {' '.join(res)} virtio_ids={','.join(sorted(ids))}")
PY
)
# A reset, refusal or timeout means some transport answered; only "no transport" errors pass.
if grep -q 'virtio_vsock_device=False' <<<"$vs" && grep -Eq 'cid2=(ENODEV|ENETUNREACH|EADDRNOTAVAIL) cid3=(ENODEV|ENETUNREACH|EADDRNOTAVAIL)' <<<"$vs"; then
  pass "no-vsock" "no vsock transport: $vs"
else fail "no-vsock" "$vs"; fi
agents=$(pgrep -a -f 'spice-vdagent|qemu-ga|vmtoolsd' 2>/dev/null)
[[ -z "$agents" ]] && pass "no-guest-agents-running" "none" || fail "no-guest-agents-running" "$agents"
usb=$(ls /sys/bus/usb/devices 2>/dev/null | grep -v '^usb' | xargs)
[[ -z "$usb" ]] && pass "no-usb-devices" "none" || fail "no-usb-devices" "$usb"

case "$ROLE" in
target)
  runuser -u "$lab_operator" -- python3 "$PROBE" /run/wm006a/ui/sock 'UI_PING\n' 'OK UI+GATEWAY\n' >/dev/null 2>&1
  for p in "${PATHS[@]}"; do
    if [[ "$p" == *sock ]]; then t=$( [[ -S "$p" ]] && echo socket ); else t=$( [[ -e "$p" ]] && echo present ); fi
    [[ -n "$t" ]] && pass "present:$p" "$t $(stat -c '%U:%G %a' "$p")" || fail "present:$p" "missing in the target"
  done
  ipl=$(ss -tulpnH | grep -c 'wm006a')
  [[ "$ipl" -eq 0 ]] && pass "no-ip-listener-for-stubs" "no TCP/UDP socket owned by a wm006a process" || fail "no-ip-listener-for-stubs" "$(ss -tulpnH | grep wm006a)"
  info "target-ip-listeners" "$(ss -tulnH | awk '{print $1, $5}' | sort -u | xargs)" ;;
dev)
  for p in "${PATHS[@]}"; do
    [[ ! -e "$p" && ! -L "$p" ]] && pass "absent:$p" "not present for root in the development guest" || fail "absent:$p" "$(ls -l "$p" 2>&1)"
  done
  for d in /run/wm006a /var/lib/wm006a-signer /var/opt/wm006a /etc/wm006a; do
    [[ ! -e "$d" ]] || fail "absent-dir:$d" "$(ls -ld "$d")"
  done
  found=$(find / /var /etc /usr -xdev \( -path /var/home/tester/wm006a-lab -o -path /var/tmp/wm006a-lab -o -path /proc \) -prune -o -name '*wm006a*' -print 2>/dev/null | head -n 20)
  found_run=$(find /run -name '*wm006a*' 2>/dev/null | head -n 5)
  [[ -z "$found$found_run" ]] && pass "no-lab-paths-anywhere" "no *wm006a* path outside this run's own harness copy" || fail "no-lab-paths-anywhere" "$found $found_run"
  # Credentials: list private keys present (excluding this guest's own SSH host keys) by public fingerprint.
  keys=$(grep -rlsE 'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY' /root /var/home /etc /var/lib /var/tmp 2>/dev/null | grep -v '^/etc/ssh/ssh_host_')
  fps=""; for k in $keys; do fps+="$(ssh-keygen -lf <(ssh-keygen -y -f "$k" 2>/dev/null) 2>/dev/null | awk '{print $2}') "; done
  echo "$fps" > "$EV/e2dev-dev-private-key-fingerprints.txt"
  info "dev-private-keys" "files=[$(xargs <<<"$keys")] fingerprints=[$(xargs <<<"$fps")] (compared with the runner key on the host)"
  # Network: user-mode NAT with restrict=on; nothing on the host gateway, including the target's
  # forwarded SSH port, and nothing outside should answer.
  net=$(python3 -I - <<'PY'
import socket
res = []
for host, port in [("10.0.2.2", 2222), ("10.0.2.2", 2223), ("10.0.2.2", 22), ("10.0.2.2", 5000), ("10.0.2.3", 53), ("1.1.1.1", 443)]:
    s = socket.socket(); s.settimeout(3)
    try:
        s.connect((host, port)); res.append(f"{host}:{port}=CONNECTED")
    except OSError as e:
        res.append(f"{host}:{port}={type(e).__name__}")
    finally:
        s.close()
print(" ".join(res))
PY
)
  grep -q CONNECTED <<<"$net" && fail "no-network-path-to-target" "$net" || pass "no-network-path-to-target" "$net" ;;
esac
