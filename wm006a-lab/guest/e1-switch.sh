# e1-switch.sh VERSION TAG : the runbook's version switch.
# Stop both services and all listening sockets, keep an offline state snapshot, replace the
# root-owned `current` symlink by same-directory rename, then start the full set again.
VER="$1"; TAG="$2"; SUITE="e1-$TAG"
REF=/var/lib/wm006a-lab-e1
units=(wm006a-signer.service wm006a-gateway.service wm006a-ui.socket wm006a-custody.socket wm006a-gateway.socket)
systemctl stop "${units[@]}"
states=$(for u in "${units[@]}"; do printf '%s=%s ' "$u" "$(systemctl show "$u" -p ActiveState --value)"; done)
grep -q '=active' <<<"$states" && fail "full-set-stopped" "$states" || pass "full-set-stopped" "$states"

# Offline snapshot of the signer state (contains the test marker, so it stays root-only in the guest).
snap="$REF/snapshots/$TAG.tar"
if tar -C /var/lib --xattrs --acls -cpf "$snap" wm006a-signer && chmod 0600 "$snap"; then
  pass "offline-state-snapshot" "$(tar -tvf "$snap" | awk '{print $1,$2,$6}' | tr '\n' ';')"
else fail "offline-state-snapshot" "tar failed"; fi

before=$(readlink /var/opt/wm006a/current)
rm -f /var/opt/wm006a/current.new
ln -s "versions/$VER" /var/opt/wm006a/current.new
mv -T /var/opt/wm006a/current.new /var/opt/wm006a/current     # rename(2) within one directory: atomic
after=$(readlink /var/opt/wm006a/current)
[[ "$after" == "versions/$VER" && ! -e /var/opt/wm006a/current.new ]] \
  && pass "atomic-rename" "current: $before -> $after (same-directory rename)" || fail "atomic-rename" "current: $before -> $after"
systemctl start wm006a-ui.socket wm006a-custody.socket wm006a-gateway.socket
