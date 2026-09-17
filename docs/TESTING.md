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

## Why changing the password in the config does NOT test the fallback

This catches people out, and it is worth understanding.

**NetworkManager keeps its own copy of every Wi-Fi password**, in its connection
profile. `/etc/wifi-failsafe.conf` is read *only* by `check_wifi.sh`. So if you
put a deliberately wrong password in the config file, nothing happens: the board
still connects normally using the password NetworkManager already has, and
`check_wifi.sh` correctly sees "I am on a network in my list" and stands down.

Its job is to answer *"am I on a wanted network?"*, not *"does my config's
password match?"*.

Remember too that `check_wifi.service` runs **once at boot**. Editing the config
does nothing until you reboot.

### How to really test the fallback

Pick whichever is least disruptive. All of them make the board genuinely unable
to reach your network, which is the only thing that triggers the fallback.

**A. Break NetworkManager's stored password** (most convenient, fully reversible)

```bash
sudo nmcli connection modify 'Orange Pi wireless' wifi-sec.psk 'deliberately-wrong'
sudo reboot
```

At boot the board cannot join, so `check_wifi.sh` tries each network in your
config — note it will *repair* the password from the config file if the config
has the right one — and starts the hotspot if none work.

To undo, once you are back in (via the hotspot at `10.42.0.1`, or by fixing it):

```bash
sudo nmcli connection modify 'Orange Pi wireless' wifi-sec.psk 'your-real-password'
sudo reboot
```

> If your config file still lists the correct password for that SSID, the script
> will fix the profile and reconnect — which is a *successful* test of the retry
> path, just not of the hotspot. To force the hotspot, put a wrong password in
> **both** the config and the NM profile, or use option B or C.

**B. Turn the router off** — the most realistic test, no changes to the board.
Power down your access point, reboot the Pi, and watch for the hotspot.

**C. Take it out of range** — carry the board somewhere with no known network and
power it up. This is the real field scenario.

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
