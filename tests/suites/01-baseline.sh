# Baseline: is this really a booted Kinoite system with a working desktop stack?
. /etc/os-release
check_eq "os-variant-is-kinoite" "kinoite" "${VARIANT_ID:-}"
info "os-version" "$PRETTY_NAME (kernel $(uname -r))"
check "ostree-booted" test -e /run/ostree-booted
check "rpm-ostree-status" rpm-ostree status
info "booted-image" "$(rpm-ostree status --json | python3 -c 'import json,sys
d=[x for x in json.load(sys.stdin)["deployments"] if x.get("booted")][0]
print(d.get("container-image-reference","?"), d.get("version","?"))')"
check "kvm-guest" bash -c 'systemd-detect-virt | grep -qx kvm && systemd-detect-virt'
check_eq "default-target" "graphical.target" "$(systemctl get-default)"
check "plasma-installed" rpm -q plasma-workspace
check "display-manager-active" bash -c 'wait_dm() { for i in $(seq 60); do systemctl is-active --quiet display-manager.service && return 0; sleep 3; done; return 1; }; wait_dm; r=$?; echo "$(basename "$(readlink -f /etc/systemd/system/display-manager.service)") $(systemctl is-active display-manager.service)"; exit $r'
check "root-is-composefs-or-ro" bash -c 'findmnt -no FSTYPE,OPTIONS / | tee /dev/stderr | grep -Eq "overlay|composefs|(^|,)ro(,|$)"'

# The disk was built from a local test layer; point the deployment's origin at the
# official upstream image (no new deployment is created) so update checks use the registry.
check "origin-set-upstream" sudo unshare -m sh -c "mount -o remount,rw /sysroot && bootc switch --mutate-in-place --transport registry $(cat ~/kt-tests/base-image)"
info "origin" "$(rpm-ostree status --json | python3 -c 'import json,sys
print([x for x in json.load(sys.stdin)["deployments"] if x.get("booted")][0].get("container-image-reference","?"))')"

# Update check against the upstream image registry (metadata only, no full download).
out=$(timeout 600 sudo rpm-ostree upgrade --check 2>&1); rc=$?
case $rc in
  0)  pass "upgrade-check" "update available: $(tail -n1 <<<"$out")" ;;
  77) pass "upgrade-check" "no update available" ;;
  *)  fail "upgrade-check" "exit $rc: $(tail -n2 <<<"$out")" ;;
esac
booted_checksum > "$STATE/booted0"
deployment_count > "$STATE/deployments0"
