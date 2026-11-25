#!/usr/bin/env bash
# Remove large preinstalled toolchains we do not need, then pick a work directory.
set -uo pipefail
echo "Before:"; df -h / /mnt 2>/dev/null
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup \
            /opt/hostedtoolcache/CodeQL /usr/local/share/boost /usr/local/julia* \
            /usr/share/swift /usr/local/share/powershell /usr/local/share/chromium 2>/dev/null
sudo docker image prune -af >/dev/null 2>&1 || true
sudo swapoff -a 2>/dev/null; sudo rm -f /mnt/swapfile /swapfile 2>/dev/null
echo "After:"; df -h / /mnt 2>/dev/null

avail_mnt=$(df -BG --output=avail /mnt 2>/dev/null | tail -1 | tr -dc 0-9)
if [[ -n "$avail_mnt" && "$avail_mnt" -ge 25 ]]; then work=/mnt/kt; else work=/var/tmp/kt; fi
sudo mkdir -p "$work" && sudo chown "$(id -u):$(id -g)" "$work"
echo "WORK=$work" >> "$GITHUB_ENV"
echo "Work directory: $work"
