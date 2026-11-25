# Install the built Flatpak for the synthetic operator (user installation, as in the README)
# and confirm the effective permissions are exactly what the manifest declares.
bundle="$LAB_SRC/org.sinteza.WalletManagerLab.flatpak"
as_op_fp() { runuser -u "$lab_operator" -- flatpak --user "$@"; }
check "flathub-remote-user" as_op_fp remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
if ! check "runtime-install" timeout 1800 runuser -u "$lab_operator" -- flatpak --user install -y --noninteractive flathub org.gnome.Platform//50; then
  blocked "app-install" "GNOME 50 runtime not installed"; return 0
fi
check "app-install" runuser -u "$lab_operator" -- flatpak --user install -y --noninteractive --bundle "$bundle"
runuser -u "$lab_operator" -- flatpak --user info --show-commit org.gnome.Platform//50 > "$EV/flatpak-runtime-commit.txt" 2>&1
info "runtime-commit" "$(cat "$EV/flatpak-runtime-commit.txt")"

perms=$(runuser -u "$lab_operator" -- flatpak --user info --show-permissions "$APP" 2>&1)
printf '%s\n' "$perms" > "$EV/flatpak-permissions.txt"
for scope in "--user" "--system"; do
  for target in "$APP" ""; do
    { echo "\$ flatpak override $scope --show $target"; runuser -u "$lab_operator" -- flatpak override $scope --show $target 2>&1; echo; } >> "$EV/flatpak-overrides.txt"
  done
done
# Expect only: sockets=wayland and filesystems=/run/wm006a/ui:ro (no devices, shared, talk names, env).
unexpected=$(awk -F= '/^\[/{sec=$0; next} /=/{v=$0; sub(/^[^=]*=/, "", v); if (v != "") print sec" "$0}' <<<"$perms" \
  | grep -vE '^\[Context\] (sockets=wayland;?|filesystems=/run/wm006a/ui:ro;?)$' || true)
grep -qE '^sockets=wayland;?$' <<<"$perms" && grep -qE '^filesystems=/run/wm006a/ui:ro;?$' <<<"$perms" && [[ -z "$unexpected" ]] \
  && pass "effective-permissions-exact" "wayland + /run/wm006a/ui:ro only" \
  || fail "effective-permissions-exact" "$(tr '\n' ' ' <<<"$perms") unexpected: $(tr '\n' ' ' <<<"$unexpected")"
ov=$(grep -v '^\$\|^$' "$EV/flatpak-overrides.txt" || true)
[[ -z "$ov" ]] && pass "no-overrides" "no user/system, app/global overrides" || fail "no-overrides" "$(tr '\n' ' ' <<<"$ov")"
