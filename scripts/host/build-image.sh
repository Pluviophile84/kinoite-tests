#!/usr/bin/env bash
# Build a bootable Kinoite qcow2 from the official container image with bootc-image-builder.
set -euo pipefail
source "$(dirname "$0")/common.sh"
: "${BASE_IMAGE:?BASE_IMAGE not set}"
BIB=quay.io/centos-bootc/bootc-image-builder:latest
LOCAL=localhost/kinoite-kt:latest
mkdir -p "$WORK/bib-out" "$OUT"

log "Generating throwaway SSH key for this run"
rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -C kt-runner -f "$KEY"
sed "s|@SSH_PUBKEY@|$(cat "$KEY.pub")|" "$REPO_ROOT/image/config.toml.in" > "$WORK/config.toml"

log "Pulling $BASE_IMAGE"
sudo podman pull -q "$BASE_IMAGE"
sudo podman image inspect "$BASE_IMAGE" --format '{{.Digest}} {{index .Labels "org.opencontainers.image.version"}}' \
  | tee "$OUT/base-image.txt"
echo "$BASE_IMAGE" >> "$OUT/base-image.txt"

log "Building test layer"
sudo podman build -q --build-arg BASE="$BASE_IMAGE" -t "$LOCAL" "$REPO_ROOT/image"

log "Running bootc-image-builder"
sudo podman run --rm --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v "$WORK/config.toml:/config.toml:ro" \
  -v "$WORK/bib-out:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "$BIB" --type qcow2 --rootfs ext4 --target-imgref "$BASE_IMAGE" "$LOCAL" 2>&1 \
  | tee "$OUT/bootc-image-builder.log" | grep -vE '^\s*$' | tail -n 40

sudo mv "$WORK/bib-out/qcow2/disk.qcow2" "$DISK"
sudo chown "$(id -u):$(id -g)" "$DISK"
sudo rm -rf "$WORK/bib-out"
log "Freeing container storage"
sudo podman rmi -f "$LOCAL" "$BASE_IMAGE" "$BIB" >/dev/null 2>&1 || true
qemu-img info "$DISK" | tee "$OUT/disk-info.txt"
df -h "$WORK"
