# Disposable Kinoite VM experiments

Use a newly designated, authorized VM and verify its boundary in the hypervisor before running the privileged setup below. Confirm its name, disposable disk and guest console, take a clean snapshot, and disable host folder mounts, clipboard sharing, USB/device passthrough and credential forwarding. Use fresh lab identities and synthetic data. Make a second throwaway development guest for the cross-guest check if the hardware can support it. A host can report VM status for entirely different reasons, so a positive `systemd-detect-virt --vm` is only one check.

## E1 / E2 setup in the authorized guest

Build the native executable on compatible Linux x86-64 before entering the administrative session. Inspect the dependencies with `readelf -d` and verify the test binary and source provenance. Use a separate non-admin guest graphical account as the operator and an unprivileged guest-only account as the outsider. The following setup is for the guest admin. Set `lab_operator` and `lab_outsider` to those existing synthetic accounts, confirm they are distinct and neither has `wheel`, and run from the 006A directory. The proposed custody identity has a nologin shell. The guest admin runs the positive custody health check as that UID for the socket experiment.

```sh
systemd-detect-virt --vm
id "$lab_operator"
id "$lab_outsider"

install -Dm644 systemd/wm006a.conf /etc/sysusers.d/wm006a.conf
systemd-sysusers /etc/sysusers.d/wm006a.conf
usermod -aG wm006a-ui "$lab_operator"
install -d -o root -g root -m0755 /var/opt/wm006a/versions/v1/bin
install -o root -g root -m0755 native/target/release/wm006a-native /var/opt/wm006a/versions/v1/bin/
ln -s versions/v1 /var/opt/wm006a/current
install -d -o root -g root -m0755 /etc/wm006a
printf 'WM006A_OPERATOR_UID=%s\nWM006A_CUSTODY_UID=%s\nWM006A_SIGNER_UID=%s\n' \
  "$(id -u "$lab_operator")" "$(id -u wm006a-custody)" "$(id -u wm006a-signer)" > /etc/wm006a/peers
chmod 0644 /etc/wm006a/peers
install -t /etc/systemd/system -o root -g root -m0644 systemd/*.socket systemd/*.service
install -Dm755 tests/socket_probe.py /var/tmp/wm006a-socket-probe.py
systemd-analyze verify /etc/systemd/system/wm006a-*.socket /etc/systemd/system/wm006a-*.service
systemctl daemon-reload
systemctl start wm006a-ui.socket wm006a-custody.socket wm006a-gateway.socket
```

Log the operator out and back in so supplementary groups apply. The three sockets are `0660`, owned by root with per-endpoint group assignments. Only the UI directory enters the Flatpak. The state folder is `0700`, owned by the signer, and its marker is `0600`. Capture namei output, groups, owner/mode, the two service PIDs and their labels with `ps -Z`. Preserve actual SELinux state, labels and any access-denial evidence. Run `systemd-analyze security wm006a-signer.service wm006a-gateway.service` as a configuration check. Keep per-test outcome evidence alongside its result.

## E2 isolation procedure

All paths and PIDs below belong to the test stubs in this guest. Run the positives first to distinguish a stopped service from a permission denial. Set `probe=/var/tmp/wm006a-socket-probe.py` and `signer_pid=$(systemctl show -p MainPID --value wm006a-signer.service)` after the first positive reply.

```sh
runuser -u "$lab_operator" -- python3 "$probe" /run/wm006a/ui/sock 'UI_PING\n' 'OK UI+GATEWAY\n'
runuser -u wm006a-custody -- python3 "$probe" /run/wm006a/custody/sock 'CUSTODY_PING\n' 'OK CUSTODY\n'
runuser -u "$lab_operator" -- python3 "$probe" /run/wm006a/ui/sock 'CUSTODY_PING\n' 'ERR REQUEST\n'
runuser -u "$lab_operator" -- python3 "$probe" /run/wm006a/custody/sock 'CUSTODY_PING\n' dac
runuser -u "$lab_operator" -- python3 "$probe" /run/wm006a/gateway/sock 'GATEWAY_PING\n' dac
runuser -u "$lab_outsider" -- python3 "$probe" /run/wm006a/ui/sock 'UI_PING\n' dac
runuser -u "$lab_outsider" -g wm006a-ui -- python3 "$probe" /run/wm006a/ui/sock 'UI_PING\n' peer
```

| Check | Procedure and passing evidence |
| --- | --- |
| Files and memory | Under the operator UID and then the outsider UID, attempt to open `/var/lib/wm006a-signer/marker` and `/proc/$signer_pid/mem` read-only with Python `os.open(path, os.O_RDONLY)`, printing only errno and closing any open descriptor immediately. Record `EACCES`/`EPERM`, or corroborate an intentionally hidden proc path as root using the original PID. A successful open fails the probe. Confirm both paths exist from the guest admin session. |
| Mount and groups | In the Flatpak shell inspect the UI socket with `test -S`, and check `test ! -e` separately for `/run/wm006a/custody/sock`, `/run/wm006a/gateway/sock` and the signer marker. Use the GUI for a positive reply, then check reconnection after restarting the socket and service. The same desktop UID is intentionally allowed to request the harmless UI health check outside Flatpak. |
| IP sockets | `journalctl -b -u wm006a-signer.service` must show both IPv4 and IPv6 creation denied by the pre-start probe. Confirm an unconfined run of `wm006a-native ip-probe` in the same guest can create both families. Capture service family, namespace and descriptor configuration. Stubs pass only Unix listening descriptors. No Internet connection is attempted. |
| Logs and crash | Record the signer PID and current time. Use guest unit `systemctl kill --kill-whom=main --signal=ABRT wm006a-signer.service`. Check the unit status for the signal and query journal/coredump records for that exact PID, executable and time window. Compare the generated marker in memory-backed administrator code against the captured unit logs and print only the equality result. Verify that the configured collector produced no payload and that the marker is absent from logs. Confirm the dump collector actually works with a separate, explicitly synthetic positive control if one is available. Otherwise report the collector portion as blocked. |
| Development boundary | Confirm the separate development guest has only its disposable disk and no shared folder, forwarded credentials, host service mount or remote access to the target guest. The target guest exposes no IP listener for these stubs. In the development guest check only for the explicit lab paths and a synthetic target marker path. Confirm the same paths are present in the target guest to verify the fixture. Record the hypervisor configuration. |
| Identity escalation configuration | Audit the synthetic operator's groups, allowed sudo rules and guest login/polkit account policy from the guest admin account. Require both UID separation and absence of an authorized privilege path from the operator. Keep the results specific to the guest policy that was inspected. |

## E1 upgrade and rollback sequence

Use two reviewed lab builds staged at `/var/opt/wm006a/versions/v1` and `v2`. Keep the root-owned `current` symlink and use same-directory rename to replace it. Stop both services and the listening sockets before a version switch, keep an offline state snapshot, then start the full set and repeat the three-identity checks. Test a reboot and an actual rpm-ostree OS rollback with both disposable deployments recorded. Compare `readlink /var/opt/wm006a/current`, `stat` on the version directory and marker, the unit files under `/etc`, binary library resolution and runtime IPC after each boot. Treat an unexpected ABI or unit mismatch as a failure. `tests/layout.py` is the separate synthetic SQLite schema compatibility probe. Keep the live fixture when a version rejects it. A real ledger's schema gate must run in the signer before its first write.

## E3 smallest useful approval experiment

Start with two isolated guest sessions and a signer-owned ASCII screen containing a harmless plan summary, its digest, and a fresh one-use request challenge. Use an expiring challenge bound to the exact immutable revision and boot generation, with atomic consumption of the challenge before recording approval. The guest UI may propose a synthetic revision. Exercise a stale revision, a modified field, replay, expiry and restart. Require the signer to surface the revision it would actually approve. Use a fake guest dialog with a synthetic phrase to exercise the human interaction. Evaluate credential-entry behavior, active seat and VT provenance, physical presence, guest input injection and how the operator recognizes trusted output before entering a synthetic phrase. Keep any real login-policy work for a separately authorized environment. A VM guest VT can exercise separation and protocol integrity. Physical keyboard routing, secure switching, devices, host remote console rights and actual KDE behavior require a separate test.
