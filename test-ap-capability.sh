#!/usr/bin/env bash
#
# test-ap-capability.sh — find out whether this board can actually run a hotspot,
# WITHOUT risking permanent loss of access.
#
#   sudo ./test-ap-capability.sh [minutes]      (default 8)
#
# What it does, in order:
#   1. Arms a dead-man's switch: in N minutes, systemd runs wifi-restore.sh and
#      puts your normal Wi-Fi back, whatever state things are in.
#   2. Arms a second, later fallback that REBOOTS the board. On boot the known-good
#      profile auto-connects, so even a wedged NetworkManager recovers.
#   3. Starts the hotspot detached (systemd-run), so it keeps going after your
#      SSH session dies — which it will, the moment the radio switches to AP mode.
#
# You will lose this SSH session. That is expected and is the point of the test.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINS="${1:-8}"
REBOOT_MINS=$(( MINS + 6 ))
HOTSPOT_SSID="${HOTSPOT_SSID:-OPiRescue}"
HOTSPOT_PASS="${HOTSPOT_PASS:-orangepi123}"
IFACE="${IFACE:-wlan0}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0"; exit 1; }
[ ${#HOTSPOT_PASS} -ge 8 ] || { echo "hotspot password must be >= 8 chars"; exit 1; }

echo "=== Pre-flight ==="
if ! iw list 2>/dev/null | sed -n '/Supported interface modes/,/Band /p' | grep -qw AP; then
    echo "  FAIL: this radio does not advertise AP mode. Aborting BEFORE touching anything."
    exit 1
fi
echo "  radio advertises AP mode: ok"
echo "  current: $(nmcli -t -f DEVICE,STATE,CONNECTION device | grep "^${IFACE}:")"
echo "  current IP: $(hostname -I)"

echo
echo "=== Arming recovery ==="
systemctl stop wifi-deadman.timer   2>/dev/null
systemctl stop wifi-deadman-reboot.timer 2>/dev/null
# AccuracySec=1s matters: systemd's default is 1 MINUTE, so timers get batched
# and can fire up to a minute late. For a recovery deadline, fire on time.
systemd-run --on-active="${MINS}min" --timer-property=AccuracySec=1s --unit=wifi-deadman \
    "$DIR/wifi-restore.sh" >/dev/null 2>&1 \
    && echo "  dead-man's switch armed: restores Wi-Fi in ${MINS} min"
systemd-run --on-active="${REBOOT_MINS}min" --timer-property=AccuracySec=1s --unit=wifi-deadman-reboot \
    /usr/sbin/reboot >/dev/null 2>&1 \
    && echo "  fallback armed: REBOOT in ${REBOOT_MINS} min if still unreachable"

cat <<TXT

=== What happens next ===
  * Your SSH session will freeze/drop within a few seconds.
  * A hotspot should appear:   SSID '${HOTSPOT_SSID}'   password '${HOTSPOT_PASS}'
  * Join it and:               ssh orangepi@10.42.0.1

  If the hotspot WORKS:
      ssh in and run:  sudo systemctl stop wifi-deadman.timer wifi-deadman-reboot.timer
      then restore normal Wi-Fi:  sudo ${DIR}/wifi-restore.sh
      (if you do nothing, it restores itself in ${MINS} min anyway)

  If the hotspot does NOT appear:
      do nothing. In ${MINS} min Wi-Fi is restored automatically.
      If that fails too, the board reboots at ${REBOOT_MINS} min and comes back
      on your normal network at its usual address.

  Afterwards the verdict is in:  /var/log/wifi-failsafe.log

TXT
echo "=== Starting hotspot in 10s (Ctrl-C now to abort) ==="
sleep 10

# Detached, so it survives the SSH drop.
systemd-run --unit=ap-test --description="one-shot hotspot capability test" \
    /bin/bash -c "
        exec >>/var/log/wifi-failsafe.log 2>&1
        echo '=== ap-test $(date -Is) ==='
        nmcli radio wifi on
        if nmcli device wifi hotspot ifname ${IFACE} con-name OPiRescue-AP \
               ssid '${HOTSPOT_SSID}' password '${HOTSPOT_PASS}'; then
            echo 'RESULT: hotspot command SUCCEEDED'
            # never let a rescue AP hijack a normal boot
            nmcli connection modify OPiRescue-AP connection.autoconnect no
            sleep 5
            echo \"state: \$(nmcli -t -f DEVICE,STATE,CONNECTION device | grep '^${IFACE}:')\"
            echo \"ip: \$(hostname -I)\"
            iw dev ${IFACE} info
        else
            echo 'RESULT: hotspot command FAILED — this radio cannot AP under NM'
        fi
    " >/dev/null 2>&1

echo "hotspot test launched. Goodbye — reconnect via the hotspot or wait for auto-restore."
