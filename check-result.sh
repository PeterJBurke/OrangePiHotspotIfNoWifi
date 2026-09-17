#!/usr/bin/env bash
# check-result.sh — read the verdict after an AP test. Safe, read-only.
echo "=== Wi-Fi failsafe log ==="
sudo cat /var/log/wifi-failsafe.log 2>/dev/null || echo "(no log - the test never ran)"
echo
echo "=== current network state ==="
nmcli -t -f DEVICE,STATE,CONNECTION device | grep '^wlan0:'
echo "ip: $(hostname -I)"
echo
echo "=== any timers still armed? ==="
systemctl list-timers 'wifi-deadman*' --no-pager 2>/dev/null | head -4
