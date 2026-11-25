# Flatpak: install from Flathub, then verify the bubblewrap sandbox actually isolates the app.
APP=org.kde.kcalc
REMOTE=flathub-kt
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
check "flatpak-present" flatpak --version
flatpak remotes --show-details > "$ART/flatpak-remotes-preinstalled.txt" 2>&1
check "remote-add" sudo flatpak remote-add --if-not-exists "$REMOTE" https://dl.flathub.org/repo/flathub.flatpakrepo
if ! check "app-install" timeout 1800 sudo flatpak install -y --noninteractive "$REMOTE" "$APP"; then
  skip "sandbox-tests" "app did not install"; return 0
fi
flatpak info "$APP" > "$ART/flatpak-info.txt" 2>&1
flatpak info --show-permissions "$APP" > "$ART/flatpak-permissions.txt" 2>&1
check "app-listed" bash -c "flatpak list --app --columns=application | grep -qx $APP"

run() { flatpak run --command=sh "$@" ; }   # run [flatpak options] APP -c '...'
echo "host-secret" > ~/kt-secret.txt
mkdir -p ~/kt-shared && echo shared > ~/kt-shared/f

out=$(run --nofilesystem=host --nofilesystem=home "$APP" -c 'cat /etc/os-release' 2>&1)
grep -q 'VARIANT_ID=kinoite' <<<"$out" && fail "sandbox-own-runtime" "host os-release visible" \
  || pass "sandbox-own-runtime" "$(grep -m1 '^NAME=' <<<"$out")"
check_not "sandbox-home-hidden" run --nofilesystem=host --nofilesystem=home "$APP" -c "cat $HOME/kt-secret.txt"
check_not "sandbox-host-usr-hidden" run "$APP" -c 'test -e /usr/bin/rpm-ostree'
check_not "sandbox-usr-readonly" run "$APP" -c 'touch /usr/kt-x'
check "sandbox-grant-ro-dir" run --filesystem="$HOME/kt-shared:ro" "$APP" -c "cat $HOME/kt-shared/f"
check_not "sandbox-ro-dir-not-writable" run --filesystem="$HOME/kt-shared:ro" "$APP" -c "touch $HOME/kt-shared/new"
check "sandbox-no-network" bash -c "out=\$(flatpak run --unshare=network --command=sh $APP -c 'ls /sys/class/net'); echo \$out; [ \"\$out\" = lo ]"
check "sandbox-pid-namespace" bash -c "n=\$(flatpak run --command=sh $APP -c 'ls -d /proc/[0-9]* | wc -l'); echo procs=\$n; [ \$n -lt 15 ]"
check "sandbox-seccomp" bash -c "flatpak run --command=sh $APP -c 'grep -E \"^Seccomp:\" /proc/self/status' | grep -Eq '2$'"
check "sandbox-nonewprivs" bash -c "flatpak run --command=sh $APP -c 'grep NoNewPrivs /proc/self/status' | grep -Eq '1$'"
if run "$APP" -c 'command -v unshare' >/dev/null 2>&1; then
  check_not "sandbox-no-nested-userns" run "$APP" -c 'unshare -U true'
else skip "sandbox-no-nested-userns" "unshare not in runtime"; fi
check_not "sandbox-no-mount" run "$APP" -c 'mount -t tmpfs none /tmp'

check "override-set" flatpak override --user --nofilesystem=home "$APP"
check "override-visible" bash -c "flatpak override --user --show $APP | grep -q '!home'"
flatpak override --user --reset "$APP"
check "flatpak-update" timeout 900 sudo flatpak update -y --noninteractive
