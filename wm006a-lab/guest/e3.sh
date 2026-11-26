# E3 guest portion: one-time approval of a synthetic plan by the custody identity, and rejection
# of the operator identity, a changed revision, a modified field, replay, expiry and a challenge
# issued before signer restart. Plans are fictional; approval records are inert text files.
SUITE=e3
E3=/var/opt/wm006a-e3/bin/wm006a-e3
UI=/run/wm006a-e3/ui/sock; CU=/run/wm006a-e3/custody/sock
REC=/var/lib/wm006a-e3/approvals
L="$EV/e3-transcript.txt"; : > "$L"
op()  { local r; r=$(runuser -u "$lab_operator" -- "$E3" client "$UI" "$1" 2>&1); printf '[operator -> ui] %s\n%s\n' "$1" "$r" >> "$L"; echo "$r"; }
cu()  { local r; r=$(runuser -u wm006a-custody -- "$E3" client "$CU" "$1" 2>&1); printf '[custody -> custody] %s\n%s\n' "$1" "$r" >> "$L"; echo "$r"; }
field() { sed -n "s/^| $1:[[:space:]]*\([^ ]*\).*/\1/p" <<<"$2" | head -n1; }
expect() {  # expect NAME EXPECTED ACTUAL
  [[ "$3" == "$2" ]] && pass "$1" "$3" || fail "$1" "expected '$2', got '$(tr '\n' ' ' <<<"$3")'"
}
plan() { echo "id=$1 from=LAB-001 to=LAB-002 amount=${2:-5} unit=TESTUNIT memo=synthetic"; }
digest() {  # independent digest of the canonical plan (sorted key=value joined by ;)
  python3 -c 'import hashlib,sys; f=dict(w.split("=",1) for w in sys.argv[1:]); print("sha256:"+hashlib.sha256(";".join(f"{k}={f[k]}" for k in sorted(f)).encode()).hexdigest())' $(plan "$1" "${2:-}")
}
records() { ls "$REC" 2>/dev/null | sort | tr '\n' ' '; }

# --- Activation, identities, and who may talk to which socket ---
r=$(op "PROPOSE $(plan P-0001)")
sp=$(systemctl show -p MainPID --value wm006a-e3-signer.service)
[[ "$sp" -gt 0 ]] && pass "e3-signer-socket-activated" "pid $sp user $(ps -o user:32= -p "$sp" | xargs) label $(ps -o label= -p "$sp")" || fail "e3-signer-socket-activated" "not running"
d1=$(digest P-0001)
expect "propose-revision-1" "REVISION P-0001 1" "$(cut -d' ' -f1-3 <<<"$r")"
expect "digest-independently-verified" "$d1" "$(cut -d' ' -f4 <<<"$r")"
e=$(runuser -u "$lab_operator" -- "$E3" client "$CU" "SCREEN P-0001" 2>&1); expect "operator-denied-custody-socket" "connect errno=13" "$e"
e=$(runuser -u "$lab_operator" -g wm006a-custody -- "$E3" client "$CU" "SCREEN P-0001" 2>&1); expect "operator-with-custody-group-peer-rejected" "ERR PEER" "$e"
expect "operator-approve-on-ui-rejected" "ERR REQUEST" "$(op "APPROVE P-0001 1 $d1 x.y")"
e=$(runuser -u wm006a-custody -- "$E3" client "$UI" "PROPOSE $(plan P-0009)" 2>&1); expect "custody-denied-ui-socket" "connect errno=13" "$e"
e=$(runuser -u "$lab_outsider" -- "$E3" client "$UI" "PROPOSE $(plan P-0009)" 2>&1); expect "outsider-denied-ui-socket" "connect errno=13" "$e"
e=$(runuser -u "$lab_outsider" -- "$E3" client "$CU" "SCREEN P-0001" 2>&1); expect "outsider-denied-custody-socket" "connect errno=13" "$e"

# --- Valid one-time approval ---
s=$(cu "SCREEN P-0001"); cp <(echo "$s") "$EV/e3-screen-P-0001.txt"
c=$(field challenge "$s")
if [[ "$(field digest "$s")" == "$d1" ]] && grep -q 'revision: 1' <<<"$s" && grep -q 'move 5 TESTUNIT from LAB-001 to LAB-002' <<<"$s"; then
  pass "signer-surfaces-revision" "screen shows plan P-0001 revision 1, its summary and digest ${d1:0:23}…"
else fail "signer-surfaces-revision" "$(tr '\n' ' ' <<<"$s")"; fi
expect "custody-approves-exact-plan" "APPROVED P-0001 rev=1 digest=$d1" "$(cu "APPROVE P-0001 1 $d1 $c")"
expect "approval-recorded-once" "P-0001-r1.txt " "$(records)"
rec=$(cat "$REC/P-0001-r1.txt" 2>/dev/null)
[[ "$rec" == "inert=true synthetic=true plan=P-0001 revision=1 digest=$d1 approver_uid=$(id -u wm006a-custody) "* ]] \
  && pass "approval-record-inert" "$(stat -c '%U %a' "$REC/P-0001-r1.txt"); approver is the custody UID" || fail "approval-record-inert" "$rec"
expect "approval-store-private" "wm006a-signer 700|wm006a-signer 700" "$(stat -c '%U %a' /var/lib/wm006a-e3)|$(stat -c '%U %a' "$REC")"

# --- Replay (sequential and concurrent) ---
expect "replay-rejected" "ERR REPLAY" "$(cu "APPROVE P-0001 1 $d1 $c")"
op "PROPOSE $(plan P-0002)" >/dev/null; d2=$(digest P-0002); c=$(field challenge "$(cu "SCREEN P-0002")")
runuser -u wm006a-custody -- "$E3" client "$CU" "APPROVE P-0002 1 $d2 $c" > "$LAB/e3-par1" 2>&1 &
runuser -u wm006a-custody -- "$E3" client "$CU" "APPROVE P-0002 1 $d2 $c" > "$LAB/e3-par2" 2>&1 &
wait
par=$(cat "$LAB/e3-par1" "$LAB/e3-par2" | awk '{print $1, $2}' | sort | tr '\n' ';'); rm -f "$LAB"/e3-par?
expect "concurrent-replay-one-wins" "APPROVED P-0002;ERR REPLAY;" "$par"

# --- Changed revision and modified field ---
op "PROPOSE $(plan P-0003)" >/dev/null; d3=$(digest P-0003); c=$(field challenge "$(cu "SCREEN P-0003")")
r=$(op "PROPOSE $(plan P-0003 6)"); d3b=$(digest P-0003 6)
expect "changed-plan-new-revision" "REVISION P-0003 2 $d3b" "$r"
expect "changed-revision-rejected" "ERR STALE_REVISION" "$(cu "APPROVE P-0003 1 $d3 $c")"
s=$(cu "SCREEN P-0003"); c=$(field challenge "$s")
grep -q 'revision: 2' <<<"$s" && grep -q 'move 6 TESTUNIT' <<<"$s" && pass "screen-shows-new-revision" "revision 2, amount 6" || fail "screen-shows-new-revision" "$(tr '\n' ' ' <<<"$s")"
expect "modified-field-rejected" "ERR BINDING" "$(cu "APPROVE P-0003 2 $d3 $c")"

# --- Expiry ---
op "PROPOSE $(plan P-0004)" >/dev/null; d4=$(digest P-0004); c=$(field challenge "$(cu "SCREEN P-0004")")
ttl=$(systemctl show wm006a-e3-signer.service -p Environment --value | tr ' ' '\n' | sed -n 's/^WM006A_E3_TTL=//p')
sleep $(( ${ttl:-15} + 3 ))
expect "expired-challenge-rejected" "ERR EXPIRED" "$(cu "APPROVE P-0004 1 $d4 $c")"

# --- Challenge from before signer restart ---
op "PROPOSE $(plan P-0005)" >/dev/null; d5=$(digest P-0005); s=$(cu "SCREEN P-0005"); c=$(field challenge "$s"); g0=$(field generation "$s")
inv0=$(systemctl show wm006a-e3-signer.service -p InvocationID --value)
systemctl restart wm006a-e3-signer.service
r=$(op "PROPOSE $(plan P-0005)"); s=$(cu "SCREEN P-0005"); g1=$(field generation "$s"); cnew=$(field challenge "$s")
inv1=$(systemctl show wm006a-e3-signer.service -p InvocationID --value)
[[ "$inv0" != "$inv1" && -n "$g1" && "$g0" != "$g1" ]] && pass "signer-restarted-new-generation" "generation $g0 -> $g1" || fail "signer-restarted-new-generation" "inv $inv0->$inv1 gen $g0->$g1"
expect "pre-restart-challenge-rejected" "ERR STALE_GENERATION" "$(cu "APPROVE P-0005 1 $d5 $c")"
# Positive control: a fresh post-restart challenge for the same plan approves exactly once.
expect "post-restart-plan-reproposed" "REVISION P-0005 1 $d5" "$r"
expect "post-restart-fresh-challenge-approves" "APPROVED P-0005 rev=1 digest=$d5" "$(cu "APPROVE P-0005 1 $d5 $cnew")"
expect "post-restart-fresh-challenge-replay-rejected" "ERR REPLAY" "$(cu "APPROVE P-0005 1 $d5 $cnew")"

# --- Only the two valid approvals exist; nothing sensitive in the journal ---
expect "records-only-valid-approvals" "P-0001-r1.txt P-0002-r1.txt P-0005-r1.txt " "$(records)"
leak=$(journalctl -b -u wm006a-e3-signer.service --no-pager -o cat | grep -cE '[0-9a-f]{8}-[0-9a-f]{8}\.[0-9a-f]{32}')
[[ "$leak" -eq 0 ]] && pass "challenges-not-logged" "no challenge strings in the signer journal" || fail "challenges-not-logged" "$leak lines"
journalctl -b -u wm006a-e3-signer.service --no-pager -o short-precise > "$EV/e3-signer-journal.txt" 2>&1
systemd-analyze security --no-pager wm006a-e3-signer.service > "$EV/e3-systemd-analyze-security.txt" 2>&1
info "e3-exposure" "$(grep 'Overall exposure' "$EV/e3-systemd-analyze-security.txt")"
