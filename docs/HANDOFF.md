# Handoff — state of play

Last updated: 2026-11-01.

## Fallback test attempted 2026-11-01 — inconclusive, waited 28 s too little

First real attempt at the one remaining test. All SSIDs off at boot, no hotspot
appeared, SSID turned back on after a few minutes. **The script was not at
fault** — it never reached the hotspot decision before a network returned.

### How long to wait: 7 minutes

Power-on to hotspot visible is about **5 min 45 s** with the four networks
currently configured. Measured on this boot, boot (`uptime -s` 17:00:39) to the
hotspot decision was **315 s**:

| phase | time |
|---|---|
| boot → service starts | 6 s |
| settle (`SETTLE_SECS=90`) | 95 s |
| 4 networks × ~55 s each | 220 s |
| → hotspot decision | **315 s** |
| hotspot up + visible in a scan | ~30 s |

It scales with the config, so this number moves as networks are added:

```
seconds to hotspot ≈ 100 + 55 × (number of configured networks)
```

The "roughly 2-3 minutes" figure elsewhere in this file is stale — it was
written when two networks were configured. There are now four.

### What actually happened

The SSID came back at 4 min 47 s. NetworkManager autoconnected to `Burkephone`
(priority 100) on its own, 28 s before the script finished its last candidate.
The guard then did the right thing:

```
no configured network reachable. Considering hotspot fallback.
still connected to 'Burkephone'. NOT replacing a live connection
with a hotspot -- that would be a downgrade. Exiting.
```

AP mode is still supported by the radio (`iw list` lists `AP`), so that check
would have passed. Decision: **do not change the scripts.** It is a timing
issue, not a bug.

### Reading the log needs care — the timestamps lie early in boot

This board has no RTC. The log for this run shows
`trying 'GL-MT6000-ccf'` at `2026-10-29 23:07:21` and `failed` at
`2026-11-01 17:05:54`, which looks like a three-day hang. It is not. The clock
booted stale by **237,458 s (2.75 days)** from `fake-hwclock` and chrony stepped
it mid-run. Convert with `uptime -s` for the real boot time before drawing any
conclusion from `/var/log/wifi-failsafe.log`.

### The trap that ended this attempt

`Burkephone` is priority #1 and it is a phone. In a pocket with the hotspot on,
the test is over before it starts. All four must be off or out of range for the
full 7 minutes: `Burkephone`, `GL-MT3000-e23`, `TP-Link_FD78_5G`,
`GL-MT6000-ccf`.

### Known inefficiency, deliberately not fixed

On the give-up path the script attempts every configured network blind, with no
scan — ~3 of the 5 minutes is spent on associations that cannot succeed. It
already scans in the settle loop and logs `not seen in scan, trying anyway`.
Gating the attempts on a rescan would cut time-to-hotspot from ~315 s to ~100 s.
Offered and declined: the script works, and changing live networking risks SSH.
Recorded here in case the wait becomes annoying later.

## Escalation path proven in the field (2026-10-26)

Observed on a board that had been running untouched for a week. A third
network has been added since the last update, and it is the one in use:

```
wlan0: connected: wififailsafe-GL-MT6000-ccf   ip 192.168.8.143   signal 100%
  wififailsafe-GL-MT3000-e23     priority 100   (choice #1)
  wififailsafe-TP-Link_FD78_5G   priority  90   (choice #2)
  wififailsafe-GL-MT6000-ccf     priority  80   (choice #3)
```

The service log for this boot, which is the escalation path running for real
against two genuinely unavailable networks:

```
[wifi-failsafe] connected to 'GL-MT6000-ccf' after 0s, but that is choice #3.
[wifi-failsafe]   scan (rescan): 16 networks seen
[wifi-failsafe]   'GL-MT3000-e23' (choice #1) not seen in scan, trying anyway
[wifi-failsafe]   could not join 'GL-MT3000-e23'
[wifi-failsafe]   'TP-Link_FD78_5G' (choice #2) not seen in scan, trying anyway
[wifi-failsafe]   could not join 'TP-Link_FD78_5G'
[wifi-failsafe] staying on 'GL-MT6000-ccf'.
```

**What this adds to what was already proven.** Previously only "first listed
network is preferred" was verified, on a board where the first choice was
available. Now verified:

* it notices it is on a lower-priority network and does not simply accept it
* it attempts each higher-priority network in order, including ones absent from
  the scan ("trying anyway")
* **failed attempts do not cost the working connection** — two joins failed and
  the board stayed up on choice #3 throughout. This is the property that makes
  the service safe to leave enabled; the whole run took 19 s.

Still **NOT** tested: the hotspot itself firing, because a configured network
was reachable the whole time. That test is unchanged and still the one gap.

### Side finding: this board has no RTC, and the clock starts days stale

`timedatectl` reports `RTC time: n/a`, there is no `/dev/rtc`, and the time is
carried across reboots by `fake-hwclock`. On this boot chrony found the clock
**577,828 s wrong — 6.7 days** — and stepped it only once the network was up:

```
Oct 19 23:16:34 chronyd: System clock wrong by 577828.702179 seconds
Oct 26 15:47:03 chronyd: System clock was stepped by 577828.702179 seconds
```

So the first ~20 s of every boot is logged under the *previous* shutdown's date.
The journal above shows exactly that — the first lines are stamped Oct 19 and
the rest Oct 26, in one 19-second service run.

Consequences: journal timestamps before the step are stale, not wrong by a
little; and anything that records wall-clock time early in boot, or with no
network at all, records a date days off. That matters for the autoland work in
the `installmavlinkrouterorangepizero3w` repo, where `dronefly.py` stamps
`datetime.now()` into the flight controller's `.BIN` log to line its decision up
against the mode change. In the drone cage there is no internet, so that stamp
can be days stale. See that repo's handoff.

## Where things stand (2026-09-17, latest)

**The network-selection side is working and proven on hardware.** The board
selects the first network listed in `/etc/wifi-failsafe.conf` by priority, chosen
by NetworkManager itself with no intervention from the script:

```
wlan0: connected: wififailsafe-GL-MT3000-e23   ip 192.168.8.143
  wififailsafe-GL-MT3000-e23     priority 100
  wififailsafe-TP-Link_FD78_5G   priority 90
14:43:14  connected to 'GL-MT3000-e23' after 0s (first choice) -- nothing to do.
```

| | |
|---|---|
| Installed + enabled at boot | yes |
| Config file is the source of truth | yes — profiles rebuilt from it before NM starts |
| First-listed network preferred | **proven on hardware** |
| Escalation through unavailable networks | **proven 2026-10-26, see top** |
| AP / hotspot mode supported by the radio | **proven** (earlier test) |
| **Hotspot fallback firing for real** | **still NOT tested** — 1 Nov attempt was cut short, see top |
| `check_wifi.timer` (periodic re-check) | disabled, deliberately |

### The one remaining test

Make every configured network unreachable and confirm `OPiRescue` appears:
turn the first network off, leave a wrong password for the second, reboot.
Expect the hotspot after about **5 min 45 s** with four networks configured —
wait a full **7 minutes** before concluding it failed. (The old "2-3 minutes"
here assumed two networks; see the 1 Nov section at the top.)

**Escape hatch:** turn the first network back on and power-cycle. Its password is
still correct at priority 100, so the board reconnects there. This test cannot
strand the board the way the earlier ones could.

### Settings that matter for that test

* `autoconnect-retries=3` in the generated keyfiles. It was `0`, which in
  NetworkManager means **infinite** — with a wrong password NM would retry
  forever in the background and could contend with the rescue hotspot for the
  radio.
* The post-NetworkManager pass no longer rebuilds profiles. That is owned by the
  pre-NM `--sync-only` pass; doing it twice produced `could not create profile`
  errors against a live NM.

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

## Changes since first deployment (2026-09-17, later)

The failsafe was installed and AP mode proven, then the user tried to test the
fallback by putting a wrong password for their main network in
`/etc/wifi-failsafe.conf` and rebooting. Nothing happened. Three things came out
of that.

### 1. The config file is now authoritative

NetworkManager keeps its own copy of every Wi-Fi password, and
`/etc/wifi-failsafe.conf` was read *only* by `check_wifi.sh`. So a wrong
password there changed nothing: the board connected normally with NM's stored
password, and the script correctly saw "I am on a wanted network" and stood
down. The config file was effectively decorative.

`check_wifi.sh` now pushes the config's passwords into the matching NM profiles
before judging anything, and bounces the link if it changed the password of the
connection it is currently riding on.

**Trade-off, deliberately accepted:** a typo in the config will now break a
working connection. That is the cost of one source of truth, and it is what the
hotspot fallback is for.

### 2. The first listed network is now genuinely preferred

The order of `SSIDS` was only honoured when starting from *disconnected*. If NM
had already autoconnected to a later entry, the script saw a wanted network and
stopped — so in the common case the order meant nothing.

It now determines which entry it landed on and, if that is not the first,
rescans and switches to the highest-priority network in range. It also sets
`connection.autoconnect-priority` in descending order so NM's own autoconnect
agrees rather than racing it.

Verified against six mocked cases including an SSID with spaces.

### 3. Everything is logged to disk

`/var/log/wifi-failsafe.log`, a header per boot plus a `RESULT:` line, so there
is a durable record across power cycles rather than only what journald kept.
Trimmed to the last 500 lines past 256KB.

### Also added

`sudo /usr/local/bin/check_wifi.sh --dry-run` — reports the networks it will try
in order, which are in range, whether NM's stored password agrees with the
config (`matches` / `DIFFERS`), and what it would do at boot. Changes nothing;
verified it exits before the password sync runs.

### Gotcha for the config file

**No commas between entries.** It is a bash array. A trailing comma is swallowed
into the entry, so the SSID still parses correctly while the password silently
gains a `,` and that network can never authenticate — an invisible failure.

### Still untested

The fallback itself has never fired in anger. AP mode is proven (see the test
result above), and the decision logic is unit-tested against mocks, but no boot
has yet gone: known network unreachable -> try the next -> start the hotspot.
The user was about to test exactly that.

## Root cause of the repeated fallback failures (2026-09-17, evening)

Three separate attempts to test the fallback failed. The cause was not what it
looked like.

```
14:24:46  NetworkManager: Activation: starting connection 'Orange Pi wireless'
14:24:47  check_wifi.sh sets GL-MT3000-e23 priority to 100
```

**NetworkManager chooses a network the instant it starts.** `check_wifi.service`
is ordered *after* NM by design, so its priority update always arrived about a
second too late and was ignored until the next boot. The board sat on the
second-choice network while the log truthfully reported what it had done.

A scan that took **171 seconds** and then wrongly reported the preferred network
absent made this look like a scanning problem. It was not — the network was
demonstrably on air at signal 100 at the time.

Underneath, NetworkManager's profiles on this image are **generated by netplan
into `/run`**, so its "memory" is really `/etc/netplan/90-NM-<uuid>.yaml`,
regenerated at each boot. The config file was never actually in charge, which is
what the user had asked for from the start.

### The fix

`wifi-failsafe-profiles.service` runs `check_wifi.sh --sync-only` **before
NetworkManager starts**. `nmcli` is unusable there (it needs NM's D-Bus), so it
writes NM keyfiles directly into `/etc/NetworkManager/system-connections/`: it
clears the netplan-generated Wi-Fi profiles and its own previous ones, then
writes one keyfile per configured network with descending `autoconnect-priority`.
NM then starts with exactly what `/etc/wifi-failsafe.conf` says.

It refuses to clear anything unless the config parsed with at least one network.
UUIDs are derived from the SSID (uuid5) so they are stable across boots.

Also: every `nmcli` call is now bounded with `timeout`, and a negative scan is no
longer trusted — a higher-priority network is attempted regardless, with the
previous connection restored if the attempt fails.

### VERIFIED vs NOT VERIFIED

Verified:
* the race is real, from NetworkManager's own logs
* the generated keyfiles parse with the expected sections, ssid and priorities
* UUID derivation is stable

**Not yet verified:** that NetworkManager on this image actually loads keyfiles
from `/etc/NetworkManager/system-connections/` when netplan is also present.
`plugins=ifupdown,keyfile` says it should. This has NOT been demonstrated on the
hardware. Test it with `--sync-only` followed by `nmcli connection show` BEFORE
relying on a reboot.

## Do not run --sync-only on a live system (2026-09-17)

`--sync-only` rebuilds NetworkManager's Wi-Fi profiles from the config file. It
is meant to run **at boot, before NetworkManager starts**, when nothing is
connected.

Run on a live system it deletes the backing config of the active connection.
NetworkManager drops that connection on its next reload. This was suggested to
the user as a "safe verification" step; it dropped their SSH session and cost
two hard reboots. The script now **refuses** to run this mode while
NetworkManager is up and the interface is connected (override
`MLR_FORCE_SYNC=1`, local console only).

### What the incident proved

The mechanism works. Afterwards NetworkManager had exactly the intended state:

```
wififailsafe-GL-MT3000-e23     priority 100
wififailsafe-TP-Link_FD78_5G   priority 90
```

with the uuid5-derived UUIDs the generator produces. NetworkManager reads the
keyfiles from `/etc/NetworkManager/system-connections/`, then migrates them into
`/etc/netplan/90-NM-<uuid>.yaml` and regenerates them into `/run`. That
migration is what tore down the live link — harmless at boot, destructive when
connected.

**So the profiles on this board are now correct and persistent.** The next boot
should select GL-MT3000-e23 on priority, without any further intervention.

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
