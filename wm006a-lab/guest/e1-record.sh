# e1-record.sh TAG EXPECT_VERSION EXPECT_GENERATION
# Record and check one E1 state: booted deployment, version link, binaries, units, sockets,
# three-identity IPC, the running binary, and the persistence file.
TAG="$1"; VER="$2"; GEN="$3"; SUITE="e1-$TAG"
REF=/var/lib/wm006a-lab-e1
E="$EV/e1-$TAG.txt"; : > "$E"

# Booted deployment (both disposable deployments are listed in the evidence).
rpm-ostree status -v > "$EV/e1-$TAG-rpm-ostree-status.txt" 2>&1
dep=$(rpm-ostree status --json | python3 -c 'import json,sys
d=json.load(sys.stdin)["deployments"]; b=[x for x in d if x.get("booted")][0]
print("checksum=%s image=%s digest=%s deployments=%d" % (b["checksum"][:16], b.get("container-image-reference","?"), str(b.get("container-image-reference-digest", b.get("base-checksum","?")))[:23], len(d)))')
info "booted-deployment" "$dep"
gen_now=$(sed -n 's/^os-generation=//p' /usr/share/wm006a-lab/os-generation 2>/dev/null); gen_now=${gen_now:-1}
[[ "$gen_now" == "$GEN" ]] && pass "os-generation" "generation $gen_now" || fail "os-generation" "expected $GEN, booted $gen_now"

# Sockets after this transition (no [Install] section, so after a boot the admin starts the full set).
pre=$(for s in ui custody gateway; do printf '%s=%s ' "$s" "$(systemctl show wm006a-$s.socket -p ActiveState --value)"; done)
info "sockets-before-start" "$pre"
systemctl start wm006a-ui.socket wm006a-custody.socket wm006a-gateway.socket
for s in ui custody gateway; do
  check "socket-$s-listening" systemctl is-active --quiet "wm006a-$s.socket"
  st=$(stat -c '%U:%G %a' "/run/wm006a/$s/sock" 2>&1)
  [[ "$st" == "root:wm006a-$s 660" ]] && pass "socket-$s-owner-mode" "$st" || fail "socket-$s-owner-mode" "$st"
done

# Version link and binaries.
link=$(readlink /var/opt/wm006a/current); lst=$(stat -c '%U:%G' /var/opt/wm006a/current)
[[ "$link" == "versions/$VER" ]] && pass "current-symlink" "current -> $link" || fail "current-symlink" "current -> $link (expected versions/$VER)"
[[ "$lst" == root:root ]] && pass "current-symlink-owner" "$lst" || fail "current-symlink-owner" "$lst"
dirs=$(stat -c '%n %U:%G %a' /var/opt/wm006a /var/opt/wm006a/versions /var/opt/wm006a/versions/v1 /var/opt/wm006a/versions/v2 \
       /var/opt/wm006a/versions/v1/bin /var/opt/wm006a/versions/v2/bin /var/opt/wm006a/versions/v*/bin/wm006a-native 2>&1)
echo "$dirs" >> "$E"
bad=$(awk '$2!="root:root" || $3!="755"' <<<"$dirs")
[[ -z "$bad" ]] && pass "version-dirs-owner-mode" "all root:root 755" || fail "version-dirs-owner-mode" "$bad"
want=$(awk -v v="$VER" '$1==v{print $2}' "$REF/versions.sha256")
cur=$(sha256sum /var/opt/wm006a/current/bin/wm006a-native | cut -c1-64)
[[ "$cur" == "$want" ]] && pass "current-binary-hash" "$VER $cur" || fail "current-binary-hash" "expected $VER $want got $cur"

# Library resolution and ABI: every NEEDED library resolves, the set matches v1, and it runs.
ldd_out=$(ldd /var/opt/wm006a/current/bin/wm006a-native 2>&1); echo "$ldd_out" >> "$E"
needed=$(readelf -d /var/opt/wm006a/current/bin/wm006a-native | awk '/NEEDED/{print $5}' | sort)
if grep -q 'not found' <<<"$ldd_out"; then fail "library-resolution" "$(grep 'not found' <<<"$ldd_out" | tr '\n' ' ')"
elif [[ "$needed" != "$(cat "$REF/needed.txt")" ]]; then fail "library-resolution" "NEEDED set changed: $(tr '\n' ' ' <<<"$needed")"
else pass "library-resolution" "$(tr '\n' ' ' <<<"$needed")all resolved"; fi
abi=$(runuser -u "$lab_outsider" -- /var/opt/wm006a/current/bin/wm006a-native ip-probe 2>&1)
[[ $(grep -c 'socket creation permitted' <<<"$abi") -eq 2 ]] && pass "runtime-abi" "binary runs on this deployment (glibc $(ldd --version | head -n1 | awk '{print $NF}'))" \
  || fail "runtime-abi" "$(tr '\n' ' ' <<<"$abi")"

# Unit files under /etc must match the reviewed copies.
um=$(cd /etc/systemd/system && sha256sum -c "$REF/units.sha256" 2>&1)
echo "$um" >> "$E"
grep -qv ': OK$' <<<"$um" && fail "unit-files-match" "$(grep -v ': OK$' <<<"$um" | tr '\n' ' ')" || pass "unit-files-match" "5 units identical to the reviewed copies"
pf=$(stat -c '%U:%G %a' /etc/wm006a/peers 2>&1)
[[ "$pf" == "root:root 644" ]] && pass "peers-file" "$pf" || fail "peers-file" "$pf"
check "systemd-loaded-units-verify" systemd-analyze verify /etc/systemd/system/wm006a-*.socket /etc/systemd/system/wm006a-*.service

# Three-identity checks (positives first so a stopped service is not mistaken for a denial).
pr() { local n="$1"; shift; local o; o=$("$@" 2>&1) && pass "$n" "$o" || fail "$n" "$o"; }
pr ui-ping-operator-roundtrip       runuser -u "$lab_operator" -- python3 "$PROBE" /run/wm006a/ui/sock 'UI_PING\n' 'OK UI+GATEWAY\n'
pr custody-ping-custody-uid         runuser -u wm006a-custody -- python3 "$PROBE" /run/wm006a/custody/sock 'CUSTODY_PING\n' 'OK CUSTODY\n'
pr ui-rejects-custody-message       runuser -u "$lab_operator" -- python3 "$PROBE" /run/wm006a/ui/sock 'CUSTODY_PING\n' 'ERR REQUEST\n'
pr operator-denied-custody-socket   runuser -u "$lab_operator" -- python3 "$PROBE" /run/wm006a/custody/sock 'CUSTODY_PING\n' dac
pr operator-denied-gateway-socket   runuser -u "$lab_operator" -- python3 "$PROBE" /run/wm006a/gateway/sock 'GATEWAY_PING\n' dac
pr outsider-denied-ui-socket        runuser -u "$lab_outsider" -- python3 "$PROBE" /run/wm006a/ui/sock 'UI_PING\n' dac
pr outsider-with-ui-group-peer-rejected runuser -u "$lab_outsider" -g wm006a-ui -- python3 "$PROBE" /run/wm006a/ui/sock 'UI_PING\n' peer

# The binary actually running, and the service identities/permissions.
sp=$(systemctl show -p MainPID --value wm006a-signer.service); gp=$(systemctl show -p MainPID --value wm006a-gateway.service)
run=$( [[ "$sp" -gt 0 ]] && sha256sum "/proc/$sp/exe" | cut -c1-64 )
[[ -n "$run" && "$run" == "$want" ]] && pass "active-binary-hash" "running signer pid $sp is $VER ($run)" || fail "active-binary-hash" "pid $sp exe ${run:-none}, expected $VER $want"
ps -o label,pid,user,group,supgrp,comm -p "$sp,$gp" >> "$E" 2>&1
# ps supgrp lists every group the process holds (primary included), so compare sorted sets.
idof() { local u g s; read -r u g s < <(ps -o user:32=,group:32=,supgrp:128= -p "$1"); printf '%s %s %s' "$u" "$g" "$(tr ',' '\n' <<<"$s" | sort | paste -sd,)"; }
sid=$(idof "$sp"); gid=$(idof "$gp")
if [[ "$sid" == "wm006a-signer wm006a-signer wm006a-gateway,wm006a-signer" && "$gid" == "wm006a-gateway wm006a-gateway wm006a-gateway" ]]; then
  pass "service-identities" "signer: $sid | gateway: $gid"
else fail "service-identities" "signer: $sid | gateway: $gid"; fi
sd=$(stat -c '%U %a' /var/lib/wm006a-signer); mk=$(stat -c '%U %a' /var/lib/wm006a-signer/marker 2>&1)
[[ "$sd" == "wm006a-signer 700" ]] && pass "state-dir-owner-mode" "$sd" || fail "state-dir-owner-mode" "$sd"
[[ "$mk" == "wm006a-signer 600" ]] && pass "marker-owner-mode" "$mk (regenerated at signer start: $(stat -c %y /var/lib/wm006a-signer/marker | cut -c1-19))" || fail "marker-owner-mode" "$mk"

# Persistence: the separate synthetic file must be unchanged.
pst=$(stat -c '%U:%G %a' /var/lib/wm006a-signer/e1-persist.txt 2>&1); psh=$(sha256sum /var/lib/wm006a-signer/e1-persist.txt 2>/dev/null | cut -c1-64)
[[ "$psh" == "$(cat "$REF/persist.sha256")" && "$pst" == "wm006a-signer:wm006a-signer 600" ]] \
  && pass "persist-file-intact" "sha256 ${psh:0:16}… $pst" || fail "persist-file-intact" "sha256 ${psh:-missing} $pst"
