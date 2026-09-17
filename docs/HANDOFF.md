# Handoff — state of play

Last updated: 2026-09-17, immediately before the first AP capability test.

## Where things stand

| | |
|---|---|
| Repo | complete, pushed, public |
| Installed on the board | **yes** — `sudo ./install.sh` has been run |
| `/etc/wifi-failsafe.conf` | **edited** with the real SSID and password |
| Dry run | **PASSED** — timer fired in 19s, detached jobs work, logging works |
| AP capability test | **NOT YET RUN** ← this is the next step |
| `check_wifi.service` enabled at boot | **NO** — deliberately, until AP mode is proven |

Nothing has touched the Wi-Fi radio yet. The board is on its normal network.

## The next step

```bash
cd ~/OrangePiHotspotIfNoWifi
sudo ./test-ap-capability.sh
```

SSH drops ~10s later, by design. Then look for a Wi-Fi network named
**`OPiRescue`** (password `orangepi123`).

- Wi-Fi restores itself after **8 minutes** whatever happens.
- If that fails, the board **reboots at 14 minutes** and comes back normally.

Both timers use `--timer-property=AccuracySec=1s`, because systemd's default
`AccuracySec` is one minute and would let a recovery deadline drift.

### When back on the normal network

```bash
sudo ~/OrangePiHotspotIfNoWifi/check-result.sh
```

That prints `/var/log/wifi-failsafe.log`, the current network state, and whether
any timers are still armed.

### Then, and only if the hotspot actually appeared

```bash
sudo systemctl enable check_wifi.service
```

If the hotspot did **not** appear, do not enable it — the fallback would be
imaginary. The likely cause would be the `aicwf_sdio` driver not really
supporting AP mode despite `iw list` advertising it.

## Important distinction

The 8-minute auto-revert exists **only in `test-ap-capability.sh`**.
`check_wifi.sh` — what runs at boot in normal use — has no timers and no
auto-revert. In the field the rescue hotspot stays up indefinitely. Verified by
inspection: `check_wifi.sh` contains no `systemd-run`, no `deadman`, no
`reboot`.

`check_wifi.service` is `Type=oneshot`, so it checks **once at boot**. It will
not switch back to home Wi-Fi by itself on returning to range; that needs a
reboot, or `check_wifi.timer` (currently disabled, and inadvisable on a flying
vehicle — a brief dropout would flip the board to hotspot mode and take the
MAVLink telemetry link with it).

## Known constraint

Claude Code runs **on this board**. A hotspot has no upstream internet, so the
Claude session dies when the hotspot starts and cannot be resumed until normal
Wi-Fi returns. The transcript is on the SD card and survives; resume with:

```bash
cd ~/mlinstall/installmavlinkrouterorangepizero3w
claude --continue
```

## If it all goes wrong

There is no out-of-band console in use (declined as too much effort). Recovery
means reflashing — see [RECOVERY.md](RECOVERY.md). The key step there is
renaming `/boot/orangepi_first_run.txt.template` to `orangepi_first_run.txt` and
filling in the Wi-Fi credentials **before first boot**; the board has no
Ethernet, so a headless first boot has no network without it.

## Bugs found and fixed while building this

Recorded so they are not re-introduced:

1. `nmcli -t -f GENERAL.CONNECTION device show wlan0` returns the **profile
   name** (`Orange Pi wireless`), not the SSID. Comparing it against a list of
   SSIDs never matches, and an early draft would have torn down a healthy
   connection — the exact failure this project prevents.
2. `wifi-restore.sh` originally hardcoded a connection UUID, which would not
   exist on a freshly flashed card — failing precisely when it mattered most.
   It now auto-detects the non-AP profile with autoconnect enabled.
3. The placeholder guard checked SSIDs but not passwords, so the shipped
   template (real SSID, dummy password) passed the check and would have dropped
   to a hotspot for no reason.
4. The dry run waited ~38s for a 30s timer and declared a working timer broken.
   systemd's 1-minute default `AccuracySec` was the cause.
