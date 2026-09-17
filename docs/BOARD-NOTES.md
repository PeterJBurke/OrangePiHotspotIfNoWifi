# Board notes — Orange Pi Zero 3W (Allwinner A733 / sun60iw2)

Hardware facts established by measurement on the actual board, not from
documentation. Recorded because several of them contradict what you will find
online for "Orange Pi Zero 3W".

## Identity

```
$ cat /proc/device-tree/model
sun60iw2                          # Allwinner A733 -- NOT the H618 most docs assume

$ uname -r
6.6.98-sun60iw2

$ cat /etc/os-release | head -2
PRETTY_NAME="Orange Pi 1.0.2 Resolute"
NAME="Ubuntu"                     # 26.04, aarch64
```

CPU: 8 cores (6× Cortex-A55 + 2× Cortex-A76), up to 1.794 GHz. 6 GB RAM.

`/boot/orangepiEnv.txt` carries `overlay_prefix=sun60i-a733`. Any guide telling
you to use `sun50i-h616-*` overlays does not apply.

## Networking

| | |
|---|---|
| Wi-Fi chip | AIC8800, driver `aicwf_sdio` |
| Interface | `wlan0` |
| **Ethernet** | **none — Wi-Fi is the only network path** |
| Managed by | NetworkManager 1.54.3 (+ wpa_supplicant) |
| `dhcpcd` | not installed |

`iw list` advertises AP mode with `#{ AP } <= 1`, but this has **not** been
proven to work on this vendor driver — see `test-ap-capability.sh`.

Wi-Fi power save is **on by default**, which causes latency spikes and dropped
telemetry. Disable it:

```
# /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf
[connection]
wifi.powersave = 2
```

## Boot timing (matters for any boot-time network script)

```
multi-user.target reached  @  8.982s
wlan0 associated           @ 15.3s
```

`NetworkManager-wait-online.service` is **disabled** by default, and
`/etc/systemd/system/network-online.target.wants/` contains only
`networking.service`. So `After=NetworkManager-wait-online.service` in a unit
file is **inert** unless you also enable that service.

Any script that checks "am I on Wi-Fi?" at boot must either enable
`NetworkManager-wait-online` or poll, or it will reliably see "not connected"
on a perfectly healthy system.

## Boot configuration

There is **no `/boot/firmware/config.txt`** and no `cmdline.txt` — those are
Raspberry Pi paths. Configuration lives in `/boot/orangepiEnv.txt`, which
`/boot/boot.cmd` imports *after* setting its defaults, so values there win:

```
console=both        # 'display' drops console=ttyS0 from the kernel cmdline
earlycon=on         # 'off' drops earlyprintk=sunxi-uart,0x02500000
overlays=uart2      # loads dtb/allwinner/overlay/sun60i-a733-uart2.dtbo
```

Headless first boot is configured by renaming
`/boot/orangepi_first_run.txt.template` to `orangepi_first_run.txt` — see
[RECOVERY.md](RECOVERY.md).

## UARTs — the part everyone gets wrong

| Device | What it is |
|---|---|
| `/dev/ttyS0` | **Debug console.** Kernel + U-Boot output at 115200, getty enabled. Header pins 8 (TX) / 10 (RX), shared with the 3-pin CPU DEBUG header through 1 kΩ resistors R82/R83. |
| `/dev/ttyS1` | **Bluetooth HCI.** Looks free (`root:dialout`, writable) but `hciattach_opi` owns it, line discipline is 15 (`N_HCI`), and **writes block forever**. Wired to the AIC8800, not to the header. Do not use. |
| `/dev/ttyS2` | UART2, header pins 11 (TX) / 13 (RX). Needs `overlays=uart2`. **This is the one to use.** |
| `/dev/ttyS6/7/8` | Available via `overlays=uart6/7/8`. |

Vendor manual §3.16.5 pin map:

| UART | RX pin | TX pin | overlay |
|---|---:|---:|---|
| UART2 | 13 | 11 | `uart2` |
| UART6 | 23 | 24 | `uart6` |
| UART7 | 18 | 16 | `uart7` |

> **Header numbering:** the 2×20 rows interleave, so descending one column steps
> by **2**. Left column: `pin = 2 × row − 1`, so the 6th entry down is pin 11.
> The pinout diagram on manual page 13 prints no pin numbers.

U-Boot prints to UART0 at 115200 on **every** boot. `console=` in
`orangepiEnv.txt` only controls the kernel, so anything attached to pins 8/10
receives boot text at power-up. That is why the flight controller uses UART2.

## Serial console (rescue path, currently unused)

Enabled by default and still enabled:

```
console=ttyS0,115200    serial-getty@ttyS0: enabled + active
agetty: 115200,57600,38400,9600
```

A 3.3 V USB-TTL adapter on **pin 8 (→ adapter RX), pin 10 (→ adapter TX),
pin 6 (GND)** at 115200 8N1 gives a login prompt with no network. Do not connect
the adapter's VCC. Not currently used by choice — see
[RECOVERY.md](RECOVERY.md#accepted-risk).

## Related

- [installmavlinkrouterorangepizero3w](https://github.com/PeterJBurke/installmavlinkrouterorangepizero3w)
  — MAVLink Router on UART2, with a build journal documenting 19 hardware gotchas.
