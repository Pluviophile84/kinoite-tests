#!/usr/bin/env bash
# Control the Kinoite VM: start | stop | ssh | scp-to | scp-from | wait-ssh | reboot | screenshot | boot-id
set -euo pipefail
source "$(dirname "$0")/common.sh"

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=15 -o BatchMode=yes)
BOOT_N_FILE="${BOOT_N_FILE:-$WORK/boot-count}"

vm_ssh() { ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" tester@127.0.0.1 "$@"; }
alive() { [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

start() {
  local n=$(( $(cat "$BOOT_N_FILE" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$BOOT_N_FILE"
  log "Starting VM ($VM_CPUS vCPU, ${VM_MEM} MiB)"
  qemu-system-x86_64 -name "$VM_NAME" -machine q35,accel=kvm -cpu host \
    -smp "$VM_CPUS" -m "$VM_MEM" \
    -drive file="$DISK",if=virtio,format=qcow2,cache=writeback,discard=unmap \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22"$VM_NET_OPTS" -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci -vga virtio -display none \
    -monitor unix:"$MON",server,nowait \
    -serial file:"$SERIAL_LOG" \
    -pidfile "$PIDF" -daemonize ${VM_EXTRA_ARGS:-}
}

wait_ssh() {
  local timeout="${1:-900}" t0=$SECONDS
  log "Waiting for SSH (up to ${timeout}s)"
  until vm_ssh true 2>/dev/null; do
    alive || { log "QEMU exited unexpectedly"; return 1; }
    (( SECONDS - t0 > timeout )) && { log "Timed out waiting for SSH"; return 1; }
    sleep 5
  done
  log "SSH up after $((SECONDS - t0))s"
}

boot_id() { vm_ssh cat /proc/sys/kernel/random/boot_id; }

reboot_vm() {
  local old; old=$(boot_id)
  log "Rebooting VM (boot id $old)"
  vm_ssh 'sudo systemctl reboot' || true
  local t0=$SECONDS
  while (( SECONDS - t0 < 900 )); do
    sleep 5
    local cur; cur=$(boot_id 2>/dev/null || true)
    if [[ -n "$cur" && "$cur" != "$old" ]]; then log "VM back after $((SECONDS - t0))s"; return 0; fi
    alive || { log "QEMU exited during reboot"; return 1; }
  done
  log "VM did not come back within 900s"; return 1
}

monitor() { python3 - "$MON" "$1" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.3); s.recv(65536)
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(1.5); s.close()
PY
}

screenshot() {
  local name="$1" ppm="$WORK/$1.ppm"
  monitor "screendump $ppm"
  if command -v convert >/dev/null; then convert "$ppm" "$OUT/$name.png" && rm -f "$ppm"
  else mv "$ppm" "$OUT/$name.ppm"; fi
  log "Screenshot saved: $name"
}

stop() {
  alive || return 0
  log "Shutting down VM"
  vm_ssh 'sudo systemctl poweroff' 2>/dev/null || true
  for _ in $(seq 60); do alive || return 0; sleep 2; done
  monitor quit || kill "$(cat "$PIDF")" 2>/dev/null || true
}

cmd="${1:?usage: vm.sh <command>}"; shift || true
case "$cmd" in
  start) start ;;
  stop) stop ;;
  ssh) vm_ssh "$@" ;;
  scp-to) scp "${SSH_OPTS[@]}" -P "$SSH_PORT" -r "$1" tester@127.0.0.1:"$2" ;;
  scp-from) scp "${SSH_OPTS[@]}" -P "$SSH_PORT" -r tester@127.0.0.1:"$1" "$2" ;;
  wait-ssh) wait_ssh "$@" ;;
  reboot) reboot_vm ;;
  screenshot) screenshot "$1" ;;
  boot-id) boot_id ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac
