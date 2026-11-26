# Install the E3 lab approval fixture beside the reviewed wm006a services (not started here).
SUITE=e3-install
E3SRC="$LAB_SRC/e3"
install -d -o root -g root -m0755 /var/opt/wm006a-e3/bin
install -o root -g root -m0755 "$E3SRC/wm006a-e3" /var/opt/wm006a-e3/bin/wm006a-e3
want=$(sha256sum "$E3SRC/wm006a-e3" | cut -c1-64); got=$(sha256sum /var/opt/wm006a-e3/bin/wm006a-e3 | cut -c1-64)
[[ "$want" == "$got" ]] && pass "e3-executable-installed" "root 0755 sha256 $got" || fail "e3-executable-installed" "$got"
install -t /etc/systemd/system -o root -g root -m0644 "$E3SRC"/systemd/wm006a-e3-*.socket "$E3SRC"/systemd/wm006a-e3-signer.service
check "e3-units-verify" systemd-analyze verify /etc/systemd/system/wm006a-e3-*.socket /etc/systemd/system/wm006a-e3-signer.service
systemctl daemon-reload
# Reference hashes of every reviewed unit (wm006a + E3) for the boot checks.
install -d -o root -g root -m0700 /var/lib/wm006a-lab-e3
{ (cd "$WS/systemd" && sha256sum wm006a-*.socket wm006a-*.service); (cd "$E3SRC/systemd" && sha256sum wm006a-e3-*); } \
  > /var/lib/wm006a-lab-e3/units.sha256
cp /var/lib/wm006a-lab-e3/units.sha256 "$EV/e3-units-reference.sha256"
info "units-without-install-section" "$(grep -L '^\[Install\]' /etc/systemd/system/wm006a-*.socket | xargs -n1 basename | tr '\n' ' ')"
