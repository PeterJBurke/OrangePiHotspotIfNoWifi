#!/usr/bin/env bash
#
# wifi-restore.sh — the dead-man's-switch payload.
#
# Tears down any hotspot and forces the known-good Wi-Fi profile back up.
# Designed to be run by a systemd timer so that a failed experiment heals
# itself without physical access to the board.
#
#   sudo ./wifi-restore.sh
#
# It is deliberately paranoid: every step is best-effort and it never exits
# early on failure, because the whole point is to recover a broken machine.

LOG=/var/log/wifi-failsafe.log
exec > >(tee -a "$LOG") 2>&1
echo "=== wifi-restore $(date -Is) ==="

IFACE="${IFACE:-wlan0}"

# Find the known-good Wi-Fi profile. Do NOT hardcode a UUID: it differs on every
# install, so a hardcoded one would fail on a freshly flashed card -- precisely
# when this script matters most. Pick the first infrastructure (non-AP) wireless
# profile; prefer one with autoconnect enabled. Override with GOOD_UUID=... if
# you have several and want a specific one.
detect_good_profile() {
    local best="" first=""
    while IFS=: read -r name uuid type; do
        [ "$type" = "802-11-wireless" ] || continue
        [ "$(nmcli -g 802-11-wireless.mode connection show "$uuid" 2>/dev/null)" = "ap" ] && continue
        [ -z "$first" ] && first="$uuid"
        if [ "$(nmcli -g connection.autoconnect connection show "$uuid" 2>/dev/null)" = "yes" ]; then
            best="$uuid"; break
        fi
    done < <(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null)
    printf '%s' "${best:-$first}"
}

GOOD_UUID="${GOOD_UUID:-$(detect_good_profile)}"
GOOD_NAME="$(nmcli -g connection.id connection show "$GOOD_UUID" 2>/dev/null || echo unknown)"

say() { echo "  $*"; }

# 1. Radio on, nothing soft-blocked.
nmcli radio wifi on 2>/dev/null && say "radio on"
say "target profile: '${GOOD_NAME}' (${GOOD_UUID:-NONE FOUND})"
command -v rfkill >/dev/null && { rfkill unblock wifi 2>/dev/null; say "rfkill unblocked"; }

# 2. Kill every hotspot/AP profile. Never touch the known-good one.
while read -r name uuid; do
    [ -z "$name" ] && continue
    [ "$uuid" = "$GOOD_UUID" ] && continue
    mode=$(nmcli -g 802-11-wireless.mode connection show "$uuid" 2>/dev/null)
    if [ "$mode" = "ap" ]; then
        say "removing AP profile: $name"
        nmcli connection modify "$uuid" connection.autoconnect no 2>/dev/null
        nmcli connection down "$uuid" 2>/dev/null
        nmcli connection delete "$uuid" 2>/dev/null
    fi
done < <(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null | awk -F: '$3=="802-11-wireless"{print $1" "$2}')

# 3. Make sure the good profile still exists and will auto-connect.
if nmcli -g connection.uuid connection show "$GOOD_UUID" >/dev/null 2>&1; then
    nmcli connection modify "$GOOD_UUID" connection.autoconnect yes 2>/dev/null
    say "good profile present, autoconnect forced on"
else
    say "WARNING: known-good profile $GOOD_UUID is GONE"
fi

# 4. Bring it up, with retries — the radio may need a moment after AP teardown.
for attempt in 1 2 3 4 5; do
    if nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q "^${IFACE}:connected"; then
        say "connected (attempt $attempt)"; break
    fi
    say "attempt $attempt: bringing up '$GOOD_NAME'"
    nmcli device disconnect "$IFACE" 2>/dev/null
    sleep 2
    nmcli connection up "$GOOD_UUID" 2>/dev/null || nmcli device wifi rescan 2>/dev/null
    sleep 8
done

# 5. Report.
STATE=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep "^${IFACE}:" | cut -d: -f2)
IP=$(hostname -I 2>/dev/null)
say "final: ${IFACE} state=${STATE:-unknown} ip=${IP:-none}"

if [ "$STATE" != "connected" ]; then
    say "STILL DOWN — restarting NetworkManager as a last resort"
    systemctl restart NetworkManager
    sleep 15
    say "after NM restart: ip=$(hostname -I)"
fi
echo "=== end $(date -Is) ==="
