#!/usr/bin/env bash
# Build the 006A test artifacts on the runner:
#   1. native signer/gateway in a Fedora container matching the guest release (+ unit/smoke tests)
#   2. web frontend with Node, then the Tauri desktop binary inside org.gnome.Sdk//50 (ABI = runtime)
#   3. the Flatpak bundle from wm006a/flatpak/org.sinteza.WalletManagerLab.json
set -euo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
WS="$REPO_ROOT/wm006a"
ART="$WORK/wm006a-artifacts"
EVD="$OUT/wm006a"; mkdir -p "$ART" "$EVD"
EV="$EVD/build-evidence.txt"; : > "$EV"
RUST_VERSION=1.100.0
FEDORA_IMG="registry.fedoraproject.org/fedora:${KT_FEDORA_VERSION:-45}"
BR="$EVD/build-results.tsv"; touch "$BR"
note() { printf '\n== %s\n' "$*" | tee -a "$EV"; }
res() { printf '%s\tbuild\t%s\t%s\n' "$1" "$2" "${3:-}" | tee -a "$BR"; }
# Lines "@@RESULT name rc" printed by the build containers become build results.
collect() { grep -a '^@@RESULT ' "$EV" | while read -r _ n rc; do
  grep -q "	$n	" "$BR" || res "$([ "$rc" = 0 ] && echo PASS || echo FAIL)" "$n" "exit $rc"; done; }

note "1. Native build and unprivileged checks in $FEDORA_IMG (Rust $RUST_VERSION)"
sudo podman run --rm -v "$WS:/w:Z" -w /w -e RUST_VERSION="$RUST_VERSION" -e E1_VERSIONS="${E1_VERSIONS:-0}" "$FEDORA_IMG" bash -euo pipefail -c '
  dnf -y -q install gcc python3 binutils curl >/dev/null
  u=https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init
  curl -sSf --proto =https --tlsv1.2 -o /tmp/rustup-init "$u"
  want=$(curl -sSf --proto =https --tlsv1.2 "$u.sha256" | cut -d" " -f1)
  echo "$want  /tmp/rustup-init" | sha256sum -c -
  chmod +x /tmp/rustup-init && /tmp/rustup-init -y -q --profile minimal --default-toolchain "$RUST_VERSION" --no-modify-path
  . "$HOME/.cargo/env"; rustc --version; cat /etc/os-release | grep ^PRETTY
  set +e
  cargo test --locked --manifest-path native/Cargo.toml -- --test-threads=1; echo "@@RESULT native-cargo-test $?"
  cargo build --locked --release --manifest-path native/Cargo.toml; echo "@@RESULT native-release-build $?"
  python3 tests/local_smoke.py native/target/release/wm006a-native; echo "@@RESULT native-local-smoke $?"
  python3 tests/layout.py; echo "@@RESULT layout-schema-probe $?"
  if [ "${E1_VERSIONS:-0}" = 1 ]; then
    # v2: identical source, distinguishable only by its embedded GNU build ID (and therefore its hash).
    RUSTFLAGS="-C link-arg=-Wl,--build-id=0x006a0e1000000000000000000000000000000002" CARGO_TARGET_DIR=native/target-v2 \
      cargo build --locked --release --manifest-path native/Cargo.toml; echo "@@RESULT native-v2-release-build $?"
  fi
  readelf -d native/target/release/wm006a-native | grep -E "NEEDED|RUNPATH|RPATH"
' 2>&1 | tee -a "$EV" || true
collect
sudo chown -R "$(id -u):$(id -g)" "$WS"
[[ -x "$WS/native/target/release/wm006a-native" ]] || { echo "::error::native build failed"; exit 1; }
sha256sum "$WS/native/target/release/wm006a-native" | tee "$ART/wm006a-native.sha256" | tee -a "$EV"
if [[ "${E1_VERSIONS:-0}" == 1 && -x "$WS/native/target-v2/release/wm006a-native" ]]; then
  cp "$WS/native/target-v2/release/wm006a-native" "$ART/wm006a-native-v2"
  (cd "$ART" && sha256sum wm006a-native-v2 > wm006a-native-v2.sha256)
  for b in "$WS/native/target/release/wm006a-native" "$ART/wm006a-native-v2"; do
    echo "$(basename "$b") build-id: $(readelf -n "$b" | awk '/Build ID/{print $3}')" | tee -a "$EV"; done
fi

if [[ "${SKIP_DESKTOP:-0}" == 1 ]]; then
  cp "$WS/native/target/release/wm006a-native" "$ART/"
  echo "SKIP_DESKTOP=1: desktop app and Flatpak bundle not built for this workflow" | tee -a "$EV"; exit 0
fi
note "2a. Frontend build (Node $(node --version))"
if (cd "$WS/desktop" && npm ci --ignore-scripts --no-audit --no-fund && npm run build) > "$EVD/frontend-build.log" 2>&1
then res PASS frontend-build "tsc + vite"; else res FAIL frontend-build "see frontend-build.log"; fi
tail -n 12 "$EVD/frontend-build.log" | tee -a "$EV"

note "2b. GNOME 50 SDK and runtime"
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y --noninteractive flathub org.gnome.Platform//50 org.gnome.Sdk//50 2>&1 | tail -n 3
for r in org.gnome.Platform//50 org.gnome.Sdk//50; do echo "$r commit $(flatpak info --user --show-commit $r)" | tee -a "$EV"; done

note "2c. Tauri desktop build inside org.gnome.Sdk//50"
flatpak run --user --share=network --filesystem="$WS" --filesystem="$WORK" \
  --env=CARGO_HOME="$WORK/sdk-cargo" --env=RUSTUP_HOME="$WORK/sdk-rustup" --env=RUST_VERSION="$RUST_VERSION" \
  --env=WS="$WS" --command=bash org.gnome.Sdk//50 -c '
  set -uo pipefail
  echo "webkit2gtk-4.1 $(pkg-config --modversion webkit2gtk-4.1)  gtk+-3.0 $(pkg-config --modversion gtk+-3.0)  libsoup-3.0 $(pkg-config --modversion libsoup-3.0)"
  u=https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init
  curl -sSf --proto =https --tlsv1.2 -o /tmp/rustup-init "$u"
  want=$(curl -sSf --proto =https --tlsv1.2 "$u.sha256" | cut -d" " -f1)
  echo "$want  /tmp/rustup-init" | sha256sum -c -
  chmod +x /tmp/rustup-init && /tmp/rustup-init -y -q --profile minimal --default-toolchain "$RUST_VERSION" --no-modify-path
  . "$CARGO_HOME/env"
  cd "$WS/desktop/src-tauri"
  # The Tauri CLI enables custom-protocol for release builds; plain cargo needs it explicitly.
  cargo build --release --locked --features tauri/custom-protocol > /tmp/cargo.log 2>&1; rc=$?
  tail -n 25 /tmp/cargo.log; echo "@@RESULT desktop-release-build-in-gnome50-sdk $rc"
  readelf -d target/release/wm006a-desktop | grep -E "NEEDED" | head -n 40
' 2>&1 | tee -a "$EV" || true
collect
D="$WS/desktop/src-tauri/target/release/wm006a-desktop"
if [[ ! -x "$D" ]]; then res BLOCKED flatpak-bundle "desktop binary missing"; cp "$WS/native/target/release/wm006a-native" "$ART/"; exit 0; fi
sha256sum "$D" | tee -a "$EV"

note "3. Flatpak bundle"
install -Dm755 "$WS/desktop/src-tauri/target/release/wm006a-desktop" "$WS/flatpak/stage/wm006a-desktop"
(cd "$WS" && flatpak-builder --user --force-clean --disable-rofiles-fuse --state-dir="$WORK/fb-state" \
   --repo="$WORK/wm-repo" "$WORK/wm-build" flatpak/org.sinteza.WalletManagerLab.json) > "$EVD/flatpak-builder.log" 2>&1 \
 && flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
      "$WORK/wm-repo" "$ART/org.sinteza.WalletManagerLab.flatpak" org.sinteza.WalletManagerLab \
 && res PASS flatpak-bundle "$(sha256sum "$ART/org.sinteza.WalletManagerLab.flatpak" | cut -c1-64)" \
 || res FAIL flatpak-bundle "see flatpak-builder.log"
tail -n 8 "$EVD/flatpak-builder.log" | tee -a "$EV"
cp "$WS/native/target/release/wm006a-native" "$ART/"
# Free runner disk before the VM phase.
rm -rf "$WORK/wm-build" "$WORK/fb-state" "$WORK/sdk-cargo" "$WORK/sdk-rustup" "$WS/desktop/src-tauri/target" "$WS/desktop/node_modules"
flatpak uninstall --user -y --noninteractive org.gnome.Sdk//50 >/dev/null 2>&1 || true
ls -la "$ART"; df -h "$WORK"
