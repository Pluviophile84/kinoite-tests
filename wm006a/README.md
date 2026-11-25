# Wallet Manager 006A experimental workspace

The desktop displays 100 fictional IDs and sends one fixed request. The native binary has separate signer and gateway modes. The signer keeps a random synthetic marker in RAM and in a private fixture file. The approval endpoint accepts a health check, which carries zero authority.

## Reproduce unprivileged experiments

Use Linux x86-64 with a C linker, Rust/Cargo (tested with 1.100.0), Node 24, npm 11, Python 3 and SQLite through Python. Run from this directory:

```sh
cargo test --locked --manifest-path native/Cargo.toml -- --test-threads=1
cargo build --locked --release --manifest-path native/Cargo.toml
python3 tests/local_smoke.py native/target/release/wm006a-native
python3 tests/layout.py

cd desktop
npm ci --ignore-scripts
npm run build
npm run desktop -- build --no-bundle -- --locked
```

Exit 77 from the pathname smoke test means the execution environment denies or lacks AF_UNIX stream sockets. The four Rust tests use socket pairs and a temporary marker directory. The pathname smoke test needs ordinary local sockets. It measures two-process startup to the first complete reply, 30 round trips and idle RSS if `/proc` exposes it.

The desktop requires GTK 3 and WebKitGTK 4.1 with JavaScriptCore and libsoup 3. For development it also needs their pkg-config files, the platform compiler/linker and Tauri's Linux prerequisites. Debian/Ubuntu package names include `libwebkit2gtk-4.1-dev`, `libgtk-3-dev` and `libxdo-dev`. Fedora uses `webkit2gtk4.1-devel`, `gtk3-devel` and `libxdo-devel`. Use an isolated build environment. See [Tauri Linux prerequisites](https://v2.tauri.app/start/prerequisites/#linux).

A successful normal CLI build writes the release executable at `desktop/src-tauri/target/release/wm006a-desktop`. Use a graphical session to start it. Confirm 100 rows, select two rows and clear them. Click **Test local IPC** with the endpoint absent for a visible error. After installing the test units in the VM, the same control should show **Signer and gateway replied.** The Vite preview provides a browser-only roster and an explicit desktop-required state.

To repeat the optional browser check, start npm run preview from desktop. With Playwright and Chromium available, run node tests/web_smoke.mjs from the workspace root. Point PLAYWRIGHT_MODULE at an absolute Playwright index.mjs path if it is installed separately. CHROME_BIN selects a compatible local Chromium. Otherwise the harness uses Playwright's downloaded Chromium. It enables Chromium's sandbox and uses only the loopback preview. The measurements cover React commit and the second animation-frame callback.

## Flatpak build and launch in the disposable VM

Use the GNOME SDK and runtime branch 50, with a release binary built in an ABI-compatible environment. Inspect the exact runtime and SDK commits with `flatpak info --show-commit`, inspect the executable with `readelf -d`, and confirm the SDK has `pkg-config --modversion webkit2gtk-4.1` before building against it. The manifest stages a local binary. The source and the build inputs stay available for review.

```sh
flatpak install --user flathub org.gnome.Platform//50 org.gnome.Sdk//50
install -Dm755 desktop/src-tauri/target/release/wm006a-desktop flatpak/stage/wm006a-desktop
flatpak-builder --user --install --force-clean .flatpak-build flatpak/org.sinteza.WalletManagerLab.json
flatpak info --show-permissions org.sinteza.WalletManagerLab
flatpak run org.sinteza.WalletManagerLab
```

Expect Wayland and one read-only runtime-directory mount at `/run/wm006a/ui`. Inspect app-specific and global overrides with `flatpak override --user --show org.sinteza.WalletManagerLab`, `flatpak override --user --show`, and their system equivalents. Inside a lab Flatpak shell run `test -S /run/wm006a/ui/sock` and verify the signer, custody and gateway paths are absent. Confirm that the GUI can test IPC again after the VM admin restarts the UI socket and signer service. Record an effective permission expansion, inaccessible socket or missing WebKit runtime as a concrete failure. This prototype uses the Wayland connection and no file or device portals.

## Measurements on Kinoite

Perform five launches of the release app in the guest and five in the Flatpak. Start the timer immediately before launching, record first visible roster time by screen capture or frame timestamp, and collect the later of the window draw and roster availability if they differ. Sum parent and WebKit child RSS at five seconds idle and during selection and scrolling. Identify child processes explicitly and report PSS where readable to account for shared mappings. Record median and range. For selection latency, record event to checked state and next paint from the WebKit performance tools or measured screen frames. Exercise initial 100-row rendering, selecting and clearing at least two rows, and scrolling to row 100. Use the same graphics backend, resolution and scale across comparisons. A marker named `roster-rendered` records React's initial commit and is useful as a secondary measurement. It precedes the compositor paint.

See [VM-EXPERIMENTS.md](VM-EXPERIMENTS.md) for guest setup, isolation probes, rollback and the custody console follow-up. The `evidence/` directory contains observations from the remote Debian environment.
