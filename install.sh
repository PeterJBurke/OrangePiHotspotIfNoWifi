#!/usr/bin/env bash
# install.sh — install the hardened Wi-Fi failsafe. Run with sudo.
#
# Deliberately does NOT enable the boot service. Installing and enabling are
# separate steps so you can prove the hotspot works on this hardware first.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

echo "==> installing scripts"
install -m755 "$DIR/check_wifi.sh"   /usr/local/bin/check_wifi.sh
install -m755 "$DIR/wifi-restore.sh" /usr/local/bin/wifi-restore.sh

echo "==> installing config (0600, root only)"
if [ -e /etc/wifi-failsafe.conf ]; then
    echo "    /etc/wifi-failsafe.conf exists - left untouched"
else
    install -m600 "$DIR/wifi-failsafe.conf.template" /etc/wifi-failsafe.conf
    echo "    created /etc/wifi-failsafe.conf - YOU MUST EDIT IT"
fi

echo "==> installing systemd units (not enabled yet)"
install -m644 "$DIR/check_wifi.service" /etc/systemd/system/check_wifi.service
install -m644 "$DIR/check_wifi.timer"   /etc/systemd/system/check_wifi.timer
systemctl daemon-reload

echo "==> fixing the boot race"
# Without this, After=NetworkManager-wait-online.service is a no-op and the
# check runs ~6s before wlan0 associates on this board.
systemctl enable NetworkManager-wait-online.service >/dev/null 2>&1 \
    && echo "    enabled NetworkManager-wait-online.service" \
    || echo "    WARNING: could not enable NetworkManager-wait-online"

echo "==> removing services that fight NetworkManager's hotspot"
for svc in hostapd dnsmasq; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
        systemctl mask "$svc" >/dev/null 2>&1 || true
        echo "    disabled+masked $svc"
    fi
done

cat <<TXT

Installed, but NOT enabled at boot. That is intentional.

  1. Edit the config:      sudo nano /etc/wifi-failsafe.conf
  2. Prove AP mode works:  sudo $DIR/test-ap-capability.sh
                           (arms an auto-restore + reboot fallback first)
  3. Only if step 2 works: sudo systemctl enable check_wifi.service

  Manual rescue any time:  sudo /usr/local/bin/wifi-restore.sh
  Optional periodic check: sudo systemctl enable --now check_wifi.timer
                           (read the warning in check_wifi.timer first)
TXT
