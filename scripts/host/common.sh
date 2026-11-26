# Shared settings for host-side scripts (sourced, not executed).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${WORK:-/mnt/kt}"
OUT="${OUT:-$WORK/results}"
DISK="${DISK:-$WORK/disk.qcow2}"
KEY="$WORK/id_ed25519"
SSH_PORT="${SSH_PORT:-2222}"
MON="${MON:-$WORK/qemu-monitor.sock}"
PIDF="${PIDF:-$WORK/qemu.pid}"
VM_NAME="${VM_NAME:-kinoite}"
SERIAL_LOG="${SERIAL_LOG:-$OUT/serial-console.log}"
VM_NET_OPTS="${VM_NET_OPTS:-}"   # extra user-mode netdev options, e.g. ",restrict=on"
VM_CPUS="${VM_CPUS:-4}"
VM_MEM="${VM_MEM:-10240}"

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }
