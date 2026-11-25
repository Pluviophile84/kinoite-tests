# Shared settings for host-side scripts (sourced, not executed).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${WORK:-/mnt/kt}"
OUT="${OUT:-$WORK/results}"
DISK="$WORK/disk.qcow2"
KEY="$WORK/id_ed25519"
SSH_PORT="${SSH_PORT:-2222}"
MON="$WORK/qemu-monitor.sock"
PIDF="$WORK/qemu.pid"
VM_CPUS="${VM_CPUS:-4}"
VM_MEM="${VM_MEM:-10240}"

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }
