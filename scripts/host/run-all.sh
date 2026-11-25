#!/usr/bin/env bash
# Boot the VM and run every test phase, including the reboots that deployment tests need.
# Never aborts early on a test failure; a phase that cannot run is recorded as FAIL.
set -uo pipefail
source "$(dirname "$0")/common.sh"
VM="$REPO_ROOT/scripts/host/vm.sh"
mkdir -p "$OUT"
HOSTLOG="$OUT/host-results.tsv"; : > "$HOSTLOG"
hostfail() { printf 'FAIL\thost\t%s\t%s\n' "$1" "$2" | tee -a "$HOSTLOG"; }
hostpass() { printf 'PASS\thost\t%s\t%s\n' "$1" "$2" | tee -a "$HOSTLOG"; }

suite() {  # run one test suite inside the VM
  log "=== Suite $1 ==="
  "$VM" ssh "bash ~/kt-tests/run-suite.sh $1" 2>&1 | tee -a "$OUT/suite-output.log"
  local rc=${PIPESTATUS[0]}
  [[ $rc -eq 0 ]] || hostfail "suite-$1-ran" "suite exited with code $rc (ssh or script error)"
}

collect() {  # gather diagnostics for the current boot
  local tag="$1"
  "$VM" ssh "sudo journalctl -b --no-pager -o short-precise" > "$OUT/journal-$tag.log" 2>&1
  "$VM" ssh "rpm-ostree status -v" > "$OUT/rpm-ostree-status-$tag.txt" 2>&1
  "$VM" ssh "systemctl --failed --no-pager; systemd-analyze; systemd-analyze blame | head -30" \
    > "$OUT/systemd-$tag.txt" 2>&1
}

"$VM" start || { hostfail vm-start "qemu failed to start"; exit 0; }
if ! "$VM" wait-ssh 1200; then
  hostfail first-boot "VM never reached SSH; see serial-console.log"
  "$VM" screenshot boot-failure || true
  exit 0
fi
hostpass first-boot "SSH reachable"

"$VM" ssh 'rm -rf ~/kt-tests'; "$VM" scp-to "$REPO_ROOT/tests" kt-tests
"$VM" ssh "echo '${BASE_IMAGE:?}' > ~/kt-tests/base-image"

# Phase 1: first boot
suite 01-baseline
sleep 20; "$VM" screenshot desktop-first-boot
suite 02-systemd
suite 03-flatpak
suite 04-security
suite 05-deploy-stage
collect boot1

# Phase 2: boot into new deployment (layered package + kernel arg)
if "$VM" reboot; then
  hostpass reboot-into-new-deployment "VM rebooted"
  suite 06-deploy-verify
  collect boot2
else
  hostfail reboot-into-new-deployment "VM did not come back after reboot"
fi

# Phase 3: rollback
if "$VM" reboot; then
  hostpass reboot-into-rollback "VM rebooted"
  suite 07-rollback-verify
  sleep 15; "$VM" screenshot desktop-after-rollback
  collect boot3
else
  hostfail reboot-into-rollback "VM did not come back after rollback reboot"
fi

"$VM" ssh 'sudo chown -R tester: /var/tmp/kinoite-tests' 2>/dev/null
rm -rf "$OUT/vm"; "$VM" scp-from /var/tmp/kinoite-tests "$OUT/vm" 2>/dev/null || hostfail fetch-results "could not copy results from VM"
"$VM" stop
exit 0
