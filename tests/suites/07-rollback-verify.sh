# Deployment, part 3: after rollback we must be back on the original deployment.
b0=$(cat "$STATE/booted0" 2>/dev/null)
b2=$(booted_checksum)
check_eq "booted-original-deployment" "$b0" "$b2"
check_not "layered-package-gone" rpm -q htop
check_not "karg-gone" grep -qw 'kinoite.test=1' /proc/cmdline
check "flatpak-survives-rollback" bash -c 'flatpak list --app --columns=application | grep -qx org.kde.kcalc'
check "var-data-survives-rollback" sudo test -s /var/lib/kt/heartbeat
# /etc belongs to each deployment: edits made after the original deployment was created
# are expected to be absent after rolling back to it. Recorded, not asserted.
if [[ -f /etc/systemd/system/kt-heartbeat.service ]]; then info "etc-after-rollback" "test unit still present in /etc"
else info "etc-after-rollback" "test unit absent: /etc reverted with the deployment"; fi
check "system-healthy-after-rollback" bash -c 's=$(timeout 300 systemctl is-system-running --wait); echo $s; [ "$s" = running ] || [ "$s" = degraded ]'
check "sddm-active-after-rollback" wait_for 180 systemctl is-active --quiet sddm

# Cleanup
check "flatpak-uninstall" sudo flatpak uninstall -y --noninteractive org.kde.kcalc
sudo flatpak uninstall -y --noninteractive --unused >/dev/null 2>&1
check "cleanup-pending-deployment" sudo rpm-ostree cleanup -p
