# Test helpers, sourced by run-suite.sh inside the VM.
# Results: one line per check, TAB-separated: STATUS  SUITE  NAME  DETAIL
KT_DIR=/var/tmp/kinoite-tests
RESULTS="$KT_DIR/results.tsv"
STATE="$KT_DIR/state"
ART="$KT_DIR/artifacts"
mkdir -p "$STATE" "$ART"

_clean() { tr '\t\n\r' '   ' <<<"$*" | cut -c1-400; }
_rec() { printf '%s\t%s\t%s\t%s\n' "$1" "$SUITE" "$2" "$(_clean "${3:-}")" | tee -a "$RESULTS"; }
pass() { _rec PASS "$@"; }
fail() { _rec FAIL "$@"; }
warn() { _rec WARN "$@"; }
skip() { _rec SKIP "$@"; }
info() { _rec INFO "$@"; }

# check NAME CMD...  -> PASS if CMD exits 0, else FAIL with last output line
check() {
  local name="$1"; shift; local out
  if out=$("$@" 2>&1); then pass "$name" "$(tail -n1 <<<"$out")"
  else fail "$name" "exit $?: $(tail -n2 <<<"$out")"; fi
}
# check_not NAME CMD... -> PASS if CMD FAILS (used for "this must be blocked")
check_not() {
  local name="$1"; shift; local out
  if out=$("$@" 2>&1); then fail "$name" "unexpectedly succeeded: $(tail -n1 <<<"$out")"
  else pass "$name" "blocked as expected: $(tail -n1 <<<"$out")"; fi
}
# check_eq NAME EXPECTED ACTUAL
check_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1" "$3"; else fail "$1" "expected '$2', got '$3'"; fi
}
booted_checksum() {
  rpm-ostree status --json | python3 -c 'import json,sys
d=json.load(sys.stdin)["deployments"]; print(next(x["checksum"] for x in d if x.get("booted")))'
}
deployment_count() { rpm-ostree status --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["deployments"]))'; }
wait_for() {  # wait_for SECONDS CMD...
  local t="$1"; shift; local end=$((SECONDS + t))
  until "$@" >/dev/null 2>&1; do (( SECONDS > end )) && return 1; sleep 3; done
}
