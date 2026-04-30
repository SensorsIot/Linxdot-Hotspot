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

### 3. Bind the case MAC

After the first boot, the device announces itself on Ethernet with a known shared setup MAC: **`02:00:5d:01:01:01`**. Look for that entry in your router's DHCP table to get the device's IP. SSH in and run the setup wizard:

```bash
ssh root@<device-ip>     # password: linxdot
linxdot-setup            # paste the MAC from the case sticker when asked
```

The wizard validates the MAC, writes it into the eMMC hardware boot partition, and reboots the device. Wait ~90 s, then look up your case MAC in the router's DHCP table to find the new IP. The case MAC is now permanent — it survives reboots, OTA updates, and any future `rkdeveloptool` re-flash.

> ⚠️ **Provision one device at a time.** Every fresh OpenLinxdot device announces the same setup MAC `02:00:5d:01:01:01`. Finish step 3 on the first device before powering on the next.

### 4. Connect to TTN

You'll need a TTN admin API key with the **Manage gateways** right (one-time, reusable across devices). Create it once at https://eu1.cloud.thethings.network → click your profile picture (top right) → **Personal API keys** → **+ Add API key** → tick **Manage gateways** → Create. TTN shows the `NNSXS.…` value once — copy it.

Then SSH back in at the new (case-MAC) IP and run the wizard again:

```bash
ssh root@<new-device-ip>
linxdot-setup
```

Phase 2 prompts you for:

| Field | Default / hint |
|---|---|
| TTN cluster | `eu1` (Europe) — or `nam1` / `au1` / `as1` |
| TTN user or organization ID | your TTN handle |
| User or organization | `u` (most common) |
| Admin API key | the `NNSXS.…` value from above |
| Gateway ID | `linxdot-<eui>` auto-generated; press Enter to accept |
| Frequency plan | per cluster default (`EU_863_870` for `eu1`); press Enter |

The wizard reads the Gateway EUI from the SX1302 chip, calls TTN's REST API to register the gateway and mint a fresh LNS key, writes the key to `/data/basicstation/tc_key.txt`, restarts basicstation, and waits for the `Connected to MUXS` handshake. When you see **"Setup complete — your gateway is live on TTN"** you're done.

If the gateway with this EUI is already registered (e.g. you re-ran the wizard), the conflict resolver detects it from TTN's response and reuses the existing gateway. If TTN's response says the gateway is owned by a different tenant, the wizard falls back to asking for an LNS key paste.

The LNS key lives on `/data` and survives reboots and OTA updates. The admin API key is held only in memory during the wizard run — never written to disk.

> ⚠️ **Don't soft-delete a TTN-registered gateway and immediately try to re-register it.** TTN community cluster only lets users soft-delete (admins can purge); the EUI stays "captive" for the cluster's restore window (~7 days) and re-registration fails with `gateway_eui_taken`. If you need to retest, re-run the wizard with the same gateway_id — the conflict resolver reuses the existing TTN registration.

### 5. Change region (optional)

If you picked a non-`eu1` cluster in step 4, the wizard already wrote `/data/docker-compose.yml` with the right `TTS_REGION` for you. To change cluster after setup:

```bash
ssh root@<device-ip>
vi /data/docker-compose.yml                           # TTS_REGION: eu1 | nam1 | au1 | as1
/etc/init.d/S80dockercompose restart
```

The `/data` override is bind-mounted on top of `/etc/docker-compose.yml` at boot, so it survives OTA updates.

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
| `TC_KEY: NOT CONFIGURED` | Step 4 didn't complete — re-run `linxdot-setup` to retry TTN registration. |
| `EUI Source: eth0` instead of `chip` | Concentrator not reset. Power-cycle the device, or run `/opt/packet_forwarder/tools/reset_lgw.sh.linxdot start`. |
| Gateway not showing on TTN | Verify EUI matches registration; `docker logs basicstation` for connection errors. |
| Repeated `excessive clock drifts (... ppm, threshold 100ppm)` | SX1302 reference oscillator drift. Cosmetic for the LNS link, but degrades RX timing on class-B/C — log a hardware issue if persistent. |

See `Docs/linxdot_fsd.md § 11 Troubleshooting` for the full list including rollback diagnosis.

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
