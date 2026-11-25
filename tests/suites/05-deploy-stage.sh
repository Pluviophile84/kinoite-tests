# Deployment, part 1: stage a new deployment (layered package + kernel argument).
# Nothing should change on the running system until reboot.
check_not "htop-absent-before" command -v htop
check "layer-package" timeout 1800 sudo rpm-ostree install -y --idempotent htop
check "kargs-append" sudo rpm-ostree kargs --append=kinoite.test=1
check_not "change-not-live-before-reboot" command -v htop
check "pending-deployment-exists" bash -c 'rpm-ostree status --json | python3 -c "
import json,sys; d=json.load(sys.stdin)[\"deployments\"]
assert not d[0].get(\"booted\"), \"no staged deployment\"
assert \"htop\" in d[0].get(\"requested-packages\",[]), d[0].get(\"requested-packages\")
print(\"staged:\", d[0][\"checksum\"][:12])"'
rpm-ostree status -v > "$ART/rpm-ostree-before-reboot.txt" 2>&1
