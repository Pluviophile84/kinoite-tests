# wm006a lab harness

Runs the 006A experimental workspace (`wm006a/`) in a disposable Fedora Kinoite VM on a GitHub runner,
following `wm006a/VM-EXPERIMENTS.md`. Manual workflow: **Actions → wm006a lab validation → Run workflow**.

- `host/build-artifacts.sh`: native signer/gateway (Fedora container, Rust 1.100.0, unit + smoke tests),
  desktop app built inside `org.gnome.Sdk//50`, Flatpak bundle from `wm006a/flatpak/`.
- `host/run-lab.sh`: boots the VM (no shared folders, agents, USB or passthrough), runs the guest phases,
  then drives the real Flatpak app in a Plasma session (QMP screendump + OCR + virtio tablet clicks).
- `guest/`: boundary, setup (verbatim from the procedure), E2 isolation, Flatpak install, sandbox checks.

Synthetic accounts (`lab_operator`, `lab_outsider`) and the signer's random `WM006A_TEST:` marker exist only
inside the throwaway VM. The marker is never printed; only equality results are logged.
Results: run summary page and the `wm006a-lab-results` artifact.
