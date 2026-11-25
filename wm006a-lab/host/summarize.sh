#!/usr/bin/env bash
# Merge build, host and guest results into results.tsv + summary.md, print key evidence to the log.
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
cat "$EVD/build-results.tsv" "$EVD/host-results.tsv" "$EVD/guest/results.tsv" 2>/dev/null > "$EVD/results.tsv"

python3 - "$EVD/results.tsv" "$EVD/summary.md" "${BASE_IMAGE:-unknown}" <<'PY'
import collections, sys
src, dst, image = sys.argv[1:4]
rows = [l.rstrip("\n").split("\t") + [""] for l in open(src, errors="replace") if l.count("\t") >= 2]
c = collections.Counter(r[0] for r in rows)
icon = {"PASS": "✅", "FAIL": "❌", "BLOCKED": "⛔", "WARN": "⚠️", "SKIP": "⏭️", "INFO": "ℹ️"}
out = ["# wm006a lab validation (synthetic data only)", "", f"Guest image: `{image}`", "",
       " · ".join(f"{icon[k]} {k}: {c[k]}" for k in icon if c[k]) or "No results recorded.", ""]
for suite in dict.fromkeys(r[1] for r in rows):
    out += [f"## {suite}", "", "| | Check | Detail |", "|---|---|---|"]
    out += [f"| {icon.get(r[0], r[0])} | {r[2]} | {r[3].replace('|', '/')[:300]} |" for r in rows if r[1] == suite]
    out.append("")
open(dst, "w").write("\n".join(out))
PY
cat "$EVD/summary.md"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$EVD/summary.md" >> "$GITHUB_STEP_SUMMARY"

# Evidence excerpts for reviewers reading only the log. The signer marker is never printed.
for f in guest/evidence/e2-probes.txt guest/evidence/selinux.txt guest/evidence/unit-config.txt \
         guest/evidence/journal-signer.txt guest/evidence/coredump-signer.txt guest/evidence/flatpak-permissions.txt \
         guest/evidence/flatpak-shell.txt qemu-cmdline.txt gui-login.txt gui-sequence.txt \
         gui-app-journal.txt gui-e1.txt os-gen2-dnf-upgrade.txt guest/evidence/e1-versions.sha256 \
         guest/evidence/e1-T4-os-upgrade-db-diff.txt guest/evidence/e1-T4-os-upgrade-staged-status.txt; do
  [[ -f "$EVD/$f" ]] || continue
  echo "::group::evidence: $f"
  grep -av 'WM006A_TEST:' "$EVD/$f" | head -n 120
  echo "::endgroup::"
done
exit 0
