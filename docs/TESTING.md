# Testing and troubleshooting

The main [README](../README.md) is all most people need. This page is for
proving the hotspot actually works, and for fixing it when it doesn't.

---

## Is it installed and armed?

```bash
systemctl is-enabled check_wifi.service     # should say: enabled
systemctl status check_wifi                 # what it did last boot
journalctl -u check_wifi -b                 # full log for this boot
```

A healthy boot looks like:

```
[wifi-failsafe] waiting up to 90s for wlan0 to settle...
[wifi-failsafe] connected to 'YourNetwork' after 0s -- nothing to do.
```

## Check your config without disconnecting

```bash
sudo /usr/local/bin/check_wifi.sh --dry-run
```

Shows the networks it will try, in order, what is currently in range, what the
board is connected to now, and what it *would* do at boot. Changes nothing.

## The config file is the source of truth

NetworkManager keeps its own copy of every Wi-Fi password. If it and
`/etc/wifi-failsafe.conf` disagree, NM would normally win — so editing a
password here used to have no effect at all.

Since 2026-09-17, `check_wifi.sh` **pushes the config's passwords into
NetworkManager at every boot**. Whatever is in `/etc/wifi-failsafe.conf` is what
the board will use.

Two consequences:

* Changing a password here now genuinely changes behaviour, so the fallback can
  be tested honestly.
* A typo here **will** break a working connection. That is the trade-off for
  having one source of truth, and it is why the hotspot fallback exists.

If the password of the currently-active connection changes, the script bounces
the link so the new password is actually exercised, rather than assumed good.

Check agreement before rebooting:

```bash
sudo /usr/local/bin/check_wifi.sh --dry-run
```

It prints `matches` or `DIFFERS` per network, and changes nothing.

Remember `check_wifi.service` runs **once at boot** — config edits take effect
on the next reboot.

### How to test the fallback

**A. Wrong password in the config** (now sufficient on its own)

```bash
sudo nano /etc/wifi-failsafe.conf     # break the password of your main network
sudo reboot
```

At boot the board pushes that wrong password into NetworkManager, fails to
join, tries your other networks in order, and starts the hotspot if none work.

Undo by putting the correct password back and rebooting.

**B. Turn the router off** — the most realistic test, no changes to the board.

**C. Take it out of range** — the real field scenario.

## Testing the boot behaviour safely

Run the boot script by hand while connected to a known network. This is exactly
what runs at boot, and it should exit immediately without touching the radio:

```bash
sudo /usr/local/bin/check_wifi.sh
```

If it does anything else — scanning, reconnecting, starting a hotspot — stop and
find out why before trusting it. At boot there is nobody watching.

---

## Fully testing the hotspot

**This disconnects you on purpose.** It is the only way to find out whether the
radio can really run an access point.

### 1. Check the recovery machinery first (safe)

```bash
sudo ./dryrun-test.sh
```

~40 seconds, never touches the radio. It proves systemd can run the delayed
recovery job that gets you back. If it does not print `ALL GOOD`, do not run the
real test — the automatic recovery would not fire either.

### 2. Run the test

```bash
sudo ./test-ap-capability.sh
```

Your ssh session freezes about 10 seconds later. Then look for a WiFi network
called `OPiRescue` (password `orangepi123`).

Before touching the radio it arms two safety nets:

| | |
|---|---|
| after 8 minutes | WiFi is restored automatically |
| after 14 minutes | the board reboots, coming back on your normal network |

So whatever happens, doing nothing gets you back.

- **Hotspot appeared:** it works. Join it, `ssh orangepi@10.42.0.1`, or just wait
  8 minutes for normal WiFi to return.
- **Hotspot did not appear:** wait. Do not pull the power.

### 3. Afterwards — do not skip this

```bash
sudo ./check-result.sh
sudo systemctl stop wifi-deadman.timer wifi-deadman-reboot.timer
```

> The reboot fallback is scheduled 6 minutes after the restore and **does not
> cancel itself when the restore succeeds** — deliberately, so it still fires if
> the restore fails. After a *successful* test it is left armed and will reboot
> the board minutes later. Harmless, but baffling if you don't expect it.
> `check-result.sh` lists anything still armed.

### Known-good result

On an Orange Pi Zero 3W (A733, `aicwf_sdio`), 2026-09-17:

```
13:02:53  hotspot UP    -- AP mode, channel 11 (2.4 GHz), 10.42.0.1
13:10:44  auto-restore fired, punctually at 8 minutes
13:10:45  hotspot profile deleted
13:10:58  back on the normal network
```

NetworkManager puts the hotspot on **2.4 GHz** even when the normal connection is
5 GHz, which is good — more devices can see it.

---

## Manual rescue

```bash
sudo /usr/local/bin/wifi-restore.sh        # kill any hotspot, restore WiFi
sudo cat /var/log/wifi-failsafe.log        # what happened
nmcli device status                        # current state
nmcli connection show                      # saved networks
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Hotspot never appears | radio can't do AP mode | `iw list \| grep -A5 "interface modes"` — look for `* AP` |
| It starts a hotspot even though WiFi is fine | boot race | `sudo systemctl enable NetworkManager-wait-online.service` |
| "placeholder password" error | config not filled in | `sudo nano /etc/wifi-failsafe.conf` |
| Hotspot starts but nothing can join it | `hostapd`/`dnsmasq` conflict | `sudo systemctl mask hostapd dnsmasq` |
| Board reboots a few minutes after a test | reboot fallback still armed | `sudo systemctl stop wifi-deadman-reboot.timer` |
| Connected to the hotspot but no internet | expected | a hotspot has no upstream connection; local ssh works fine |
| Wrong network after reboot | another profile autoconnects | `nmcli connection show`, then `nmcli connection modify <name> connection.autoconnect no` |

### If you run anything on the Pi that needs internet

While the hotspot is up the board has **no upstream internet**. Anything running
on it that needs the network — Claude Code, `apt`, Tailscale — stops working
until normal WiFi is restored. Local ssh to `10.42.0.1` is unaffected.

### Optional: re-check periodically

By default the check runs **once at boot**. To also re-check every 5 minutes:

```bash
sudo systemctl enable --now check_wifi.timer
```

> Think carefully on a flying vehicle. A brief WiFi dropout would flip the board
> into hotspot mode mid-flight and take any telemetry link with it.
