#!/usr/bin/env bash
#
# install.sh — Wi-Fi hotspot failsafe for Orange Pi Zero 3W.
#
#   wget -O install.sh https://raw.githubusercontent.com/PeterJBurke/OrangePiHotspotIfNoWifi/refs/heads/main/install.sh
#   sudo chmod 777 install.sh
#   sudo ./install.sh
#
# Installs everything and enables it at boot. Afterwards, put your WiFi details
# in /etc/wifi-failsafe.conf with nano.
#
# Options:
#   MLR_NO_ENABLE=1     install but do not enable at boot
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/PeterJBurke/OrangePiHotspotIfNoWifi/main"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF=/etc/wifi-failsafe.conf

c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'; c_bld=$'\033[1m'; c_off=$'\033[0m'
ok()   { echo "${c_grn}  [ok]${c_off} $*"; }
warn() { echo "${c_yel}  [warn]${c_off} $*"; }
step() { echo; echo "${c_bld}==> $*${c_off}"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root:  sudo $0"
command -v nmcli >/dev/null || die "NetworkManager (nmcli) not found"

# ---------------------------------------------------------------- 0. bootstrap
# Allow the wget-one-file workflow: fetch whatever is missing.
step "Fetching components"
fetch() {
    if [ -f "$DIR/$1" ]; then echo "$DIR/$1"; return; fi
    local tmp="/tmp/wififailsafe-$1"
    if command -v curl >/dev/null; then curl -fsSL "$REPO_RAW/$1" -o "$tmp"
    else wget -qO "$tmp" "$REPO_RAW/$1"; fi || die "could not download $1"
    echo "$tmp"
}
SRC_CHECK="$(fetch check_wifi.sh)"
SRC_REST="$(fetch wifi-restore.sh)"
SRC_SVC="$(fetch check_wifi.service)"
SRC_TMR="$(fetch check_wifi.timer)"
ok "components ready"

# ------------------------------------------------------------------- 1. board
step "Checking hardware"
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
[ "$MODEL" = "sun60iw2" ] && ok "Orange Pi Zero 3W (A733) detected" \
    || warn "expected 'sun60iw2', got '$MODEL' — continuing anyway"
iw list 2>/dev/null | sed -n '/Supported interface modes/,/Band /p' | grep -qw AP \
    && ok "Wi-Fi adapter supports hotspot (AP) mode" \
    || warn "adapter may not support AP mode — the hotspot may not work"

# ------------------------------------------------------------------ 2. config
step "Wi-Fi configuration"
if [ -f "$CONF" ]; then
    ok "$CONF already exists — leaving it alone"
else
    SRC_CONF="$(fetch wifi-failsafe.conf.template)"
    install -m600 "$SRC_CONF" "$CONF"
    ok "created $CONF (root-only, mode 600)"
    NEEDS_EDIT=1
fi

# ----------------------------------------------------------------- 3. install
step "Installing"
install -m755 "$SRC_CHECK" /usr/local/bin/check_wifi.sh
install -m755 "$SRC_REST"  /usr/local/bin/wifi-restore.sh
install -m644 "$SRC_SVC"   /etc/systemd/system/check_wifi.service
install -m644 "$SRC_TMR"   /etc/systemd/system/check_wifi.timer
systemctl daemon-reload
ok "scripts and services installed"

# Without this the boot check runs ~6s before wlan0 associates and would
# wrongly decide the network is down.
systemctl enable NetworkManager-wait-online.service >/dev/null 2>&1 \
    && ok "enabled NetworkManager-wait-online (prevents a boot race)"

for svc in hostapd dnsmasq; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
        systemctl mask "$svc" >/dev/null 2>&1 || true
        ok "disabled $svc (it conflicts with the hotspot)"
    fi
done

# ------------------------------------------------------------------ 4. enable
step "Enabling at boot"
if [ "${MLR_NO_ENABLE:-0}" = "1" ]; then
    warn "MLR_NO_ENABLE=1 — installed but NOT enabled"
else
    systemctl enable check_wifi.service >/dev/null 2>&1
    ok "enabled — it will run at every boot"
fi

HS_SSID="$(grep -oP '^HOTSPOT_SSID="\K[^"]+' "$CONF" 2>/dev/null || echo OPiRescue)"
HS_PASS="$(grep -oP '^HOTSPOT_PASSWORD="\K[^"]+' "$CONF" 2>/dev/null || echo orangepi123)"
USERNAME="$(logname 2>/dev/null || echo orangepi)"

if [ "${NEEDS_EDIT:-0}" = "1" ]; then
cat <<TXT

${c_yel}${c_bld}One more step:${c_off} put your WiFi details in the config file.

    ${c_bld}sudo nano ${CONF}${c_off}

  Change this line:

      "CHANGEME|PUT_THE_REAL_PASSWORD_HERE"

  to your network name and password, for example:

      "MyHomeWiFi|mypassword123"

  Then save with Ctrl+X, then Y, then Enter.

TXT
fi

cat <<TXT
${c_grn}${c_bld}Installed.${c_off}

  If the Pi ever cannot reach your WiFi, it creates a hotspot instead:

      network   ${c_bld}${HS_SSID}${c_off}
      password  ${c_bld}${HS_PASS}${c_off}
      then      ${c_bld}ssh ${USERNAME}@10.42.0.1${c_off}

TXT
