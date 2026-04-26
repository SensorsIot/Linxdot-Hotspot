# Linxdot LoRa Gateway

[![Build](https://github.com/SensorsIot/Linxdot-Hotspot/actions/workflows/build.yml/badge.svg)](https://github.com/SensorsIot/Linxdot-Hotspot/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/SensorsIot/Linxdot-Hotspot?include_prereleases)](https://github.com/SensorsIot/Linxdot-Hotspot/releases)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

![LoRaWAN](https://img.shields.io/badge/LoRaWAN-Gateway-green)
![TTN](https://img.shields.io/badge/TTN-Compatible-blue)
![Platform](https://img.shields.io/badge/Platform-Linxdot_LD1001-orange)

Turn your **Linxdot LD1001** into a **LoRaWAN gateway** for [The Things Network](https://www.thethingsnetwork.org/).

OpenLinxdot is a custom Buildroot firmware that connects the Linxdot hotspot to TTN via the secure Basics Station protocol. Read-only rootfs, Ethernet-only over-the-air updates with bootloader-level auto-rollback, no cloud subscriptions.

---

## Get Started

### 1. Download

Grab the latest release from [GitHub Releases](https://github.com/SensorsIot/Linxdot-Hotspot/releases) — you need `linxdot-basics-station.img.xz` (the factory image). Decompress:

```bash
xz -d linxdot-basics-station.img.xz
```

### 2. Flash

You'll need a Linux host (Raspberry Pi, PC, or VM) with `rkdeveloptool`:

```bash
sudo apt-get install rkdeveloptool
```

Put the Linxdot into Loader mode: with power disconnected, hold the **BT-Pair** button (near the antenna connector) and connect power. Keep holding for 5 s.

> **One-time only.** BT-Pair is a vendor-bootloader feature; mainline U-Boot in OpenLinxdot ignores it. Future firmware updates use OTA over Ethernet, so this `rkdeveloptool` flash is the *only* time you'll need the USB cable. If you ever do need to re-flash (very rare), see [`Docs/linxdot_fsd.md`](Docs/linxdot_fsd.md) for the serial-console + Maskrom recovery procedure.

```bash
sudo rkdeveloptool ld                            # should show "Loader"
sudo rkdeveloptool wl 0 linxdot-basics-station.img
sudo rkdeveloptool rd                            # reboot into new firmware
```

Connect Ethernet and wait ~2 minutes for first boot.

### 3. Boot the gateway and read its EUI

The Gateway EUI is burned into the SX1302 concentrator chip and printed by Basics Station at startup. To see it, bootstrap the container with a placeholder key (you'll replace it with the real one in step 5):

```bash
ssh root@<device-ip>                                       # password: linxdot
echo placeholder > /data/basicstation/tc_key.txt
/etc/init.d/S80dockercompose start
sleep 10
docker logs basicstation 2>&1 | grep "Gateway EUI:"
# → Gateway EUI:   0016C001F140B34D
```

### 4. Register on TTN and get an LNS key

On [TTN Console](https://console.cloud.thethings.network):

1. **Gateways → Register gateway**. Enter the Gateway EUI from step 3, pick your frequency plan (e.g. `Europe 863-870 MHz`), register.
2. Open the gateway's **API keys → Add API key**. Tick **Link as Gateway to a Gateway Server for traffic exchange** under *Gateway connection (also LNS Key)*. Create, copy the `NNSXS.…` value — TTN shows it once.

### 5. Install the real key

```bash
echo 'NNSXS.your-real-key-here...' > /data/basicstation/tc_key.txt
chmod 600 /data/basicstation/tc_key.txt
/etc/init.d/S80dockercompose restart
sleep 15
docker logs basicstation 2>&1 | grep -i "Connected to MUXS"
# → [TCE:VERB] Connected to MUXS.
```

On TTN Console your gateway should show **Connected**. The key lives on `/data` and survives reboots and OTA updates — you only do this once per device.

### 6. Change region (optional)

Default is `eu1` (Europe). To switch to another TTN cluster, drop a `/data` override of the compose file (this also makes your customization OTA-safe — runtime edits to `/etc/docker-compose.yml` stack on the overlayfs and can mask future firmware fixes):

```bash
cp /etc/docker-compose.yml /data/docker-compose.yml   # /data override is bind-mounted at boot
vi /data/docker-compose.yml                           # TTS_REGION: eu1 | nam1 | au1 | ...
/etc/init.d/S80dockercompose restart
```

---

## Updates

**What you do:** nothing — once a device is online and registered with TTN, it keeps itself current. Your TTN key, region setting, and any data on `/data` survive every update and every rollback.

**When updates trigger:** **once per boot**, ~60 s after the network comes up. The `ota-check` script polls the GitHub Releases feed for this repo and installs the newest release if it's newer than what's running. There is **no periodic timer** — a gateway that stays powered on for weeks will keep its current version until something reboots it. If you want regular pickup on a 24/7 device, either schedule a weekly reboot or wire `ota-check` into a cron entry yourself.

**Trigger a check manually**, no reboot required:

```bash
ssh root@<device-ip> ota-check
```

If a newer version is available it'll download, verify, install, and reboot — total time ~2-3 minutes including the reboot. Otherwise it logs "no update available" and exits.

**What happens during an update:**

1. `ota-check` fetches the `.swu` bundle (~30 MB) from GitHub Releases
2. SWUpdate verifies the bundle's **RSA-4096 signature** against the public key embedded in the rootfs — unsigned or tampered bundles are refused before any disk write
3. SWUpdate writes the new boot + rootfs to the **inactive A/B slot** (the running slot is untouched, so basicstation keeps serving traffic until the reboot)
4. U-Boot env is flipped: `boot_slot` switches, `upgrade_available=1` arms a 3-reboot trial window
5. Device reboots into the new slot — brief LoRa outage (~30-60 s) while basicstation comes back
6. A boot-time `S98confirm` health check (Docker up, basicstation up) clears `upgrade_available` and commits the upgrade

**If something goes wrong:** the new slot's health check doesn't pass → bootcount climbs past 3 → U-Boot's `altbootcmd` automatically flips back to the previous slot on the next boot. No screwdriver, no truck roll. The failed slot stays around for diagnostics; the next successful update overwrites it.

**Migrating from a pre-A/B (Phase 1) image:** the A/B layout requires a one-time reflash. Back up `/data/basicstation/tc_key.txt` first — `/data` is recreated on reflash. Restore the key after flashing, and all subsequent updates arrive via OTA.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Can't enter Loader mode | Make sure the cable supports data (not charge-only). Try a longer button hold (up to 10 s). |
| No network after boot | Connect Ethernet **before** powering on; check router DHCP leases. |
| `TC_KEY: NOT CONFIGURED` | Step 5 not done — add the API key to `tc_key.txt` and restart compose. |
| `EUI Source: eth0` instead of `chip` | Concentrator not reset. Power-cycle the device, or run `/opt/packet_forwarder/tools/reset_lgw.sh.linxdot start`. |
| Gateway not showing on TTN | Verify EUI matches registration; `docker logs basicstation` for connection errors. |
| Repeated `excessive clock drifts (... ppm, threshold 100ppm)` | SX1302 reference oscillator drift. Cosmetic for the LNS link, but degrades RX timing on class-B/C — log a hardware issue if persistent. |

See `Docs/linxdot_fsd.md § 9 Troubleshooting` for the full list including rollback diagnosis.

---

## Default credentials

| Access | Username | Password |
|---|---|---|
| SSH | `root` | `linxdot` |

Change the password after first login: `passwd`.

---

## Serial console (optional)

For debugging without network, connect via the 3.5 mm audio jack:

```bash
picocom -b 1500000 /dev/ttyUSB0
```

Baud rate is **1,500,000** (1.5 Mbaud), 8N1. Console is also available remotely via the Workbench Pi at `rfc2217://192.168.0.87:4003`.

---

## For developers

| Document | Scope |
|---|---|
| [`Docs/linxdot_fsd.md`](Docs/linxdot_fsd.md) | Functional specification — architecture, phases, requirements, OTA design, V&V, build/release procedures |
| [`Docs/Hardware.md`](Docs/Hardware.md) | Hardware reference — GPIO pinouts, peripherals, boot chain, BootROM status |

### Tech stack

![Buildroot](https://img.shields.io/badge/Buildroot-2024.02-yellow)
![Kernel](https://img.shields.io/badge/Kernel-5.15.104-blue)
![Docker](https://img.shields.io/badge/Docker-Enabled-2496ED?logo=docker&logoColor=white)
![SX1302](https://img.shields.io/badge/LoRa-SX1302-green)
![RK3566](https://img.shields.io/badge/SoC-RK3566-red)

## License

MIT
