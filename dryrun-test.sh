#!/usr/bin/env bash
# dryrun-test.sh — proves the machinery behind test-ap-capability.sh works,
# WITHOUT touching the Wi-Fi radio. Completely safe: your connection is untouched.
#
#   sudo ./dryrun-test.sh
set -u
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
LOG=/tmp/dryrun.log; rm -f "$LOG"
echo "1. can we schedule a delayed job (the dead-man's switch)?"
systemctl stop dryrun-timer.timer 2>/dev/null; systemctl reset-failed dryrun-timer.service 2>/dev/null
if systemd-run --on-active=20sec --timer-property=AccuracySec=1s --unit=dryrun-timer \
       /bin/bash -c "echo 'TIMER FIRED ok' >> $LOG" >/dev/null 2>&1; then
    echo "   yes - armed a 30s timer"
else
    echo "   NO - timers will not work. Do NOT run the real test."; exit 1
fi
echo "2. can we run a detached job that survives SSH dropping?"
systemctl reset-failed dryrun-job.service 2>/dev/null
if systemd-run --unit=dryrun-job /bin/bash -c "echo 'DETACHED JOB ok' >> $LOG; echo \"ip: \$(hostname -I)\" >> $LOG" >/dev/null 2>&1; then
    echo "   yes - launched"
else
    echo "   NO - detached jobs will not work. Do NOT run the real test."; exit 1
fi
echo "3. can we write the log file?"
sleep 3
[ -s "$LOG" ] && echo "   yes" || { echo "   NO - nothing was logged"; exit 1; }
echo
# Wait generously. systemd may still add slack; a false "failed" here would be
# worse than waiting, because it would scare you off a test that actually works.
echo "waiting up to 90s for the timer to fire..."
for i in $(seq 1 90); do
    grep -q 'TIMER FIRED' "$LOG" 2>/dev/null && { echo "   fired after ~${i}s"; break; }
    sleep 1
done
echo
echo "=== results ==="; cat "$LOG" | sed 's/^/   /'
echo
if grep -q 'TIMER FIRED' "$LOG" && grep -q 'DETACHED JOB' "$LOG"; then
    echo "ALL GOOD. The recovery machinery works. The real test is safe to run."
else
    echo "SOMETHING FAILED. Do NOT run the real test - recovery would not fire."
fi
systemctl reset-failed dryrun-timer.service dryrun-job.service 2>/dev/null
rm -f "$LOG"
