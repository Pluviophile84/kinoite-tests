# "Mount and groups" check from VM-EXPERIMENTS.md, inside a lab Flatpak shell as the operator.
# Needs the operator's runtime directory: from the graphical session if it came up, else lingering.
uid=$(uid_of "$lab_operator")
if [[ ! -d "/run/user/$uid" ]]; then
  loginctl enable-linger "$lab_operator"; sleep 5
  info "operator-runtime-dir" "no graphical session; using a lingering user manager"
fi
shell() { as_operator flatpak run --command=sh "$APP" -c "$1"; }
out=$(shell 'test -S /run/wm006a/ui/sock && echo ui=socket || echo ui=MISSING
for p in /run/wm006a/custody/sock /run/wm006a/gateway/sock /var/lib/wm006a-signer/marker; do
  test ! -e "$p" && echo "$p=absent" || echo "$p=VISIBLE"; done' 2>&1)
printf '%s\n' "$out" > "$EV/flatpak-shell.txt"
grep -q '^ui=socket$' <<<"$out" && pass "sandbox-ui-socket-present" "test -S /run/wm006a/ui/sock" || fail "sandbox-ui-socket-present" "$(tr '\n' ' ' <<<"$out")"
for p in custody/sock gateway/sock; do
  grep -q "/run/wm006a/$p=absent" <<<"$out" && pass "sandbox-${p%/sock}-absent" "test ! -e /run/wm006a/$p" || fail "sandbox-${p%/sock}-absent" "$(grep "$p" <<<"$out")"
done
grep -q 'marker=absent' <<<"$out" && pass "sandbox-marker-absent" "test ! -e /var/lib/wm006a-signer/marker" || fail "sandbox-marker-absent" "$(grep marker <<<"$out")"
mnt=$(shell 'grep " /run/wm006a" /proc/self/mountinfo' 2>&1)
echo "$mnt" >> "$EV/flatpak-shell.txt"
grep -Eq ' /run/wm006a/ui ro[, ]' <<<"$mnt" && pass "sandbox-ui-mount-readonly" "$(cut -d' ' -f5,6 <<<"$mnt" | head -n1)" \
  || fail "sandbox-ui-mount-readonly" "$(tr '\n' ' ' <<<"$mnt")"
# Supplementary: the fixed health check from inside the sandbox (probe passed on stdin; home is not shared).
if shell 'command -v python3' >/dev/null 2>&1; then
  r=$(as_operator flatpak run --command=python3 "$APP" - /run/wm006a/ui/sock 'UI_PING\n' 'OK UI+GATEWAY\n' < "$PROBE" 2>&1); rc=$?
  [[ $rc -eq 0 ]] && pass "sandbox-shell-ui-roundtrip" "$r" || fail "sandbox-shell-ui-roundtrip" "exit $rc: $r"
else skip "sandbox-shell-ui-roundtrip" "no python3 in runtime"; fi
