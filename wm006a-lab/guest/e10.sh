# e10.sh STEP : E10 scheduler lifecycle with real Kinoite events (run as root in the guest).
STEP="$1"; SUITE="e10-$STEP"
E10=/var/opt/wm006a-e10/bin/wm006a-e10
PROBE10=/var/opt/wm006a-e10/bin/e10_probe.py
CTL=/run/wm006a-e10/ctl
REF=/var/lib/wm006a-lab-e10; install -d -m0700 "$REF"
L="$EV/e10-transcript.txt"
talk() {  # talk AS_USER LINE  (root talks directly)
  local who="$1" line="$2" r
  r=$(runuser -u "$who" -- python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode()+b"\n"); print(s.recv(4096).decode().strip())' "$CTL" "$line" 2>&1)
  printf '[%s] %s -> %s\n' "$who" "$line" "$r" >> "$L"; echo "$r"
}
status() { talk root STATUS; }
sv() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$2"; }
pid() { sv pid "$(status)"; }
scan() { python3 -I "$PROBE10" scan "$(pid)" "$1" 2>&1 | tee -a "$L"; }
capture() { local s; s=$(status); python3 -I "$PROBE10" capture "$(sv pid "$s")" "$(sv key_addr "$s")" "$1" 2>&1 | tee -a "$L"; }
# The wm006a sockets have no [Install] section, so after a boot the admin starts the full set (E1).
signer_up() { systemctl start wm006a-ui.socket wm006a-custody.socket wm006a-gateway.socket
              runuser -u "$lab_operator" -- python3 "$PROBE" /run/wm006a/ui/sock 'UI_PING\n' 'OK UI+GATEWAY\n' >/dev/null 2>&1; }
arm() {  # arm LABEL -> arms, captures, positive-control scan; echoes epoch
  signer_up
  local r; r=$(talk wm006a-custody "ARM operational")
  local e; e=$(sed -n 's/.*epoch=\([0-9]*\).*/\1/p' <<<"$r")
  if [[ "$r" == ARMED* ]] && capture "$1" | grep -q nonzero=True && scan "$1" | grep -q 'full=1 .*slot=key'; then
    pass "armed-key-present-$1" "$r; root probe finds the key exactly once in daemon memory"
  else fail "armed-key-present-$1" "$r"; fi
  echo "$e" > "$REF/epoch-$1"
}
event_seen() {  # event_seen NAME SINCE_MONO  -> daemon recorded the event after SINCE
  local s; s=$(status)
  python3 -c 'import re,sys; ev=re.search(r"events=\[(.*)\]", sys.argv[1]).group(1).split()
t=float(sys.argv[3]); sys.exit(0 if any(e.split("@")[0]==sys.argv[2] and float(e.split("@")[1])>=t for e in ev) else 1)' "$s" "$1" "$2"
}
mono_now() { python3 -c 'import time; print(f"{time.monotonic():.1f}")'; }
preserved() {  # preserved EVENT LABEL T0
  local s; s=$(status)
  if event_seen "$1" "$3" && [[ "$(sv state "$s")" == armed ]] && scan "$2" | grep -q 'full=1 .*slot=key'; then
    pass "$1-observed-grant-preserved" "daemon saw the real $1 event; still armed; key intact"
  else fail "$1-observed-grant-preserved" "seen=$(event_seen "$1" "$3" && echo yes || echo no) $s"; fi
}
cleared() {  # cleared REASON LABEL
  local s r; s=$(status); r=$(scan "$2")
  if [[ "$(sv state "$s")" == disarmed && "$(sv reason "$s")" == "$1" && "$(sv key_loaded "$s")" == 0 ]] && grep -q 'full=0 half1=0 half2=0 slot=zero' <<<"$r"; then
    pass "$1-disarmed-key-cleared" "state=disarmed reason=$1; root scan: $r"
  else fail "$1-disarmed-key-cleared" "$s | $r"; fi
}
old_epoch_rejected() {  # old_epoch_rejected LABEL
  local r; r=$(talk "$lab_operator" "DISPATCH $(cat "$REF/epoch-$1") after-$1")
  [[ "$r" == REJECT* ]] && pass "old-grant-rejected-after-$1" "$r" || fail "old-grant-rejected-after-$1" "$r"
}
op_sid() { loginctl list-sessions --no-legend | awk -v u="$lab_operator" '$3==u && $4=="seat0" && $6=="user"{print $1}' | head -n1; }

case "$STEP" in
install)
  install -Dm644 "$LAB_SRC/e10/systemd/wm006a-e10.sysusers" /etc/sysusers.d/wm006a-e10.conf
  systemd-sysusers /etc/sysusers.d/wm006a-e10.conf
  install -d -o root -g root -m0755 /var/opt/wm006a-e10/bin
  install -o root -g root -m0755 "$LAB_SRC/e10/wm006a-e10" "$LAB_SRC/e10/e10_probe.py" /var/opt/wm006a-e10/bin/
  chmod 0700 "$PROBE10"   # root-only probe
  install -o root -g root -m0644 "$LAB_SRC/e10/systemd/wm006a-e10.service" /etc/systemd/system/
  check "unit-verify" systemd-analyze verify /etc/systemd/system/wm006a-e10.service
  systemctl daemon-reload; systemctl enable --now wm006a-e10.service; sleep 3
  check "service-enabled-at-boot" systemctl is-enabled --quiet wm006a-e10.service
  check "service-running" systemctl is-active --quiet wm006a-e10.service
  s=$(status)
  [[ "$(sv state "$s")" == disarmed && "$(sv reason "$s")" == start ]] && pass "starts-disarmed" "$s" || fail "starts-disarmed" "$s"
  inh=$(systemd-inhibit --list --no-pager 2>&1 | grep wm006a-e10)
  # logind may list the lock types in either order (sleep:shutdown or shutdown:sleep).
  [[ "$(sv inhibitor "$s")" == held ]] && grep -Eq 'sleep:shutdown|shutdown:sleep' <<<"$inh" && grep -q delay <<<"$inh" \
    && pass "delay-inhibitor-held" "$(xargs <<<"$inh")" || fail "delay-inhibitor-held" "status inhibitor=$(sv inhibitor "$s"); list: $inh"
  journalctl -b -u wm006a-e10.service --no-pager -o cat | grep -q 'mlock failed' && fail "key-page-locked" "mlock failed" || pass "key-page-locked" "mlock succeeded (no failure logged)"
  info "logind-capabilities" "CanSuspend=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend | cut -d' ' -f2) CanHibernate=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate | cut -d' ' -f2) mem_sleep=[$(cat /sys/power/mem_sleep)] swaps=[$(tail -n +2 /proc/swaps | awk '{print $1}' | xargs)]"
  e=$(talk "$lab_operator" "STATUS"); [[ "$e" == "ERR PEER" ]] && pass "status-root-only" "operator STATUS -> $e" || fail "status-root-only" "$e"
  e=$(talk "$lab_operator" "ARM operational"); [[ "$e" == "ERR PEER" ]] && pass "operator-cannot-arm" "$e" || fail "operator-cannot-arm" "$e"
  e=$(runuser -u wm006a-e10 -- python3 -I "$PROBE10" scan 1 x 2>&1); [[ "$e" == *Permission* || "$e" == *Errno* ]] && pass "probe-root-only" "probe as daemon user fails: $(tail -n1 <<<"$e" | cut -c1-80)" || fail "probe-root-only" "$e" ;;

roles)
  e=$(talk wm006a-custody "ARM treasury"); [[ "$e" == "ERR ROLE treasury" ]] && pass "treasury-cannot-arm" "$e" || fail "treasury-cannot-arm" "$e"
  e=$(talk wm006a-custody "ARM watch-only"); [[ "$e" == "ERR ROLE watch-only" ]] && pass "watch-only-cannot-arm" "$e" || fail "watch-only-cannot-arm" "$e"
  # A real disk-backed swap is a hibernation target: arming must be refused while it is active.
  sw=/var/wm006a-e10-swapfile
  fallocate -l 64M "$sw" && chmod 600 "$sw" && mkswap -q "$sw" >/dev/null && swapon "$sw"
  signer_up; e=$(talk wm006a-custody "ARM operational")
  [[ "$e" == "ERR HIBERNATION_TARGET $sw" ]] && pass "disk-swap-blocks-arming" "$e (real swapon of $sw)" || fail "disk-swap-blocks-arming" "$e"
  swapoff "$sw"; rm -f "$sw" ;;

session)
  arm session >/dev/null
  sid=$(op_sid)
  if [[ -z "$sid" ]]; then
    for c in screen-lock session-switch gui-close gui-crash logout; do blocked "$c-observed-grant-preserved" "no operator graphical session"; done
  else
    info "operator-session" "$sid $(loginctl show-session "$sid" -p Type -p Class -p VTNr | xargs)"
    t=$(mono_now); loginctl lock-session "$sid"; sleep 3; preserved screen-lock session "$t"
    loginctl unlock-session "$sid"; sleep 2
    t=$(mono_now); vt=$(loginctl show-session "$sid" -p VTNr --value); chvt 3; sleep 3; chvt "${vt:-1}"; sleep 2; preserved session-switch session "$t"
    t=$(mono_now)
    runuser -u "$lab_operator" -- python3 -I -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"HELLO\n"); s.recv(64); time.sleep(1); s.sendall(b"BYE\n"); s.close()' "$CTL"
    sleep 2; preserved gui-close session "$t"
    t=$(mono_now)
    runuser -u "$lab_operator" -- python3 -I -c 'import os,signal,socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"HELLO\n"); s.recv(64); time.sleep(1); os.kill(os.getpid(), signal.SIGKILL)' "$CTL"
    sleep 2; preserved gui-crash session "$t"
    t=$(mono_now); loginctl terminate-session "$sid"; sleep 4; preserved logout session "$t"
    r=$(talk "$lab_operator" "DISPATCH $(cat "$REF/epoch-session") row-after-session-events")
    [[ "$r" == DISPATCHED* ]] && pass "dispatch-after-preserving-events" "$r" || fail "dispatch-after-preserving-events" "$r"
  fi ;;

signer-failure)
  arm sf >/dev/null; t=$(mono_now)
  systemctl kill -s KILL --kill-whom=main wm006a-signer.service; sleep 3
  event_seen signer-failure "$t" && pass "signer-failure-observed" "SIGKILL of wm006a-signer seen by the scheduler" || fail "signer-failure-observed" "$(status)"
  cleared signer-failure sf; old_epoch_rejected sf
  systemctl reset-failed wm006a-signer.service 2>/dev/null; signer_up
  r=$(talk wm006a-custody "ARM operational"); [[ "$r" == ARMED* && "$r" != *"epoch=$(cat "$REF/epoch-sf") "* ]] && pass "explicit-rearm-after-signer-failure" "$r" || fail "explicit-rearm-after-signer-failure" "$r" ;;

expiry)
  arm ex >/dev/null
  ttl=$(sed -n 's/.*ttl_left=\([0-9]*\).*/\1/p' <<<"$(status)"); sleep $(( ${ttl:-45} + 3 ))
  cleared expiry ex; old_epoch_rejected ex ;;

clock-jump)
  arm cj >/dev/null; t=$(mono_now)
  timedatectl set-ntp false; date -s "+2 hours" >/dev/null; sleep 3
  s=$(status)
  event_seen clock-jump "$t" && [[ "$(sv state "$s")" == paused && "$(sv reason "$s")" == clock-jump ]] \
    && pass "clock-jump-pauses" "real +2h wall-clock step; $s" || fail "clock-jump-pauses" "$s"
  r=$(talk "$lab_operator" "DISPATCH $(cat "$REF/epoch-cj") row-while-paused")
  [[ "$r" == "REJECT state=paused" ]] && pass "paused-dispatch-rejected" "$r" || fail "paused-dispatch-rejected" "$r"
  signer_up; r=$(talk wm006a-custody "ARM operational"); s2=$(scan cj)
  [[ "$r" == ARMED* ]] && grep -q 'full=0 half1=0 half2=0' <<<"$s2" && pass "fresh-approval-replaces-paused-key" "$r; old key gone: $s2" || fail "fresh-approval-replaces-paused-key" "$r | $s2"
  date -s "-2 hours" >/dev/null; timedatectl set-ntp true; sleep 3 ;;

stop)
  arm st >/dev/null; p=$(pid); since=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl stop wm006a-e10.service; sleep 1
  j=$(journalctl -u wm006a-e10.service --since "$since" --no-pager -o cat)
  grep -q 'zeroized reason=stop' <<<"$j" && grep -q 'e10 scheduler stopped' <<<"$j" \
    && pass "stop-zeroizes-before-exit" "$(grep 'zeroized reason=stop' <<<"$j")" || fail "stop-zeroizes-before-exit" "$(tr '\n' ' ' <<<"$j" | tail -c 300)"
  res=$(systemctl show wm006a-e10.service -p Result --value)
  cd_out=$(coredumpctl list --no-pager "$p" 2>&1)
  [[ "$res" == success ]] && grep -q 'No coredumps' <<<"$cd_out" && pass "stop-clean-exit-no-core" "Result=$res; no core dump for pid $p" || fail "stop-clean-exit-no-core" "Result=$res; $cd_out"
  systemctl start wm006a-e10.service; sleep 3; s=$(status)
  [[ "$(sv state "$s")" == disarmed && "$(sv reason "$s")" == start ]] && pass "restart-requires-rearm" "$s" || fail "restart-requires-rearm" "$s"
  old_epoch_rejected st ;;

pre-reboot) arm rb >/dev/null; pid > "$REF/pid-rb" ;;
post-reboot)
  if [[ $(journalctl --list-boots --no-pager 2>/dev/null | wc -l) -lt 2 ]]; then
    blocked "reboot-zeroized-before-shutdown" "no persistent journal for the previous boot"
  else
    j=$(journalctl -b -1 -u wm006a-e10.service --no-pager -o cat)
    grep -q 'event prepare-for-shutdown' <<<"$j" && grep -q 'zeroized reason=shutdown' <<<"$j" \
      && pass "reboot-zeroized-before-shutdown" "previous boot: PrepareForShutdown seen, key zeroized under the delay inhibitor" \
      || fail "reboot-zeroized-before-shutdown" "$(tail -n 5 <<<"$j" | tr '\n' ' ')"
  fi
  s=$(status)
  [[ "$(sv state "$s")" == disarmed && "$(sv reason "$s")" == start && "$(sv key_loaded "$s")" == 0 ]] && pass "boot-starts-disarmed" "$s" || fail "boot-starts-disarmed" "$s"
  old_epoch_rejected rb ;;

pre-suspend) arm sl >/dev/null; date '+%Y-%m-%d %H:%M:%S' > "$REF/since-sl" ;;
suspend-now) systemd-run --quiet --on-active=3 --unit=wm006a-e10-suspend systemctl suspend && echo "suspend scheduled" ;;
post-suspend)
  since=$(cat "$REF/since-sl")
  journalctl -b --since "$since" --no-pager -o short-monotonic > "$EV/e10-suspend-journal.txt" 2>&1
  order=$(python3 - "$since" <<'PY'
import json, subprocess, sys
rows = [json.loads(l) for l in subprocess.run(["journalctl", "-b", "--since", sys.argv[1], "-o", "json", "--no-pager"],
        capture_output=True, text=True).stdout.splitlines() if l.strip()]
def first(pred):
    return next((int(r["__MONOTONIC_TIMESTAMP"]) for r in rows if pred(str(r.get("MESSAGE", "")))), None)
z = first(lambda m: "zeroized reason=sleep" in m)
s = first(lambda m: m.startswith("PM: suspend entry"))
x = first(lambda m: m.startswith("PM: suspend exit"))
print(f"zeroize={z} suspend_entry={s} suspend_exit={x} ok={z is not None and s is not None and x is not None and z < s < x}")
PY
)
  grep -q 'ok=True' <<<"$order" && pass "suspend-zeroized-before-sleep-entry" "$order" || fail "suspend-zeroized-before-sleep-entry" "$order"
  info "suspend-kernel-lines" "$(grep -E 'PM: suspend (entry|exit)|ACPI: PM: (Preparing|Waking|Low-level)' "$EV/e10-suspend-journal.txt" | awk '{$1="";print}' | head -n 4 | tr '\n' ';')"
  cleared sleep sl; old_epoch_rejected sl
  s=$(status); [[ "$(sv inhibitor "$s")" == held ]] && pass "inhibitor-retaken-after-resume" "inhibitor=held" || fail "inhibitor-retaken-after-resume" "$s"
  signer_up; r=$(talk wm006a-custody "ARM operational"); [[ "$r" == ARMED* ]] && pass "explicit-rearm-after-resume" "$r" || fail "explicit-rearm-after-resume" "$r" ;;
suspend-blocked) SUITE=e10-post-suspend; blocked "suspend-zeroized-before-sleep-entry" "$2"; blocked "sleep-disarmed-key-cleared" "$2" ;;

hibernate)
  ch=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate | cut -d' ' -f2 | tr -d '"')
  blocked "hibernate-disarms-and-clears" "VM cannot hibernate: logind CanHibernate=$ch, swap=[$(tail -n +2 /proc/swaps | awk '{print $1}' | xargs)], /sys/power/disk=[$(cat /sys/power/disk)]" ;;

final)
  labels=$(ls /run/wm006a-e10-probe 2>/dev/null | xargs)
  r=$(python3 -I "$PROBE10" files $labels -- /var/lib /var/tmp /var/log /etc /var/opt /var/home 2>&1)
  [[ $? -eq 0 ]] && pass "no-key-on-disk-or-journal" "$r (all $(wc -w <<<"$labels") captured keys)" || fail "no-key-on-disk-or-journal" "$r"
  rm -rf /run/wm006a-e10-probe
  [[ ! -e /run/wm006a-e10-probe ]] && pass "probe-copies-destroyed" "root-only captured copies removed from /run" || fail "probe-copies-destroyed" "still present"
  journalctl -b -u wm006a-e10.service --no-pager -o short-monotonic > "$EV/e10-daemon-journal.txt" 2>&1 ;;
esac
