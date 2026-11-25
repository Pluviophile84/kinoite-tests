#!/usr/bin/env bash
# Fail the workflow if any test failed or nothing ran.
set -uo pipefail
source "$(dirname "$0")/common.sh"
f="$OUT/results.tsv"
[[ -s "$f" ]] || { echo "::error::No test results were produced."; exit 1; }
fails=$(grep -c '^FAIL' "$f" || true)
passes=$(grep -c '^PASS' "$f" || true)
echo "PASS=$passes FAIL=$fails"
if (( fails > 0 )); then
  grep '^FAIL' "$f" | while IFS=$'\t' read -r _ s n d; do echo "::error title=$s/$n::$d"; done
  exit 1
fi
