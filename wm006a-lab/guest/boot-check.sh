# boot-check.sh baseline|enable|enabled
#   baseline: right after a reboot with the units as reviewed (no [Install], nothing enabled):
#             nothing listens and no service runs until the admin acts.
#   enable:   admin adds sockets.target.wants links for the five sockets (unit files untouched).
#   enabled:  right after the next reboot: sockets listen at boot with the right owner/mode,
#             no service was started at boot, and the first request socket-activates the signer.
MODE="$1"; SUITE="boot-$MODE"
SOCKETS=(wm006a-ui wm006a-custody wm006a-gateway wm006a-e3-ui wm006a-e3-custody)
SERVICES=(wm006a-signer wm006a-gateway wm006a-e3-signer)
path_of() { case $1 in wm006a-e3-ui) echo /run/wm006a-e3/ui/sock ;; wm006a-e3-custody) echo /run/wm006a-e3/custody/sock ;; *) echo "/run/wm006a/${1#wm006a-}/sock" ;; esac; }
group_of() { case $1 in wm006a-e3-ui) echo wm006a-ui ;; wm006a-e3-custody) echo wm006a-custody ;; *) echo "$1" ;; esac; }
units_unchanged() {
  local r; r=$(cd /etc/systemd/system && sha256sum -c /var/lib/wm006a-lab-e3/units.sha256 2>&1)
  grep -qv ': OK$' <<<"$r" && fail "unit-files-unchanged" "$(grep -v ': OK$' <<<"$r" | tr '\n' ' ')" \
    || pass "unit-files-unchanged" "$(grep -c ': OK$' <<<"$r") reviewed unit files byte-identical"
}
services_not_started() {
  local s st bad=""
  for s in "${SERVICES[@]}"; do st=$(systemctl show "$s.service" -p ActiveState --value); [[ "$st" == inactive ]] || bad+="$s=$st "; done
  [[ -z "$bad" ]] && pass "no-service-started-at-boot" "${SERVICES[*]} inactive" || fail "no-service-started-at-boot" "$bad"
}

case "$MODE" in
  baseline)
    info "boot" "$(cat /proc/sys/kernel/random/boot_id) uptime $(cut -d' ' -f1 /proc/uptime)s"
    bad=""
    for s in "${SOCKETS[@]}"; do
      st=$(systemctl show "$s.socket" -p ActiveState --value); [[ "$st" == inactive && ! -e "$(path_of "$s")" ]] || bad+="$s=$st "
    done
    [[ -z "$bad" ]] && pass "sockets-not-listening-without-enable" "all 5 inactive and absent after boot (units have no [Install], nothing enabled)" \
      || fail "sockets-not-listening-without-enable" "$bad"
    services_not_started
    units_unchanged ;;
  enable)
    for s in "${SOCKETS[@]}"; do
      ln -sfn "/etc/systemd/system/$s.socket" "/etc/systemd/system/sockets.target.wants/$s.socket"
    done
    systemctl daemon-reload
    links=$(ls -l /etc/systemd/system/sockets.target.wants/ | grep wm006a | awk '{print $9"->"$11}' | tr '\n' ' ')
    [[ $(ls /etc/systemd/system/sockets.target.wants/ | grep -c '^wm006a') -eq 5 ]] && pass "wants-links-created" "$links" || fail "wants-links-created" "$links"
    units_unchanged ;;
  enabled)
    boot_us=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
    info "boot" "$(cat /proc/sys/kernel/random/boot_id) checked at uptime $(cut -d' ' -f1 /proc/uptime)s, before any admin action"
    for s in "${SOCKETS[@]}"; do
      st=$(systemctl show "$s.socket" -p ActiveState --value); p=$(path_of "$s")
      [[ "$st" == active ]] && pass "$s-listening-at-boot" "active without admin action" || fail "$s-listening-at-boot" "$st"
      om=$(stat -c '%U:%G %a' "$p" 2>&1)
      [[ "$om" == "root:$(group_of "$s") 660" ]] && pass "$s-owner-mode-at-boot" "$p $om" || fail "$s-owner-mode-at-boot" "$p $om"
    done
    services_not_started
    units_unchanged
    # First request after boot must socket-activate the signer (and through it the gateway).
    t=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
    r=$(runuser -u "$lab_operator" -- python3 "$PROBE" /run/wm006a/ui/sock 'UI_PING\n' 'OK UI+GATEWAY\n' 2>&1)
    since=$(systemctl show wm006a-signer.service -p ActiveEnterTimestampMonotonic --value)
    [[ "$r" == *matched=True* && "$since" -gt "$t" ]] && pass "first-request-activates-signer" "$r; signer started at +$(( (since - t) / 1000 )) ms" \
      || fail "first-request-activates-signer" "$r since=$since t=$t"
    gs=$(systemctl show wm006a-gateway.service -p ActiveState --value)
    [[ "$gs" == active ]] && pass "gateway-activated-on-demand" "$gs" || fail "gateway-activated-on-demand" "$gs"
    # Positive control for the E3 sockets: a valid proposal must start the E3 service on demand.
    e3_before=$(systemctl show wm006a-e3-signer.service -p ActiveState --value)
    t=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
    r=$(runuser -u "$lab_operator" -- /var/opt/wm006a-e3/bin/wm006a-e3 client /run/wm006a-e3/ui/sock \
        "PROPOSE id=P-0090 from=LAB-010 to=LAB-011 amount=1 unit=TESTUNIT memo=boot-control" 2>&1)
    since=$(systemctl show wm006a-e3-signer.service -p ActiveEnterTimestampMonotonic --value)
    e3_after=$(systemctl show wm006a-e3-signer.service -p ActiveState --value)
    if [[ "$e3_before" == inactive && "$r" == "REVISION P-0090 1 sha256:"* && "$e3_after" == active && "$since" -gt "$t" ]]; then
      pass "first-proposal-activates-e3-signer" "inactive -> active at +$(( (since - t) / 1000 )) ms; reply ${r:0:40}…"
    else fail "first-proposal-activates-e3-signer" "before=$e3_before after=$e3_after since=$since t=$t reply=$r"; fi ;;
esac
