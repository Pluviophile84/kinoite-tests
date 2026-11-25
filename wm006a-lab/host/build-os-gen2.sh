#!/usr/bin/env bash
# Build OS generation 2 from the image the VM boots, and serve it from a local registry that the
# VM reaches as 10.0.2.2:5000 (QEMU user networking). Requires build-image.sh with KEEP_IMAGES=1.
set -uo pipefail
source "$(dirname "$0")/../../scripts/host/common.sh"
EVD="$OUT/wm006a"; mkdir -p "$EVD"
BR="$EVD/build-results.tsv"
res() { printf '%s\tbuild\t%s\t%s\n' "$1" "$2" "${3:-}" | tee -a "$BR"; }
LOCAL=localhost/kinoite-kt:latest
GEN2=localhost/kinoite-kt:gen2

if ! sudo podman image exists "$LOCAL"; then res FAIL os-gen2-image "generation-1 image not kept"; exit 0; fi
if sudo podman build --build-arg BASE="$LOCAL" -t "$GEN2" "$REPO_ROOT/wm006a-lab/os-gen2" > "$EVD/os-gen2-build.log" 2>&1; then
  sudo podman run --rm "$GEN2" cat /usr/share/wm006a-lab/dnf-upgrade-summary.txt > "$EVD/os-gen2-dnf-upgrade.txt" 2>&1
  res PASS os-gen2-image "$(grep -m1 -E 'dnf_exit' "$EVD/os-gen2-dnf-upgrade.txt"); $(grep -iE 'upgrad(e|ing)[^a-z]*[0-9]+ package' "$EVD/os-gen2-dnf-upgrade.txt" | head -n1)"
else res FAIL os-gen2-image "see os-gen2-build.log"; tail -n 20 "$EVD/os-gen2-build.log"; exit 0; fi

sudo podman run -d --name wm006a-registry -p 5000:5000 docker.io/library/registry:2 >/dev/null
for _ in $(seq 30); do curl -sf http://127.0.0.1:5000/v2/ >/dev/null && break; sleep 1; done
if sudo podman push -q --tls-verify=false "$GEN2" docker://127.0.0.1:5000/kinoite-kt:gen2 > "$EVD/os-gen2-push.log" 2>&1; then
  res PASS os-gen2-served "$(curl -s http://127.0.0.1:5000/v2/kinoite-kt/tags/list)"
else res FAIL os-gen2-served "see os-gen2-push.log"; fi
sudo podman rmi -f "$LOCAL" "${BASE_IMAGE:-}" >/dev/null 2>&1 || true
df -h "$WORK" /
