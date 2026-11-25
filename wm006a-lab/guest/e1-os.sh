# e1-os.sh upgrade|rollback TAG : real rpm-ostree deployment transitions (reboot is done by the runner).
ACTION="$1"; TAG="$2"; SUITE="e1-$TAG"
REF=/var/lib/wm006a-lab-e1
booted() { rpm-ostree status --json | python3 -c 'import json,sys; print([x for x in json.load(sys.stdin)["deployments"] if x.get("booted")][0]["checksum"])'; }
case "$ACTION" in
  upgrade)
    booted > "$REF/deployment-A"
    out=$(timeout 2400 rpm-ostree rebase ostree-unverified-registry:10.0.2.2:5000/kinoite-kt:gen2 2>&1); rc=$?
    printf '%s\n' "$out" > "$EV/e1-$TAG-rebase.txt"
    [[ $rc -eq 0 ]] && pass "os-upgrade-staged" "$(tail -n1 <<<"$out")" || fail "os-upgrade-staged" "exit $rc: $(tail -n2 <<<"$out")"
    rpm-ostree db diff > "$EV/e1-$TAG-db-diff.txt" 2>&1
    info "package-diff" "$(grep -cE '^ *(Upgraded|Downgraded|Added|Removed)|^  [a-z0-9]' "$EV/e1-$TAG-db-diff.txt") lines; see e1-$TAG-db-diff.txt"
    rpm-ostree status -v > "$EV/e1-$TAG-staged-status.txt" 2>&1 ;;
  verify-upgrade)
    a=$(cat "$REF/deployment-A"); b=$(booted); echo "$b" > "$REF/deployment-B"
    [[ "$b" != "$a" ]] && pass "booted-new-deployment" "A=${a:0:16} -> B=${b:0:16}" || fail "booted-new-deployment" "still on A ${a:0:16}"
    n=$(rpm-ostree status --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["deployments"]))')
    [[ $n -ge 2 ]] && pass "rollback-target-kept" "$n deployments" || fail "rollback-target-kept" "$n deployments" ;;
  rollback)
    out=$(rpm-ostree rollback 2>&1); rc=$?
    printf '%s\n' "$out" > "$EV/e1-$TAG-rollback.txt"
    [[ $rc -eq 0 ]] && pass "os-rollback-requested" "$(tail -n1 <<<"$out")" || fail "os-rollback-requested" "exit $rc: $(tail -n2 <<<"$out")" ;;
  verify-rollback)
    a=$(cat "$REF/deployment-A"); b=$(cat "$REF/deployment-B" 2>/dev/null); now=$(booted)
    [[ "$now" == "$a" ]] && pass "booted-original-deployment" "A=${a:0:16} (B=${b:0:16} kept)" || fail "booted-original-deployment" "booted ${now:0:16}, A=${a:0:16}" ;;
esac
