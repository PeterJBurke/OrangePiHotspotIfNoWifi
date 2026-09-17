<!-- Background for anyone wondering why this project exists separately. -->

Upstream: [RaspberryPiHotspotIfNoWifi](https://github.com/PeterJBurke/RaspberryPiHotspotIfNoWifi).
Its logic is sound and it is pure `nmcli`, so it *looks* portable to the Orange
Pi. Installed unchanged on this board it locks you out on the next reboot.

# Why this is a rewrite, not a port

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
