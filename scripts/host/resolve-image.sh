#!/usr/bin/env bash
# Decide which Kinoite image to test. Uses $FEDORA_VERSION if given, otherwise the
# newest *stable* Fedora release that ships Kinoite (never rawhide or beta).
set -euo pipefail
REPO=quay.io/fedora-ostree-desktops/kinoite
ver="${FEDORA_VERSION:-}"

if [[ -z "$ver" ]]; then
  ver=$(curl -fsSL --retry 3 https://fedoraproject.org/releases.json | python3 -c '
import json, sys
rels = json.load(sys.stdin)
vs = [int(r["version"]) for r in rels
      if str(r.get("version", "")).isdigit() and "kinoite" in str(r.get("variant", "")).lower()]
print(max(vs) if vs else "")
' 2>/dev/null || true)
fi

candidates=()
[[ -n "$ver" ]] && candidates+=("$ver" "$((ver - 1))") || candidates+=(46 45 44 43)
for v in "${candidates[@]}"; do
  if skopeo inspect --raw "docker://$REPO:$v" >/dev/null 2>&1; then
    echo "Using $REPO:$v"
    echo "BASE_IMAGE=$REPO:$v" >> "$GITHUB_ENV"
    echo "KT_FEDORA_VERSION=$v" >> "$GITHUB_ENV"
    exit 0
  fi
  echo "Tag $v not found, trying next" >&2
done
echo "::error::Could not find a Kinoite image tag (tried: ${candidates[*]})"
exit 1
