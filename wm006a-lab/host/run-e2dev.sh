#!/usr/bin/env bash
# E2 development-boundary check: a target guest (wm006a set up) and a separate development guest
# running side by side on the runner. Records both hypervisor configurations and checks, from the
# host and from inside each guest, that the development guest has no path to the target.
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
VM="$REPO_ROOT/scripts/host/vm.sh"
ART="$WORK/wm006a-artifacts"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
HR="$EVD/host-results.tsv"; : > "$HR"
HC="$EVD/e2dev-hypervisor-config.txt"; : > "$HC"
hres() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" | tee -a "$HR"; }
DEV_DISK="$WORK/dev.qcow2"
tvm() { VM_NAME=kinoite-target VM_MEM=6144 VM_CPUS=2 "$VM" "$@"; }
dvm() { DISK="$DEV_DISK" PIDF="$WORK/dev.pid" MON="$WORK/dev-monitor.sock" SSH_PORT=2223 VM_NAME=kinoite-dev \
        SERIAL_LOG="$OUT/serial-console-dev.log" BOOT_N_FILE="$WORK/dev-boot-count" VM_NET_OPTS=",restrict=on" \
        VM_MEM=4096 VM_CPUS=2 "$VM" "$@"; }
tphase() { log "=== target: $* ==="; tvm ssh "sudo bash ~/wm006a-lab/guest/run.sh $*" 2>&1 | tee -a "$EVD/guest-output.log"; }
dphase() { log "=== dev: $* ==="; dvm ssh "sudo bash ~/wm006a-lab/guest/run.sh $*" 2>&1 | tee -a "$EVD/guest-output-dev.log"; }
hc() { { printf '$ %s\n' "$*"; "$@" 2>&1; printf '\n'; } >> "$HC"; }

# ---- Disposable disks: an independent full copy for the development guest, made before first boot ----
cp --sparse=always "$DISK" "$DEV_DISK"
for d in "$DISK" "$DEV_DISK"; do qemu-img snapshot -c clean "$d"; hc qemu-img info "$d"; hc stat -c '%n inode=%i size=%s' "$d"; done
ti=$(stat -c %i "$DISK"); di=$(stat -c %i "$DEV_DISK")
tb=$(qemu-img info --output=json "$DISK" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("backing-filename","none"))')
db=$(qemu-img info --output=json "$DEV_DISK" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("backing-filename","none"))')
[[ "$ti" != "$di" && "$tb" == none && "$db" == none ]] && hres PASS e2dev-host disks-independent "separate files (inodes $ti, $di), no backing chain; clean snapshot on each" \
  || hres FAIL e2dev-host disks-independent "inodes $ti/$di backing $tb/$db"

tvm start || { hres FAIL e2dev-host target-start "qemu failed"; exit 0; }
dvm start || { hres FAIL e2dev-host dev-start "qemu failed"; exit 0; }
TP=$(cat "$PIDF"); DP=$(cat "$WORK/dev.pid")
for n in target:"$TP" dev:"$DP"; do
  echo "== ${n%%:*} QEMU command line" >> "$HC"; tr '\0' ' ' < "/proc/${n#*:}/cmdline" >> "$HC"; printf '\n\n' >> "$HC"
done
tvm wait-ssh 1200 || { hres FAIL e2dev-host target-boot "no SSH"; exit 0; }
dvm wait-ssh 1200 || { hres FAIL e2dev-host dev-boot "no SSH"; exit 0; }
hres PASS e2dev-host both-guests-running "target pid $TP (ssh 127.0.0.1:2222), dev pid $DP (ssh 127.0.0.1:2223), concurrently"

# ---- Hypervisor-level checks ----
tcmd=$(tr '\0' ' ' < "/proc/$TP/cmdline"); dcmd=$(tr '\0' ' ' < "/proc/$DP/cmdline")
bad='-virtfs|-fsdev|vhost-user-fs|vhost-vsock|vsock|usb-host|spicevmc|vdagent|-chardev|vfio|-spice|-vnc|smb='
for n in target dev; do c=tcmd; [[ $n == dev ]] && c=dcmd
  if grep -Eq -- "$bad" <<<"${!c}"; then hres FAIL e2dev-host "$n-no-sharing-options" "$(grep -Eo -- "$bad" <<<"${!c}" | xargs)"
  else hres PASS e2dev-host "$n-no-sharing-options" "no shared folders, vsock, agent/clipboard channels, remote display, USB or PCI passthrough"; fi
done
grep -q 'restrict=on' <<<"$dcmd" && hres PASS e2dev-host dev-network-restricted "user-mode NAT with restrict=on: no host or outside access; only its own SSH forward" \
  || hres FAIL e2dev-host dev-network-restricted "restrict=on missing"
for n in target:"$TP":"$DISK":"$DEV_DISK" dev:"$DP":"$DEV_DISK":"$DISK"; do
  IFS=: read -r name pid own other <<<"$n"
  fds=$(for f in /proc/"$pid"/fd/*; do readlink "$f"; done 2>/dev/null | grep -E '\.qcow2' | sort -u | xargs)
  echo "== $name QEMU open disk files: $fds" >> "$HC"
  [[ "$fds" == "$own" ]] && hres PASS e2dev-host "$name-opens-only-own-disk" "$fds" || hres FAIL e2dev-host "$name-opens-only-own-disk" "open: $fds (other disk: $other)"
done
hc ss -tlnp
fw=$(ss -tlnpH | grep -E 'qemu' | awk '{print $4}' | sort | xargs)
[[ "$fw" == "127.0.0.1:2222 127.0.0.1:2223" ]] && hres PASS e2dev-host host-forwards-loopback-only "$fw (one SSH forward per guest, host loopback only)" \
  || hres FAIL e2dev-host host-forwards-loopback-only "$fw"
[[ -z "${SSH_AUTH_SOCK:-}" ]] && hres PASS e2dev-host no-agent-on-runner "no SSH agent on the runner to forward" || hres FAIL e2dev-host no-agent-on-runner "$SSH_AUTH_SOCK"
for n in target dev; do v=tvm; [[ $n == dev ]] && v=dvm
  a=$($v ssh 'echo "${SSH_AUTH_SOCK:-none}"')
  [[ "$a" == none ]] && hres PASS e2dev-host "$n-no-credential-forwarding" "no agent socket in the admin SSH session (BatchMode, no -A)" || hres FAIL e2dev-host "$n-no-credential-forwarding" "$a"
done

# ---- Target: fixture set up; development guest: only the boundary scripts, nothing from the target ----
stage="$WORK/wm006a-stage"; rm -rf "$stage"; mkdir -p "$stage/ws/native/target/release"
cp -r "$REPO_ROOT/wm006a/systemd" "$REPO_ROOT/wm006a/tests" "$stage/ws/"
cp "$ART/wm006a-native" "$stage/ws/native/target/release/"; cp "$ART/wm006a-native.sha256" "$stage/"
cp -r "$REPO_ROOT/wm006a-lab/guest" "$stage/"
dstage="$WORK/wm006a-dev-stage"; rm -rf "$dstage"; mkdir -p "$dstage/guest"
cp "$REPO_ROOT"/wm006a-lab/guest/{lib.sh,run.sh,e2dev.sh} "$dstage/guest/"
tvm ssh 'rm -rf ~/wm006a-lab'; tvm scp-to "$stage" wm006a-lab
dvm ssh 'rm -rf ~/wm006a-lab'; dvm scp-to "$dstage" wm006a-lab

tphase 01-setup
tphase e2dev target
dphase e2dev dev

# Runner key must not exist inside the development guest (compared by public fingerprint).
runner_fp=$(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')
dvm ssh 'sudo cat /var/tmp/wm006a-lab/evidence/e2dev-dev-private-key-fingerprints.txt' > "$EVD/dev-fps.txt" 2>/dev/null
grep -q -- "$runner_fp" "$EVD/dev-fps.txt" && hres FAIL e2dev-host dev-holds-no-runner-credential "runner private key found in dev guest" \
  || hres PASS e2dev-host dev-holds-no-runner-credential "runner key ${runner_fp:0:20}… not among private keys in the dev guest ($(xargs < "$EVD/dev-fps.txt" | wc -w) found, all its own)"

hres SKIP scope physical-host-checks "E3 physical-console trust and real-host hypervisor settings are separate tests"

# ---- Collect both guests ----
tvm ssh 'sudo chown -R tester: /var/tmp/wm006a-lab' 2>/dev/null; rm -rf "$EVD/guest"; tvm scp-from /var/tmp/wm006a-lab "$EVD/guest" 2>/dev/null
dvm ssh 'sudo chown -R tester: /var/tmp/wm006a-lab' 2>/dev/null; rm -rf "$EVD/guest-dev"; dvm scp-from /var/tmp/wm006a-lab "$EVD/guest-dev" 2>/dev/null
cat "$EVD/guest-dev/results.tsv" >> "$HR" 2>/dev/null || hres FAIL e2dev-host fetch-dev-results "could not copy dev guest results"
[[ -f "$EVD/guest/results.tsv" ]] || hres FAIL e2dev-host fetch-target-results "could not copy target results"
tvm stop; dvm stop
exit 0
