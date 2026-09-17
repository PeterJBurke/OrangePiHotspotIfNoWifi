# Handoff — state of play

Last updated: 2026-09-17, immediately before the first AP capability test.

## Where things stand

**DONE AND WORKING.** AP mode is proven on this hardware and the failsafe is
armed at boot.

| | |
|---|---|
| Installed + configured | yes |
| Dry run | passed (timer fired in 19s) |
| **AP capability test** | **PASSED** — see below |
| `check_wifi.service` enabled at boot | **yes** |
| `check_wifi.timer` (periodic re-check) | disabled, deliberately |
| `hostapd` / `dnsmasq` | masked |
| `NetworkManager-wait-online` | enabled (fixes the boot race) |

### AP test result, 2026-09-17

```
13:02:53  hotspot UP    -- AP mode, channel 11 (2.4 GHz), 10.42.0.1
13:10:44  dead-man's switch fired, punctually at 8 min
13:10:45  AP profile deleted
13:10:58  back on the normal network
```

The operator confirmed `OPiRescue` was visible and joinable from another device.

Notable: NetworkManager placed the AP on **2.4 GHz channel 11** even though the
station link was 5 GHz — good for client compatibility.

The boot script was then run by hand while connected to a known network and
behaved correctly:

```
[wifi-failsafe] waiting up to 90s for wlan0 to settle...
[wifi-failsafe] connected to '<known ssid>' after 0s -- nothing to do.
```

Exited immediately, touched nothing. Only then was the service enabled.

### One gotcha worth remembering

After the test, `wifi-deadman.timer` had already fired and cleaned up, but
**`wifi-deadman-reboot.timer` was still armed** and would have rebooted the board
~3 minutes later. The reboot fallback is intentionally scheduled 6 minutes after
the restore, so it survives a failed restore — but it does not cancel itself when
the restore succeeds. After any successful test, run:

```bash
sudo systemctl stop wifi-deadman.timer wifi-deadman-reboot.timer
```

`check-result.sh` lists any timers still armed, for exactly this reason.

## Front page simplified, 2026-09-17

The README now follows the format of installmavlinkrouter2024: flash the image,
ssh in, `wget` the installer, run it, edit one line with nano. **Nothing about
testing appears on the front page.** Dry run, AP capability test and
troubleshooting moved to [TESTING.md](TESTING.md); the rationale for rewriting
rather than porting is in [WHY-A-REWRITE.md](WHY-A-REWRITE.md).

`install.sh` is self-bootstrapping, so the single-file `wget` in the README
works: it downloads whatever components are missing. It is non-interactive (the
user edits `/etc/wifi-failsafe.conf` with nano), enables the service at boot,
and never overwrites an existing config.

## Wi-Fi power save — fixed properly 2026-09-17

An audit found power save back **on** despite having been disabled and
"verified" earlier. NetworkManager reads `conf.d` alphabetically and the last
file wins; the stock `default-wifi-powersave-on.conf` sorts *after* a `99-`
prefix, so it silently overrode the setting on every reconnect. Now written as
`zz-mavlink-wifi-powersave-off.conf` and verified by bouncing the link rather
than reading back what was just set.

Fixed in the installmavlinkrouterorangepizero3w repo (gotcha #20), since that is
where the power-save handling lives.

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
