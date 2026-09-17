#!/usr/bin/env bash
#
# check_wifi.sh — connect to a known Wi-Fi network, or fall back to a hotspot.
#
# Hardened rewrite of PeterJBurke/RaspberryPiHotspotIfNoWifi for a HEADLESS
# Orange Pi Zero 3W, where losing Wi-Fi means losing the machine.
#
# Differences from the original, and why:
#
#   1. WAITS for NetworkManager to settle before judging. The original races
#      boot: multi-user.target is reached at ~9s on this board but wlan0 only
#      associates at ~15s, so the original would decide "not connected" and
#      convert a perfectly healthy Wi-Fi setup into a hotspot on EVERY boot.
#   2. NEVER deletes connection profiles. The original deletes every profile
#      matching a desired SSID before reconnecting, so one wrong password in
#      the config permanently destroys the working profile.
#   3. Refuses to run with placeholder SSIDs, instead of tearing down a good
#      connection to chase networks named "Network_1".
#   4. Checks AP capability BEFORE disturbing anything, and aborts if the radio
#      cannot do AP -- rather than disconnecting first and discovering later.
#   5. Marks the hotspot autoconnect=no, so a rescue AP can never hijack a
#      normal boot.
#   6. Credentials live in /etc/wifi-failsafe.conf (0600), not in this script.
#      The original ships passwords inside a world-readable file in
#      /usr/local/bin.

set -u

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

CONF="${CONF:-/etc/wifi-failsafe.conf}"
IFACE="${IFACE:-wlan0}"
SETTLE_SECS="${SETTLE_SECS:-90}"     # how long to let NM associate before judging
CONNECT_WAIT="${CONNECT_WAIT:-25}"   # per-SSID association timeout

log() { echo "[wifi-failsafe] $*"; }

[ "$(id -u)" -eq 0 ] || { log "ERROR: must run as root"; exit 1; }
command -v nmcli >/dev/null || { log "ERROR: nmcli not found"; exit 1; }

# ---------------------------------------------------------------- config
if [ ! -r "$CONF" ]; then
    log "ERROR: $CONF not found. Refusing to run."
    exit 1
fi
# shellcheck disable=SC1090
. "$CONF"

HOTSPOT_SSID="${HOTSPOT_SSID:-}"
HOTSPOT_PASSWORD="${HOTSPOT_PASSWORD:-}"
[ -n "$HOTSPOT_SSID" ] || { log "ERROR: HOTSPOT_SSID unset in $CONF"; exit 1; }
[ ${#HOTSPOT_PASSWORD} -ge 8 ] || { log "ERROR: HOTSPOT_PASSWORD must be >= 8 chars"; exit 1; }

# SSIDS is a bash array of "ssid|password" entries.
if [ "${#SSIDS[@]}" -eq 0 ]; then
    log "ERROR: no SSIDS configured in $CONF. Refusing to run."
    exit 1
fi
for entry in "${SSIDS[@]}"; do
    _ssid="${entry%%|*}"; _pass="${entry#*|}"
    case "$_ssid" in
        Network_1|Network_2|Network_3|""|CHANGEME)
            log "ERROR: placeholder SSID '$_ssid' still in $CONF."
            log "       Refusing to run -- this is how you lose a headless box."
            exit 1 ;;
    esac
    # A real SSID paired with the template password is just as dangerous: the
    # connect fails and we drop to a hotspot for no reason.
    case "$_pass" in
        PUT_THE_REAL_PASSWORD_HERE|CHANGEME|""|password|itspassword)
            log "ERROR: placeholder password for SSID '$_ssid' in $CONF."
            log "       Refusing to run -- edit $CONF before arming this."
            exit 1 ;;
    esac
    if [ "$_pass" = "$_ssid" ]; then
        log "WARNING: password identical to SSID for '$_ssid' -- is that right?"
    fi
done

# Return the SSID currently associated on $IFACE.
# NOTE: GENERAL.CONNECTION gives the PROFILE NAME, which on Orange Pi images is
# "Orange Pi wireless" while the SSID is something else entirely. Comparing the
# profile name against a list of SSIDs silently never matches, and the script
# would tear down a perfectly good connection. Resolve the profile to its SSID.
if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "=== DRY RUN — nothing will be changed ==="
    echo
    echo "Config file: $CONF"
    echo "Networks it will try, in order:"
    i=1
    for entry in "${SSIDS[@]}"; do
        echo "   $i. ${entry%%|*}   (password: ${#entry} chars total, hidden)"
        i=$((i+1))
    done
    echo
    echo "Rescue hotspot if none work:"
    echo "   SSID     $HOTSPOT_SSID"
    echo "   password $HOTSPOT_PASSWORD"
    echo
    cur_prof="$(nmcli -t -f GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | cut -d: -f2-)"
    cur="$(nmcli -g 802-11-wireless.ssid connection show "$cur_prof" 2>/dev/null)"
    [ -z "$cur" ] && cur="$(iw dev "$IFACE" link 2>/dev/null | awk '/SSID:/{ $1=""; sub(/^ /,""); print; exit }')"
    echo "Right now this board is connected to: ${cur:-<nothing>}"
    match=0
    for entry in "${SSIDS[@]}"; do [ "$cur" = "${entry%%|*}" ] && match=1; done
    echo
    if [ "$match" = "1" ]; then
        echo "VERDICT: that IS in your list, so at boot it would do nothing."
        echo "         This is the normal, healthy case."
    elif [ -n "$cur" ]; then
        echo "VERDICT: connected, but '$cur' is NOT in your list."
        echo "         At boot it would try your listed networks instead."
    else
        echo "VERDICT: not connected. At boot it would try each listed network,"
        echo "         then start the '$HOTSPOT_SSID' hotspot if none worked."
    fi
    echo
    echo "Which networks are actually in range right now:"
    nmcli -t -f SSID,SIGNAL dev wifi list --rescan yes 2>/dev/null \
        | awk -F: 'NF&&$1!=""{printf "   %-32s signal %s\n", $1, $2}' | sort -u | head -15
    echo
    echo "Password check — does NetworkManager agree with $CONF?"
    for entry in "${SSIDS[@]}"; do
        _s="${entry%%|*}"; _p="${entry#*|}"
        _u="$(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null \
            | awk -F: '$3=="802-11-wireless"{print $2}' \
            | while read -r u; do
                  [ "$(nmcli -g 802-11-wireless.ssid connection show "$u" 2>/dev/null)" = "$_s" ] && echo "$u"
              done | head -1)"
        if [ -z "$_u" ]; then
            printf "   %-32s no saved profile yet (will be created)\n" "$_s"
        else
            _st="$(nmcli -s -g 802-11-wireless-security.psk connection show "$_u" 2>/dev/null)"
            if [ "$_st" = "$_p" ]; then
                printf "   %-32s matches\n" "$_s"
            else
                printf "   %-32s DIFFERS — at boot the config value wins\n" "$_s"
            fi
        fi
    done
    echo
    echo "NOTE: at boot, passwords from $CONF are pushed into NetworkManager,"
    echo "      so this file is the single source of truth. A wrong password"
    echo "      here WILL break that network — which is what makes the hotspot"
    echo "      fallback testable. See docs/TESTING.md."
    echo
    exit 0
fi

current_ssid() {
    local prof ssid
    prof="$(nmcli -t -f GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | cut -d: -f2-)"
    if [ -z "$prof" ] || [ "$prof" = "--" ]; then return 1; fi
    ssid="$(nmcli -g 802-11-wireless.ssid connection show "$prof" 2>/dev/null)"
    # Fall back to the live association if the profile has no ssid field.
    [ -z "$ssid" ] && ssid="$(iw dev "$IFACE" link 2>/dev/null | awk '/SSID:/{ $1=""; sub(/^ /,""); print; exit }')"
    printf '%s' "$ssid"
}
is_connected() {
    [ "$(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep "^${IFACE}:" | cut -d: -f2)" = "connected" ]
}
ssid_is_wanted() {
    local cur="$1" e
    for e in "${SSIDS[@]}"; do [ "$cur" = "${e%%|*}" ] && return 0; done
    return 1
}

# ------------------------------------ 0. make the config file authoritative
# NetworkManager keeps its own copy of every Wi-Fi password. If the config file
# and NM disagree, NM wins -- which meant a password change here had no effect,
# and the fallback could never be tested honestly.
#
# So: before judging anything, push the config's passwords into the matching NM
# profiles. The config file becomes the single source of truth.
#
# Consequence worth knowing: a typo here will now genuinely break a working
# connection. That is the point -- but it is why the hotspot fallback exists.
sync_passwords() {
    local entry ssid pass uuid stored changed_active=0 n=0
    local active_uuid
    active_uuid="$(nmcli -t -f GENERAL.CON-UUID device show "$IFACE" 2>/dev/null | cut -d: -f2-)"

    for entry in "${SSIDS[@]}"; do
        ssid="${entry%%|*}"; pass="${entry#*|}"
        uuid="$(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null \
            | awk -F: '$3=="802-11-wireless"{print $2}' \
            | while read -r u; do
                  [ "$(nmcli -g 802-11-wireless.ssid connection show "$u" 2>/dev/null)" = "$ssid" ] && echo "$u"
              done | head -1)"
        [ -n "$uuid" ] || continue    # no profile yet; it gets created on connect

        stored="$(nmcli -s -g 802-11-wireless-security.psk connection show "$uuid" 2>/dev/null)"
        if [ "$stored" != "$pass" ]; then
            log "updating stored password for '$ssid' from $CONF"
            nmcli connection modify "$uuid" \
                802-11-wireless-security.key-mgmt wpa-psk \
                802-11-wireless-security.psk "$pass" 2>/dev/null || \
                log "  WARNING: could not update '$ssid'"
            n=$((n+1))
            [ "$uuid" = "$active_uuid" ] && changed_active=1
        fi
    done

    [ "$n" -gt 0 ] && log "synced $n password(s) from $CONF"

    # If we changed the password of the connection we are riding on, bounce it
    # so the new password is actually exercised rather than assumed good.
    if [ "$changed_active" = "1" ]; then
        log "active connection's password changed — reconnecting to test it"
        nmcli device disconnect "$IFACE" >/dev/null 2>&1
        sleep 3
        nmcli connection up "$active_uuid" >/dev/null 2>&1 || true
        sleep 5
    fi
}
sync_passwords

# ------------------------------------------------- 1. let the network settle
# This is the fix for the boot race. Do not judge until NM has had its chance.
log "waiting up to ${SETTLE_SECS}s for $IFACE to settle..."
waited=0
while [ "$waited" -lt "$SETTLE_SECS" ]; do
    if is_connected; then
        cur="$(current_ssid)"
        if ssid_is_wanted "$cur"; then
            log "connected to '$cur' after ${waited}s -- nothing to do."
            exit 0
        fi
        log "connected, but to '$cur' which is not in the wanted list."
        break
    fi
    sleep 3; waited=$((waited + 3))
done
is_connected || log "not connected after ${waited}s."

# ------------------------------------------- 2. try each configured network
for entry in "${SSIDS[@]}"; do
    ssid="${entry%%|*}"; pass="${entry#*|}"
    log "trying '$ssid'..."
    # NOTE: no profile deletion. If a profile exists we update its password
    # in place; otherwise nmcli creates one. A bad password never costs you
    # the profile you are currently relying on.
    existing="$(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null \
        | awk -F: '$3=="802-11-wireless"{print $1"\t"$2}' \
        | while IFS=$'\t' read -r nm uu; do
              [ "$(nmcli -g 802-11-wireless.ssid connection show "$uu" 2>/dev/null)" = "$ssid" ] && echo "$uu"
          done | head -1)"
    if [ -n "$existing" ]; then
        nmcli connection modify "$existing" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" 2>/dev/null
        nmcli connection up "$existing" ifname "$IFACE" >/dev/null 2>&1
    else
        nmcli device wifi connect "$ssid" password "$pass" ifname "$IFACE" >/dev/null 2>&1
    fi
    w=0
    while [ "$w" -lt "$CONNECT_WAIT" ]; do
        if is_connected && [ "$(current_ssid)" = "$ssid" ]; then
            log "SUCCESS: connected to '$ssid'."
            exit 0
        fi
        sleep 3; w=$((w + 3))
    done
    log "failed to connect to '$ssid'."
done

# ------------------------------------------------ 3. hotspot, but carefully
log "no configured network reachable. Considering hotspot fallback."

# Check capability BEFORE tearing anything down.
if ! iw list 2>/dev/null | sed -n '/Supported interface modes/,/Band /p' | grep -qw AP; then
    log "ERROR: radio does not support AP mode. NOT starting a hotspot."
    log "       Leaving Wi-Fi as-is so autoconnect can keep retrying."
    exit 1
fi

if is_connected; then
    log "still connected to '$(current_ssid)'. NOT replacing a live connection"
    log "with a hotspot -- that would be a downgrade. Exiting."
    exit 0
fi

log "starting hotspot '$HOTSPOT_SSID'..."
nmcli radio wifi on
if nmcli device wifi hotspot ifname "$IFACE" con-name "wifi-failsafe-ap" \
        ssid "$HOTSPOT_SSID" password "$HOTSPOT_PASSWORD"; then
    # A rescue AP must never win a normal boot.
    nmcli connection modify wifi-failsafe-ap connection.autoconnect no 2>/dev/null
    log "SUCCESS: hotspot '$HOTSPOT_SSID' is up. Reach the board at 10.42.0.1"
    exit 0
else
    log "ERROR: hotspot failed to start. Re-enabling autoconnect and retrying Wi-Fi."
    for e in "${SSIDS[@]}"; do :; done
    nmcli device disconnect "$IFACE" 2>/dev/null
    nmcli device wifi rescan 2>/dev/null
    exit 1
fi
