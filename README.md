# OrangePiHotspotIfNoWifi

Automatically fall back to a Wi-Fi hotspot on an **Orange Pi Zero 3W** when it
can't reach any of your known networks — so a headless board with no Ethernet
doesn't become unreachable.

This is the Orange Pi counterpart to
[RaspberryPiHotspotIfNoWifi](https://github.com/PeterJBurke/RaspberryPiHotspotIfNoWifi),
**rewritten rather than ported.** The original's logic is sound, but installed
unchanged on this hardware it locks you out on the next reboot. See
[Why this is a rewrite](#why-this-is-a-rewrite).

Tested on: Orange Pi Zero 3W, Allwinner **A733** (`sun60iw2`), Ubuntu 26.04,
kernel 6.6.98, NetworkManager 1.54.3, `aicwf_sdio` Wi-Fi.

---

## The short version

```bash
git clone https://github.com/PeterJBurke/OrangePiHotspotIfNoWifi.git
cd OrangePiHotspotIfNoWifi
sudo ./install.sh                     # installs; enables NOTHING at boot
sudo nano /etc/wifi-failsafe.conf     # your real SSIDs + passwords
sudo ./test-ap-capability.sh          # prove the hotspot works, recoverably
sudo systemctl enable check_wifi.service   # ONLY after the test passes
```

Read the rest before running step 4 — it will drop your SSH session on purpose.

---

## Read this first

**This board has no Ethernet.** Wi-Fi is the only way in. If it breaks and the
hotspot doesn't come up, your options are physical access or reflashing the SD
card. That risk is accepted here by design; the fallback is
[docs/RECOVERY.md](docs/RECOVERY.md), which takes ~30–45 minutes.

Everything below exists to make that outcome unlikely.

---

## Step 1 — Install

```bash
sudo ./install.sh
```

This installs the scripts and systemd units, creates `/etc/wifi-failsafe.conf`
(mode `0600`), enables `NetworkManager-wait-online.service`, and disables and
masks `hostapd` and `dnsmasq` — both are installed and enabled on the stock
image and both fight NetworkManager's hotspot.

**It deliberately does not enable anything at boot.** Installing and arming are
separate steps, so you can prove the hotspot works before trusting it.

## Step 2 — Configure

```bash
sudo nano /etc/wifi-failsafe.conf
```

```ini
SSIDS=(
  "YourHomeNetwork|yourpassword"
  "YourPhoneHotspot|otherpassword"
)
HOTSPOT_SSID="OPiRescue"
HOTSPOT_PASSWORD="orangepi123"      # 8+ characters
```

Networks are tried in order. Credentials live here, `root`-only — **not** inside
the script, where the upstream project puts them in a world-readable file under
`/usr/local/bin`.

The script refuses to run while placeholder SSIDs (`Network_1`, `CHANGEME`) are
present, rather than tearing down a working link to chase networks that don't
exist.

## Step 2.5 — Dry run (safe, touches nothing)

```bash
sudo ./dryrun-test.sh
```

Proves the recovery machinery works — delayed timers, detached jobs, logging —
**without touching the radio**. Takes ~40 s. If this does not say `ALL GOOD`, do
not run the real test: the auto-recovery would not fire either.

## Step 3 — Prove AP mode works

**This is the step that matters.** Your Wi-Fi chip is an AIC8800 with the
`aicwf_sdio` driver. `iw list` claims AP support, but vendor SDIO drivers often
don't deliver it, and the board associates on 5 GHz where AP support is patchier
still. If the hotspot silently fails, the fallback you're relying on isn't there.

```bash
sudo ./test-ap-capability.sh
```

Before touching the radio, it:

1. Aborts immediately if the radio doesn't advertise AP mode.
2. Arms a **dead-man's switch** — in 8 minutes, `wifi-restore.sh` tears down any
   hotspot and forces your known-good profile back up.
3. Arms a **reboot** at 14 minutes as a second layer. The rescue AP is
   `autoconnect=no` and your normal profile is `autoconnect=yes`, so a reboot
   always returns you to your usual network.
4. Starts the hotspot **detached** via `systemd-run`, so it survives your SSH
   session dying — which it will, the moment the radio switches to AP mode.

**You will lose your SSH session. That is the test.**

- **Hotspot appears:** join `OPiRescue`, then `ssh orangepi@10.42.0.1`. Disarm
  with `sudo systemctl stop wifi-deadman.timer wifi-deadman-reboot.timer`, then
  `sudo /usr/local/bin/wifi-restore.sh`.
- **Hotspot doesn't appear:** do nothing. Wi-Fi returns by itself in 8 minutes;
  if that fails, the board reboots at 14 and comes back normally.

Either way the verdict is in `/var/log/wifi-failsafe.log`. Afterwards:

```bash
sudo ./check-result.sh
```

> **If you run Claude Code (or anything else needing internet) *on* this board:**
> a hotspot gives the board no upstream internet, so those tools stop working
> until normal Wi-Fi is restored. Local SSH to `10.42.0.1` still works fine.

## Step 4 — Arm it

Only once the hotspot is proven:

```bash
sudo systemctl enable check_wifi.service
```

Optional periodic re-check (**off by default, read the warning first**):

```bash
sudo systemctl enable --now check_wifi.timer
```

> On a flying vehicle, think carefully. A transient Wi-Fi dropout would convert
> the board into a hotspot mid-mission and take the telemetry link with it.

---

## Why this is a rewrite

The upstream script is pure `nmcli` and touches no Raspberry-Pi-specific paths,
so it *looks* portable. Five things break it here.

### 1. A confirmed boot race — fatal

Measured on this board:

```
multi-user.target reached  @  8.982s
wlan0 associated           @ 15.3s      <- 6.3s LATER
```

`check_wifi.service` is `WantedBy=multi-user.target` and guards with
`After=NetworkManager-wait-online.service` — but that service is **disabled** on
this image, and `/etc/systemd/system/network-online.target.wants/` holds only
`networking.service`. An `After=` on a unit that never starts is inert.

So it runs before Wi-Fi is up, decides "not connected", and converts a healthy
Wi-Fi setup into a hotspot — **on every boot**.

*Fixed:* poll up to 90 s for association before judging, and the installer
actually enables `NetworkManager-wait-online.service`.

### 2. It deletes the profile you depend on

Upstream finds every profile matching a desired SSID and `nmcli connection
delete`s it *before* reconnecting. One typo in the configured password
permanently destroys the working profile.

*Fixed:* never delete. Update the password in place, or create a new profile.

### 3. Unconfigured defaults tear down a live link

Defaults are `Network_1/2/3`, so any real SSID fails the match: it disconnects,
chases three networks that don't exist (~21 s), then builds a hotspot.

*Fixed:* refuse to run with placeholder SSIDs.

### 4. AP capability is assumed, not checked

Upstream disconnects first and discovers the hotspot doesn't work afterwards —
leaving neither Wi-Fi nor hotspot.

*Fixed:* check AP capability **before** disturbing anything, and never replace a
live connection with a hotspot.

### 5. Passwords in a world-readable script

*Fixed:* `/etc/wifi-failsafe.conf`, mode `0600`.

### A bug found while testing this rewrite

`nmcli -t -f GENERAL.CONNECTION device show wlan0` returns the **profile name** —
on this image `Orange Pi wireless` — not the SSID it is actually joined to. An early
draft compared the profile name against the SSID list, never matched, and would
have torn down a healthy connection: the exact failure it was written to prevent.
`current_ssid()` now resolves the profile to its real SSID with an
`iw dev … link` fallback, verified against the live connection.

Upstream gets this right, incidentally — it reads the SSID from `nmcli dev wifi`.

---

## Files

```
install.sh                   installs everything; enables nothing
dryrun-test.sh               proves the recovery machinery works, touches nothing
check-result.sh              read the verdict after a test (read-only)
check_wifi.sh                connect-or-hotspot logic
check_wifi.service           systemd unit with ordering that actually works
check_wifi.timer             OPTIONAL periodic re-check (off by default)
wifi-restore.sh              dead-man's-switch payload: kill AP, restore Wi-Fi
test-ap-capability.sh        prove AP mode works, with recovery armed first
wifi-failsafe.conf.template  config template
docs/RECOVERY.md             rebuild from a blank SD card
docs/BOARD-NOTES.md          measured hardware facts for this board
```

## Rescue commands

```bash
sudo /usr/local/bin/wifi-restore.sh                                 # kill AP, restore Wi-Fi
sudo systemctl stop wifi-deadman.timer wifi-deadman-reboot.timer    # disarm timers
sudo systemctl disable check_wifi.service                           # stop it at boot
cat /var/log/wifi-failsafe.log                                      # what happened
nmcli device status; nmcli connection show                          # current state
```

## If it all goes wrong

[docs/RECOVERY.md](docs/RECOVERY.md) — flashing a new image, getting back onto
Wi-Fi headlessly via `/boot/orangepi_first_run.txt` (there's no Ethernet port, so
this step is not optional), and re-applying this project and MAVLink Router.

## Related

- [installmavlinkrouterorangepizero3w](https://github.com/PeterJBurke/installmavlinkrouterorangepizero3w)
  — MAVLink Router on UART2 for the same board
- [docs/BOARD-NOTES.md](docs/BOARD-NOTES.md) — UART map, boot config, and the
  traps specific to the A733
