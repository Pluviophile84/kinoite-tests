#!/usr/bin/env bash
# Root helper for the GUI phase, driven from the runner. Prints one line of detail; exit 0 = OK.
#   login | launch [ENV=VAL ...] | quit | applog | state | sockets-stop | sockets-start | services-stop | restart-ui
set -u
op=lab_operator
APP=org.sinteza.WalletManagerLab
uid=$(id -u "$op")
user_ctl() { systemctl --machine="$op@.host" --user "$@"; }

case "${1:-}" in
  login)
    mkdir -p /etc/plasmalogin.conf.d
    printf '[Autologin]\nUser=%s\nSession=plasma.desktop\nRelogin=false\n' "$op" > /etc/plasmalogin.conf.d/90-wm006a-lab.conf
    # Keep first-login dialogs from covering the test window (operator-only, synthetic account).
    home=$(getent passwd "$op" | cut -d: -f6)
    runuser -u "$op" -- mkdir -p "$home/.config/autostart"
    runuser -u "$op" -- sh -c "printf '[Desktop Entry]\nHidden=true\n' > '$home/.config/autostart/org.kde.plasma-welcome.desktop'"
    runuser -u "$op" -- sh -c "printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' > '$home/.config/kscreenlockerrc'"
    systemctl restart display-manager.service
    for _ in $(seq 60); do
      sid=$(loginctl list-sessions --no-legend | awk -v u="$op" '$3==u{print $1}' | head -n1)
      if [[ -n "$sid" ]]; then
        props=$(loginctl show-session "$sid" -p Type -p Active -p State -p Seat -p Class | tr '\n' ' ')
        if grep -q 'Active=yes' <<<"$props" && grep -q 'Type=wayland' <<<"$props"; then
          for _ in $(seq 40); do  # wait for the compositor to export WAYLAND_DISPLAY
            user_ctl show-environment 2>/dev/null | grep -q '^WAYLAND_DISPLAY=' && { echo "session $sid $props"; exit 0; }
            sleep 3; done
          echo "session $sid $props but no WAYLAND_DISPLAY in user manager"; exit 1
        fi
      fi
      sleep 3
    done
    echo "no active graphical session for $op: $(loginctl list-sessions --no-legend | tr '\n' ';') $(journalctl -b -u display-manager.service -n 8 --no-pager -o cat | tr '\n' ' ')"
    exit 1 ;;
  launch)
    shift; envs=(); for e in "$@"; do envs+=(--env="$e"); done
    user_ctl stop wm006a-gui.service >/dev/null 2>&1; user_ctl reset-failed wm006a-gui.service >/dev/null 2>&1
    systemd-run --machine="$op@.host" --user --quiet --unit=wm006a-gui --collect \
      flatpak run "${envs[@]}" "$APP" && echo "launched ${envs[*]:-}" ;;
  quit) user_ctl stop wm006a-gui.service 2>&1; echo stopped ;;
  applog) journalctl -b _UID="$uid" --since "-15min" --no-pager -o cat | grep -viE 'kwin|plasmashell|baloo|kded' | tail -n 40 ;;
  state)  # one line of key=value pairs for the runner
    sv() { systemctl show "$1" -p "$2" --value; }
    lbl() { local p; p=$(sv "$1" MainPID); [[ "$p" -gt 0 ]] && ps -o label= -p "$p" | tr -d ' ' || echo none; }
    apid=$(user_ctl show wm006a-gui.service -p MainPID --value 2>/dev/null)
    printf 'signer_active=%s signer_inv=%s signer_since=%s signer_pid=%s signer_label=%s gateway_active=%s gateway_pid=%s gateway_label=%s ui_socket=%s ui_sock=%s app_active=%s app_pid=%s app_inv=%s\n' \
      "$(sv wm006a-signer.service ActiveState)" "$(sv wm006a-signer.service InvocationID)" \
      "$(sv wm006a-signer.service ActiveEnterTimestampMonotonic)" "$(sv wm006a-signer.service MainPID)" "$(lbl wm006a-signer.service)" \
      "$(sv wm006a-gateway.service ActiveState)" "$(sv wm006a-gateway.service MainPID)" "$(lbl wm006a-gateway.service)" \
      "$(sv wm006a-ui.socket ActiveState)" "$([ -S /run/wm006a/ui/sock ] && echo socket || echo absent)" \
      "$(user_ctl is-active wm006a-gui.service 2>/dev/null)" "${apid:-0}" \
      "$(user_ctl show wm006a-gui.service -p InvocationID --value 2>/dev/null)" ;;
  now) awk '{printf "%d\n", $1*1000000}' /proc/uptime ;;
  sockets-stop) systemctl stop wm006a-signer.service wm006a-gateway.service wm006a-ui.socket wm006a-custody.socket wm006a-gateway.socket; ls -l /run/wm006a/ui/ 2>&1 | tr '\n' ' '; echo ;;
  sockets-start) systemctl start wm006a-ui.socket wm006a-custody.socket wm006a-gateway.socket && echo started ;;
  services-stop) systemctl stop wm006a-signer.service wm006a-gateway.service && echo "services stopped, sockets listening" ;;
  services-state) systemctl status --no-pager -n 0 wm006a-signer.service wm006a-gateway.service ;;
  restart-ui) systemctl restart wm006a-ui.socket wm006a-signer.service && echo "restarted ui socket and signer" ;;
  *) echo "unknown: ${1:-}"; exit 2 ;;
esac
