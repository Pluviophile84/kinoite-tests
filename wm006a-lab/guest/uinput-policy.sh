# uinput-policy.sh apply|state TAG|check TAG : guest-only policy that keeps /dev/uinput away from
# the active-seat (operator) user, and its verification.
STEP="$1"; TAG="${2:-}"; SUITE="uinput-${TAG:-$STEP}"; [[ "$STEP" == final ]] && SUITE=uinput-final
RULE=/etc/udev/rules.d/72-wm006a-no-uinput-uaccess.rules
acl_user() { getfacl -p /dev/uinput 2>/dev/null | grep -E "^user:$lab_operator:" || true; }
tags() { udevadm info -q property -n /dev/uinput | sed -n 's/^CURRENT_TAGS=//p'; }
sticky() { udevadm info -q property -n /dev/uinput | sed -n 's/^TAGS=//p'; }
indexed() { ls /run/udev/tags/uaccess 2>/dev/null | grep -qx 'c10:223' && echo yes || echo no; }   # uinput = misc 10:223
OVR=/etc/udev/rules.d/40-kdeconnect-uinput.rules
op_open() { runuser -u "$lab_operator" -- python3 -I -c 'import os
try:
    os.close(os.open("/dev/uinput", os.O_WRONLY)); print("opened")
except OSError as e: print(f"errno={e.errno} {e.strerror}")' 2>&1; }
case "$STEP" in
apply)
  install -Dm644 /dev/stdin "$RULE" <<'EOF'
# wm006a lab guest policy: never grant /dev/uinput to the active-seat user.
# Sorted after the rules that tag uinput for uaccess and before 73-seat-late.rules applies ACLs.
SUBSYSTEM=="misc", KERNEL=="uinput", TAG-="uaccess", TAG-="seat"
EOF
  # udev tags are sticky and logind applies seat ACLs from the uaccess tag index, so removing the
  # tag later is not enough: override the rule that adds it (same file name in /etc wins).
  if [[ -f /usr/lib/udev/rules.d/40-kdeconnect-uinput.rules ]]; then
    cp /usr/lib/udev/rules.d/40-kdeconnect-uinput.rules "$EV/40-kdeconnect-uinput.rules.original"
    printf '# wm006a lab guest policy: overrides /usr/lib/udev/rules.d/40-kdeconnect-uinput.rules so\n# /dev/uinput is never tagged for uaccess (KDE Connect remote input is disabled).\n' > "$OVR"
  fi
  check "policy-rule-installed" test -s "$RULE"
  check "kdeconnect-uaccess-rule-overridden" test -f "$OVR"
  info "policy-rule" "$(grep -v '^#' "$RULE" | xargs) ($(basename "$RULE"))"
  info "uinput-before-policy" "tags=$(tags) acl_user=[$(acl_user)] $(stat -c '%U:%G %a' /dev/uinput)"
  info "where-uinput-gets-uaccess" "$(grep -rls 'uinput' /usr/lib/udev/rules.d /etc/udev/rules.d 2>/dev/null | xargs -r grep -l uaccess | xargs | tr ' ' ',')"
  # Kinoite's first-boot setup (plasma-setup) takes seat0 on the next boot and blocks the
  # operator's autologin; mask it so the operator session is the one tested.
  units=$(systemctl list-unit-files --no-legend 'plasma-setup*' 2>/dev/null | awk '{print $1}' | xargs)
  [[ -n "$units" ]] && systemctl mask $units >/dev/null 2>&1
  info "first-boot-setup-masked" "${units:-none found} -> $(for u in $units; do printf '%s=%s ' "$u" "$(systemctl is-enabled "$u" 2>&1)"; done)" ;;
state)   # state TAG : record device policy state (no operator action)
  t=$(tags); a=$(acl_user)
  [[ ":$t:" != *":uaccess:"* ]] && pass "no-uaccess-tag" "CURRENT_TAGS=$t" || fail "no-uaccess-tag" "CURRENT_TAGS=$t"
  [[ "$(indexed)" == no && ":$(sticky):" != *":uaccess:"* ]] && pass "not-in-uaccess-index" "TAGS=$(sticky); /run/udev/tags/uaccess has no c10:223" || fail "not-in-uaccess-index" "TAGS=$(sticky) indexed=$(indexed)"
  [[ -z "$a" ]] && pass "no-operator-acl" "$(getfacl -p /dev/uinput 2>/dev/null | grep -v '^#' | xargs)" || fail "no-operator-acl" "$a"
  o=$(getfacl -p /dev/uinput 2>/dev/null | grep -E '^user:[^:]+:' | xargs || true)
  [[ -z "$o" ]] && pass "no-user-acl-at-all" "no named-user ACL entries (greeter included)" || fail "no-user-acl-at-all" "$o" ;;
check)   # check TAG : with the operator's Plasma session active
  sid=$(loginctl list-sessions --no-legend | awk -v u="$lab_operator" '$3==u && $4=="seat0" && $6=="user"{print $1}' | head -n1)
  props=$( [[ -n "$sid" ]] && loginctl show-session "$sid" -p Active -p Type -p VTNr | xargs )
  [[ "$props" == *"Active=yes"* && "$props" == *"Type=wayland"* ]] && pass "plasma-session-active" "session $sid $props; active VT $(cat /sys/class/tty/tty0/active)" \
    || fail "plasma-session-active" "session '$sid' $props"
  echo "$sid" > "/var/tmp/wm006a-lab/uinput-session-$TAG"
  t=$(tags); a=$(acl_user); r=$(op_open)
  [[ ":$t:" != *":uaccess:"* ]] && pass "no-uaccess-tag" "CURRENT_TAGS=$t" || fail "no-uaccess-tag" "CURRENT_TAGS=$t"
  [[ "$(indexed)" == no && ":$(sticky):" != *":uaccess:"* ]] && pass "not-in-uaccess-index" "TAGS=$(sticky); not indexed" || fail "not-in-uaccess-index" "TAGS=$(sticky) indexed=$(indexed)"
  [[ -z "$a" ]] && pass "no-operator-acl" "$(getfacl -p /dev/uinput 2>/dev/null | grep -v '^#' | xargs)" || fail "no-operator-acl" "$a"
  info "other-acl-entries" "$(getfacl -p /dev/uinput 2>/dev/null | grep -E '^user:[^:]+:' | xargs || true)"
  [[ "$r" == errno=13* ]] && pass "operator-uinput-write-denied" "operator open(/dev/uinput, O_WRONLY) while Plasma is active: $r" \
    || fail "operator-uinput-write-denied" "$r" ;;
final)   # final "EXPECTED RECORDS" CODE... : only the expected approvals exist; codes not logged
  want="${2//,/ }"; shift 2
  recs=$(ls /var/lib/wm006a-e3/approvals 2>/dev/null | sort | xargs)
  [[ "$recs" == "$want" ]] && pass "records-only-console-approvals" "$recs" || fail "records-only-console-approvals" "have [$recs] want [$want]"
  j=$(journalctl -o cat --no-pager -u 'wm006a-e3-console@*' -u wm006a-e3-signer.service); hits=0
  for c in "$@"; do grep -awq "$c" <<<"$j" && hits=$((hits+1)); done
  [[ $hits -eq 0 && $# -gt 0 ]] && pass "codes-not-logged" "none of the $# codes in the agent/signer journal (all boots)" || fail "codes-not-logged" "$hits of $#"
  journalctl --no-pager -o short-precise -u 'wm006a-e3-console@*' | grep console-approval | sed 's/.*console-approval //' > "$EV/approval-provenance.txt" ;;
esac
