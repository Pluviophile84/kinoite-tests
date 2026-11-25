#!/usr/bin/env bash
# Merge results into results.tsv and a Markdown summary (also shown on the run page).
set -uo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p "$OUT"
cat "$OUT/host-results.tsv" "$OUT/vm/results.tsv" 2>/dev/null > "$OUT/results.tsv" || true

python3 - "$OUT/results.tsv" "$OUT/summary.md" "${BASE_IMAGE:-unknown}" <<'PY'
import sys, collections
src, dst, image = sys.argv[1:4]
rows = []
for line in open(src, encoding="utf-8", errors="replace"):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 3:
        rows.append((p[0], p[1], p[2], p[3] if len(p) > 3 else ""))
count = collections.Counter(r[0] for r in rows)
icon = {"PASS": "✅", "FAIL": "❌", "WARN": "⚠️", "SKIP": "⏭️", "INFO": "ℹ️"}
out = [f"# Fedora Kinoite VM test results", "", f"Image: `{image}`", "",
       " · ".join(f"{icon.get(k,'')} {k}: {count[k]}" for k in ["PASS","FAIL","WARN","SKIP","INFO"] if count[k]) or "No results recorded.",
       ""]
suites = list(dict.fromkeys(r[1] for r in rows))
for s in suites:
    out += [f"## {s}", "", "| | Test | Detail |", "|---|---|---|"]
    for st, su, name, det in rows:
        if su == s:
            det = det.replace("|", "\\|")[:300]
            out.append(f"| {icon.get(st, st)} | {name} | {det} |")
    out.append("")
open(dst, "w").write("\n".join(out))
PY
cat "$OUT/summary.md"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
exit 0
