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

```bash
sudo rkdeveloptool ld                            # should show "Loader"
sudo rkdeveloptool wl 0 linxdot-basics-station.img
sudo rkdeveloptool rd                            # reboot into new firmware
```

Connect Ethernet and wait ~2 minutes for first boot. Future firmware updates arrive automatically over Ethernet — this reflash is the only time you'll need the USB cable.

### 3. Find the Gateway EUI

SSH in (password `linxdot`):

```bash
ssh root@<device-ip>
docker logs basicstation 2>&1 | grep "Station EUI"
```

### 4. Register on TTN and get an API key

On [TTN Console](https://console.cloud.thethings.network):

1. **Gateways → Register gateway**. Enter the Gateway EUI, pick your frequency plan (e.g. `Europe 863-870 MHz`), register.
2. Open the gateway's **API keys → Add API key**. Tick **Link as Gateway to a Gateway Server...**, create. Copy the key starting with `NNSXS.` — you won't see it again.

### 5. Configure and start

```bash
ssh root@<device-ip>
echo 'NNSXS.your-key-here...' > /data/basicstation/tc_key.txt
/etc/init.d/S80dockercompose restart
/etc/init.d/S80dockercompose status       # expect TC_KEY configured, basicstation Up
```

On TTN Console your gateway should show **Connected**.

### 6. Change region (optional)

Default is `eu1`. To change:

```bash
ssh root@<device-ip>
vi /data/docker-compose.yml       # TTS_REGION: eu1 | nam1 | au1
/etc/init.d/S80dockercompose restart
```

---

## Updates

Devices running the A/B-layout firmware pick up new releases automatically — 60 s after boot, `ota-check` polls GitHub Releases, applies any newer version to the inactive slot, and reboots. If the new slot fails to reach TTN within the trial window, U-Boot rolls back to the old slot automatically. `/data` (your TTN key, Docker state, config) is preserved across updates.

Trigger a check manually without rebooting:

```bash
ssh root@<device-ip> ota-check
```

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
