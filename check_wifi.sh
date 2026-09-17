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
SYNC_ONLY=0
case "${1:-}" in
    --dry-run)   DRY_RUN=1 ;;
    --sync-only) SYNC_ONLY=1 ;;
esac

CONF="${CONF:-/etc/wifi-failsafe.conf}"
IFACE="${IFACE:-wlan0}"
SETTLE_SECS="${SETTLE_SECS:-90}"     # how long to let NM associate before judging
CONNECT_WAIT="${CONNECT_WAIT:-25}"   # per-SSID association timeout

LOGFILE="${LOGFILE:-/var/log/wifi-failsafe.log}"

# Log to the journal AND to disk, so there is a durable record of what was
# tried on each boot even if journald is volatile or the board is power-cycled.
log() {
    echo "[wifi-failsafe] $*"
    [ -n "${LOGFILE:-}" ] && printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null || true
}

# Keep the file from growing without bound.
rotate_log() {
    [ -f "$LOGFILE" ] || return 0
    local sz; sz=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$sz" -gt 262144 ]; then
        tail -n 500 "$LOGFILE" > "${LOGFILE}.tmp" 2>/dev/null && mv "${LOGFILE}.tmp" "$LOGFILE"
    fi
}

[ "$(id -u)" -eq 0 ] || { log "ERROR: must run as root"; exit 1; }
command -v nmcli >/dev/null || { log "ERROR: nmcli not found"; exit 1; }

rotate_log
{ echo; echo "================ boot $(date '+%Y-%m-%d %H:%M:%S') ================"; } >> "$LOGFILE" 2>/dev/null || true

# Never exit silently. A previous version died between writing the boot header
# and its first log line -- leaving an empty section in the log and no clue why,
# on the one boot that mattered. Now every exit is accounted for.
_finish() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        log "EXITED with status $rc at line ${_last_line:-?} -- see above"
    fi
}
trap _finish EXIT
trap '_last_line=$LINENO' DEBUG

# ---------------------------------------------------------------- config
if [ ! -r "$CONF" ]; then
    log "ERROR: $CONF not found. Refusing to run."
    exit 1
fi

# Check the config parses BEFORE sourcing it. Sourcing a broken file can take
# the whole script down before it can report anything.
if ! bash -n "$CONF" 2>/tmp/.wififailsafe-conferr; then
    log "ERROR: $CONF has a syntax error and cannot be read:"
    while IFS= read -r l; do log "    $l"; done < /tmp/.wififailsafe-conferr
    log "    Common cause: a stray comma between entries, or an unclosed )."
    rm -f /tmp/.wififailsafe-conferr
    exit 1
fi
rm -f /tmp/.wififailsafe-conferr

# shellcheck disable=SC1090
. "$CONF" || { log "ERROR: failed to load $CONF"; exit 1; }
log "loaded $CONF"

HOTSPOT_SSID="${HOTSPOT_SSID:-}"
HOTSPOT_PASSWORD="${HOTSPOT_PASSWORD:-}"
[ -n "$HOTSPOT_SSID" ] || { log "ERROR: HOTSPOT_SSID unset in $CONF"; exit 1; }
[ ${#HOTSPOT_PASSWORD} -ge 8 ] || { log "ERROR: HOTSPOT_PASSWORD must be >= 8 chars"; exit 1; }

# SSIDS is a bash array of "ssid|password" entries.
if [ -z "${SSIDS+x}" ]; then
    log "ERROR: $CONF defines no SSIDS array at all. Refusing to run."
    log "    Expected:  SSIDS=( \"MyNetwork|mypassword\" )"
    exit 1
fi
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
    # A trailing comma is swallowed into the password, so the SSID still looks
    # right while that network can never authenticate. Catch it explicitly.
    case "$_pass" in
        *,)
            log "ERROR: password for '$_ssid' ends with a comma."
            log "       This is a bash array -- do NOT put commas between entries."
            log "       Write:   \"$_ssid|thepassword\""
            log "       Not:     \"$_ssid|thepassword\","
            exit 1 ;;
    esac
    case "$entry" in
        *,*) log "WARNING: entry for '$_ssid' contains a comma -- is that intended?" ;;
    esac
done

# Record exactly what was parsed. If a stray comma corrupted a password, the
# character count here will look wrong for that entry.
_i=1
for entry in "${SSIDS[@]}"; do
    log "network #${_i}: '${entry%%|*}' (password ${#entry} chars incl. name)"
    _i=$((_i + 1))
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

# Find the NM profile uuid for a given SSID, if one exists.
profile_for_ssid() {
    local want="$1" u
    nmcli -t -f UUID,TYPE connection show 2>/dev/null \
        | awk -F: '$2=="802-11-wireless"{print $1}' \
        | while read -r u; do
              [ "$(nmcli -g 802-11-wireless.ssid connection show "$u" 2>/dev/null)" = "$want" ] && { echo "$u"; return; }
          done | head -1
}

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
    local PRIO=100
    local active_uuid
    active_uuid="$(nmcli -t -f GENERAL.CON-UUID device show "$IFACE" 2>/dev/null | cut -d: -f2-)"

    for entry in "${SSIDS[@]}"; do
        ssid="${entry%%|*}"; pass="${entry#*|}"
        uuid="$(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null \
            | awk -F: '$3=="802-11-wireless"{print $2}' \
            | while read -r u; do
                  [ "$(nmcli -g 802-11-wireless.ssid connection show "$u" 2>/dev/null)" = "$ssid" ] && echo "$u"
              done | head -1)"
        if [ -z "$uuid" ]; then
            # No profile exists, so NetworkManager can never autoconnect to this
            # network -- it cannot choose something it has never been told about.
            # Create it up front (this does NOT connect), so NM's own priority
            # logic can do the work using its own scanning, which is far more
            # reliable than us scanning and deciding.
            log "creating NetworkManager profile for '$ssid'"
            if nmcli connection add type wifi con-name "wififailsafe-$ssid" \
                    ifname "$IFACE" ssid "$ssid" \
                    802-11-wireless-security.key-mgmt wpa-psk \
                    802-11-wireless-security.psk "$pass" \
                    connection.autoconnect yes \
                    connection.autoconnect-priority "$PRIO" >/dev/null 2>&1; then
                log "  created (priority $PRIO)"
            else
                log "  WARNING: could not create profile for '$ssid'"
            fi
            PRIO=$((PRIO - 10))
            continue
        fi

        # Tell NetworkManager the order matters too, so its own autoconnect
        # prefers the first entry rather than whichever it saw last.
        nmcli connection modify "$uuid" connection.autoconnect yes \
            connection.autoconnect-priority "$PRIO" 2>/dev/null || true
        PRIO=$((PRIO - 10))

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

# --sync-only runs BEFORE NetworkManager starts, purely to get the profiles and
# their priorities in place. Without this, NM has already picked a network by
# the time the main pass runs -- it chose TP-Link at 14:24:46 while our priority
# update landed at 14:24:47, one second too late to matter.
if [ "$SYNC_ONLY" = "1" ]; then
    # Runs BEFORE NetworkManager starts. nmcli is unavailable here (it talks to
    # NM over D-Bus), so write NetworkManager's keyfiles directly.
    #
    # Why this exists: NM picks a network the instant it starts. A priority set
    # afterwards is ignored until the next boot -- NM chose TP-Link at 14:24:46
    # while our update landed at 14:24:47. And on Ubuntu the profiles are
    # generated by netplan into /run, so NM's "memory" is really
    # /etc/netplan/90-NM-*.yaml. Both are rebuilt from the config file here, so
    # /etc/wifi-failsafe.conf is the single source of truth on every boot.

    # ------------------------------------------------------------------
    # HARD SAFETY GUARD.
    #
    # This mode rewrites NetworkManager's profiles from scratch. It is meant to
    # run at boot, BEFORE NetworkManager starts, when nothing is connected.
    #
    # Run on a LIVE system it deletes the backing config of the connection you
    # are using; NM then drops that connection on its next reload. That happened
    # to a real user over SSH and cost two hard reboots. Never again: if
    # NetworkManager is up and a Wi-Fi link is active, refuse.
    # ------------------------------------------------------------------
    if [ "${MLR_FORCE_SYNC:-0}" != "1" ]; then
        if systemctl is-active --quiet NetworkManager 2>/dev/null; then
            wstate="$(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep "^${IFACE}:" | cut -d: -f2)"
            if [ "$wstate" = "connected" ]; then
                log "REFUSING to run --sync-only: NetworkManager is running and"
                log "  ${IFACE} is connected. This mode rebuilds NM's profiles and"
                log "  would drop your connection -- including an SSH session."
                log "  It is meant to run at boot, before NetworkManager starts."
                log "  It will apply by itself on the next reboot."
                log "  (override with MLR_FORCE_SYNC=1 only from a local console)"
                exit 0
            fi
        fi
    fi

    KEYDIR=/etc/NetworkManager/system-connections
    mkdir -p "$KEYDIR"

    # Refuse to wipe anything unless the config is known good -- checked above.
    if [ "${#SSIDS[@]}" -lt 1 ]; then
        log "sync-only: config has no networks; leaving existing profiles alone"
        exit 1
    fi

    # Drop NetworkManager's remembered Wi-Fi profiles. Only ones NM/netplan
    # generated, and only our own; anything hand-written elsewhere is left.
    removed=0
    for f in /etc/netplan/90-NM-*.yaml; do
        [ -e "$f" ] || continue
        if grep -qE '^\s*(wifis|access-points):' "$f" 2>/dev/null; then
            rm -f "$f" && removed=$((removed + 1))
        fi
    done
    for f in "$KEYDIR"/wififailsafe-*.nmconnection; do
        [ -e "$f" ] && rm -f "$f" && removed=$((removed + 1))
    done
    [ "$removed" -gt 0 ] && log "sync-only: cleared $removed remembered Wi-Fi profile(s)"

    # Write one keyfile per configured network, highest priority first.
    PRIO=100; idx=1
    for entry in "${SSIDS[@]}"; do
        ssid="${entry%%|*}"; pass="${entry#*|}"
        # Stable UUID derived from the SSID, so it does not churn every boot.
        uuid="$(python3 - "$ssid" <<'PYUUID'
import sys, uuid
print(uuid.uuid5(uuid.NAMESPACE_DNS, "wifi-failsafe:" + sys.argv[1]))
PYUUID
)"
        safe="$(printf '%s' "$ssid" | tr -c 'A-Za-z0-9._-' '_')"
        out="$KEYDIR/wififailsafe-${idx}-${safe}.nmconnection"
        umask 077
        cat > "$out" <<KEYEOF
[connection]
id=wififailsafe-${ssid}
uuid=${uuid}
type=wifi
interface-name=${IFACE}
autoconnect=true
autoconnect-priority=${PRIO}
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid=${ssid}

[wifi-security]
key-mgmt=wpa-psk
psk=${pass}

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
KEYEOF
        chmod 600 "$out"
        log "sync-only: wrote profile #${idx} '${ssid}' (priority ${PRIO})"
        PRIO=$((PRIO - 10)); idx=$((idx + 1))
    done

    log "sync-only: NetworkManager will choose from these, highest priority first"
    exit 0
fi

# ------------------------------------------------- 1. let the network settle
# This is the fix for the boot race. Do not judge until NM has had its chance.
log "waiting up to ${SETTLE_SECS}s for $IFACE to settle..."
waited=0
while [ "$waited" -lt "$SETTLE_SECS" ]; do
    if is_connected; then
        cur="$(current_ssid)"
        if ssid_is_wanted "$cur"; then
            # Connected to *a* wanted network -- but is it the preferred one?
            # NetworkManager may have joined whichever it saw first.
            idx=0; want_idx=-1
            for e in "${SSIDS[@]}"; do
                [ "$cur" = "${e%%|*}" ] && { want_idx=$idx; break; }
                idx=$((idx + 1))
            done
            if [ "$want_idx" -le 0 ]; then
                log "connected to '$cur' after ${waited}s (first choice) -- nothing to do."
                exit 0
            fi

            log "connected to '$cur' after ${waited}s, but that is choice #$((want_idx + 1))."

            # Remember what we are on, so a failed attempt can be undone.
            prev_uuid="$(nmcli -t -f GENERAL.CON-UUID device show "$IFACE" 2>/dev/null | cut -d: -f2-)"

            # Scan, but never trust it blindly and never let it hang. At boot
            # this call has been observed taking 171 SECONDS and then returning
            # nothing useful, while the same command takes 0.4s once the system
            # has settled. Cached results first, one bounded rescan as backup.
            INRANGE="$(timeout 15 nmcli -t -f SSID device wifi list --rescan no 2>/dev/null)"
            n_cached=$(printf '%s\n' "$INRANGE" | grep -c . || true)
            log "  scan (cached): $n_cached networks seen"
            i=0
            found_any=0
            for e in "${SSIDS[@]}"; do
                [ "$i" -ge "$want_idx" ] && break
                printf '%s\n' "$INRANGE" | grep -qxF "${e%%|*}" && found_any=1
                i=$((i + 1))
            done
            if [ "$found_any" = "0" ]; then
                INRANGE="$(timeout 25 nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null)"
                n_fresh=$(printf '%s\n' "$INRANGE" | grep -c . || true)
                log "  scan (rescan): $n_fresh networks seen"
            fi

            i=0
            for e in "${SSIDS[@]}"; do
                [ "$i" -ge "$want_idx" ] && break
                pref="${e%%|*}"; prefpass="${e#*|}"
                if printf '%s\n' "$INRANGE" | grep -qxF "$pref"; then
                    log "  '$pref' (choice #$((i + 1))) is in range -- switching to it"
                else
                    # The scan is not authoritative on this driver. If we have a
                    # saved profile for it, try anyway: a failed association
                    # costs ~20s and is undone below, whereas trusting a bad
                    # scan silently leaves us on the wrong network.
                    # The scan on this driver is not trustworthy: at boot it has
                    # reported a network absent that was demonstrably on air and
                    # at full signal. Try regardless -- a failed association is
                    # bounded and undone below.
                    log "  '$pref' (choice #$((i + 1))) not seen in scan, trying anyway"
                fi

                timeout 30 nmcli device wifi connect "$pref" password "$prefpass" ifname "$IFACE" >/dev/null 2>&1
                sleep 5
                if [ "$(current_ssid)" = "$pref" ]; then
                    log "SUCCESS: switched to preferred network '$pref'."
                    log "RESULT: connected to '$pref'"
                    exit 0
                fi
                log "  could not join '$pref'"
                # Undo: make sure we are back where we started before trying the next.
                if [ -n "${prev_uuid:-}" ] && ! is_connected; then
                    log "  restoring previous connection '$cur'"
                    timeout 30 nmcli connection up "$prev_uuid" >/dev/null 2>&1 || true
                    sleep 5
                fi
                i=$((i + 1))
            done
            log "staying on '$cur'."
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
            log "RESULT: connected to '$ssid'"
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
    log "RESULT: hotspot mode"
    exit 0
else
    log "ERROR: hotspot failed to start. Re-enabling autoconnect and retrying Wi-Fi."
    for e in "${SSIDS[@]}"; do :; done
    nmcli device disconnect "$IFACE" 2>/dev/null
    nmcli device wifi rescan 2>/dev/null
    exit 1
fi
