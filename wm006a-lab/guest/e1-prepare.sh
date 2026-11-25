# E1 preparation (after 01-setup installed v1): stage v2, write reference data, create the
# separate synthetic persistence file, and allow the guest to pull the gen-2 OS image.
SUITE=e1-prepare
REF=/var/lib/wm006a-lab-e1      # root-only reference data and offline snapshots (never copied out)
install -d -o root -g root -m0700 "$REF" "$REF/snapshots"

# v2: same layout as v1, root-owned, beside it.
install -d -o root -g root -m0755 /var/opt/wm006a/versions/v2/bin
install -o root -g root -m0755 "$LAB_SRC/wm006a-native-v2" /var/opt/wm006a/versions/v2/bin/wm006a-native
v1=$(sha256sum /var/opt/wm006a/versions/v1/bin/wm006a-native | cut -c1-64)
v2=$(sha256sum /var/opt/wm006a/versions/v2/bin/wm006a-native | cut -c1-64)
printf 'v1 %s\nv2 %s\n' "$v1" "$v2" > "$REF/versions.sha256"
cp "$REF/versions.sha256" "$EV/e1-versions.sha256"
[[ "$v1" == "$(cut -c1-64 "$LAB_SRC/wm006a-native.sha256")" ]] && pass "v1-hash-matches-build" "$v1" || fail "v1-hash-matches-build" "$v1"
[[ "$v2" == "$(cut -c1-64 "$LAB_SRC/wm006a-native-v2.sha256")" ]] && pass "v2-hash-matches-build" "$v2" || fail "v2-hash-matches-build" "$v2"
[[ "$v1" != "$v2" ]] && pass "v1-v2-distinguishable" "build-id v1=$(readelf -n /var/opt/wm006a/versions/v1/bin/wm006a-native | awk '/Build ID/{print $3}') v2=$(readelf -n /var/opt/wm006a/versions/v2/bin/wm006a-native | awk '/Build ID/{print $3}')" \
  || fail "v1-v2-distinguishable" "identical hashes"

# Reference copies of the reviewed unit files, to compare /etc against after every transition.
(cd "$WS/systemd" && sha256sum wm006a-*.socket wm006a-*.service) > "$REF/units.sha256"
cp "$REF/units.sha256" "$EV/e1-units-reference.sha256"
readelf -d /var/opt/wm006a/versions/v1/bin/wm006a-native | awk '/NEEDED/{print $5}' | sort > "$REF/needed.txt"

# Start the signer once so systemd creates its state directory, then add the persistence file.
runuser -u "$lab_operator" -- python3 "$PROBE" /run/wm006a/ui/sock 'UI_PING\n' 'OK UI+GATEWAY\n' >/dev/null 2>&1
if [[ -d /var/lib/wm006a-signer ]]; then
  printf 'WM006A_E1_PERSIST synthetic fixture %s\n' "$(cat /proc/sys/kernel/random/uuid)" > "$REF/persist.tmp"
  install -o wm006a-signer -g wm006a-signer -m0600 "$REF/persist.tmp" /var/lib/wm006a-signer/e1-persist.txt
  rm -f "$REF/persist.tmp"
  sha256sum /var/lib/wm006a-signer/e1-persist.txt | cut -c1-64 > "$REF/persist.sha256"
  pass "persist-file-created" "/var/lib/wm006a-signer/e1-persist.txt sha256 $(cat "$REF/persist.sha256")"
else fail "persist-file-created" "signer state directory missing"; fi

# The gen-2 OS image is served by the runner (10.0.2.2 from inside QEMU user networking).
install -Dm644 /dev/stdin /etc/containers/registries.conf.d/50-wm006a-lab.conf <<'EOF'
[[registry]]
location = "10.0.2.2:5000"
insecure = true
EOF
check "lab-registry-reachable" curl -sf --max-time 20 http://10.0.2.2:5000/v2/kinoite-kt/tags/list
