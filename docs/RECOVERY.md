# Recovery — rebuilding from a blank SD card

If Wi-Fi is lost and the board becomes unreachable, this is the full path back.
There is deliberately **no out-of-band console** in this setup (see
[Accepted risk](#accepted-risk)), so recovery means reflashing.

Budget roughly 30–45 minutes.

---

## 1. Flash the OS

Download the Orange Pi Zero 3W Ubuntu image (the one this was built on:
**Ubuntu 26.04 "Resolute", Orange Pi 1.0.2, kernel 6.6.98-sun60iw2, aarch64**).

Write it with Raspberry Pi Imager, balenaEtcher or `dd`.

> **Check your board first.** `cat /proc/device-tree/model` should say
> `sun60iw2` (Allwinner **A733**). Many boards sold as "Zero 3W" are H618
> (`sun50i-h616`) and need a different image and different UART overlays.

## 2. Get back on Wi-Fi headlessly — before first boot

This is the important step, and it is easy to miss. The freshly-written SD card
has `/boot/orangepi_first_run.txt.template`. With the card still in your
computer:

1. Rename it to **`/boot/orangepi_first_run.txt`**
2. Edit it:

```ini
FR_net_change_defaults=1
FR_net_ethernet_enabled=0
FR_net_wifi_enabled=1
FR_net_wifi_ssid='YourSSID'
FR_net_wifi_key='YourPassword'
FR_net_wifi_countrycode='US'
```

The board joins your Wi-Fi on first boot with no monitor or keyboard.

> The file stores the key in plaintext and deletes itself after first run
> (`FR_general_delete_this_file_after_completion=1`).

There is **no Ethernet port** on this board, so without this step a headless
first boot has no network at all.

## 3. Find it and log in

```bash
ssh orangepi@orangepi.local
# or find the address on your router, then:
ssh orangepi@192.168.1.xxx
```

Default credentials are `orangepi` / `orangepi` unless the image differs.

## 4. Re-apply this project

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/PeterJBurke/OrangePiHotspotIfNoWifi.git
cd OrangePiHotspotIfNoWifi
sudo ./install.sh
sudo nano /etc/wifi-failsafe.conf     # real SSIDs + passwords
```

Do **not** enable `check_wifi.service` until the AP test has passed
(see the main README).

## 5. Re-apply MAVLink Router, if this board flies

```bash
git clone https://github.com/PeterJBurke/installmavlinkrouterorangepizero3w.git
cd installmavlinkrouterorangepizero3w
sudo ./install.sh
sudo reboot
./test_serial.sh
```

That sets up UART2 on header pins 11/13, serves MAVLink on TCP 5678, and
disables Wi-Fi power save. Flight-controller wiring:

| Pi pin | → | Flight controller |
|---:|---|---|
| 11 | → | RX |
| 13 | ← | TX |
| 14 | — | GND |

The FC's telemetry port must be **57600** with `SERIALn_PROTOCOL = 2`.

## 6. Restore anything else

- Tailscale: `sudo tailscale up` and re-authenticate
- Static DHCP lease on your router — strongly recommended, since the address
  changing is a recurring source of "it stopped working"

---

## Accepted risk

This project deliberately ships **without** an out-of-band rescue path. The
board's serial console is enabled by default (`console=ttyS0,115200`, getty on,
header pins 8 TX / 10 RX / 6 GND) and a ~$5 USB-TTL adapter at 115200 8N1 would
give a login prompt with no network at all — turning "reflash" into "plug in and
fix".

That was considered and declined as not worth the effort. The fallback is this
document. It is a real, tested path, just a slower one.

If you change your mind, nothing needs configuring — the console is already
live. Just wire an adapter to pins 8/10/6 and open it at 115200.
