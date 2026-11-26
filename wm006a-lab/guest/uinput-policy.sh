# uinput-policy.sh apply|state TAG|check TAG : guest-only policy that keeps /dev/uinput away from
# the active-seat (operator) user, and its verification.
STEP="$1"; TAG="${2:-}"; SUITE="uinput-${TAG:-$STEP}"
RULE=/etc/udev/rules.d/72-wm006a-no-uinput-uaccess.rules
acl_user() { getfacl -p /dev/uinput 2>/dev/null | grep -E "^user:$lab_operator:" || true; }
tags() { udevadm info -q property -n /dev/uinput | sed -n 's/^CURRENT_TAGS=//p'; }
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
  check "policy-rule-installed" test -s "$RULE"
  info "policy-rule" "$(grep -v '^#' "$RULE" | xargs) ($(basename "$RULE"))"
  info "uinput-before-policy" "tags=$(tags) acl_user=[$(acl_user)] $(stat -c '%U:%G %a' /dev/uinput)"
  info "where-uinput-gets-uaccess" "$(grep -rls 'uinput' /usr/lib/udev/rules.d /etc/udev/rules.d 2>/dev/null | xargs -r grep -l uaccess | xargs | tr ' ' ',')" ;;
state)   # state TAG : record device policy state (no operator action)
  t=$(tags); a=$(acl_user)
  [[ ":$t:" != *":uaccess:"* ]] && pass "no-uaccess-tag" "CURRENT_TAGS=$t" || fail "no-uaccess-tag" "CURRENT_TAGS=$t"
  [[ -z "$a" ]] && pass "no-operator-acl" "$(getfacl -p /dev/uinput 2>/dev/null | grep -v '^#' | xargs)" || fail "no-operator-acl" "$a" ;;
check)   # check TAG : with the operator's Plasma session active
  sid=$(loginctl list-sessions --no-legend | awk -v u="$lab_operator" '$3==u && $4=="seat0" && $6=="user"{print $1}' | head -n1)
  props=$( [[ -n "$sid" ]] && loginctl show-session "$sid" -p Active -p Type -p VTNr | xargs )
  [[ "$props" == *"Active=yes"* && "$props" == *"Type=wayland"* ]] && pass "plasma-session-active" "session $sid $props; active VT $(cat /sys/class/tty/tty0/active)" \
    || fail "plasma-session-active" "session '$sid' $props"
  echo "$sid" > "/var/tmp/wm006a-lab/uinput-session-$TAG"
  t=$(tags); a=$(acl_user); r=$(op_open)
  [[ ":$t:" != *":uaccess:"* ]] && pass "no-uaccess-tag" "CURRENT_TAGS=$t" || fail "no-uaccess-tag" "CURRENT_TAGS=$t"
  [[ -z "$a" ]] && pass "no-operator-acl" "$(getfacl -p /dev/uinput 2>/dev/null | grep -v '^#' | xargs)" || fail "no-operator-acl" "$a"
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
