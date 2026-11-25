# Security isolation: SELinux, immutable OS, privilege separation, kernel hardening, containers.
check_eq "selinux-enforcing" "Enforcing" "$(getenforce)"
info "selinux-policy" "$(sestatus | awk -F: '/Loaded policy/{gsub(/ /,"",$2);print $2}')"
avc=$(sudo journalctl -b -k --no-pager -q | grep -c 'avc:  denied' || true)
sudo journalctl -b --no-pager -q | grep 'avc:  denied' > "$ART/avc-denials.txt" 2>/dev/null
[[ "$avc" -eq 0 ]] && pass "selinux-no-avc-denials" "0" || warn "selinux-no-avc-denials" "$avc denials this boot (see artifacts)"

check_not "usr-readonly-as-root" sudo touch /usr/kt-x
check_not "usr-bin-readonly-as-root" sudo cp /bin/true /usr/bin/kt-true
check "etc-writable" sudo bash -c 'echo x > /etc/kt-probe && rm /etc/kt-probe'
check "var-writable" sudo bash -c 'echo x > /var/kt-probe && rm /var/kt-probe'
check_not "shadow-unreadable-by-user" cat /etc/shadow
check_not "user-cannot-write-etc" touch /etc/kt-user

check "firewalld-active" systemctl is-active --quiet firewalld
info "firewall-zone" "$(sudo firewall-cmd --get-default-zone 2>&1)"
prl=$(sudo sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')
[[ "$prl" != yes ]] && pass "ssh-root-login-restricted" "permitrootlogin=$prl" || fail "ssh-root-login-restricted" "permitrootlogin=yes"

for kv in kernel.randomize_va_space=2 fs.protected_symlinks=1 fs.protected_hardlinks=1; do
  k=${kv%=*}; check_eq "sysctl-$k" "${kv#*=}" "$(sysctl -n "$k")"
done
for k in kernel.kptr_restrict kernel.dmesg_restrict kernel.yama.ptrace_scope kernel.unprivileged_bpf_disabled fs.protected_regular user.max_user_namespaces; do
  info "sysctl-$k" "$(sysctl -n "$k" 2>&1)"
done
info "kernel-lockdown" "$(cat /sys/kernel/security/lockdown 2>/dev/null || echo n/a)"
sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort > "$ART/setuid-setgid.txt"
info "setuid-setgid-count" "$(wc -l < "$ART/setuid-setgid.txt") files (list in artifacts)"

# Rootless containers (podman ships with Kinoite)
IMG=registry.fedoraproject.org/fedora-minimal:latest
if check "podman-rootless-run" timeout 600 podman run --rm "$IMG" true; then
  check "container-selinux-label" bash -c "podman run --rm $IMG cat /proc/self/attr/current | tee /dev/stderr | grep -q container_t"
  check "container-root-is-mapped" bash -c "podman run --rm $IMG cat /proc/self/uid_map | awk '\$1==0{print; ok=(\$2!=0)} END{exit !ok}'"
  mkdir -p ~/kt-sel && echo data > ~/kt-sel/f
  check_not "selinux-blocks-unlabeled-bind" podman run --rm -v "$HOME/kt-sel:/data" "$IMG" cat /data/f
  check "selinux-allows-relabeled-bind" podman run --rm -v "$HOME/kt-sel:/data:Z" "$IMG" cat /data/f
  check "container-caps-reduced" bash -c "podman run --rm $IMG cat /proc/self/status | awk '/CapEff/{print; exit (\$2==\"000001ffffffffff\")}'"
  check_not "container-cannot-see-host-procs" bash -c "podman run --rm $IMG cat /proc/1/cmdline | tr '\0' ' ' | grep -q systemd"
fi
