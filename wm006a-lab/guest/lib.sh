# Result helpers for the wm006a lab, sourced by guest scripts that run as root in the VM.
# One line per check, TAB-separated: STATUS  SUITE  NAME  DETAIL
LAB=/var/tmp/wm006a-lab
RESULTS="$LAB/results.tsv"
EV="$LAB/evidence"
mkdir -p "$EV"
LAB_SRC="${LAB_SRC:-/var/home/tester/wm006a-lab}"
WS="$LAB_SRC/ws"                       # the 006A directory (systemd/, tests/, native/target/...)
PROBE=/var/tmp/wm006a-socket-probe.py
APP=org.sinteza.WalletManagerLab
lab_operator=lab_operator
lab_outsider=lab_outsider

_clean() { tr '\t\n\r' '   ' <<<"$*" | cut -c1-400; }
_rec() { printf '%s\t%s\t%s\t%s\n' "$1" "$SUITE" "$2" "$(_clean "${3:-}")" | tee -a "$RESULTS"; }
pass() { _rec PASS "$@"; }
fail() { _rec FAIL "$@"; }
blocked() { _rec BLOCKED "$@"; }
warn() { _rec WARN "$@"; }
info() { _rec INFO "$@"; }
skip() { _rec SKIP "$@"; }

check() {  # check NAME CMD...  -> PASS on exit 0
  local name="$1"; shift; local out
  if out=$("$@" 2>&1); then pass "$name" "$(tail -n1 <<<"$out")"
  else fail "$name" "exit $?: $(tail -n2 <<<"$out")"; fi
}
evidence() {  # evidence FILE CMD...  -> append command and output to an evidence file
  local f="$EV/$1"; shift
  { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n\n' "$?"; } >> "$f"
}
uid_of() { id -u "$1"; }
as_operator() {  # run in the operator's login context (session bus if a session exists)
  local uid; uid=$(uid_of "$lab_operator")
  runuser -u "$lab_operator" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}
