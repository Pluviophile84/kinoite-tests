# E1/E2 setup, following wm006a/VM-EXPERIMENTS.md as the guest admin, from the 006A directory.
cd "$WS" || { fail "workspace-present" "$WS missing"; return 0; }

# Synthetic accounts: a non-admin graphical operator and an unprivileged outsider.
for u in "$lab_operator" "$lab_outsider"; do
  id "$u" >/dev/null 2>&1 || useradd -m -c "006A synthetic ${u#lab_}" "$u"
done
# Throwaway random password (never printed) so the account is not locked for the graphical login.
echo "$lab_operator:$(head -c 18 /dev/urandom | base64)" | chpasswd
[[ "$(uid_of $lab_operator)" != "$(uid_of $lab_outsider)" ]] && pass "accounts-distinct" "$(id $lab_operator) / $(id $lab_outsider)" \
  || fail "accounts-distinct" "same UID"
if id -nG "$lab_operator" | grep -qw wheel || id -nG "$lab_outsider" | grep -qw wheel; then
  fail "accounts-not-wheel" "a lab account is in wheel"
else pass "accounts-not-wheel" "neither account is in wheel"; fi

# Provenance: binary in the guest must match the one built and hashed on the runner.
expected=$(cut -d' ' -f1 "$LAB_SRC/wm006a-native.sha256")
actual=$(sha256sum native/target/release/wm006a-native | cut -d' ' -f1)
[[ "$expected" == "$actual" ]] && pass "binary-provenance" "sha256 $actual" || fail "binary-provenance" "expected $expected got $actual"
evidence setup.txt readelf -d native/target/release/wm006a-native

# --- verbatim setup block from VM-EXPERIMENTS.md ---
setup_log="$EV/setup.txt"
{
set -x
systemd-detect-virt --vm
id "$lab_operator"
id "$lab_outsider"

install -Dm644 systemd/wm006a.conf /etc/sysusers.d/wm006a.conf
systemd-sysusers /etc/sysusers.d/wm006a.conf
usermod -aG wm006a-ui "$lab_operator"
install -d -o root -g root -m0755 /var/opt/wm006a/versions/v1/bin
install -o root -g root -m0755 native/target/release/wm006a-native /var/opt/wm006a/versions/v1/bin/
ln -s versions/v1 /var/opt/wm006a/current
install -d -o root -g root -m0755 /etc/wm006a
printf 'WM006A_OPERATOR_UID=%s\nWM006A_CUSTODY_UID=%s\nWM006A_SIGNER_UID=%s\n' \
  "$(id -u "$lab_operator")" "$(id -u wm006a-custody)" "$(id -u wm006a-signer)" > /etc/wm006a/peers
chmod 0644 /etc/wm006a/peers
install -t /etc/systemd/system -o root -g root -m0644 systemd/*.socket systemd/*.service
install -Dm755 tests/socket_probe.py /var/tmp/wm006a-socket-probe.py
systemd-analyze verify /etc/systemd/system/wm006a-*.socket /etc/systemd/system/wm006a-*.service
echo "verify_exit=$?"
systemctl daemon-reload
systemctl start wm006a-ui.socket wm006a-custody.socket wm006a-gateway.socket
set +x
} >> "$setup_log" 2>&1
# --- end verbatim block ---

grep -q '^verify_exit=0' "$setup_log" && pass "units-verify" "systemd-analyze verify exit 0" \
  || fail "units-verify" "$(grep -B3 '^verify_exit' "$setup_log" | tr '\n' ' ')"
for s in ui custody gateway; do
  check "socket-$s-listening" systemctl is-active --quiet "wm006a-$s.socket"
done
getent passwd wm006a-custody | grep -Eq ':(/usr)?/s?bin/nologin$' && pass "custody-nologin" "$(getent passwd wm006a-custody | cut -d: -f7)" \
  || fail "custody-nologin" "$(getent passwd wm006a-custody)"
check "operator-in-ui-group" bash -c "id -nG $lab_operator | grep -qw wm006a-ui"
check "outsider-not-in-lab-groups" bash -c "! id -nG $lab_outsider | grep -Eqw 'wm006a-(ui|custody|gateway)'"
for s in ui custody gateway; do
  st=$(stat -c '%U:%G %a' "/run/wm006a/$s/sock" 2>&1)
  [[ "$st" == "root:wm006a-$s 660" ]] && pass "socket-$s-owner-mode" "$st" || fail "socket-$s-owner-mode" "$st"
done
