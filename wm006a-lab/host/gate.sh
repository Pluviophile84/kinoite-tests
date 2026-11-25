#!/usr/bin/env bash
# Verdict for the wm006a validation:
#   COMPLETE   every required check present with PASS, and no FAIL anywhere
#   INCOMPLETE a required check is missing or BLOCKED (and nothing failed)
#   FAILED     any check FAILed
# Exits 0 only for COMPLETE. Writes verdict.txt and appends it to the run summary.
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
python3 - "$EVD/results.tsv" "$REPO_ROOT/wm006a-lab/required-checks.txt" "$EVD/verdict.txt" <<'PY'
import sys
res_path, req_path, out_path = sys.argv[1:4]
status = {}
try:
    for line in open(res_path, errors="replace"):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3:
            key = f"{p[1]}/{p[2]}"
            # Worst status wins if a check is recorded more than once.
            rank = {"FAIL": 3, "BLOCKED": 2, "WARN": 1, "PASS": 0}
            if key not in status or rank.get(p[0], 0) > rank.get(status[key], 0):
                status[key] = p[0]
except FileNotFoundError:
    pass
required = [l.strip() for l in open(req_path) if l.strip() and not l.startswith("#")]
missing = [r for r in required if r not in status]
blocked = [r for r in required if status.get(r) == "BLOCKED"]
not_pass = [r for r in required if r in status and status[r] not in ("PASS", "BLOCKED")]
failed = sorted(k for k, v in status.items() if v == "FAIL")
passed = sum(1 for r in required if status.get(r) == "PASS")
if failed or not_pass:
    verdict = "FAILED"
elif missing or blocked:
    verdict = "INCOMPLETE"
else:
    verdict = "COMPLETE"
lines = [f"VERDICT: {verdict}", f"required checks passed: {passed}/{len(required)}"]
for label, items in (("failed", failed), ("required not PASS", not_pass), ("required missing", missing), ("required blocked", blocked)):
    if items:
        lines.append(f"{label} ({len(items)}): " + ", ".join(items))
open(out_path, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(0 if verdict == "COMPLETE" else 1)
PY
rc=$?
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo; echo "## Validation verdict"; echo; echo '```'; cat "$EVD/verdict.txt"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi
[[ $rc -eq 0 ]] || echo "::error title=wm006a validation $(head -n1 "$EVD/verdict.txt" | cut -d' ' -f2)::$(sed -n '3,$p' "$EVD/verdict.txt" | tr '\n' ' ')"
exit $rc
