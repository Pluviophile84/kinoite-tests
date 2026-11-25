# Fedora Kinoite VM tests

Automated tests of Fedora Kinoite in a real virtual machine, run on free GitHub-hosted runners.

Each run:

1. Enables KVM on the runner (the run stops if KVM is unavailable; no slow software emulation).
2. Builds a bootable Kinoite disk image from the official `quay.io/fedora-ostree-desktops/kinoite`
   image using `bootc-image-builder`. A thin layer only adds passwordless sudo for a throwaway
   `tester` user, enables sshd and adds a serial console.
3. Boots it with QEMU/KVM and runs the suites in `tests/suites/` over SSH:

| Suite | What it checks |
|---|---|
| 01-baseline | Kinoite variant, ostree boot, Plasma/SDDM up, update check |
| 02-systemd | boot health, transient/persistent/user units, timers, sandbox directives |
| 03-flatpak | Flathub install, bubblewrap isolation (filesystem, network, PID, seccomp), overrides |
| 04-security | SELinux enforcing, read-only `/usr`, kernel hardening, rootless podman isolation |
| 05–07 deploy | package layering + kernel arg, reboot into new deployment, rollback, reboot back |

Results: the run summary page, plus the `kinoite-test-results` artifact (results.tsv, summary.md,
journals, serial console log, desktop screenshots, rpm-ostree status).

Run manually from **Actions → Kinoite VM tests → Run workflow**, optionally with a Fedora version.
The SSH key is generated per run and never stored; nothing in this repository is secret.
