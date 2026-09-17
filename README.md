# Outline

This makes an Orange Pi Zero 3W create its own WiFi hotspot if it cannot connect
to your WiFi.

Useful for headless boards with no Ethernet port: if the Pi can't find your
network, you can still reach it by joining the hotspot it creates.

Tested in 2026 on Orange Pi Zero 3W (Allwinner A733) with Ubuntu 26.04.

## Target hardware/prerequisites

* SD Card
* Orange Pi Zero 3W
* Ubuntu image from Orange Pi (this was built on Ubuntu 26.04 "Resolute")
* Your WiFi network name and password

## Installing

Download and install the Orange Pi Ubuntu image from:
```
http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/service-and-support/Orange-Pi-Zero-3W.html
```
Follow the instructions there to copy the image to an sd card.


Boot the Pi with the SD card and ssh into it.


Get the script to install and configure the Pi:
```
wget -O install.sh https://raw.githubusercontent.com/PeterJBurke/OrangePiHotspotIfNoWifi/refs/heads/main/install.sh
```
Run script (takes about 30 seconds):
```
sudo chmod 777 ~/install.sh;
sudo ~/install.sh
```

Then put your WiFi network name and password in the config file:
```
sudo nano /etc/wifi-failsafe.conf
```
Change this line:
```
  "CHANGEME|PUT_THE_REAL_PASSWORD_HERE"
```
to your own network, for example:
```
  "MyHomeWiFi|mypassword123"
```
Save with **Ctrl+X**, then **Y**, then **Enter**.

Done!

## Using it

Nothing to do day to day. The Pi connects to your WiFi as normal.

If it ever cannot reach your WiFi, it creates a hotspot instead:

| | |
|---|---|
| Network | `OPiRescue` |
| Password | `orangepi123` |
| Then ssh to | `orangepi@10.42.0.1` |

Join that network from a laptop or phone and you are back in control of the Pi.

The hotspot stays up until the Pi is rebooted, so it works out in the field with
no network anywhere. On the next reboot it tries your normal WiFi first.

## Changing the settings

Your networks and the hotspot name/password live in one file:

```
sudo nano /etc/wifi-failsafe.conf
```

You can list more than one network. **The first one listed is preferred** — if
the Pi ends up on a later one but the first is in range, it switches to the
first. Note there are **no commas** between the lines:

```
SSIDS=(
  "HomeWiFi|homepassword"
  "PhoneHotspot|phonepassword"
)

HOTSPOT_SSID="OPiRescue"
HOTSPOT_PASSWORD="orangepi123"
```

This file is the source of truth: at every boot its passwords are pushed into
NetworkManager, so what you put here is what the Pi uses. Changes take effect on
the next reboot.

## Checking it works

See what it did on the last few boots:

```
sudo cat /var/log/wifi-failsafe.log
```

Each boot is logged, with what it tried and how it turned out:

```
================ boot 2026-09-17 14:05:28 ================
2026-09-17 14:05:28  waiting up to 90s for wlan0 to settle...
2026-09-17 14:05:31  connected to 'HomeWiFi' after 3s (first choice) -- nothing to do.
```

See the networks it will try, and what it would do, without changing anything:

```
sudo /usr/local/bin/check_wifi.sh --dry-run
```

Also:

```
systemctl status check_wifi
journalctl -u check_wifi -b
```

For a full test of the hotspot, and for troubleshooting, see
**[docs/TESTING.md](docs/TESTING.md)**.

## How it works

At boot the Pi waits for WiFi to come up, then:

* If it connected to the **first** network on your list — nothing happens.
* If it connected to a later one, it checks whether an earlier one is in range
  and switches if so.
* If it is not connected at all, it tries each of your networks in order.
* If none of them work, it starts the `OPiRescue` hotspot on `10.42.0.1`.

Everything it tried is written to `/var/log/wifi-failsafe.log`, one section per
boot.

The hotspot is marked so it never takes over a normal boot, and the script never
deletes the WiFi settings you rely on.

## Uninstalling

```
sudo systemctl disable --now check_wifi.service
sudo rm /usr/local/bin/check_wifi.sh /usr/local/bin/wifi-restore.sh
sudo rm /etc/systemd/system/check_wifi.service /etc/systemd/system/check_wifi.timer
sudo rm /etc/wifi-failsafe.conf
```

## Notes for this board

The Orange Pi Zero 3W is not a Raspberry Pi, and a few things differ enough to
matter. See **[docs/BOARD-NOTES.md](docs/BOARD-NOTES.md)** for the UART map, boot
configuration, and the traps specific to the Allwinner A733.

If the Pi becomes unreachable and you have to start over, see
**[docs/RECOVERY.md](docs/RECOVERY.md)**.

## Authors

Peter Burke

## License

The scripts in this repository are provided as-is.

## Acknowledgments

Adapted for the Orange Pi from
[installmavlinkrouter2024](https://github.com/PeterJBurke/installmavlinkrouter2024)
and [RaspberryPiHotspotIfNoWifi](https://github.com/PeterJBurke/RaspberryPiHotspotIfNoWifi).
Why it is a rewrite rather than a port: **[docs/WHY-A-REWRITE.md](docs/WHY-A-REWRITE.md)**.
