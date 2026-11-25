#!/usr/bin/env bash
# Make /dev/kvm usable on the GitHub runner, or stop with a clear message.
# Nested virtualization on hosted runners is unofficial; this run tells us whether it works.
set -euo pipefail
echo "CPU virtualization flags: $(grep -Eoc '(vmx|svm)' /proc/cpuinfo || true)"
if [[ ! -e /dev/kvm ]]; then
  echo "::error title=No KVM::/dev/kvm is not present on this runner. Refusing to fall back to slow software emulation."
  exit 1
fi
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
  | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
sleep 1
ls -l /dev/kvm
echo "KVM is available."
