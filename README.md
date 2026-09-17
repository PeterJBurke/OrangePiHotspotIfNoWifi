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

You can list more than one network; they are tried in order. Note there are
**no commas** between the lines:

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

See the networks it will try, and what it would do, without changing anything:

```
sudo /usr/local/bin/check_wifi.sh --dry-run
```

```
systemctl status check_wifi
```

To see what it did on the last boot:

```
journalctl -u check_wifi -b
```

For a full test of the hotspot, and for troubleshooting, see
**[docs/TESTING.md](docs/TESTING.md)**.

## How it works

At boot the Pi waits for WiFi to come up, then:

* If it connected to one of your networks — nothing happens.
* If not, it tries each of your networks in turn.
* If none of them work, it starts the `OPiRescue` hotspot on `10.42.0.1`.

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
