# Deployment, part 2: after reboot we must be on the new deployment; then request a rollback.
b0=$(cat "$STATE/booted0" 2>/dev/null)
b1=$(booted_checksum)
echo "$b1" > "$STATE/booted1"
[[ -n "$b0" && "$b1" != "$b0" ]] && pass "booted-new-deployment" "${b0:0:12} -> ${b1:0:12}" \
  || fail "booted-new-deployment" "still on ${b1:0:12}"
check "layered-package-present" rpm -q htop
check "karg-applied" grep -qw 'kinoite.test=1' /proc/cmdline
check "rollback-target-kept" bash -c "n=\$(rpm-ostree status --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"deployments\"]))'); echo deployments=\$n; [ \$n -ge 2 ]"

# /etc and /var state carried into the new deployment
check "etc-unit-carried-over" test -f /etc/systemd/system/kt-heartbeat.service
check "timer-enabled-after-reboot" systemctl is-enabled --quiet kt-heartbeat.timer
check "timer-fired-after-reboot" wait_for 90 bash -c 'boot=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) )); last=$(sudo tail -n1 /var/lib/kt/heartbeat); [ "$last" -ge "$boot" ]'
check "flatpak-survives-deployment" bash -c 'flatpak list --app --columns=application | grep -qx org.kde.kcalc'
check "user-linger-persisted" test -e /var/lib/systemd/linger/tester
check "sddm-active-after-reboot" wait_for 180 systemctl is-active --quiet sddm

check "rollback-request" sudo rpm-ostree rollback
