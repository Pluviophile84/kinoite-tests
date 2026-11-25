# E2 isolation procedure from wm006a/VM-EXPERIMENTS.md. Positives run first so a stopped
# service is not mistaken for a permission denial.
probe=$PROBE
OPEN="python3 $LAB_SRC/guest/open_probe.py"

run_probe() {  # run_probe NAME runuser-args... -- path message expected
  local name="$1"; shift; local out rc
  out=$("$@" 2>&1); rc=$?
  printf '%s\n$ %s\n%s\n[exit %s]\n\n' "$name" "$*" "$out" "$rc" >> "$EV/e2-probes.txt"
  [[ $rc -eq 0 ]] && pass "$name" "$out" || fail "$name" "exit $rc: $out"
}

# --- round trip and identity probes (verbatim from the procedure) ---
run_probe "ui-ping-operator-roundtrip"     runuser -u "$lab_operator" -- python3 "$probe" /run/wm006a/ui/sock 'UI_PING\n' 'OK UI+GATEWAY\n'
run_probe "custody-ping-custody-uid"       runuser -u wm006a-custody -- python3 "$probe" /run/wm006a/custody/sock 'CUSTODY_PING\n' 'OK CUSTODY\n'
run_probe "ui-rejects-custody-message"     runuser -u "$lab_operator" -- python3 "$probe" /run/wm006a/ui/sock 'CUSTODY_PING\n' 'ERR REQUEST\n'
run_probe "operator-denied-custody-socket" runuser -u "$lab_operator" -- python3 "$probe" /run/wm006a/custody/sock 'CUSTODY_PING\n' dac
run_probe "operator-denied-gateway-socket" runuser -u "$lab_operator" -- python3 "$probe" /run/wm006a/gateway/sock 'GATEWAY_PING\n' dac
run_probe "outsider-denied-ui-socket"      runuser -u "$lab_outsider" -- python3 "$probe" /run/wm006a/ui/sock 'UI_PING\n' dac
run_probe "outsider-with-ui-group-peer-rejected" runuser -u "$lab_outsider" -g wm006a-ui -- python3 "$probe" /run/wm006a/ui/sock 'UI_PING\n' peer

signer_pid=$(systemctl show -p MainPID --value wm006a-signer.service)
gateway_pid=$(systemctl show -p MainPID --value wm006a-gateway.service)
info "service-pids" "signer=$signer_pid gateway=$gateway_pid"
[[ "$signer_pid" -gt 0 ]] && pass "signer-socket-activated" "MainPID $signer_pid" || fail "signer-socket-activated" "signer not running: $(systemctl status --no-pager -n 20 wm006a-signer.service 2>&1 | tail -n 5)"
[[ "$gateway_pid" -gt 0 ]] && pass "gateway-socket-activated" "MainPID $gateway_pid" || fail "gateway-socket-activated" "gateway not running"

# --- evidence the procedure asks for ---
for s in ui custody gateway; do evidence namei.txt namei -l "/run/wm006a/$s/sock"; done
evidence namei.txt namei -l /var/lib/wm006a-signer/marker
evidence identities.txt id "$lab_operator"; evidence identities.txt id "$lab_outsider"
evidence identities.txt id wm006a-signer; evidence identities.txt id wm006a-gateway; evidence identities.txt id wm006a-custody
evidence selinux.txt getenforce
evidence selinux.txt ps -Z -p "$signer_pid,$gateway_pid" -o label,pid,user,group,supgrp,comm
evidence selinux.txt ls -Z /run/wm006a/ui/sock /run/wm006a/custody/sock /run/wm006a/gateway/sock /var/opt/wm006a/versions/v1/bin/wm006a-native
evidence selinux.txt ls -dZ /var/lib/wm006a-signer
evidence selinux.txt bash -c "journalctl -b --no-pager -q | grep -i 'avc:  denied' | grep -i wm006a || echo 'no wm006a AVC denials'"
info "signer-selinux-label" "$(ps -o label= -p "$signer_pid" 2>/dev/null)"
st=$(stat -c '%U %a' /var/lib/wm006a-signer 2>&1); mk=$(stat -c '%U %a' /var/lib/wm006a-signer/marker 2>&1)
[[ "$st" == "wm006a-signer 700" ]] && pass "state-dir-owner-mode" "$st" || fail "state-dir-owner-mode" "$st"
[[ "$mk" == "wm006a-signer 600" ]] && pass "marker-owner-mode" "$mk" || fail "marker-owner-mode" "$mk"
systemd-analyze security --no-pager wm006a-signer.service wm006a-gateway.service > "$EV/systemd-analyze-security.txt" 2>&1
info "systemd-analyze-security" "$(grep -E 'Overall exposure level' "$EV/systemd-analyze-security.txt" | tr '\n' ' ')"
for u in wm006a-signer wm006a-gateway; do
  evidence unit-config.txt systemctl show "$u.service" -p User,SupplementaryGroups,PrivateNetwork,RestrictAddressFamilies,ProtectProc,ProtectSystem,NoNewPrivileges,CapabilityBoundingSet,LimitCORE,SystemCallFilter
done

# --- Files and memory ---
for path in /var/lib/wm006a-signer/marker "/proc/$signer_pid/mem"; do
  test -e "$path" && pass "exists-as-admin:${path/#\/proc\/$signer_pid/\/proc\/SIGNER}" "present" \
                  || fail "exists-as-admin:${path/#\/proc\/$signer_pid/\/proc\/SIGNER}" "missing"
  for who in "$lab_operator" "$lab_outsider"; do
    label="${path/#\/proc\/$signer_pid/\/proc\/SIGNER}"
    out=$(runuser -u "$who" -- $OPEN "$path" 2>&1); rc=$?
    case $rc in
      0) pass "open-denied:$who:$label" "$out" ;;
      2) if test -e "$path"; then pass "open-denied:$who:$label" "$out (hidden from $who; root confirms PID $signer_pid path exists)"
         else fail "open-denied:$who:$label" "$out and missing as root"; fi ;;
      1) fail "open-denied:$who:$label" "open SUCCEEDED" ;;
      *) fail "open-denied:$who:$label" "$out" ;;
    esac
  done
done

# --- IP sockets ---
jl=$(journalctl -b -u wm006a-signer.service --no-pager -o cat 2>&1)
printf '%s\n' "$jl" > "$EV/journal-signer.txt"
grep -Eq '^IPv4: .*(not supported|not permitted|denied)' <<<"$jl" && pass "signer-ipv4-denied" "$(grep -m1 '^IPv4:' <<<"$jl")" || fail "signer-ipv4-denied" "$(grep -m1 '^IPv4' <<<"$jl" || echo 'no IPv4 line in journal')"
grep -Eq '^IPv6: .*(not supported|not permitted|denied)' <<<"$jl" && pass "signer-ipv6-denied" "$(grep -m1 '^IPv6:' <<<"$jl")" || fail "signer-ipv6-denied" "$(grep -m1 '^IPv6' <<<"$jl" || echo 'no IPv6 line in journal')"
ctl=$(runuser -u "$lab_outsider" -- /var/opt/wm006a/current/bin/wm006a-native ip-probe 2>&1)
echo "$ctl" > "$EV/ip-probe-unconfined.txt"
[[ $(grep -c 'socket creation permitted' <<<"$ctl") -eq 2 ]] && pass "unconfined-control-creates-both" "$(tr '\n' ' ' <<<"$ctl")" \
  || fail "unconfined-control-creates-both" "$ctl"
sns=$(readlink "/proc/$signer_pid/ns/net"); hns=$(readlink /proc/1/ns/net)
[[ -n "$sns" && "$sns" != "$hns" ]] && pass "signer-private-netns" "$sns vs host $hns" || fail "signer-private-netns" "signer=$sns host=$hns"
fds=$(ls -l "/proc/$signer_pid/fd" 2>&1 | awk 'NR>1{print $NF}' | sort | uniq -c | tr '\n' ' ')
info "signer-descriptors" "$fds"
evidence ip-sockets.txt ss -xlp
evidence ip-sockets.txt ss -tulpn

# --- Identity escalation configuration ---
groups_op=$(id -nG "$lab_operator")
sudo_op=$(sudo -l -U "$lab_operator" 2>&1)
echo "$sudo_op" > "$EV/sudo-operator.txt"
admin_rules=$(grep -rhs 'adminIdentities\|unix-group:\|unix-user:' /etc/polkit-1/rules.d /usr/share/polkit-1/rules.d 2>/dev/null | sort -u)
echo "$admin_rules" > "$EV/polkit-admin-rules.txt"
if grep -qi 'not allowed to run sudo' <<<"$sudo_op" && ! grep -qw wheel <<<"$groups_op"; then
  pass "operator-no-sudo-path" "groups: $groups_op; sudo: not allowed"
else fail "operator-no-sudo-path" "groups: $groups_op; sudo: $(tr '\n' ' ' <<<"$sudo_op" | cut -c1-200)"; fi
info "polkit-admin-identity" "$(tr '\n' ' ' <<<"$admin_rules" | cut -c1-250)"
[[ "$(uid_of $lab_operator)" != "$(uid_of wm006a-signer)" && "$(uid_of $lab_operator)" != "$(uid_of wm006a-custody)" ]] \
  && pass "uid-separation" "operator=$(uid_of $lab_operator) signer=$(uid_of wm006a-signer) custody=$(uid_of wm006a-custody) gateway=$(uid_of wm006a-gateway)" \
  || fail "uid-separation" "UID overlap"

# --- Logs and crash (last, because it stops the signer) ---
pattern=$(cat /proc/sys/kernel/core_pattern); info "core-pattern" "$pattern"
start_ts=$(date +%s)
systemctl kill --kill-whom=main --signal=ABRT wm006a-signer.service
sleep 4
res=$(systemctl show wm006a-signer.service -p Result -p ExecMainCode -p ExecMainStatus | tr '\n' ' ')
grep -q 'ExecMainStatus=6' <<<"$res" && pass "crash-signal-recorded" "$res" || fail "crash-signal-recorded" "$res"
cd_out=$(coredumpctl info --no-pager "$signer_pid" 2>&1); echo "$cd_out" > "$EV/coredump-signer.txt"
if grep -q 'No coredumps found' <<<"$cd_out"; then pass "crash-no-dump-payload" "no coredump record for PID $signer_pid"
elif grep -Eq 'Storage: (none|.*\(missing\))' <<<"$cd_out" || ! grep -q 'Storage: /' <<<"$cd_out"; then
  pass "crash-no-dump-payload" "metadata only: $(grep -E 'Storage:|Signal:' <<<"$cd_out" | tr '\n' ' ')"
else fail "crash-no-dump-payload" "$(grep -E 'Storage:' <<<"$cd_out")"; fi
journalctl -b -u wm006a-signer.service --since "@$start_ts" --no-pager > "$EV/journal-signer-crash.txt" 2>&1
# The marker is read into this Python process's memory only and never printed.
cmp=$(python3 - <<'PY' 2>&1
import subprocess
marker = open("/var/lib/wm006a-signer/marker", "rb").read()
logs = subprocess.run(["journalctl", "-b", "-o", "export", "--no-pager"], capture_output=True).stdout
dumps = subprocess.run(["coredumpctl", "info", "--no-pager"], capture_output=True).stdout
print(f"marker_in_journal={marker in logs} marker_in_coredump_info={marker in dumps}")
PY
)
grep -q 'marker_in_journal=False marker_in_coredump_info=False' <<<"$cmp" && pass "crash-marker-absent-from-logs" "$cmp" || fail "crash-marker-absent-from-logs" "$cmp"
# Synthetic positive control: an ordinary dumpable process with core dumps allowed.
bash -c 'ulimit -c unlimited; exec sleep 300' & ctl_pid=$!
sleep 1; kill -ABRT "$ctl_pid"; wait "$ctl_pid" 2>/dev/null; sleep 4
ctl_out=$(coredumpctl info --no-pager "$ctl_pid" 2>&1); echo "$ctl_out" > "$EV/coredump-control.txt"
if grep -Eq 'Storage: /.*' <<<"$ctl_out" && ! grep -q '(missing)' <<<"$ctl_out"; then
  pass "collector-positive-control" "$(grep -m1 'Storage:' <<<"$ctl_out")"
else blocked "collector-positive-control" "collector did not store a control dump: $(grep -m1 -E 'Storage:|No coredumps' <<<"$ctl_out")"; fi

# Restore the lab for the Flatpak phase.
systemctl reset-failed wm006a-signer.service 2>/dev/null
systemctl restart wm006a-ui.socket wm006a-custody.socket wm006a-gateway.socket
check "lab-restored-after-crash" runuser -u "$lab_operator" -- python3 "$probe" /run/wm006a/ui/sock 'UI_PING\n' 'OK UI+GATEWAY\n'
