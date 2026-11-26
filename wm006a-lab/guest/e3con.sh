# e3con.sh STEP [ARGS] : E3 guest-console helper (run as root in the guest).
STEP="$1"; shift; SUITE="e3con-$STEP"
E3=/var/opt/wm006a-e3/bin/wm006a-e3
UI=/run/wm006a-e3/ui/sock
RES=/run/wm006a-e3-console
vt_active() { cat /sys/class/tty/tty0/active; }
screen9() { python3 -I -c 'import sys; d=open("/dev/vcs9","rb").read(); w=int(sys.argv[1]); print("\n".join(d[i:i+w].decode("latin-1").rstrip() for i in range(0,len(d),w)).rstrip())' "$(stty -F /dev/tty9 size 2>/dev/null | awk '{print $2}')"; }
case "$STEP" in
install)
  install -o root -g root -m0755 "$LAB_SRC/e3/wm006a-e3-console" /var/opt/wm006a-e3/bin/
  install -o root -g root -m0644 "$LAB_SRC/e3/systemd/wm006a-e3-console@.service" /etc/systemd/system/
  check "console-unit-verify" systemd-analyze verify /etc/systemd/system/wm006a-e3-console@.service
  # Console steps (VT switches, a deliberate wrong-VT attempt) need more than the 15 s default.
  install -Dm644 /dev/stdin /etc/systemd/system/wm006a-e3-signer.service.d/50-console-ttl.conf <<'EOF2'
[Service]
Environment=WM006A_E3_TTL=60
EOF2
  systemctl daemon-reload
  info "challenge-ttl" "$(systemctl show wm006a-e3-signer.service -p Environment --value)"
  systemctl start wm006a-e3-ui.socket wm006a-e3-custody.socket
  check "e3-sockets-listening" systemctl is-active --quiet wm006a-e3-ui.socket wm006a-e3-custody.socket
  info "tty-policy" "dev.tty.legacy_tiocsti=$(sysctl -n dev.tty.legacy_tiocsti 2>&1) tty9=$(stat -c '%U:%G %a' /dev/tty9) vcs9=$(stat -c '%U:%G %a' /dev/vcs9 2>&1) vcsa9=$(stat -c '%U:%G %a' /dev/vcsa9 2>&1) uinput=$(stat -c '%U:%G %a' /dev/uinput 2>&1) NAutoVTs=$(sed -n 's/^#*NAutoVTs=//p' /etc/systemd/logind.conf /usr/lib/systemd/logind.conf 2>/dev/null | head -n1)" ;;
propose) runuser -u "$lab_operator" -- "$E3" client "$UI" "PROPOSE id=$1 from=LAB-001 to=LAB-002 amount=${2:-5} unit=TESTUNIT memo=synthetic" ;;
start)
  rm -f "$RES/result-$1"; systemctl reset-failed "wm006a-e3-console@$1.service" 2>/dev/null
  systemctl start "wm006a-e3-console@$1.service" && sleep 2 && echo "started on $(systemctl show "wm006a-e3-console@$1.service" -p TTYPath --value)" ;;
result) if [[ -f "$RES/result-$1" ]]; then cat "$RES/result-$1"; else echo "pending unit=$(systemctl is-active "wm006a-e3-console@$1.service")"; fi ;;
vt) vt_active ;;
chvt) chvt "$1"; sleep 1; vt_active ;;
seat) echo "active_vt=$(vt_active) seat0_active_session=$(loginctl show-seat seat0 -p ActiveSession --value) sessions=[$(loginctl list-sessions --no-legend | awk '{print $1":"$3":"$4":"$7}' | xargs)]" ;;
screen) screen9 ;;
code) screen9 | sed -n 's/.*CONFIRMATION CODE: \([0-9]\{6\}\).*/\1/p' | head -n1 ;;
inject)   # guest root reads the console buffer and injects the code into tty9 with TIOCSTI
  code=$(screen9 | sed -n 's/.*CONFIRMATION CODE: \([0-9]\{6\}\).*/\1/p' | head -n1)
  python3 -I -c 'import fcntl,sys,termios; fd=open("/dev/tty9","rb",buffering=0).fileno()
for ch in (sys.argv[1]+"\n").encode(): fcntl.ioctl(fd, termios.TIOCSTI, bytes([ch]))
print("injected", len(sys.argv[1]), "digits via TIOCSTI as root")' "$code" 2>&1 ;;
negatives)
  # The operator's graphical session must not be able to read, write, inject into or switch to
  # the approval terminal, nor start the agent.
  opn() { runuser -u "$lab_operator" -- python3 -I -c 'import os,sys
try:
    os.close(os.open(sys.argv[1], int(sys.argv[2]))); print("opened"); sys.exit(1)
except OSError as e: print(f"errno={e.errno} {e.strerror}")' "$1" "$2" 2>&1; }
  for spec in "/dev/tty9:1:write" "/dev/vcs9:0:read" "/dev/vcsa9:0:read" "/dev/uinput:1:write" "/dev/tty0:1:write"; do
    IFS=: read -r p mode what <<<"$spec"; r=$(opn "$p" "$mode")
    [[ "$r" == errno=* ]] && pass "operator-cannot-$what-$(basename "$p")" "$r" || fail "operator-cannot-$what-$(basename "$p")" "$r"
  done
  r=$(runuser -u "$lab_operator" -- chvt 9 2>&1); a=$(vt_active)
  [[ "$a" != tty9 ]] && pass "operator-cannot-switch-vt" "chvt 9 as operator: $(tail -n1 <<<"$r"); active VT still $a" || fail "operator-cannot-switch-vt" "active=$a $r"
  r=$(runuser -u "$lab_operator" -- systemctl start --no-ask-password wm006a-e3-console@P-0999.service 2>&1)
  [[ "$(systemctl is-active wm006a-e3-console@P-0999.service)" != active ]] && pass "operator-cannot-start-agent" "$(tail -n1 <<<"$r")" || fail "operator-cannot-start-agent" "agent started"
  r=$(runuser -u "$lab_operator" -- python3 -I -c 'import fcntl,termios,os
fd=os.open("/dev/tty9", os.O_WRONLY)' 2>&1)
  [[ "$r" == *Permission* || "$r" == *Errno* ]] && pass "operator-cannot-tiocsti-tty9" "cannot even open tty9: $(tail -n1 <<<"$r")" || fail "operator-cannot-tiocsti-tty9" "$r" ;;
final)   # final CODE... : approvals recorded, typed codes absent from all logs
  recs=$(ls /var/lib/wm006a-e3/approvals 2>/dev/null | sort | xargs)
  [[ "$recs" == "P-0001-r1.txt P-0003-r2.txt" ]] && pass "records-only-console-approvals" "$recs" || fail "records-only-console-approvals" "$recs"
  # Whole-word search of the agent's and signer's messages (6-digit codes would collide with
  # timestamps and PIDs if the whole raw journal were searched as substrings).
  j=$(journalctl -b -o cat --no-pager -u 'wm006a-e3-console@*' -u wm006a-e3-signer.service -u wm006a-e3-ui.socket -u wm006a-e3-custody.socket); hits=0
  for c in "$@"; do grep -awq "$c" <<<"$j" && hits=$((hits+1)); done
  [[ $hits -eq 0 && $# -gt 0 ]] && pass "codes-not-logged" "none of the $# confirmation codes appears in the agent or signer journal ($(wc -l <<<"$j") lines)" || fail "codes-not-logged" "$hits of $# codes found"
  journalctl -b --no-pager -o short-precise -u 'wm006a-e3-console@*' > "$EV/e3con-agent-journal.txt" 2>&1
  grep 'console-approval' "$EV/e3con-agent-journal.txt" | sed 's/.*console-approval //' > "$EV/e3con-approval-provenance.txt" ;;
esac
