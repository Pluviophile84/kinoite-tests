# systemd: boot health, transient/persistent/user units, timers, sandboxing directives.
state=$(timeout 300 systemctl is-system-running --wait 2>/dev/null)
if [[ "$state" == running ]]; then pass "system-running" "$state"
else
  failed=$(systemctl --failed --plain --no-legend | awk '{print $1}' | tr '\n' ' ')
  if [[ "$(xargs <<<"$failed")" == mcelog.service ]]; then
    pass "system-running" "degraded only by mcelog.service, which needs machine-check hardware a VM lacks"
  else warn "system-running" "state=$state failed units: ${failed:-none}"; fi
fi
systemd-analyze > "$ART/systemd-analyze.txt" 2>&1
systemd-analyze blame > "$ART/systemd-blame.txt" 2>&1
info "boot-time" "$(head -n1 "$ART/systemd-analyze.txt")"

check "transient-unit" sudo systemd-run --quiet --wait --pipe -u kt-transient /usr/bin/true

# Persistent service + timer in /etc (writable, survives deployments of the same lineage)
sudo tee /etc/systemd/system/kt-heartbeat.service >/dev/null <<'EOF'
[Unit]
Description=Kinoite test heartbeat
[Service]
Type=oneshot
StateDirectory=kt
ExecStart=/bin/sh -c 'date +%%s >> /var/lib/kt/heartbeat'
EOF
sudo tee /etc/systemd/system/kt-heartbeat.timer >/dev/null <<'EOF'
[Unit]
Description=Kinoite test heartbeat timer
[Timer]
OnBootSec=10s
OnActiveSec=5s
OnUnitActiveSec=30s
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF
check "unit-verify" sudo systemd-analyze verify /etc/systemd/system/kt-heartbeat.service /etc/systemd/system/kt-heartbeat.timer
sudo systemctl daemon-reload
check "timer-enable" sudo systemctl enable --now kt-heartbeat.timer
check "timer-fired" wait_for 60 sudo test -s /var/lib/kt/heartbeat
check "unit-journal" bash -c 'sudo journalctl -u kt-heartbeat.service --no-pager -q | grep -q .'

# Sandboxing directives are enforced
out=$(sudo systemd-run --quiet --wait --pipe \
  -p ProtectSystem=strict -p ProtectHome=yes -p PrivateTmp=yes -p NoNewPrivileges=yes \
  -p DynamicUser=yes -p PrivateNetwork=yes \
  /bin/sh -c 'touch /etc/kt-x 2>/dev/null && echo ETC_WRITABLE; ls /home/tester >/dev/null 2>&1 && echo HOME_VISIBLE;
              ls /sys/class/net | tr "\n" " "; echo; grep NoNewPrivs /proc/self/status' 2>&1)
grep -q ETC_WRITABLE <<<"$out" && fail "sandbox-protectsystem" "/etc writable" || pass "sandbox-protectsystem" "/etc read-only in unit"
grep -q HOME_VISIBLE <<<"$out" && fail "sandbox-protecthome" "home visible" || pass "sandbox-protecthome" "home hidden"
grep -Eq '^lo *$' <<<"$out" && pass "sandbox-privatenetwork" "only lo" || fail "sandbox-privatenetwork" "$out"
grep -Eq 'NoNewPrivs:\s+1' <<<"$out" && pass "sandbox-nonewprivs" "NoNewPrivs=1" || fail "sandbox-nonewprivs" "$out"
check_not "sandbox-no-root-file" sudo test -e /etc/kt-x

# User manager
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/kt-user.service <<'EOF'
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo ok > %h/kt-user-ran'
EOF
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user daemon-reload
check "user-unit" bash -c 'systemctl --user start kt-user.service && test -s ~/kt-user-ran'
check "linger-enable" sudo loginctl enable-linger tester
