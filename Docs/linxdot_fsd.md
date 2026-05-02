# OpenLinxdot — Functional Specification Document (FSD)

## 1. Introduction

### 1.1 Purpose

This document is the canonical functional specification for **OpenLinxdot**, custom Buildroot firmware that turns the Linxdot LD1001 LoRaWAN gateway into a clean-room, OTA-updatable TTN gateway. It specifies what the system must do, the constraints under which it operates, the interfaces it exposes, the procedures for building / releasing / recovering it, and the verification evidence that confirms each requirement has been met. § 9 (Developer Guide) extends the spec with concrete guidance for contributors making changes intended to ship via OTA.

`README.md` is the operator-facing companion to this document; `CLAUDE.md` is the AI-agent onboarding companion. Where the three disagree, **this FSD is canonical**.

### 1.2 Scope

In scope:
- All firmware shipped to deployed Linxdot LD1001 hardware: bootloader, kernel, rootfs, services.
- The Buildroot tree (this repository), CI pipeline, OTA delivery infrastructure (GitHub Releases + signing).
- Operational procedures for build, release, factory flashing, OTA, recovery.

Out of scope:
- TTN-side account or network configuration (operator's responsibility).
- WiFi support (firmware extraction is operator-side; not redistributable).
- Cellular / non-Ethernet transports.

### 1.3 Audience

| Reader | Sections of primary interest |
|---|---|
| **Maintainers** building & releasing firmware | § 8 (Operations), § 12 (Backlog), § 13 (Appendix) |
| **Contributors** changing the firmware | § 5 (Requirements), § 9 (Developer Guide), § 10 (V&V) |
| **Field operators** deploying & supporting devices | `README.md` (primary), § 8.8 / § 11 (Recovery, Troubleshooting) |
| **Security reviewers** auditing the OTA chain | § 5.2 (NFR-2.x), § 7 (Interfaces), § 8.5 (Signing key lifecycle), § 10.3 (TC-4.3) |

### 1.4 Definitions, Acronyms & Conventions

**Glossary:**

| Term | Meaning |
|---|---|
| **A/B slot** | Two redundant rootfs+boot partitions (`p1`+`p2` = slot A, `p3`+`p4` = slot B). The active slot is selected by U-Boot env `boot_slot`; the inactive slot receives OTA writes. |
| **Basics Station** | Semtech reference LoRa packet-forwarder. Connects gateway to the LNS over WebSocket+TLS. |
| **BL31** | EL3 secure-monitor firmware. In OpenLinxdot Phase 3+ this is the rkbin vendor binary `rk3568_bl31_v1.43.elf` (see § 4.3, § 13.1). |
| **CUPS** | Configuration & Update Server — Basics Station's optional config endpoint. **Not used** by OpenLinxdot. |
| **DTB / DTS** | Device Tree (Blob / Source). Vendor `rk3566-linxdot.dtb` is used through Phase 4; replaced by an in-tree DTS in Phase 5. |
| **EUI** | Extended Unique Identifier — the 64-bit identity for the gateway, read from the SX1302 chip ID. |
| **FIT image** | U-Boot's Flattened Image Tree — packages BL31 + U-Boot proper into one verifiable container. |
| **LNS** | LoRaWAN Network Server. For OpenLinxdot the LNS is TTN at `wss://<region>.cloud.thethings.network`. |
| **LFS** | Git Large File Storage. Vendor blobs (`Image`, `*.dtb`, modules) are LFS-tracked. |
| **OTA** | Over-the-Air update. In OpenLinxdot: Ethernet-only, polling GitHub Releases. |
| **rkbin** | Rockchip's binary blob repository — DDR TPL and BL31 sources. |
| **SoC** | System-on-Chip. Linxdot LD1001 uses the Rockchip RK3566. |
| **SPL** | Secondary Program Loader — first stage of U-Boot, runs from on-chip SRAM. |
| **SWUpdate** | OTA install agent (sbabic/swupdate). Consumes signed `.swu` bundles. |
| **`.swu`** | SWUpdate's bundle format — a CPIO archive containing `sw-description` + payloads + signatures. |
| **TC key** | Thing Configuration key — TTN-issued LNS API key, stored in `/data/basicstation/tc_key.txt`. |
| **TF-A** | Trusted Firmware-A. Source-built (v2.12.0) but its BL31 output is unused; rkbin BL31 is linked instead (§ 4.3, § 13.1). |
| **TPL** | Tertiary Program Loader — Rockchip terminology for the DDR-init blob the SPL pulls in. |
| **trial boot** | The first boot after a slot upgrade, marked by `upgrade_available=1`. Must be confirmed within `bootlimit` boots or U-Boot rolls back. |
| **upper / lower / overlay** | overlayfs concepts. The rootfs is the *lower*; `/data/overlay/<dir>/upper` collects writes. |

**Conventions** (RFC 2119):
- **Must** — mandatory; non-negotiable for compliance.
- **Should** — recommended; deviations require justification.
- **May** — optional.
- Code/file references use backticks: `board/linxdot/overlay/etc/init.d/S60ota`.
- Filesystem paths starting with `/` refer to the on-device filesystem; paths without are repo-relative.
- Section cross-references use the `§ N.X` form. References preceded by "runbook" point to `Docs/phase3_hardware_validation.md`, not this document.

### 1.5 References

| Source | Description |
|---|---|
| `README.md` | Operator-facing quick start: flashing, TTN setup, troubleshooting. |
| `Docs/Hardware.md` | Board reference: GPIO, peripherals, BootROM status. |
| `Docs/phase3_hardware_validation.md` | Hardware bring-up runbook for Phase 3 (TC-3.x procedures). |
| `CLAUDE.md` | AI-agent onboarding (Phase 1 baseline + gotchas). |
| Buildroot manual | https://buildroot.org/downloads/manual/manual.html (2024.02 LTS). |
| SWUpdate documentation | https://sbabic.github.io/swupdate/. |
| Basics Station documentation | https://doc.sm.tc/station/. |
| TTN gateway docs | https://www.thethingsindustries.com/docs/gateways/. |
| RFC 2119 | Keywords for use in RFCs to indicate requirement levels. |

## 2. System Overview

OpenLinxdot is a custom Buildroot-based firmware that turns a **Linxdot LD1001** (Rockchip RK3566, ARMv8) into a LoRaWAN gateway for **The Things Network (TTN)** via the Semtech Basics Station protocol. It replaces the vendor CrankkOS userspace with a minimal, inspectable, auditable stack: a read-only Buildroot rootfs, a single Docker container running Basics Station, and — from Phase 3 onward — a source-built bootloader that enables Ethernet-only OTA updates with bootloader-level auto-rollback.

**Users / stakeholders:**
- **End users** who want to run a TTN LoRaWAN gateway without cloud subscriptions or vendor lock-in.
- **Field operators** who deploy devices and may have limited physical access (devices often installed in enclosed or remote locations).
- **Maintainers** who build the firmware, release updates, and manage signing keys.

**Primary goals:**
- Secure, unattended LoRaWAN packet forwarding to TTN via Basics Station over WebSocket (TLS).
- First-time bring-up in under 10 minutes.
- Subsequent firmware updates delivered **over Ethernet only**, with automatic rollback on failure — no physical access required.
- Clean-room userspace with no vendor tracking, telemetry, or Helium/Crankk remnants.

**Non-goals:**
- Not a general-purpose Linux distribution — the system runs exactly one workload (Basics Station).
- No local packet forwarder fallback (UDP semtech) — Basics Station only.
- No web UI for configuration. SSH + simple files on `/data` only.

**High-level flow:**
```
BootROM → idbloader (SPL + DDR init) → TF-A BL31 → U-Boot → boot.scr
  → Linux 5.15.104 → BusyBox init → S00datapart..S40network..S49ntp..S50sshd..S60ota..[S70<app>]
  → application → external service (TTN LNS / etc.)
```
S60ota is the consolidated OTA hook (acquire + commit). Application services
slot in at S70+; the OTA layer is application-agnostic.

## 3. System Architecture

### 3.1 Logical Architecture

| Subsystem | Role |
|---|---|
| **Bootloader** (idbloader + U-Boot + TF-A BL31) | Loads kernel, implements A/B slot selection and automatic rollback on failure. |
| **Kernel + DTB** | Vendor Linux 5.15.104 binary with Rockchip vendor DTB (Phase 1–3). Built from source in Phase 2+. |
| **BusyBox init** | Runs the small set of init scripts (S00–S99) that mount filesystems, set up networking, start services. |
| **Overlayfs** | Preserves writes to `/usr`, `/var/log`, `/var/lib`, `/etc` on the read-only rootfs, backed by `/data`. |
| **Docker engine** | Runs exactly one container: `xoseperez/basicstation`. |
| **Basics Station** | LoRaWAN packet forwarder, connects to TTN via WebSocket+TLS. |
| **OTA agent** (Phase 4) | `ota-check` CLI + `S60ota` init hook (single script, two phases). Phase 1 (committed slot, synchronous): fetch manifest, compare version, download `.swu`, hand to SWUpdate, reboot. Phase 2 (trial slot, backgrounded): poll `/etc/ota/health-probe`; on healthy, clear trial flags. |
| **SWUpdate** (Phase 4) | Writes inactive A/B slot, sets U-Boot env flags for trial boot. |
| **Health probe** (Phase 4) | `/etc/ota/health-probe` — swappable executable, exit `0` = commit, non-zero = not yet. The OTA layer is application-agnostic; application packages overwrite this file with their own probe. The OTA-only base ships a default that checks route + clock-bootstrap + manifest reachability. |

### 3.2 Hardware / Platform Architecture

Target hardware is fully documented in `Docs/Hardware.md` (reference manual). Summary:

- **SoC:** Rockchip RK3566, quad-core ARM Cortex-A55 @ 1.8 GHz, aarch64.
- **Memory:** 2 GiB LPDDR4.
- **Storage:** 28.9 GiB eMMC (plenty of headroom — A/B layout uses ~1.6 GiB).
- **LoRa:** Semtech SX1302 concentrator on SPI (`/dev/spidev0.0`).
- **Network:** Gigabit Ethernet (Realtek RTL8211F). WiFi + BT present but not used by default.
- **Serial console:** UART2 @ **1,500,000 baud** on 3.5 mm TRRS jack. Exposed remotely via the Workbench Pi at `rfc2217://192.168.0.87:4003`.
- **USB:** USB-C behind the case, wired to the RK3566 USB2.0 controller — enables Rockchip download mode for `rkdeveloptool` flashing. Accessible from serial via `rockusb` / `download` commands without any physical button.
- **BootROM:** confirmed **non-secure** (see `Docs/Hardware.md § BootROM secure-mode status`).

### 3.3 Software Architecture

**Build system:** Buildroot 2024.02 LTS with `BR2_EXTERNAL` tree (this repository). Custom defconfig `configs/linxdot_ld1001_defconfig`, rootfs overlay under `board/linxdot/overlay/`, partition layout in `board/linxdot/genimage.cfg`.

**Update model (Phase 3+):** A/B slot, bootloader-level rollback.

| Partition | Filesystem | Purpose | Shared across updates? |
|---|---|---|---|
| `uboot` (raw, offset 32 KiB, ~14 MiB) | — | `u-boot-rockchip.bin` — unified SPL + FIT (TF-A BL31 + U-Boot) | Frozen after factory flash |
| `uboot_env` (raw, 14 MiB + 128 KiB) | — | U-Boot env (primary + redundant) | Persistent |
| `boot_a` (p1, 30 MiB) | vfat | Kernel + DTB + boot.scr (slot A) | Replaced on OTA targeting A |
| `rootfs_a` (p2, 500 MiB) | ext4 | Rootfs (slot A) | Replaced on OTA targeting A |
| `boot_b` (p3, 30 MiB) | vfat | Kernel + DTB + boot.scr (slot B) | Replaced on OTA targeting B |
| `rootfs_b` (p4, 500 MiB) | ext4 | Rootfs (slot B) | Replaced on OTA targeting B |
| `data` (p5, 512 MiB) | ext4 | `/data` — TTN key, Docker, overlayfs upper | **Preserved across updates** |

**U-Boot environment variables** (used by the rollback state machine):

| Name | Purpose | Typical values |
|---|---|---|
| `boot_slot` | Currently-active slot | `A`, `B` |
| `bootcount` | Incremented automatically each boot by `CONFIG_BOOTCOUNT_LIMIT` | `0`..`bootlimit` |
| `bootlimit` | Trial-boot retry threshold | `3` |
| `upgrade_available` | `1` during a trial boot after SWUpdate stages a new slot | `0`, `1` |
| `altbootcmd` | Rollback script: flip slot if `upgrade_available=1`, reset bootcount, retry | (see `board/linxdot/uboot/env.txt`) |

**Boot sequence (Phase 3+):**
1. BootROM loads the SPL portion of `u-boot-rockchip.bin` from eMMC sector 64 (32 KiB offset).
2. SPL initialises DDR (via rkbin DDR blob) and loads the FIT image from within the same blob at ~8 MiB.
3. TF-A BL31 runs at EL3, then passes control to U-Boot in EL2.
4. U-Boot's compiled bootcmd picks partition 1 or 3 from `${boot_slot}`, loads `boot.scr`.
5. `boot.scr` loads `Image` + `rk3566-linxdot.dtb` from the same partition, sets `root=/dev/mmcblk0p2` or `p4`, `booti`.
6. Kernel → BusyBox init → services.
7. `S60ota` runs early in init.d ordering — *before* the application:
   - Phase 1 (committed slot): `ota-check` synchronously fetches the manifest. If a newer image exists, it downloads, applies via SWUpdate, sets `upgrade_available=1`, flips `boot_slot`, and reboots — phase 2 never runs on this slot.
   - Phase 2 (trial slot, `upgrade_available=1`): forks a background loop that polls `/etc/ota/health-probe` for up to `HEALTH_TIMEOUT` seconds. On exit-0, clears trial flags (`upgrade_available=0`, `bootcount=0`).
   - Phase 1 and 2 are mutually exclusive: a trial boot must not OTA on top of an unconfirmed slot.
8. If boot attempts exceed `bootlimit` without clearing flags, U-Boot runs `altbootcmd` → slot flips, device boots old slot.

## 4. Implementation Phases

### 4.1 Phase 1 — Infrastructure Foundation (complete)

**Scope:** Replace CrankkOS userspace with a clean Buildroot rootfs while keeping the vendor bootloader, kernel, and DTB as binary blobs. Produce a flashable single-slot image.

**Deliverables:**
- Buildroot defconfig with Docker + Basics Station stack.
- Minimal init scripts (S00datapart, S01mountall, S40network, S50sshd, S60dockerd, S80dockercompose).
- CI pipeline that builds, packages, and publishes a `.img.xz` on tag.
- Persistent MAC derived from eMMC CID.

**Exit criteria:** Device flashes via `rkdeveloptool`, boots, obtains DHCP lease, connects to TTN once `TC_KEY` is configured, survives power cycles.

### 4.2 Phase 2 — Kernel from source (planned)

**Scope:** Replace the vendor Linux 5.15.104 binary with an in-tree-built mainline kernel (6.1 LTS or later) with RK3566 support.

**Deliverables:** Buildroot-built kernel with SPI, Ethernet, SDIO WiFi, I2C, USB all functional. Ability to change console baud rate (via DTB `stdout-path`).

**Exit criteria:** Device boots self-built kernel, all peripherals function at parity with Phase 1, Basics Station reaches TTN.

### 4.3 Phase 3 — Bootloader from source (in progress, branch `OTA`)

**Scope:** Replace vendor U-Boot 2017.09 (which lacks writable env and has a `boot.scr` execution bug) with mainline U-Boot 2024.04+ on `quartz64-a-rk3566_defconfig` base, plus an EL3 monitor (BL31) compatible with the vendor 5.15 kernel.

> **BL31 sourcing note (2026-04-23).** We originally scoped TF-A BL31 from source (v2.12.0, PLAT=rk3568). Hardware validation on the Workbench LD1001 proved that the vendor 5.15 kernel hangs silently after `Starting kernel ...` on that BL31 — consistent with the kernel calling Rockchip-vendor SIP SMCs that upstream TF-A v2.12.0 does not implement. Phase 3 therefore uses rkbin's prebuilt `rk3568_bl31_v1.43.elf` (the canonical version referenced by rkbin's own `RKTRUST/RK3568TRUST.ini`). The TF-A source build is kept enabled because `BR2_TARGET_UBOOT_NEEDS_ATF_BL31` force-selects it, but its output is unused — U-Boot's make opts link rkbin's BL31 instead. This will be revisited when Phase 2 (mainline kernel) lands and vendor SMCs are no longer required. See Constants (§13.1).

**Deliverables:**
- `BR2_TARGET_UBOOT` + `BR2_TARGET_ARM_TRUSTED_FIRMWARE` + `BR2_PACKAGE_ROCKCHIP_RKBIN` enabled in defconfig.
- `board/linxdot/uboot/linxdot.fragment` with OTA-specific U-Boot config (1.5 Mbaud, env in MMC at 0xE00000, `CONFIG_BOOTCOUNT_LIMIT`, slot-aware bootcmd).
- `board/linxdot/uboot/env.txt` default env with `altbootcmd`.
- `board/linxdot/boot.cmd` compiled to `boot.scr`.
- `genimage.cfg` updated to GPT + A/B layout.

**Exit criteria:** Device boots from built U-Boot; deliberately-broken slot triggers `altbootcmd` rollback automatically; `fw_setenv` / `fw_printenv` work from userspace.

### 4.4 Phase 4 — OTA update layer (in progress, branch `OTA`)

**Scope:** Layer SWUpdate + signed `.swu` bundles + boot-time polling of GitHub Releases on top of Phase 3.

**Deliverables:**
- SWUpdate enabled with signature verification against `/etc/swupdate/public.pem`.
- `sw-description` template declaring `target-A` / `target-B` selections (writes to the inactive slot, sets `boot_slot` + `upgrade_available=1`).
- `/usr/sbin/ota-check` CLI: fetch manifest, compare version, download `.swu`, invoke SWUpdate, reboot. Supports `--dry-run` (manifest reachability check only, used by the default health probe).
- `S60ota` boot-time hook — single script, two mutually-exclusive phases (acquire on committed slots; commit on trial slots, backgrounded so init can continue to the application).
- `/etc/ota/health-probe` — swappable application-defined probe (exit-code contract). Default ships with the OTA layer; application packages overwrite it.
- CI extensions: produce signed `.swu`, emit `manifest.json` with `{ version, url, sha256, size }`, upload alongside factory image.

**Exit criteria:** Tagged release on GitHub is picked up by a deployed device within one boot cycle; healthy update commits, broken update rolls back without human intervention.

### 4.5 Phase 5 — Curated in-tree DTS (planned)

**Scope:** Replace vendor `rk3566-linxdot.dtb` with an in-tree DTS the community can audit and modify. Enables full bootarg control and removes the last vendor binary.

**Exit criteria:** All peripherals functional from in-tree DTS, no vendor DTB required.

### 4.6 Phase 6 — SX1302 hardware bring-up (in progress, branch `test`)

**Scope:** Layer minimal LoRa-concentrator hardware enablement on top of the OTA-only base, *without* re-introducing Docker / basicstation. Two scripts and one init hook prove the chip is electrically alive and answering SPI before any application is added at S70+.

**Deliverables:**
- `BR2_PACKAGE_SPI_TOOLS=y` in defconfig (provides `spi-pipe` for `/dev/spidev0.0` transactions; ~50 KB on target).
- `/usr/sbin/sx1302-reset` — single script that owns the entire bring-up. The chip-readiness check is **part of the reset procedure**, not a separate diagnostic, because that's where it conceptually belongs: a "reset" that doesn't verify the chip came back is a reset that lies. Sequence:
  1. **Power rails**: drop POWER (gpio 23) + EXTRA (gpio 17) to 0, settle, raise to 1.
  2. **Reset pulse**: drive RESET (gpio 15) high, settle, drive low (release).
  3. **L1 chip ID**: read VERSION register `0x5610`, expect `0x10`.
  4. **L2 register sweep**: read 6 addresses, require ≥2 distinct values (rules out stuck-bus failures where every read returns the same byte).
  5. **L3 write/readback**: write a flipped pattern to GPIO_DIR (`0x4203`, harmless), read back, restore. Rules out "read-only zombie" failures where the chip echoes hardcoded values but internal state can't be mutated.
  
  Exit 0 only if all five steps pass.
- `/etc/init.d/S30sx1302` — calls `sx1302-reset` before `S40network` so the chip is operational by the time userspace is up. Always exits 0 — a dead chip must not block OTA, since OTA is what ships the fix.

**Exit criteria:** On a clean boot, `S30sx1302` logs `OK SX1302 fully operational (power + reset + chip ID + sweep + write/readback)` via `logger -t sx1302`; manual re-runs of `/usr/sbin/sx1302-reset` exit 0; `cat /sys/class/gpio/gpio23/value` returns `1` post-boot.

## 5. Functional Requirements

### 5.1 Functional Requirements (FR)

#### Gateway function
- **FR-1.1** [Must]: The system shall run exactly one Basics Station container configured for SX1302 on SPI at `/dev/spidev0.0`.
- **FR-1.2** [Must]: The system shall read the LoRaWAN gateway EUI from the SX1302 concentrator chip (not from `eth0`).
- **FR-1.3** [Must]: The system shall connect to a TTN cluster via WebSocket+TLS using the Basics Station LNS protocol.
- **FR-1.4** [Must]: The system shall use the TC (Thing Configuration) key from `/data/basicstation/tc_key.txt` to authenticate with TTN.
- **FR-1.5** [Should]: The system shall support at minimum the TTN regions `eu1`, `nam1`, `au1` by setting `TTS_REGION` in `/data/basicstation/region.env` (interpolated into the rootfs `docker-compose.yml`).

#### Provisioning & configuration
- **FR-2.1** [Must]: On first boot the system shall create `/data/basicstation/tc_key.txt` as a placeholder template until the operator populates it.
- **FR-2.2** [Must]: The system shall determine `eth0`'s MAC by trying, in priority order: (1) a per-unit record at sector 0 of `/dev/mmcblk1boot0` (typically the device's case-printed MAC, written once via `linxdot-setup` or `set-eth-mac` — see § 8.3 *After first boot*); (2) an admin override at `/data/eth0_mac`; (3) the shared setup-fallback MAC `02:00:5d:01:01:01`. The boot0 record lives in the eMMC's hardware boot partition, outside the GPT, so it survives both OTA updates and `rkdeveloptool wl 0 image.img` factory re-flashes. The setup-fallback MAC is intentionally non-unique so operators have a known address to look for in their router's DHCP table on a freshly-flashed device; binding the case MAC via the wizard is the first provisioning step.
- **FR-2.3** [Must]: The system shall obtain an IPv4 address via DHCP on `eth0`.
- **FR-2.4** [Should]: The system shall synchronise time via NTP before TLS connections are attempted.
- **FR-2.5** [Must]: Before any TLS-validating service runs (basicstation's WSS to TTN, `ota-check`'s HTTPS fetch from GitHub) the system shall step the wall-clock to a sane value via NTP. The step is performed by `/usr/sbin/clock-bootstrap` (idempotent: no-op if `date +%Y >= 2024`, otherwise runs `ntpd -gq <server>` against `pool.ntp.org` / `time.cloudflare.com` / `time.google.com` with a 30 s per-server watchdog). At boot it is invoked from `S49ntp` *before* the long-running disciplining `ntpd` binds udp/123 (only one ntpd can hold the port; the helper detects a running ntpd at runtime and stops/restarts it around its own step). `ota-check` calls it defensively for ad-hoc runs. This is required because the LD1001 has no battery-backed RTC (constraint C-7). `S49ntp` also drops a 0-byte `/data/overlay/etc/upper/ntp.conf` if present — the empty placeholder shipped by the Buildroot ntp package can persist in the writable overlay and silently mask the rootfs config.

#### Over-the-Air updates (Phase 4)
- **FR-3.1** [Must]: The system shall poll `https://github.com/SensorsIot/Linxdot-Hotspot/releases/latest/download/manifest.json` synchronously during boot (`S60ota` phase 1, before the application starts) and compare the `version` field against `/etc/os-release VERSION_ID`. Polling is once per boot only; there is no periodic poll. Acquisition is skipped on a trial boot (`upgrade_available=1`) to prevent OTA-on-OTA stacking.
- **FR-3.2** [Must]: The operator shall be able to trigger an update check manually via `ssh root@<device> ota-check` without rebooting.
- **FR-3.3** [Must]: When a newer version is available the system shall download the `.swu` bundle, verify its sha256 against the manifest, and apply it to the currently-inactive A/B slot via SWUpdate.
- **FR-3.4** [Must]: After staging an update the system shall set `boot_slot=<inactive>`, `upgrade_available=1`, `bootcount=0` in the U-Boot environment and reboot.
- **FR-3.5** [Must]: If `/etc/swupdate/public.pem` is present the system shall refuse to apply `.swu` bundles whose `sw-description` signature does not verify against it.
- **FR-3.6** [Must]: Before staging a new update the system shall verify `upgrade_available=0` (current slot committed); if still `1`, `ota-check` shall refuse to run.
- **FR-3.7** [Should]: `ota-check` shall log all actions and errors to `logger -t ota` (syslog).

#### Rollback (Phase 4)
- **FR-4.1** [Must]: On a trial boot (`upgrade_available=1`), `S60ota` phase 2 shall poll `/etc/ota/health-probe` every 5 s for up to `HEALTH_TIMEOUT` seconds (default 300). On the first exit-0 it commits the slot. The probe is a swappable executable owned by the application package — the OTA layer never imports application logic. The default probe shipped with the OTA-only base honors a `HEALTH_CHECK` selector in `/etc/default/ota` (overridable via `/data/ota.conf`) with values `full` (route + clock-bootstrap + manifest reachability), `network` (route + clock only), `always` (instant pass), `never` (instant fail — for rollback drills).
- **FR-4.2** [Must]: Commit shall consist of `fw_setenv upgrade_available 0 && fw_setenv bootcount 0`.
- **FR-4.3** [Must]: U-Boot shall increment `bootcount` on every boot (`CONFIG_BOOTCOUNT_LIMIT`).
- **FR-4.4** [Must]: U-Boot shall execute `altbootcmd` when `bootcount > bootlimit`.
- **FR-4.5** [Must]: `altbootcmd` shall flip `boot_slot` **only** when `upgrade_available=1`; when `upgrade_available=0` it shall reset `bootcount` and retry the current slot (preventing spurious rollback on a healthy slot).
- **FR-4.6** [Must]: After `altbootcmd` fires, the old slot shall boot without further operator intervention.

#### Remote operation
- **FR-5.1** [Must]: The system shall run Dropbear SSH on port 22 with `root` / `linxdot` credentials (operator is expected to change the password on first access).
- **FR-5.2** [Should]: Dropbear host keys shall persist across reboots via the `/etc` overlay on `/data`.
- **FR-5.3** [Should]: The physical serial console shall be accessible remotely via the Workbench Pi at `rfc2217://192.168.0.87:4003` at 1.5 Mbaud.

#### Diagnostics
- **FR-6.1** [Should]: The system shall expose Docker logs via `docker logs basicstation` for operator diagnosis of TTN connectivity.
- **FR-6.2** [Should]: `/etc/init.d/S80dockercompose status` shall report TC key configuration, reset script status, and container state.

### 5.2 Non-Functional Requirements (NFR)

- **NFR-1.1** [Must]: A successful OTA update (download, apply, commit) shall complete in under 5 minutes on a typical home broadband connection.
- **NFR-1.2** [Must]: A failed trial boot shall roll back to the prior slot without any operator action.
- **NFR-1.3** [Must]: The root filesystem shall be mounted read-only; all persistent writes shall be confined to `/data`.
- **NFR-2.1** [Must]: OTA bundles shall be cryptographically signed (RSA-4096) in production deployments.
- **NFR-2.2** [Must]: The system shall not embed signing private keys in the rootfs.
- **NFR-2.3** [Should]: The system shall not expose any unauthenticated network service other than SSH and the Basics Station outbound WebSocket.
- **NFR-3.1** [Should]: Boot to "Basics Station connected to TTN" shall complete in under 2 minutes on warm boot.
- **NFR-4.1** [Should]: The build system shall be fully reproducible from the `BR2_EXTERNAL` tree plus a pinned Buildroot LTS version.
- **NFR-4.2** [Should]: Reproducibility: Phase 3+ builds all security-critical components (U-Boot, TF-A, BL31) from source with pinned versions. The Rockchip DDR TPL blob is the only proprietary component and cannot be replaced on RK356x.

### 5.3 Constraints

- **C-1** The RK3566 BootROM expects the SPL (idbloader) at eMMC sector 64 (32 KiB) and the FIT image (U-Boot + BL31) at sector 16384 (8 MiB). These offsets are fixed by silicon. Phase 3+ writes a single unified `u-boot-rockchip.bin` at offset 32 KiB whose internal layout places both sub-parts at the required absolute offsets.
- **C-2** The vendor DTB (`rk3566-linxdot.dtb`) declares `stdout-path = "serial2:1500000n8"`; while this DTB is used, console must remain at 1.5 Mbaud. Phase 5 (in-tree DTS) lifts this constraint.
- **C-3** A Rockchip DDR init blob from rkbin (`rk3568_ddr_*_v1.xx.bin`) is unavoidable on RK356x — fully FOSS boot is not possible.
- **C-4** The bootloader blob (`u-boot-rockchip.bin`, covering SPL + FIT with BL31 + U-Boot) is **not** updated by OTA. It remains as first written at factory-flash time. Updating it would require a new factory image and `rkdeveloptool`. This is intentional: there is no redundant bootloader slot, so a bad bootloader write would brick the device.
- **C-5** Devices flashed with the pre-A/B (Phase 1) image cannot receive OTA updates. A one-time `rkdeveloptool` reflash with the A/B image is required to migrate. `/data` is recreated on reflash; `tc_key.txt` must be backed up beforehand.
- **C-6** WiFi firmware (`firmware/brcm/`) is not distributable under the Broadcom licence and must be extracted from a CrankkOS image locally before building a WiFi-capable variant.
- **C-7** The LD1001 has no battery-backed RTC. On every power loss the kernel clock resets to a stale value (observed: `2017-08-05`). Until the clock is stepped to a sane value, every service that does TLS server-cert validation (`basicstation`'s WSS to TTN, `ota-check`'s HTTPS fetch from GitHub) fails with "certificate is not yet valid". The bootstrap is `/usr/sbin/clock-bootstrap` — an idempotent helper that runs `ntpd -gq <server>` (`-g` lets the first adjust exceed the panic threshold). It is invoked from a custom `S49ntp` *before* the disciplining `ntpd` binds udp/123 (only one ntpd at a time — the helper also stops/restarts the disciplining daemon if a runtime caller like `ota-check` finds it already up). The custom `S49ntp` additionally drops a 0-byte upper-layer `/etc/ntp.conf` from `/data/overlay/etc/upper/`, which would otherwise mask the rootfs's pool config and leave the disciplining ntpd useless.

## 6. Risks, Assumptions & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Mainline U-Boot lacks a Linxdot-specific peripheral quirk | Medium | High | Start from `quartz64-a-rk3566_defconfig`, iterate; keep vendor U-Boot blob as fallback until Phase 3 validated on hardware. |
| OTA bundle signature mismatch bricks all deployed devices after key rotation | Low | High | Ship new public key in firmware image *before* rotating the private key; rotation procedure documented in § 8.5. |
| Partial `.swu` download corrupts slot | Low | Low | SWUpdate verifies sha256 of each image before committing; `upgrade_available` is not set on failed download. |
| `S60ota` phase-2 health-probe false-negative (slow application start, transient network) | Medium | Medium | `HEALTH_TIMEOUT=300 s` default; tunable per-device via `/data/ota.conf`. Worst-case outcome is a rollback to the prior known-good slot, which is recoverable. Application packages can ship their own `/etc/ota/health-probe` with tighter or looser checks as needed. |
| Private signing key leaks | Low | High | Key stored only in GitHub Actions secret (`OTA_SIGNING_KEY`). Rotation procedure in § 8.5. Devices only trust the baked-in public key. |
| `host-tools.tar.gz` bundles runner libc via unfiltered `ldd` (base-build job) and the release job `sudo cp`s it into `/usr/local/lib/` + runs `ldconfig` | High (already observed 2026-04-23) | High | genimage's only non-system dep is `libconfuse2`; filter `ldd` to non-system libs **or** drop the bundle and `apt-get install libconfuse2` on the release runner. Never replay the release install step inside the devcontainer — Debian trixie's `/bin/sh` will SIGFPE against an Ubuntu 22.04 libc (`GLIBC_2.38 not found`). See § 8.2. |
| EL3 is now a Rockchip vendor binary (`rk3568_bl31_v1.43.elf` from rkbin) instead of TF-A v2.12.0 built from source | Medium | Medium | Accepted for Phase 3 to unblock vendor 5.15 kernel (see §4.3). Pin the exact rkbin file path in defconfig + Buildroot snapshot. No CVE response channel; mitigation is to revisit once Phase 2 (mainline kernel) removes the dependency on Rockchip-vendor SIP SMCs and source TF-A can be re-adopted. |

**Assumptions:**
- The LD1001 BootROM is shipped **non-secure** (evidence: vendor SPL prints `## Verified-boot: 0`, accepts unsigned custom `-dirty` build). This has been spot-checked on one unit; operators should confirm on their own hardware before first flash.
- Ethernet is always available for OTA. Cellular-only deployments are out of scope.
- The device clock is reasonably accurate after NTP sync; signature verification does not depend on strict time checks in SWUpdate's default config.

**Dependencies:**
- Buildroot 2024.02 LTS.
- U-Boot 2024.04 (or later) upstream support for RK3566.
- TF-A upstream support for RK3568 (used as `PLAT` for RK3566).
- Rockchip rkbin DDR TPL blob (`rk3568_ddr_1560MHz_v1.18.bin`).
- GitHub Releases as the OTA artifact hosting endpoint.
- Docker image `xoseperez/basicstation` (upstream).
- TTN (The Things Network) as the LNS.

## 7. Interface Specifications

### 7.1 External Interfaces

| Interface | Direction | Protocol | Endpoint |
|---|---|---|---|
| TTN LNS | Outbound | Basics Station over WebSocket+TLS | `wss://<cluster>.cloud.thethings.network` |
| TTN Identity Server (provisioning, used by `linxdot-setup`) | Outbound | HTTPS REST + Bearer auth | `https://<cluster>.cloud.thethings.network/api/v3/{auth_info,users/<u>/gateways,gateways/<id>/api-keys}` |
| OTA manifest poll | Outbound | HTTPS GET | `https://github.com/SensorsIot/Linxdot-Hotspot/releases/latest/download/manifest.json` |
| OTA bundle download | Outbound | HTTPS GET | URL from manifest `url` field |
| SSH | Inbound | SSH (Dropbear) | TCP 22 |
| Serial console | Bidirectional | UART (8N1, 1.5 Mbaud) | ttyS2 @ 3.5 mm TRRS jack, also `rfc2217://192.168.0.87:4003` via Workbench |
| Device provisioning (flashing) | Inbound | Rockchip USB (rkusb) | USB-C on device, Loader or Maskrom mode |

### 7.2 Internal Interfaces

- **U-Boot ↔ Linux**: `/etc/fw_env.config` tells `libubootenv` where the env partition lives (`/dev/mmcblk0` @ `0xE00000`, 64 KiB, redundant at `0xE10000`). Must match `CONFIG_ENV_OFFSET` / `CONFIG_ENV_SIZE` / `CONFIG_ENV_OFFSET_REDUND` in `board/linxdot/uboot/linxdot.fragment`.
- **OTA agent ↔ SWUpdate**: `ota-check` invokes `swupdate -i update.swu -e stable,linxdot-ld1001,target-<B|A>`.
- **SWUpdate ↔ U-Boot env**: via `libubootenv`'s bootloader handler to set `boot_slot`, `upgrade_available`, `bootcount`.
- **Basics Station ↔ SX1302**: SPI on `/dev/spidev0.0` (via Docker device passthrough).
- **Docker ↔ persistent storage**: `/data/docker` (data-root), not `/var/lib/docker`.

### 7.3 Data Models / Schemas

**`manifest.json`** (published with each Release):
```json
{
  "version": "1.2.3",
  "url": "https://github.com/SensorsIot/Linxdot-Hotspot/releases/download/v1.2.3/linxdot-basics-station-1.2.3.swu",
  "sha256": "abc123..."
}
```

**`sw-description`** (libconfig syntax, first entry of every `.swu` CPIO archive) declares two selections:
- `target-B`: writes `rootfs.ext4` → `/dev/mmcblk0p4`, `boot.vfat` → `/dev/mmcblk0p3`, sets `boot_slot=B`.
- `target-A`: writes `rootfs.ext4` → `/dev/mmcblk0p2`, `boot.vfat` → `/dev/mmcblk0p1`, sets `boot_slot=A`.

Template at `board/linxdot/swupdate/sw-description.tmpl` with `@VERSION@`, `@SHA_ROOTFS@`, `@SHA_BOOT@` placeholders substituted at CI packaging time.

**`/etc/os-release`** (generated by `post-build.sh`):
```
NAME="OpenLinxdot"
ID=openlinxdot
PRETTY_NAME="OpenLinxdot <VERSION>"
VERSION="<VERSION>"
VERSION_ID=<VERSION>
```
`VERSION` is set to `${GITHUB_REF_NAME#v}` by CI (e.g. `1.2.3` for tag `v1.2.3`), or `dev` for local builds.

**`/dev/mmcblk1boot0` — per-unit MAC record** (sector 0, 32 bytes, written by `set-eth-mac`):

| Offset | Size | Field    | Contents                                          |
|--------|------|----------|---------------------------------------------------|
| 0      | 8    | magic    | ASCII `"OLNXMAC1"` (`4f 4c 4e 58 4d 41 43 31`)    |
| 8      | 6    | mac      | Raw MAC bytes; byte 0 must have unicast bit clear |
| 14     | 18   | reserved | Zero (room for future fields, e.g. CRC)           |

`S40network` accepts the record only if the magic matches exactly, the MAC is neither all-zero nor all-FF, and byte 0 is unicast — otherwise it falls through to the next tier of FR-2.2. The eMMC's hardware boot partition lives outside the GPT, so this record is preserved across SWUpdate (which only writes the partitions in `sw-description`) and across `rkdeveloptool wl 0 image.img` factory re-flashes (which write the user data area, not the HW boot partitions). Operators run `linxdot-setup` (or `set-eth-mac` directly) once per device, typically with the MAC printed on the case sticker (see § 8.3 *After first boot*).

**`/data/.setup-state`** (one-line ASCII, written by `linxdot-setup`):

| Value             | Meaning                                                              |
|-------------------|----------------------------------------------------------------------|
| (file absent)     | Fresh device — wizard runs Phase A (bind case MAC)                   |
| `mac-bound`       | Phase A complete — wizard runs Phase B (TTN registration + key)      |
| `setup-complete`  | Both phases done — wizard prints status only                         |

The state file lives on `/data` so it survives OTA and rollback. Removing it forces the wizard back to Phase A.

## 8. Operational Procedures

### 8.1 Build

```
cd buildroot   # Buildroot 2024.02.8 extracted here
make BR2_EXTERNAL=$(pwd)/.. linxdot_ld1001_defconfig
make -j$(nproc)
# Output: output/images/linxdot-basics-station.img
```

First build takes ~1 hour (downloads toolchain, all source tarballs). Subsequent builds use ccache and `buildroot/dl/` cache.

### 8.2 Release (maintainer)

1. `git tag v1.2.3 && git push --tags`.
2. CI pipeline (see `.github/workflows/build.yml`):
   - Validate: shell syntax, OTA static tests (`tests/test_consistency.sh`, `tests/test_ota_state_machine.sh`).
   - `detect-changes`: compare hash of base-affecting files against stored hash from `base-latest` release.
   - `base-build` (only if changed, ~1 h): full Buildroot rebuild → uploads `rootfs.tar.xz` + `host-tools.tar.gz` to `base-latest` prerelease.
   - `release` (~3 min): download cached base, apply overlay, run `post-build.sh` + `post-image.sh`, validate image, build signed `.swu` if `OTA_SIGNING_KEY` secret is set, emit `manifest.json`, upload `.img.xz` + `.swu` + `manifest.json` to the tagged release.

> **Do NOT replay the `release` job's "Install host tools" step locally (especially inside the devcontainer).** `host-tools.tar.gz` is currently built with an unfiltered `ldd` loop (`.github/workflows/build.yml` Bundle host tools step) that includes `libc.so.6` and `ld-linux-x86-64.so.2` from the Ubuntu 22.04 runner. The release job then `sudo cp`s them into `/usr/local/lib/` and runs `ldconfig`, which fatally downgrades the libc seen by `/bin/sh` on any newer distro (symptom: `Floating point exception` + `GLIBC_2.38 not found`, container fails to start). `genimage`'s only non-apt dependency is `libconfuse2` — install that instead. This CI behaviour is tracked in the risk table (§6).

### 8.3 First-time flashing

Option A — normal (requires one-time case-open):
1. Download `linxdot-basics-station.img.xz` from GitHub Releases.
2. `xz -d linxdot-basics-station.img.xz`.
3. Put device in Loader mode: hold **BT-Pair** button (near antenna connector) while connecting power; hold 5 s.
4. `sudo rkdeveloptool ld` → should show `DevNo=1 Vid=0x2207,Pid=0x350a,...Loader`.
5. `sudo rkdeveloptool wl 0 linxdot-basics-station.img && sudo rkdeveloptool rd`.

Option B — remote (if a USB cable is routed to a host running `rkdeveloptool`, e.g. the Workbench Pi):
1. Over serial, reboot and interrupt U-Boot autoboot with Ctrl-C.
2. At the `=>` prompt: `rockusb 0 mmc 0` (or `download`).
3. Host sees the device; `rkdeveloptool ld` confirms; proceed with `wl 0 ...`.

This avoids repeat case-opens for Phase 3 → Phase 4 upgrade flashing.

**After first boot — bind the case MAC** (one-time per device):

A fresh device boots with the shared setup-fallback MAC `02:00:5d:01:01:01` (FR-2.2 tier 3). Find that MAC in the router's DHCP table to get its IP, then SSH in and run the wizard:

```
ssh root@<device-ip>
linxdot-setup        # wizard prompts for the case MAC and confirms
```

The wizard validates the input, calls `set-eth-mac` to write a 32-byte record (format in § 7.3) to sector 0 of `/dev/mmcblk1boot0`, then offers to reboot. On every subsequent boot `S40network` reads the record and assigns the case MAC to `eth0` before DHCP starts. The eMMC's hardware boot partition lives outside the GPT, so the record survives both OTA updates and any future `rkdeveloptool` re-flash — bind once, never again. The MAC printed on each device's case is from FX Technology's IEEE-allocated MA-M block (OUI prefix `0c:86:29:e0:_:_`/`0c:86:29:e1:_:_` etc.) and is the unit's globally-unique identity. Skipping the wizard is harmless for TTN traffic (the gateway EUI is what matters, FR-1.2) but the device will keep announcing the shared setup-fallback MAC.

Caveats:
- Changing `eth0`'s MAC bounces the interface, so the device's DHCP lease is renewed (likely a new IP). Re-discover via the router's DHCP table.
- Because the setup-fallback MAC is the same on every fresh device, **only provision one device at a time** on a given LAN — two simultaneously fresh devices will collide on DHCP. Bind the case MAC of the first before plugging in the next.

The non-interactive equivalent (for scripted provisioning) is `set-eth-mac aa:bb:cc:dd:ee:ff`, which the wizard wraps.

**After the case-MAC reboot — register on TTN** (Phase B, one-time per device):

After Phase A reboots the device, find it again in the router's DHCP table under the case MAC, SSH back in, and re-run the wizard. It detects `state=mac-bound` from `/data/.setup-state` and runs Phase B:

```
ssh root@<new-device-ip>
linxdot-setup
```

Phase B drives a REST conversation with the chosen TTN cluster's identity server. Inputs (gateway name + frequency plan are only prompted when registering a brand-new gateway — see step 3 below):

| Prompt | Default |
|---|---|
| Cluster | `eu1` (or `nam1` / `au1` / `as1`) |
| User / org ID | the operator's TTN handle |
| User or organization | `u` (most common) |
| Admin API key | operator pastes any blob containing `NNSXS.<token>` — wizard extracts via `grep -oE 'NNSXS\.[A-Z0-9.]+'` |
| Gateway name *(new only)* | `linxdot-<lower-eui>` (operator may override) |
| Frequency plan *(new only)* | per-cluster default (`EU_863_870` for `eu1`, `US_902_928_FSB_2` for `nam1`, etc.) |

The admin API key needs the **Manage gateways** right (or at minimum `RIGHT_USER_GATEWAYS_CREATE` plus `RIGHT_GATEWAY_SETTINGS_API_KEYS` on the new gateway). It is held only in memory during the wizard run — never written to disk. The wizard:

1. Bootstraps basicstation with a placeholder LNS key so it prints the Gateway EUI from the SX1302 chip; the wizard scrapes that from the container logs.
2. Calls `GET /api/v3/auth_info` to verify the API key works against the chosen cluster, parses the rights array, and reports an actionable error if the create-gateway right is missing. **Recoverable errors loop**: instead of aborting, the wizard prints the "What to do" block and waits for the operator to fix the issue (typo, missing right, stale clock, network blip) and press Enter to retry.
3. `GET /api/v3/<owner_path>/gateways?field_mask=ids&limit=1000` to find any gateway already registered with the device's EUI under the same owner. If a match is found, the wizard skips the gateway-name + frequency-plan prompts and adopts that `gateway_id`. The list call also doubles as the owner-validation step (404 → typo, 401/403 → missing list right).
4. If no match: `POST /api/v3/users/<owner>/gateways` (or `/organizations/<owner>/gateways`) registers the gateway with the prompted name, EUI, frequency plan, and `enforce_duty_cycle=true`. On 409 (cross-tenant — owner couldn't list it but TTN has it) the wizard parses TTN's `details[].attributes.gateway_id` to find the existing gateway, GETs it, and either silently reuses or falls back to a manual LNS-key paste with a direct console URL.
5. `POST /api/v3/gateways/<gid>/api-keys` with `RIGHT_GATEWAY_LINK` to mint a fresh LNS key, extracts the `NNSXS.…` value from the response.
6. Writes `TTS_REGION=<cluster>` to `/data/basicstation/region.env`. The rootfs `docker-compose.yml` resolves `${TTS_REGION:-eu1}` from this env file (loaded by `S80dockercompose`), so the operator's region choice rides through OTA without freezing a whole compose-file snapshot on `/data`.
7. Writes the LNS key to `/data/basicstation/tc_key.txt` (mode 600), restarts basicstation via `S80dockercompose restart`, polls Docker logs for `Connected to MUXS` (timeout 60 s). The handshake step also loops on failure — the operator can fix clock / region / firewall in another shell and press Enter to retry.
8. Writes `setup-complete` to `/data/.setup-state`. Re-running the wizard at this point prints status only (TC key present, basicstation running, TTN connected) without re-prompting.

JSON parsing is awk/sed/`tr`-based; no `jq` dependency. `curl` is the only network tool used.

Caveat for retests: TTN community cluster only allows users to soft-delete gateways (purge requires admin rights), and the EUI stays held by the soft-deleted entry for the cluster's restore window (typically 7 days). Don't delete a gateway just to re-register the same EUI — re-run the wizard with the same `gateway_id` and the EUI-list pre-check (step 3) will reuse the existing TTN registration.

### 8.4 Migration from pre-A/B (Phase 1 → Phase 3+)

Single-slot Phase 1 devices **cannot** receive OTA. One-time reflash required:

1. `ssh root@<device>` and back up `/data/basicstation/tc_key.txt` (and `/data/basicstation/region.env` if present).
2. Follow § 8.3 with the first A/B-layout release image.
3. Re-populate `/data/basicstation/tc_key.txt` with the saved key.
4. All subsequent updates arrive via OTA — no further case-opens.

### 8.5 OTA signing key lifecycle

**Initial setup (one time, by maintainer):**
```
sh scripts/gen-signing-key.sh
gh secret set OTA_SIGNING_KEY < ota-signing.key
mkdir -p board/linxdot/overlay/etc/swupdate
cp ota-signing.pub board/linxdot/overlay/etc/swupdate/public.pem
git add board/linxdot/overlay/etc/swupdate/public.pem
git commit -m "ota: add signing public key"
shred -u ota-signing.key
```

**Rotation:** generate a new pair, commit the *new* public key, release firmware containing the new key, wait for all devices to upgrade, then replace the GitHub secret with the new private key. Signing the first release after rotation with the old key (still committed as a backup) ensures devices that haven't upgraded yet can still receive the transition build.

**Key compromise:** devices only trust the key baked into their rootfs. A leaked private key cannot be used to attack already-deployed devices unless they are also reflashed.

### 8.6 Manual OTA trigger

```
ssh root@<device> ota-check
```

Same logic as boot-time `S60ota` phase 1 — no reboot required. Refuses to run if `upgrade_available=1` (current slot not yet committed). `ota-check --dry-run` is also accepted; it stops after manifest fetch+parse and is what the default health probe uses to validate the OTA path during phase 2.

### 8.7 Region change

```
ssh root@<device>
echo TTS_REGION=nam1 > /data/basicstation/region.env   # eu1 / nam1 / au1 / as1
/etc/init.d/S80dockercompose restart
```

A pre-v1.0.7 device with `/data/docker-compose.yml` still in place is migrated automatically on the first v1.0.7 boot: `S80dockercompose.migrate_region_override` extracts `TTS_REGION`, writes `region.env`, and renames the override to `/data/docker-compose.yml.pre-v1.0.7.bak`. This also clears the pre-v1.0.7 `STATION_RADIOINIT` setting that races against `S80dockercompose`'s host-side reset and intermittently leaves the SX1302 in reset (`Failed to set SX1250_0 in STANDBY_RC mode` on basicstation startup).

### 8.8 Recovery procedures

| Situation | Action |
|---|---|
| Device boots old slot unexpectedly | Check `fw_printenv boot_slot bootcount upgrade_available`. If `boot_slot` differs from last known + logs show OTA attempt, rollback fired — diagnose via `logger -t ota` entries. |
| `upgrade_available=1` stuck after the application is healthy | `/etc/ota/health-probe` returned non-zero or `S60ota` phase 2 was killed before it ran. Diagnose: `cat /etc/ota/health-probe; /etc/ota/health-probe; echo $?`. If the probe exits 0 manually, force a commit: `fw_setenv upgrade_available 0; fw_setenv bootcount 0`. |
| Neither slot boots | U-Boot recovery. If U-Boot is healthy, interrupt with Ctrl-C at serial, `rockusb 0 mmc 0`, reflash via `rkdeveloptool`. |
| Corrupt U-Boot env | Env is redundant (primary + backup). If both corrupted, default env is used (device still boots slot A but lacks rollback state). `fw_setenv` writes fresh values on next boot. |
| `rkdeveloptool` needed but case is sealed | Enter download mode from serial: Ctrl-C to U-Boot, `rockusb 0 mmc 0` (requires pre-routed USB cable per § 8.3 Option B). |

## 9. Developer Guide — Making Changes OTA-Compatible

This chapter is for contributors changing the firmware. The goal is concrete: tell you, before you open a PR, what survives an OTA update on a deployed device, what gets replaced, what is frozen forever, and where each kind of change must live to be delivered safely. The deeper rationale for each rule lives in the corresponding requirement (§ 5), constraint (§ 5.3), risk (§ 6), or session-6 learning (§ 12.2) — this chapter cross-references rather than duplicates.

### 9.1 The OTA contract — what changes vs. what's frozen

Three buckets, one source of truth. Every file you touch falls into exactly one of them; commit-time decisions are easier when you know which.

| Bucket | What's in it | OTA behaviour |
|---|---|---|
| **A/B-replaced** | Kernel `Image`, DTB, modules, all of `/usr`, the rootfs overlay (`/etc`, `/lib`, `/sbin`, `/bin` defaults), shipped configs, init scripts, `ota-check`, `S60ota`, `/etc/ota/health-probe`, SWUpdate's `swupdate.config` baked into the binary, `sw-description.tmpl`, `os-release`. | Written to the inactive A/B slot on every successful OTA, swapped in at the next boot. **The unit of OTA delivery.** |
| **Persistent** | `/data` (partition 5): TTN key, Docker images & metadata, `/data/overlay/{usr,etc,var_lib}/upper` (overlayfs writes), user-supplied `/data/docker-compose.yml`, anything else under `/data`. | Untouched by SWUpdate. Survives every update *and* every rollback. |
| **Frozen at factory flash** | `u-boot-rockchip.bin` (idbloader + SPL + FIT + BL31 + U-Boot proper), the U-Boot env *defaults* compiled into the binary, the partition layout (`genimage.cfg` regions and offsets), the env-partition offsets in `linxdot.fragment`. | Never updated by OTA. Changing any of them in the source tree means every deployed device needs a one-time `rkdeveloptool` reflash to receive the change (constraint **C-4**). |

The corollary is simple: **if your change must reach already-deployed devices without a truck roll, it must end up in the A/B-replaced bucket.** Everything else is one-shot at factory time.

### 9.2 Where to put what — a decision table

| Goal | File location | OTA behaviour |
|---|---|---|
| Default config file (every device gets this baseline) | `board/linxdot/overlay/<path>` | Replaced on every OTA — your default ships in the new rootfs. |
| Operator-customizable config | Document a `/data/<...>` override + a bind-mount or symlink in the init script (see `S01mountall`'s `/data/docker-compose.yml` pattern) | Operator's override survives OTA; firmware default is always the latest from the rootfs. |
| New init script | `board/linxdot/overlay/etc/init.d/S##name` | Replaced on every OTA. Keep `S##` numbering ordered around existing scripts (boot order matters: `S00datapart` → `S01mountall` → `S40network` → `S49ntp` → `S50sshd` → `S60ota` → application services at `S70+`). The OTA layer must run before the application so a broken application image cannot block OTA acquisition; the application's own probe (`/etc/ota/health-probe`) gates the slot commit in phase 2. |
| New userspace tool / agent | `board/linxdot/overlay/usr/sbin/<name>`, or a Buildroot package under `package/<name>/` | Replaced on every OTA. |
| Persistent application state | `/data/<your-app>/` — write at runtime, document the path | Survives OTA. **Never use `/var`, `/etc`, `/root`, `/home` as a "persistent" location** — see § 9.3. |
| New kernel module (Phase 1–4) | Add prebuilt under `board/linxdot/modules/<kernel-version>/` (LFS-tracked) | Replaced on every OTA via `post-build.sh`. Add the file to the CI base-hash (§ 9.6). |
| New kernel feature (Phase 2+) | Buildroot kernel defconfig fragment | Replaced on every OTA. |
| New SX1302 / Basics Station setting | Either patch `board/linxdot/overlay/etc/docker-compose.yml` (default for everyone) or document via env vars / `/data/docker-compose.yml` override | Default replaced on every OTA; per-device override survives. |

### 9.3 Common pitfalls — the overlayfs traps

The read-only rootfs is union-mounted with overlayfs uppers on `/data` for `/usr`, `/var/lib`, and `/etc`. That gives operators a writable filesystem on top of an immutable image, but it creates two failure modes that have already burned us once each (§ 12.2 captures the post-mortems).

**Trap 1: runtime edits to `/etc/<x>` mask future firmware fixes.**
Anything written at runtime under `/etc`, `/usr`, or `/var/lib` lands in `/data/overlay/<dir>/upper` and **persists across OTA**. After OTA, the new rootfs ships an updated lower, but the upper still wins. So if a future firmware ships a fix to `/etc/docker-compose.yml`, the device that was patched at runtime keeps the broken (or old) version.

*The rule:* **shipped defaults belong in the rootfs overlay (`board/linxdot/overlay/`); per-device customizations belong on `/data` with a bind-mount or symlink in an init script.** The current pattern is `/data/docker-compose.yml` → bind-mounted over `/etc/docker-compose.yml` by `S01mountall`. Replicate that pattern for any new config file you expect operators to override.

**Trap 2: don't overlay a path whose target is a symlink.**
`/var/log -> ../tmp` (Buildroot default). Mounting an overlay at `/var/log` resolves through the symlink onto `/tmp`, replacing the `S00datapart` tmpfs with a `/data`-backed overlay. A 500 MB OTA download then fills `/data`'s 487 MiB before the slot write finishes. Diagnostic: `mountpoint -q /tmp` returns true on a healthy boot, false if you've shadowed it. `S01mountall` no longer overlays `/var/log` (commit `b3ccf3e`); follow the same lead for any new overlay target.

**Trap 3: `/tmp` is sized for current-bundle downloads, not arbitrary growth.**
`ota-check` does a pre-flight `df /tmp` against `manifest.json`'s `size` field and refuses the download if free space is insufficient. If you grow the rootfs past a free-space margin (currently ~500 MiB on a 1 GiB tmpfs), bundle downloads start failing on devices with low overlay churn. Either keep the rootfs under that bound, or change `ota-check` to stream into a different location.

**Trap 4: A/B slot-portability needs `index=off,xino=off,redirect_dir=off` on every overlay mount.**
The `/data` upper rides between two different rootfs lowers (slots A and B have different ext4 inode numbers). Default `index=on/xino=on` caches origin file-handle hints from the FIRST mount, then ESTALE-rejects (`err=-116`) on the slot's first boot. **All three options** must be present on every `mount -t overlay` line — `tests/test_consistency.sh` enforces this statically.

**Trap 5: busybox userspace lacks `pgrep`.**
`pidof <name> >/dev/null` is the busybox-friendly substitute. The static check in `tests/test_consistency.sh` greps every overlay shell script for stray `pgrep` and fails the build.

### 9.4 Bootloader-touching changes (the C-4 wall)

Constraint **C-4** (§ 5.3) is absolute: the bootloader blob is not OTA-updatable. Any change to one of the following requires every deployed device to be `rkdeveloptool`-reflashed to receive it:

- `board/linxdot/uboot/linxdot.fragment` (U-Boot Kconfig)
- `board/linxdot/uboot/env.txt` (compiled-in env defaults — *not* runtime env)
- `board/linxdot/boot.cmd` / `boot.scr` content (note: this is *also* in the boot partition and *is* OTA-replaceable; only the U-Boot-side bootcmd is frozen)
- `board/linxdot/genimage.cfg` partition offsets, sizes, or count
- `board/linxdot/overlay/etc/fw_env.config` env partition offsets

Three checks before you merge any change to the above:

1. **Run `sh tests/test_consistency.sh` locally.** It cross-validates that env offsets / sizes match across the U-Boot fragment, `fw_env.config`, `env.txt`, and `genimage.cfg`. Drift here means U-Boot writes to one location and Linux's `libubootenv` reads from another, which silently bricks rollback.
2. **Verify the fragment's Kconfig intent without burning a 30-min CI base-build.** Clone upstream U-Boot at the pinned version, `make quartz64-a-rk3566_defconfig`, append your fragment to `.config`, run `make olddefconfig`, and inspect the result. Be aware: Kconfig's `default y if !(...)` rules fire only at `defconfig` time, *not* `olddefconfig` (which is what fragment-merging uses). The current `# CONFIG_ENV_IS_NOWHERE is not set` line in the fragment exists for exactly this reason — see § 12.1 session-5 learnings for the full story.
3. **Plan the migration path.** A bootloader change requires a new factory-image release **and** an explicit operator action (the `rkdeveloptool wl` re-flash). Document this in the release notes and in `Docs/linxdot_fsd.md § 8.4` (the migration procedure). `/data` is preserved across the re-flash by genimage's keep-data flag, but operator instructions must call this out.

### 9.5 SWUpdate / `sw-description` changes

`board/linxdot/swupdate/swupdate.config` is the source of truth for the SWUpdate binary's compiled feature set, and `board/linxdot/swupdate/sw-description.tmpl` is the per-bundle install recipe. Both have non-obvious failure modes documented in § 12.2.

**Three rules that catch all the recurring SWUpdate bugs we've hit:**

1. **`swupdate.config` Kconfig symbol names must be exact.** The upstream symbol for U-Boot bootloader plugin is `CONFIG_UBOOT` — not `CONFIG_BOOTLOADER_UBOOT`. `olddefconfig` silently drops misnamed symbols, the binary ships missing the feature, and bundles get rejected at install time with messages like `"Registered bootloaders: none loaded"`. Read the SWUpdate Kconfig source for any new symbol you add.
2. **Plugin and handler are separate symbols.** `CONFIG_UBOOT=y` registers the libubootenv-backed *plugin*; `CONFIG_BOOTLOADERHANDLER=y` registers the *image handler* that dispatches `bootenv:` sections in `sw-description`. Both are required to write U-Boot env from a bundle. Without the handler you get `"bootloader support absent but sw-description has bootloader section!"` even though `print_registered_bootloaders` says `uboot loaded`. `tests/test_consistency.sh` enforces both being on whenever a `bootenv:` section appears in the template.
3. **The selector splits at the FIRST comma only.** SWUpdate's `parse_image_selector` reads `-e <set>,<mode>` and assigns `set` = first segment, `mode` = entire remainder including any further commas. The libconfig parser then constructs path `software.<set>.<mode>` and runs a single lookup. A nested `software.stable.linxdot-ld1001.target-B` group is unreachable from selector `stable,linxdot-ld1001,target-B` — that asks for a literal libconfig key `"linxdot-ld1001,target-B"` (single key with embedded comma). Keep the template flat: `software.stable.target-{A,B}`, with hardware identity in `hardware-compatibility = ["linxdot-ld1001"]`. The static test fails on any embedded comma in the mode key.

**Adding a new partition target.** Both `target-A` and `target-B` selections must be updated symmetrically — one writing to `p1`+`p2`, the other to `p3`+`p4`. Skipping one breaks rollback for that direction. The partition number → device-node mapping (`/dev/mmcblk0pN` in `sw-description` is U-Boot's view; Linux sees the same partitions as `/dev/mmcblk1pN`) is the same trap as `root=`. Test on real hardware in both directions before signing off.

### 9.6 Signing key and CI base-hash discipline

**Signing keys.** The OTA chain enforces signature verification both ways:

- The public half lives at `board/linxdot/overlay/etc/swupdate/public.pem`, baked into the rootfs.
- The private half lives only in the GitHub Actions secret `OTA_SIGNING_KEY`. CI signs `sw-description` with `openssl dgst -sha256 -sign` (raw RSA-PKCS1v15) on every release.
- `swupdate.config` must have `CONFIG_SIGNED_IMAGES=y` AND `CONFIG_SIGALG_RAWRSA=y`. `tests/test_consistency.sh` enforces the bidirectional implication — if `public.pem` is in the overlay, signing must be compiled in; if signing is compiled in, `public.pem` must be in the overlay. Either side broken in isolation silently disables verification (rc16 shipped public.pem but `CONFIG_SIGNED_IMAGES=n` and `swupdate -k` returned `invalid option -- 'k'` — every bundle was accepted).

Rotation procedure is in § 8.5. Don't rotate without first shipping the new public key in a release that the existing private key still signs.

**CI base-hash discipline.** The CI pipeline has a `detect-changes` job that hashes a list of files; if the hash matches the cached `base-latest` prerelease, the 30-min base-build is skipped and the release job composes from yesterday's cached rootfs. **Files that affect the Buildroot base build but aren't in this hash will silently bypass rebuild** — your fix appears CI-green but ships in a stale rootfs. The current hash list (in `.github/workflows/build.yml`) covers `configs/linxdot_ld1001_defconfig`, `board/linxdot/uboot/linxdot.fragment`, `board/linxdot/uboot/env.txt`, `board/linxdot/post-build.sh`, `board/linxdot/swupdate/swupdate.config`, plus the LFS blobs and prebuilt modules.

If your change touches Buildroot's base-build inputs, **add the file to the hash list in the same PR.** The release job re-applies `board/linxdot/overlay/`, `board/linxdot/swupdate/sw-description.tmpl`, `board/linxdot/genimage.cfg`, and `board/linxdot/post-image.sh` on every run, so those don't need to be hashed — they pick up changes without a rebuild.

### 9.7 Pre-merge checklist

Before opening a PR for a change that's intended to ship via OTA:

- [ ] `sh tests/test_consistency.sh` passes locally.
- [ ] If your change touches the U-Boot fragment, env, partition layout, or `fw_env.config`: documented as a bootloader-frozen change (§ 9.4) and migration plan added to release notes.
- [ ] If your change adds persistent state: stored under `/data/<...>`, not in the overlayfs traps. Documented in the relevant init script.
- [ ] If your change adds an init script: numbered consistently with the existing `S##` ordering; exits 0 on `start`/`stop`; doesn't block boot longer than necessary (`S60ota` pattern for long-running tasks: do the synchronous part, then background the rest before exiting).
- [ ] If your change touches signing or `swupdate.config`: bidirectional signature test (signed bundle accepted, unsigned bundle refused) verified on hardware.
- [ ] If your change touches a Buildroot base-build input: the file is in the `detect-changes` hash list in `.github/workflows/build.yml`.
- [ ] If your change can be hardware-tested: TC-4.4 (happy path) re-run locally on the Workbench LD1001 and the result documented in the PR description.

### 9.8 Verification harness

Two test suites underpin the rules in this chapter, both running in CI on every push:

- **`tests/test_consistency.sh`** — static checks that don't need a built image. Catches drift between fragment / env / fw_env.config / genimage.cfg, missing CONFIG_BOOTLOADERHANDLER when `bootenv:` is in the template, embedded commas in selectors, missing `index=off`/`xino=off` on overlay mounts, stray `pgrep` calls, public.pem ↔ CONFIG_SIGNED_IMAGES asymmetry. Each rule was added in response to a runtime bug we hit on hardware (§ 12.2).
- **`tests/test_ota_state_machine.sh`** — a 10-scenario shell-level simulation of the bootcount / altbootcmd state machine, exercising healthy boots, transient hangs, trial-boot commit, rollback in both directions, bootlimit edge cases. Catches FR-4.x logic regressions before hardware.

If you add a runtime gotcha that bit you on hardware, add a static check to `test_consistency.sh` in the same PR — that's how the existing checks were built up over Phase 4.

## 10. Verification & Validation

### 10.1 Phase 1 verification

| Test ID | Feature | Procedure | Expected |
|---|---|---|---|
| TC-1.1 | Boot to login | Flash image, connect serial @ 1.5 Mbaud, power on | SPL/U-Boot output, kernel boot, `localhost login:` |
| TC-1.2 | Network DHCP | `ip addr show eth0` after boot | IPv4 address assigned |
| TC-1.3 | SSH | `ssh root@<ip>` (pw `linxdot`) | Shell prompt |
| TC-1.4 | Docker healthy | `docker info` | `storage-driver: overlay2`, `data-root: /data/docker` |
| TC-1.5 | Read-only rootfs | `mount \| grep "on / "` | `ro` flag present |
| TC-1.6 | Persistent data | `echo test > /data/test && reboot; cat /data/test` | File survives |
| TC-1.7 | /etc overlay | `touch /etc/testfile && reboot; ls /etc/testfile` | File persists via overlayfs |
| TC-1.8 | Stable MAC | `ip link show eth0` before and after reflash | MAC unchanged (derived from eMMC CID) |
| TC-1.9 | TTN connection | Configure `tc_key.txt`, restart compose, `docker logs basicstation` | `EUI Source: chip`, successful WebSocket upgrade, INFO msgs from LNS |

### 10.2 Phase 3 verification

| Test ID | Feature | Procedure | Expected |
|---|---|---|---|
| TC-3.1 | Static env consistency | `sh tests/test_consistency.sh` on CI | Offsets agree across fragment, fw_env.config, genimage.cfg |
| TC-3.2 | OTA state machine | `sh tests/test_ota_state_machine.sh` | All 10 simulated scenarios pass (healthy boots, transient hangs, trial-boot commit, rollback both directions, bootlimit edge) |
| TC-3.3 | Built U-Boot boots | Flash built image, observe serial | Reaches Linux login using Buildroot-produced `u-boot-rockchip.bin` (unified SPL + FIT + BL31) |
| TC-3.4 | `fw_setenv` from Linux | `fw_setenv test_var hello; fw_printenv test_var` on device | Writes and reads back correctly |
| TC-3.5 | Healthy-slot transient resilience | Force enough reboots to exceed `bootlimit` without committing (simulate crash before `S60ota` phase 2 commits on slot A) | `altbootcmd` fires, resets `bootcount`, slot remains A (not flipped) |
| TC-3.6 | Rollback on broken slot | Install garbage to rootfs_b, `fw_setenv boot_slot B upgrade_available 1 bootcount 0`, reboot | U-Boot tries B, fails N times, `altbootcmd` flips to A, device boots A |

### 10.3 Phase 4 verification

The test plan is **build-time-optimized**: most failure-mode tests are runtime-only (no rebuild) by toggling `HEALTH_CHECK` in `/data/ota.conf` or replacing `/etc/ota/health-probe` via SSH. The CI cost model is:

| Change type | CI build cost | Use for |
|---|---|---|
| Tag-only bump (same commit) | ~2 min (assembly only, full base cache hit) | OTA mechanism tests, slot-flip, version diff |
| Overlay-only edit (`/etc/init.d/*`, `/etc/ota/*`, `/etc/default/ota`) | ~2-3 min (assembly only) | Behavioral tests of init scripts, probe logic |
| `defconfig` / package edit | ~30 min cold (full base rebuild) | Avoid if at all possible |
| Runtime config (`/data/ota.conf`, SSH-edit) | **0 min** (no build) | Most failure-mode tests |

Two releases (`vN` and `vN+1`, same commit) are sufficient for the full happy-path + most failure-path coverage.

| Test ID | Feature | Procedure | Expected | Build cost |
|---|---|---|---|---|
| **TC-4.1** | SWU packaging | `sh tests/test_swu_packaging.sh` | CPIO archive built, `sw-description` is first entry, sha256 placeholders substituted | 0 |
| **TC-4.2** | Image layout | `IMAGE=... sh tests/test_image_layout.sh` | 5 partitions, boot_a at 16 MiB, non-empty SPL region at 32 KiB and env region at 14 MiB | 0 |
| **TC-4.3** | Static OTA-compatibility | `sh tests/test_consistency.sh` | All cross-file invariants hold (env offsets, selector path, signing symmetry, overlayfs flags, busybox-pgrep) | 0 |
| **TC-4.4** | Happy-path OTA (`vN → vN+1`) | Device on `vN`, retag same commit as `vN+1` (or push a new release), power-cycle | After ≤ 5 min: `VERSION_ID=vN+1`, `boot_slot` flipped, `upgrade_available=0`, `bootcount=0`, `S60ota` phase 2 logged commit | 1× retag (~2 min) |
| **TC-4.5** | Phase 1 skipped on trial boot | Force trial state without an OTA: `fw_setenv upgrade_available 1; fw_setenv bootcount 0; reboot` | Phase 1 does NOT fetch manifest (no OTA-on-OTA); phase 2 polls health probe; commits within `HEALTH_TIMEOUT` | 0 |
| **TC-4.6** | Health-check rollback (`HEALTH_CHECK=never`) | `echo HEALTH_CHECK=never > /data/ota.conf; fw_setenv upgrade_available 1; reboot`; reboot 3× more | After exhausting `bootlimit`: U-Boot fires `altbootcmd`, slot flips, `upgrade_available=0`, `bootcount=0`, device on previous version. **Cleanup:** `rm /data/ota.conf` | 0 |
| **TC-4.7** | Pre-apply failure (network blocked) | Add `127.0.0.1 github.com` to overlay `/etc/hosts` (or block via firewall), run `ota-check` | `ota-check` exits non-zero, `/tmp/update.swu` absent, slot untouched, `upgrade_available=0` | 0 |
| **TC-4.8** | Health-probe swappability | `printf '#!/bin/sh\nexit 1\n' > /etc/ota/health-probe`; trigger trial state | Probe ignores `HEALTH_CHECK`, S60 phase 2 always fails, bootloader rolls back after `bootlimit` | 0 |
| **TC-4.9** | Cold-boot clock bootstrap | Power off ≥ 10 min, power on, SSH immediately | `date` initially shows ~2017 (RK3566 RTC default); within ≤ 90 s, jumps to current year; HTTPS manifest fetch succeeds post-jump | 0 (real power cycle) |
| **TC-4.10** | `/data` persistence across OTA | `echo marker > /data/marker` before OTA | After slot flip: `/data/marker` intact, `/data/.initialized` intact, eMMC-bound MAC still applied to `eth0` | 0 (rides on TC-4.4) |
| **TC-4.11** | Overlayfs A/B portability | Inspect `/etc` overlay before and after slot flip; check `dmesg` | No `ESTALE` / `failed to verify` entries; `/etc` upper-layer files visible on both slots' lowerdirs (verifies `index=off,xino=off,redirect_dir=off`) | 0 (rides on TC-4.4) |
| **TC-4.12** | Manual trigger | `ssh root@<device> ota-check` | Same flow as boot-time phase 1; foreground; refuses if `upgrade_available=1` | 0 |
| **TC-4.13** | Manifest reachability probe | `ssh root@<device> ota-check --dry-run` | Exits 0 on healthy network; verifies clock + DNS + TLS + manifest fetch+parse without downloading the `.swu` | 0 |
| **TC-4.14** | Concurrent `ota-check` race (regression — closed by design) | n/a — root cause removed by S60ota consolidation. The pre-consolidation race depended on `S99otacheck` guaranteeing a 60s-post-boot overlap window with any operator action. With S60ota: phase 1 (full) and phase 2 (`--dry-run`) are mutually exclusive per boot; manual `ota-check` on a trial slot is refused via `upgrade_available=1`; the only theoretical collision is "operator SSHs `ota-check` within phase 1's ~30s window of power-on", and the second invocation would still be refused after phase 1's swupdate runs. No active fix needed. | 0 |
| **TC-4.15** | Signature required | Tamper bytes in `sw-description` (in-place `dd if=/dev/urandom of=orig.swu bs=1 count=16 seek=200 conv=notrunc`), run `swupdate -c -i orig.swu -k /etc/swupdate/public.pem` | Tampered: `EVP_DigestVerifyFinal failed`, `Image invalid or corrupted`, no slot write. Original (positive control): `SWUPDATE successful` | 0 (in-place corruption, no rebuild) |
| **TC-4.16** | Full-brick recovery (closed by design) | n/a — covered by union of TC-3.6 (bootloader-level rollback via env manipulation) + TC-4.6 (`HEALTH_CHECK=never`-driven bootcount overflow). U-Boot's `bootcount_env` driver is failure-mode-agnostic: same arc whether userspace dies early (kernel panic) or late (S60ota refuses commit). | n/a | 0 |

**Pre-test checklist:**
- Device reachable on the LAN; root credentials known.
- Workbench Pi serial console accessible (required for TC-4.16 — SSH won't work if init crashes).
- `/data/ota.conf` absent on the device (defaults apply at start).
- `gh release list` shows the expected `vN`, `vN+1`.

**Suggested execution order** (build-cost-minimal): TC-4.1 → 4.2 → 4.3 (CI static checks) → 4.9 (cold boot) → 4.4 (happy path) → 4.10, 4.11 (free observations after 4.4) → 4.6 (rollback drill) → 4.7 (network block) → 4.8 (probe swap) → 4.5 (trial-boot phase split) → 4.12, 4.13 (manual triggers) → 4.14 (race regression) → 4.15, 4.16 (hostile / brick recovery — last). **Total CI build cost for the full plan: ≤ 4 release builds × ~2 min ≈ 8 min.**

### 10.4 Phase 6 verification — SX1302 hardware bring-up

| Test ID | Feature | Procedure | Expected | Build cost |
|---|---|---|---|---|
| **TC-6.1** | GPIO sysfs available | `ls /sys/class/gpio/` on device | `export`, `unexport`, `gpiochip0..128` (5 RK3566 banks) all present | 0 |
| **TC-6.2** | `/dev/spidev0.0` exposed | `ls /dev/spidev*; readlink /sys/bus/spi/devices/spi0.0/driver` | `/dev/spidev0.0` exists; driver symlink points at `spidev` (not the legacy `sx1301` kernel driver) | 0 |
| **TC-6.3** | `spi-pipe` binary present | `which spi-pipe; spi-pipe --help 2>&1 \| head -1` | Binary on PATH; help message printed (proves `BR2_PACKAGE_SPI_TOOLS=y` was honored at build time) | 1× cold rebuild (~30 min, only when defconfig changes) |
| **TC-6.4** | Reset procedure end-to-end | `/usr/sbin/sx1302-reset; echo $?` | Exit 0; final log line `OK SX1302 fully operational (power + reset + chip ID + sweep + write/readback)`; intermediate logs show all 6 steps (power rails, reset pulse, GPIO state, chip ID, sweep, write/readback) passing in order | 0 |
| **TC-6.5** | L1 chip ID | Step 4 of `sx1302-reset` reads `0x5610` | Log: `chip ID = 0x10 (OK)` | 0 |
| **TC-6.6** | L2 register sweep | Step 5 reads 6 addresses (`0x5610, 0x5611, 0x5604, 0x5614, 0x5615, 0x4203`) | At least 2 distinct values across the 6 reads (rules out stuck SPI bus / zombie state); log `sweep =<values> (distinct=N, OK)` | 0 |
| **TC-6.7** | L3 write/readback | Step 6 saves GPIO_DIR (`0x4203`) original value, writes XOR-flipped pattern, reads back, restores | Readback matches written value; log `write/readback OK (orig=0xNN wrote=0xNN got=0xNN, restored)` | 0 |
| **TC-6.8** | Boot-time S30sx1302 hook | Power-cycle device, then SSH and grep `dmesg`/syslog for `sx1302` | `OK SX1302 fully operational` appears during boot, before `S40network` runs | 0 |
| **TC-6.9** | Dead-chip resilience | Simulate by removing `spi-pipe` (e.g., `mv /usr/bin/spi-pipe /tmp/`), reboot | S30 logs failure (`spi-pipe not on PATH`) but exits 0; OTA layer (S60) still runs; device remains reachable via SSH. **Cleanup:** `mv /tmp/spi-pipe /usr/bin/` | 0 |
| **TC-6.10** | Idempotent re-run | `/usr/sbin/sx1302-reset && /usr/sbin/sx1302-reset` (run twice) | Both runs exit 0; second run repeats the GPIO writes (fine — no harm) and re-verifies SPI; original GPIO_DIR value is preserved across both runs (since each restores it) | 0 |

**Suggested execution order:** TC-6.1, 6.2 (no-build observations) → 6.3 (verify spi-tools is in build) → 6.4 (full reset procedure end-to-end) → 6.5–6.7 (drill into individual L1/L2/L3 steps via the same script's logs) → 6.8 (boot-time path) → 6.9 (failure mode) → 6.10 (idempotence). **Build cost:** 1× cold rebuild for TC-6.3 if `spi-tools` wasn't already on, otherwise 0.

### 10.5 Traceability Matrix

| Requirement | Priority | Test Case(s) | Status |
|---|---|---|---|
| FR-1.1 | Must | TC-1.4, TC-1.9 | Covered |
| FR-1.2 | Must | TC-1.9 | Covered |
| FR-1.3 | Must | TC-1.9 | Covered |
| FR-1.4 | Must | TC-1.9 | Covered |
| FR-1.5 | Should | TC-1.9 (region switch) | Covered |
| FR-2.1 | Must | TC-1.9 | Covered |
| FR-2.2 | Must | TC-1.8 | Covered |
| FR-2.3 | Must | TC-1.2 | Covered |
| FR-2.4 | Should | TC-1.9 (TLS works) | Covered |
| FR-3.1 | Must | TC-4.4, TC-4.5 | Covered |
| FR-3.2 | Must | TC-4.12 | Covered |
| FR-3.3 | Must | TC-4.1, TC-4.4 | Covered |
| FR-3.4 | Must | TC-3.2, TC-4.4 | Covered |
| FR-3.5 | Must | TC-4.15 | Covered |
| FR-3.6 | Must | TC-3.2, TC-4.12 | Covered |
| FR-3.7 | Should | TC-4.4 (logs visible) | Covered |
| FR-4.1 | Must | TC-4.4, TC-4.6, TC-4.8 | Covered |
| FR-4.2 | Must | TC-3.4, TC-4.4 | Covered |
| FR-4.3 | Must | TC-3.2 | Covered |
| FR-4.4 | Must | TC-3.2, TC-3.5 | Covered |
| FR-4.5 | Must | TC-3.5 | Covered |
| FR-4.6 | Must | TC-3.6, TC-4.6, TC-4.16 | Covered |
| FR-5.1 | Must | TC-1.3 | Covered |
| FR-5.2 | Should | TC-1.7 (overlay persists host keys) | Covered |
| FR-5.3 | Should | Manual verification via Workbench | Covered |
| FR-6.1 | Should | TC-1.9 | Covered |
| FR-6.2 | Should | TC-1.9 | Covered |
| NFR-1.1 | Must | TC-4.4 (timed) | Covered |
| NFR-1.2 | Must | TC-3.6, TC-4.5 | Covered |
| NFR-1.3 | Must | TC-1.5 | Covered |
| NFR-2.1 | Must | TC-4.3 | Covered |
| NFR-2.2 | Must | Review (key files absent from rootfs) | Covered |
| NFR-2.3 | Should | Review (port scan) | Covered |
| NFR-3.1 | Should | TC-1.1, TC-1.9 (timed) | Covered |
| NFR-4.1 | Should | CI reproducibility | Covered |
| NFR-4.2 | Should | Build review | Covered |

## 11. Troubleshooting

| Symptom | Likely cause | Diagnostic | Corrective action |
|---|---|---|---|
| Can't enter flash mode | Wrong button / charge-only cable | Check USB enumeration on host (`lsusb`) | Use BT-Pair button + data cable; try longer hold (up to 10 s) |
| No network after boot | Ethernet unplugged before boot, or DHCP slow | `ip addr show eth0`; check router leases | Plug Ethernet before powering; reboot |
| `TC_KEY: NOT CONFIGURED` | `tc_key.txt` placeholder still in place | `cat /data/basicstation/tc_key.txt` | Replace file with real key; `/etc/init.d/S80dockercompose restart` |
| `EUI Source: eth0` (not `chip`) | Concentrator not reset before container start | `docker logs basicstation` | `/opt/packet_forwarder/tools/reset_lgw.sh.linxdot start`; `docker-compose restart` |
| Gateway not connecting to TTN | Bad API key, wrong region, firewall | `docker logs basicstation` | Verify key and region; open outbound 443 |
| OTA never triggers | Device still on Phase 1 single-slot image | `fw_printenv` returns error | Migrate per § 8.4 |
| OTA triggers but rolls back | New slot fails health gate | Serial console during trial boot: check kernel panic, init errors, Docker failures | Fix underlying issue in firmware, re-release |
| `upgrade_available=1` stuck | `S60ota` phase 2 probe never returned 0 within `HEALTH_TIMEOUT`, or didn't run | `logger -t ota` entries; `cat /etc/ota/health-probe; /etc/ota/health-probe; echo $?`; check `/data/ota.conf` for `HEALTH_CHECK=never` left over from a rollback drill | Resolve probe failure (network, application, config); manual override: `fw_setenv upgrade_available 0; fw_setenv bootcount 0` |
| Can't boot either slot | Bootloader broken or both slots corrupted | Serial console for U-Boot output | `rockusb` from U-Boot prompt; reflash via `rkdeveloptool` |

## 12. Open Items / Backlog

Consolidated list of work remaining per phase. Close an item by deleting its line (with the commit that closes it). Cross-reference FR/NFR/TC IDs where applicable; the state flags are:

- **`[ ]`** open — not started or not yet verified
- **`[~]`** in progress / partial
- **`[x]`** done (keep briefly for visibility, prune when a phase closes)

### 12.1 Phase 3 — Bootloader from source

**Software / CI (closed):**
- [x] TF-A v2.12.0 pinned; rk3568 plat builds
- [x] U-Boot 2024.04 on `quartz64-a-rk3566` with `linxdot.fragment` (baud, env, bootcount, slot-aware bootcmd)
- [x] Unified `u-boot-rockchip.bin` flow (SPL + FIT + BL31)
- [x] rkbin DDR TPL pinned to `rk3568_ddr_1560MHz_v1.18.bin`
- [x] CI end-to-end green (base-build + release) — run 24827994009, 2026-04-23
- [x] TC-3.1 consistency tests (`tests/test_consistency.sh`) — runs in CI validate
- [x] TC-3.2 state machine simulation (`tests/test_ota_state_machine.sh`) — runs in CI validate

**Hardware validation (open — FSD §4.3 exit criteria):**
- [x] **Pre-flight: BootROM non-secure-lock verification** (evidence-cleared 2026-04-23: SPL prints `Verified-boot: 0`, unsigned `-dirty` builds run).
- [x] Physical flashing path from Workbench Pi (`rkdeveloptool` via routed USB-C at SLOT1/2, `boot_merger`-packed loader for `db` — see runbook §0 + §8.2).
- [x] Runbook `Docs/phase3_hardware_validation.md` covering BootROM check, flashing, and TC-3.3..TC-3.6 procedures with pass criteria.
- [x] **TC-3.3** Built U-Boot boots to Linux login on hardware — signed off 2026-04-23 on the Workbench LD1001 at 192.168.0.142 (run 24854453113, commit `01e3fd7`). Full chain: vendor DDR TPL → our SPL 2024.04 → FIT hash verify → rkbin BL31 v1.43 → U-Boot 2024.04 → autoboot → kernel → BusyBox userspace → dropbear + Docker + SWUpdate all started.
- [x] **TC-3.4** `fw_setenv` / `fw_printenv` round-trip from userspace — signed off 2026-04-24 on the Workbench LD1001 (CI run `24880830241`, commit `020e64b`). Cold-boot serial log: `Loading Environment from MMC... OK`. `fw_setenv tc34_cold ...` writes to redundant copy with incremented flag, `fw_printenv` reads back correctly. After `reboot -f`, U-Boot reads the libubootenv-written copy (value `tc34_cold` persists), proving the Linux ↔ eMMC ↔ U-Boot handoff works in both directions.
- [x] **TC-3.5** Healthy-slot transient resilience — signed off 2026-04-24. With `CONFIG_BOOTCOUNT_ENV=y` + `CONFIG_BOOTCOUNT_LIMIT=y`, U-Boot's `bootcount_env` driver only increments `bootcount` when `upgrade_available=1` (see `drivers/bootcount/bootcount_env.c`). In steady state (`upgrade_available=0`), bootcount stays at 0 across reboots and `altbootcmd` can never fire, so transient kernel panics / reboots cannot cause spurious slot flips — the invariant FR-4.5 requires. Verified by reboot in steady state: serial shows no `Saving Environment` during boot, post-boot `fw_printenv` shows `boot_slot` unchanged and `bootcount=0`.
- [x] **TC-3.6** Broken-slot rollback — signed off 2026-04-24. Sequence: `fw_setenv upgrade_available=1 bootcount=2`, `reboot -f`. Serial log: `Loading Environment from MMC... OK` → `Saving Environment to MMC... Writing to redundant MMC(0)... OK` (bootcount 2→3) → `Saving Environment to MMC... Writing to MMC(0)... OK` (next boot: bootcount 3→4) → `Warning: Bootlimit (3) exceeded. Using altbootcmd.` → `Saving Environment to MMC... Writing to redundant MMC(0)... OK` (altbootcmd's `saveenv` after flipping slot). Post-reboot state: `boot_slot=B`, `bootcount=0`, `upgrade_available=0`, and the device booted from `/dev/mmcblk1p4` (rootfs_b) — `/proc/cmdline` confirms. Redundant-env ping-pong also validated end-to-end (writes alternate between primary and redundant copies).

**Session-3 learnings captured in the runbook and applied in code (commits `5c88e53`, `ad63c3e`, `3441c0a`, `01e3fd7`):**
- `root=/dev/mmcblk1p{2,4}` in `bootargs` (kernel's view of eMMC), not `mmcblk0` (U-Boot's view). Regression from Phase 1 commit `1291432` that cost us hours of silent rootwait before diagnosis.
- `env.txt` must duplicate compiled-in `bootcmd`, `bootdelay`, and the aarch64 load addresses — saved env is wholesale-replace, not merge.
- Local builds need `git lfs pull` before `post-build.sh`; the prebuilt kernel Image + DTB in `board/linxdot/blobs/` are LFS pointers otherwise.
- TF-A v2.12.0 was the planned BL31; switched to vendor rkbin BL31 v1.43 after hardware proved mainline TF-A doesn't implement the Rockchip SIP SMCs the vendor 5.15 kernel calls. Revisit when Phase 2 (mainline kernel) lands.
- Phase 3 permanently removes the vendor BT-Pair → Loader shortcut (vendor-SPL feature). Post-Phase-3 re-flash path is `serial Ctrl-C spam → U-Boot prompt → mw.l 0xfdc20200 0xef08a53c; reset → Maskrom → db → wl`. Fully documented in runbook §1.1 and §8.1.

**Session-4 learnings captured in code (commits `a4cafbb`, `14e0887`):**
- `/etc/fw_env.config` must reference `/dev/mmcblk1` (Linux's view of eMMC), not `/dev/mmcblk0` — same U-Boot-vs-Linux numbering mismatch as `root=`. Shipped overlay was wrong; `fw_printenv` returned "Cannot initialize environment".
- `CONFIG_ENV_OFFSET_REDUND` alone does *not* enable redundant env — `CONFIG_SYS_REDUNDAND_ENVIRONMENT=y` is also required. Without it U-Boot writes only the primary copy; power-loss mid-`saveenv` leaves no valid env → device unbootable.
- `mkenvimage` must be called with `-r` when the target U-Boot has redundant env enabled. `-r` inserts the 1-byte "active" flag between CRC32 and env data; without it U-Boot can't parse the shipped env and falls back to compiled-in defaults (losing `altbootcmd` / `bootcount` / `boot_slot` from `env.txt`).
- In-place image flash from the running device (`xz -dc /tmp/new.img.xz | dd of=/dev/mmcblk1; sysrq b`) is a faster alternative to the Maskrom dance when the device is booted and reachable — about 90 seconds end-to-end, no serial pre-arm needed.

**Session-5 learnings captured in code (commit `1b45368`):**
- `quartz64-a-rk3566_defconfig` ships with `CONFIG_ENV_IS_NOWHERE=y` as its Kconfig default. Adding `CONFIG_ENV_IS_IN_MMC=y` in our fragment does NOT auto-disable NOWHERE — Kconfig's `default y if !(ENV_IS_IN_*)` rule only fires during `make defconfig`, not `olddefconfig` (which is what fragment merging uses). The merged `.config` keeps BOTH drivers compiled in. Our fragment now explicitly `# CONFIG_ENV_IS_NOWHERE is not set`.
- With both drivers active, U-Boot's `env_load` iterates by priority: MMC first, then NOWHERE. If MMC has any hiccup (CRC check fails, even for reasons we haven't fully isolated), NOWHERE unconditionally succeeds with compiled-in defaults. `gd->env_load_prio` then sticks at NOWHERE, and every subsequent `saveenv` targets NOWHERE → prints `Saving Environment to nowhere... not possible`. The device silently runs on defaults and `altbootcmd` / `bootcount` / `boot_slot` / rollback all break.
- TC-3.4's initial "PASS" sign-off in session 4 was misleading in scope. `fw_setenv` / `fw_printenv` only validate the Linux ↔ eMMC handoff via libubootenv reading `/dev/mmcblk1` at the configured offsets — they do NOT prove U-Boot is using that env. U-Boot's `env_load` had been silently falling through to NOWHERE since cold boot, which was only caught by reading the serial log for the `Loading Environment from MMC... *** Warning - bad CRC` line. Any future env-related TC must include serial-log verification of the U-Boot load message.
- Diagnosis method: Python `zlib.crc32` over a byte-accurate dump of each env copy (both mkenvimage-produced and libubootenv-written) was the definitive tool for ruling out CRC-math, ENV_SIZE, padding, and flag-scheme hypotheses. When `zlib.crc32(buf[5:0x10000]) == struct.unpack('<I', buf[:4])` holds on-disk, libubootenv is writing correctly and any "bad CRC" failure is in U-Boot's load path, not the writer. `make quartz64-a-rk3566_defconfig + fragment + olddefconfig` locally (without needing a full build) is the fastest way to verify a fragment's Kconfig intent before burning a CI cycle.
- CI `detect-changes` hash must cover every file Buildroot consumes at base-build time — U-Boot fragment, env.txt, post-build.sh. Commit `020e64b` added these after a stale-cache hit caused `1b45368`'s fragment fix to be silently ignored (release job assembled from yesterday's `base-latest` artifact). A missing file here = invisible cache poisoning; the CI "green" flag says nothing about whether the artifact reflects current source.
- `drivers/bootcount/bootcount_env.c` — U-Boot's env-backed bootcount driver only increments `bootcount` when `upgrade_available=1`. In steady state, `bootcount_inc()` is a no-op: neither `env_set_ulong("bootcount", ...)` nor `env_save()` runs. This gives A/B systems the right semantic (transient steady-state crashes don't unnecessarily rollback), but means TC-3.5's test is structural rather than dynamic: we rely on the driver's behavior as written rather than exercising bootcount overflow. Worth bearing in mind if switching bootcount backends (e.g., to `bootcount_ram.c` or an SoC register — those increment unconditionally).

**Defense-in-depth (open — non-blocking):**
- [ ] Bake `altbootcmd` into U-Boot compiled-in default env (via `CONFIG_USE_DEFAULT_ENV_FILE=y` + pre-build hook to stage `env.txt`). Currently lives only in flashed `uboot-env.bin`; compiled-in fallback is missing. FR-4.4 defense case.

### 12.2 Phase 4 — OTA update layer

**Software scaffolding (present — verified end-to-end on rc12+):**
- [x] `ota-check` script (FR-3.1, FR-3.2, FR-3.3, FR-3.7) — in `board/linxdot/overlay/usr/sbin/ota-check`. Supports `--dry-run` for the health probe.
- [x] `S60ota` boot-time hook (FR-3.1, FR-4.1) — in overlay init.d. Replaces the legacy `S99otacheck` (acquire) + `S98confirm` (commit) pair with a single two-phase script. Phase 2 backgrounds the probe loop so init can continue to `S70+` (application).
- [x] `/etc/ota/health-probe` — swappable application probe (FR-4.1). Default ships with the OTA-only base, honors `HEALTH_CHECK` selector via `/etc/default/ota` and `/data/ota.conf`.
- [x] `sw-description.tmpl` (FR-3.3, FR-3.5) — in `board/linxdot/swupdate/`. Flat 2-level layout (`software.stable.target-{A,B}`).
- [x] `scripts/gen-signing-key.sh` (FR-3.5, signing-key lifecycle) — keypair deployed: private half in `OTA_SIGNING_KEY` GitHub secret, public half in `board/linxdot/overlay/etc/swupdate/public.pem`. CI signs every release with `openssl dgst -sha256 -sign`; deployed devices verify via `swupdate -k`.
- [x] CI `.swu` build + `manifest.json` (with `size` field for pre-flight) emission — exercised on rc11→rc12.

**Hardware validation (Workbench LD1001 — Phase 4 complete, all gates PASS):**
- [x] **TC-4.1** SWU packaging static test (`tests/test_swu_packaging.sh`) — CI green from rc1 onward.
- [x] **TC-4.2** Image-layout partition check (`tests/test_image_layout.sh`) — CI green from rc1 onward.
- [x] **TC-4.3** Signature required — signed off 2026-04-25 on rc17 (`CONFIG_SIGNED_IMAGES=y` + `CONFIG_SIGALG_RAWRSA=y`). Bidirectional: a signed bundle (rc17, has `sw-description.sig` second in cpio) feeds through `swupdate -v -c -i …swu -k /etc/swupdate/public.pem` with exit 0 and "SWUPDATE successful"; an unsigned bundle (rc15, no `.sig`) is refused with exit 1 and `description file name not the first of the list: rootfs.ext4 instead of sw-description.sig`. With `CONFIG_SIGNED_IMAGES=y`, swupdate hard-requires `sw-description.sig` as the second cpio entry — there is no fallback for the parser to accept an unsigned bundle. **Note**: `rc17` was the first build with signing actually compiled in; `rc16` shipped public.pem in the rootfs but the binary still parsed `-k` as `invalid option -- 'k'`, silently bypassing verification — caught in this session and locked down by static check in `tests/test_consistency.sh`.
- [x] **TC-4.4** Happy-path OTA — signed off 2026-04-25 on the Workbench LD1001 (rc12 → rc13 with the legacy S98confirm); re-validated 2026-05-02 on the consolidated S60ota with the v1.0.10 → v1.1.0 → v1.2.0 chain. Final hop's slot-B trial boot ran S60ota phase 2 (the new code), polled `/etc/ota/health-probe` (default — full mode), committed within ~90 s. Final state: `VERSION_ID=1.2.0`, `boot_slot=B`, `upgrade_available=0`, `bootcount=0`. No human intervention from power-on through commit.
- [x] **TC-4.5** Phase 1 skipped on trial boot — implicit pass during TC-4.4 (no OTA-on-OTA observed); not actively forced.
- [x] **TC-4.6** Health-check rollback (`HEALTH_CHECK=never`) — signed off 2026-04-25 on rc14 → rc15 with the legacy S98confirm. Boots after the OTA reboot: `boot 1: slot=A ua=1 bc=1 ver=rc15` → `boot 2: slot=A ua=1 bc=2 ver=rc15` → `boot 3: slot=A ua=1 bc=3 ver=rc15` (still under bootlimit) → `boot 4: slot=B ua=0 bc=0 ver=rc14` — bootcount overflowed (3→4 > limit 3), U-Boot ran `altbootcmd` which flipped `boot_slot` A→B, cleared `upgrade_available` and `bootcount`. End-to-end exercise of FR-4.4/4.6 from health-failure through to bootloader-driven recovery, no human intervention. Re-test on consolidated S60ota deferred (probe ownership unchanged; bootloader path identical).
- [x] **TC-4.8** Health-probe swappability — signed off 2026-05-02 on v1.2.0. Replacing `/etc/ota/health-probe` with `#!/bin/sh\nexit 1\n` causes the probe to fail regardless of `HEALTH_CHECK` setting; restoring the default makes it pass. Confirms the application-package contract — overlay drops a probe, OTA layer doesn't import application logic.
- [x] **TC-4.9** Cold-boot clock bootstrap — signed off 2026-05-02. After power-cycle, `date` showed `2017-08-05` for ≤ 90 s, then jumped to `2026-05-02` via `/usr/sbin/clock-bootstrap`. HTTPS manifest fetch succeeded immediately after.
- [x] **TC-4.10** `/data` persistence across OTA — implicit pass during TC-4.4 chain (eMMC-bound MAC, `/data/.initialized`, sshd host keys all survived two slot flips).
- [x] **TC-4.11** Overlayfs A/B portability — implicit pass during TC-4.4 chain (devices crossed `A → B → A → B` without `ESTALE`; `/etc` upper-layer files visible on both slots' lowerdirs).
- [x] **TC-4.12** Manual trigger (`ssh root@<device> ota-check`) — exercised in rc7 / rc11 / v1.0.x; flow matches FR-3.2.
- [x] **TC-4.13** Manifest reachability probe (`ota-check --dry-run`) — signed off 2026-05-02 on v1.2.0; default `/etc/ota/health-probe` exits 0 in committed state, `HEALTH_CHECK=always` short-circuits to 0, `HEALTH_CHECK=never` short-circuits to 1.
- [x] **TC-4.14** Concurrent `ota-check` race — **closed by design 2026-05-02**. The race observed on v1.0.9 (sha256 mismatch from two parallel processes; self-recovered) depended on `S99otacheck` always firing 60s post-boot, guaranteeing an overlap window with any operator-triggered `ota-check`. The S60ota consolidation removed `S99otacheck` entirely; phase 1 and phase 2 are mutually exclusive per boot, and trial-slot manual runs are refused via the `upgrade_available=1` check. No `flock` needed.
- [x] **TC-4.7** Pre-apply failure (network blocked) — signed off 2026-05-02 on v1.2.0. With `127.0.0.1 github.com` in `/etc/hosts`, `ota-check` fails at manifest fetch (`curl (7) Failed to connect`), logs `ota: error: could not fetch manifest`, exits 1. Post-failure state unchanged: `boot_slot=B`, `upgrade_available=0`, `bootcount=0`, no `/tmp/update.swu` written. Sanity-check after restoring `/etc/hosts`: `ota-check` succeeds, reports `already up to date`.
- [x] **TC-4.15** Signature required — re-signed off 2026-05-02 on v1.2.0. Positive control: `swupdate -c -i v1.2.0.swu -k /etc/swupdate/public.pem` → "SWUPDATE successful", exit 0. Negative: `dd if=/dev/urandom of=v1.2.0.swu bs=1 count=16 seek=200 conv=notrunc` (corrupts 16 bytes inside sw-description content), then `swupdate -c` → `EVP_DigestVerifyFinal failed, error 0x2000068` → `Error Verifying Data` → `Image invalid or corrupted. Not installing`. State unchanged: `boot_slot=B, upgrade_available=0, bootcount=0`. RSA-PKCS1v15-SHA256 against `/etc/swupdate/public.pem` is enforced end-to-end on the consolidated S60ota stack.
- [x] **TC-4.16** Full-brick recovery — **closed by design 2026-05-02**. The failure path (`bootcount > bootlimit → altbootcmd → slot flip`) is exercised by the union of TC-3.6 (real-hardware bootcount overflow via env manipulation) and TC-4.6 (real-hardware `HEALTH_CHECK=never` driving the same overflow through the S60ota path). U-Boot's `bootcount_env` driver is failure-mode-agnostic — it increments whenever `upgrade_available=1` regardless of whether userspace died early (kernel panic, init crash) or late (S60ota refusing commit). Both paths converge on the same arc; TC-4.16 would only add orthogonal coverage if the bootloader treated failure modes differently, which it doesn't. Marked closed without crafting a deliberately-broken release.

**Session-6 learnings captured in code (commits `c36c7e8`, `09cf861`, `a983d88`, `aa01e4f`, `b3ccf3e`, `fc79f0d`, `0e4cbf5`, `e3e77d8`):**

The Phase 4 hardware bring-up peeled four nested SWUpdate-config bugs and two userspace bugs, none of which any prior CI signal caught. Each got a matching test_consistency.sh check on the way out so the same drift is caught at PR-time instead of "swupdate rejects bundle on hardware" time.

- **SWUpdate Kconfig name discipline.** Upstream's bootloader Kconfig is just `CONFIG_UBOOT` (not `CONFIG_BOOTLOADER_UBOOT`); `CONFIG_LIBCONFIG=y` requires `HAVE_LIBCONFIG` from a Buildroot-level `BR2_PACKAGE_LIBCONFIG=y`. `olddefconfig` silently drops misnamed symbols — an earlier swupdate.config shipped with `BOOTLOADER_NONE=y, SSL_IMPL_NONE=y, no LIBCONFIG`, so swupdate parsed nothing and rejected every bundle. *No build-time error, no runtime hint until you read the trace and see "Registered bootloaders: none loaded".*
- **Selector splits at FIRST comma only, then joins with `.`.** SWUpdate's `parse_image_selector` (`core/parser.c`) takes `-e <set>,<mode>` and assigns `set = first segment`, `mode = entire remainder including any further commas`. The libconfig parser then constructs path `software.<set>.<mode>` and runs a single `config_lookup` (`corelib/parsing_library_libconfig.c::find_root_libconfig` → `mstrcat(nodes, ".")`). A nested `software.stable.linxdot-ld1001.target-B` group is unreachable from selector `stable,linxdot-ld1001,target-B` — that asks for `software → stable → "linxdot-ld1001,target-B"` (a single key with embedded comma). Flatten sw-description so `<mode>` is a single libconfig key.
- **Bootloader plugin ≠ bootloader handler.** `CONFIG_UBOOT=y` registers the libubootenv-backed *plugin* that knows how to talk to the U-Boot env. It does NOT register an *image handler* for `bootenv:` sections in sw-description. `core/parser.c:184` requires `find_handler("uboot")` or `find_handler("bootenv")` before accepting any bundle that touches the bootloader env — both come from `handlers/boot_handler.c`, gated on a separate `CONFIG_BOOTLOADERHANDLER=y`. Without it, parse-time error is `"bootloader support absent but sw-description has bootloader section!"` even though `print_registered_bootloaders` says `uboot loaded`.
- **busybox userspace lacks `pgrep`.** `S98confirm`'s health check called `pgrep dockerd >/dev/null 2>&1`. Buildroot's busybox ships `pidof` but not `pgrep`. Result: `pgrep` returned 127 (command not found), shell saw non-zero, `is_healthy` returned false, S98confirm logged "FAILED" and queued a rollback after the 60 s timeout — even though dockerd was running fine. `pidof dockerd >/dev/null 2>&1` is the busybox-friendly fix. Static check now greps every overlay shell script for a stray `pgrep`.
- **Overlayfs slot-portability needs `index=off,xino=off,redirect_dir=off`.** A/B layouts share one /data partition (overlay upper) but flip between two rootfs partitions (overlay lower) at every commit. With default `index=on/xino=on`, overlayfs caches origin file-handle hints from the FIRST mount's lowerdir; on slot-B's first boot the lowerdir is a different ext4 fs with different inodes, and the kernel rejects the mount with `failed to verify upper root origin / err=-116 (ESTALE)`. /usr, /var/lib, /etc all stay read-only and S98confirm can't even rewrite scripts. Fix in `S01mountall::mount_overlay` adds the three `*_off` options. Static check requires both `index=off` and `xino=off` in any `mount -t overlay` line (multi-line continuation handled).
- **`/var/log -> ../tmp` symlink + S01mountall overlay collision** (rc5). Mounting an overlay at `/var/log` resolves through the symlink onto `/tmp`, replacing the S00datapart tmpfs with a `/data`-backed overlay. 500 MB OTA downloads then fill `/data`'s 487 MiB. `S01mountall` no longer overlays `/var/log` — log files live in tmpfs and are intentionally lost across reboots. `ota-check` also gained a pre-flight check: refuse to download if `/tmp` free space < `manifest.size` (the `size` field added to `manifest.json` for this).
- **Concurrent `ota-check` race on `/tmp/update.swu` — closed by design.** Boot-time `S99otacheck` (60 s after boot) and a manual `ota-check` both `rm -f /tmp/update.swu` before curl — the second invocation can unlink while the first is still curling, manifesting as `curl: (23) Failure writing output to destination` or a sha256 mismatch (observed on v1.0.9 OTA, self-recovered). The S60ota consolidation (2026-05-02) removed `S99otacheck`, eliminating the always-on overlap window; the remaining theoretical collision (operator runs `ota-check` within phase-1's ~30 s) is rare and self-arbitrating via `upgrade_available=1` refusal. Marked closed without a `flock` retrofit.
- **Vendor 5.15 kernel rejects genimage's metadata_csum'd `data.ext4`.** First boot of any fresh image hits `EXT4-fs error (mmcblk1p5): iget: checksum invalid` and `mount failed`. `S00datapart`'s `e2fsck -pf` + `resize2fs` recovers it on subsequent boots, but the FIRST boot of a fresh image lands without `/data` mounted (and therefore without overlays). Open: pass `-O ^metadata_csum,^metadata_csum_seed` to genimage's mke2fs invocation, or have `S00datapart` `mkfs.ext4 -F` if the first mount fails.
- **CI base hash must cover every file the release job re-applies.** The base-hash list in `.github/workflows/build.yml` gates the cached-rootfs reuse, but the release job re-applies `board/linxdot/overlay/`, `board/linxdot/swupdate/sw-description.tmpl`, `board/linxdot/genimage.cfg`, and `board/linxdot/post-image.sh` on every run — these are NOT in the base hash by design (they're part of the fast release pass), so they pick up changes without a 40-min full rebuild. `swupdate.config` IS in the base hash (it gates Buildroot's `make swupdate` recompile). Drift-debugging takeaway: when a fix to an overlay file appears not to take effect, the release log's "Applying overlay…" line is the source of truth, not the base build.
- **`swupdate.config` is the source of truth for the swupdate binary.** The buildroot package wrapper passes the kconfig file through `make olddefconfig` and links against host libs gated by `BR2_PACKAGE_*` env vars (HAVE_LIBSSL/HAVE_LIBCONFIG/HAVE_LIBUBOOTENV). Misnamed kconfig symbols are silently dropped; missing BR2 packages disable the corresponding feature even if the swupdate-side symbol is set. The pairing of the two has to be right for the binary to actually have the feature compiled in.
- **Public key in overlay is not enough — `CONFIG_SIGNED_IMAGES=y` must also be on.** rc16 shipped `public.pem` in the rootfs and CI signed `sw-description`, but `ota-check`'s `swupdate -k /etc/swupdate/public.pem` produced `swupdate: invalid option -- 'k'` and exited 0. swupdate's argument parser only registers `-k` when the verifier is compiled in (`CONFIG_SIGNED_IMAGES=y`); without it `getopt` rejects the flag, the verification path is silently skipped, and any bundle (signed or not) is accepted. Caught by the test suite now: if the overlay public.pem exists, `test_consistency.sh` requires `CONFIG_SIGNED_IMAGES=y` AND `CONFIG_SIGALG_RAWRSA=y` (the algorithm matching CI's `openssl dgst -sha256 -sign` raw RSA-PKCS1v15 output). The reverse implication is also enforced — turning on signing without shipping a public key would brick every bundle on hardware.

### 12.3 Phase 5 — Curated in-tree DTS (not started)

- [ ] Replace vendor `rk3566-linxdot.dtb` with in-tree DTS covering all peripherals (eth, WiFi, SPI for SX1302, eMMC, USB, UART2 @ 1.5 Mbaud).
- [ ] Remove C-2 console-baud constraint once DTS is in-tree.

### 12.4 Housekeeping

- [x] Hardware validation runbook — `Docs/phase3_hardware_validation.md`.
- [ ] Prune Phase 1 vendor blobs from `board/linxdot/blobs/` (`idbloader.img`, `u-boot.itb`) once Phase 3 is hardware-validated and the branch merges — currently kept as a rollback fallback for the pre-A/B migration path (C-5, §8.4).
- [x] Migrate CLAUDE.md to describe the merged (Phase 3+) baseline once `OTA` → `main`. Done 2026-04-26 alongside the v1.0.0 release (rewrote tech stack, project structure, key conventions, and gotchas; pointers to FSD § 9 Developer Guide for OTA-compat changes).


## 13. Appendix

### 13.1 Constants

| Constant | Value | Defined in |
|---|---|---|
| Console baud | 1,500,000 (Phase 1–3) | vendor DTB `stdout-path` |
| `CONFIG_ENV_OFFSET` | `0xE00000` (14 MiB) | `board/linxdot/uboot/linxdot.fragment`, `overlay/etc/fw_env.config`, `genimage.cfg` |
| `CONFIG_ENV_SIZE` | `0x10000` (64 KiB) | same |
| `CONFIG_ENV_OFFSET_REDUND` | `0xE10000` | same |
| `bootlimit` | `3` | `board/linxdot/uboot/env.txt` |
| TF-A version | `v2.12.0` source (built but unused; vendor BL31 overrides at U-Boot link, see below) | defconfig `BR2_TARGET_ARM_TRUSTED_FIRMWARE_CUSTOM_VERSION_VALUE` |
| TF-A platform | `rk3568` (for RK3566 by convention) | defconfig `BR2_TARGET_ARM_TRUSTED_FIRMWARE_PLATFORM` |
| **Effective BL31** | `bin/rk35/rk3568_bl31_v1.43.elf` (rkbin) — required because vendor 5.15 kernel calls Rockchip-vendor SIP SMCs upstream TF-A does not implement | `BR2_PACKAGE_ROCKCHIP_RKBIN_BL31_FILENAME` |
| U-Boot defconfig base | `quartz64-a-rk3566` | defconfig `BR2_TARGET_UBOOT_BOARD_DEFCONFIG` |
| DDR TPL blob | `bin/rk35/rk3568_ddr_1560MHz_v1.18.bin` (rkbin) | `BR2_PACKAGE_ROCKCHIP_RKBIN_TPL_FILENAME` |
| OTA manifest URL | `https://github.com/SensorsIot/Linxdot-Hotspot/releases/latest/download/manifest.json` | `overlay/usr/sbin/ota-check` |

### 13.2 Extraction from CrankkOS (historical, Phase 1 bring-up)

```
# Mount source partitions
sudo mount -o loop,offset=$((40960*512)),ro crankkos-linxdotrk3566-1.0.0-pktfwd.img /tmp/crankk-boot
sudo losetup -f --show -o $((204800*512)) --sizelimit $((1024000*512)) crankkos.img
sudo mount -o ro /dev/loopN /tmp/crankk-root

# Extract boot blobs (raw dd)
dd if=crankkos.img of=board/linxdot/blobs/idbloader.img bs=512 skip=64    count=8000
dd if=crankkos.img of=board/linxdot/blobs/u-boot.itb   bs=512 skip=16384  count=16384

# Kernel, DTB, modules, firmware copied from the extracted filesystems.
```

### 13.3 Useful commands

```
# On the device
fw_printenv                            # full U-Boot env
fw_printenv boot_slot bootcount upgrade_available
fw_setenv upgrade_available 0          # force-commit slot
ota-check                              # manual update check
/etc/init.d/S80dockercompose status    # Basics Station + TC_KEY state
docker logs basicstation               # LNS connection log

# On the host (via Workbench)
python3 -c "import serial; s=serial.serial_for_url('rfc2217://192.168.0.87:4003', baudrate=1500000); ..."
curl http://192.168.0.87:8080/api/devices      # workbench slot map
ssh pi@192.168.0.87 'sudo rkdeveloptool ld'    # rkdeveloptool status (needs USB routed)
```

### 13.4 Repository layout

```
configs/linxdot_ld1001_defconfig   Buildroot defconfig
external.desc + external.mk + Config.in   BR2_EXTERNAL tree
board/linxdot/
  boot.cmd                         U-Boot boot script source (compiled to boot.scr)
  genimage.cfg                     GPT partition layout + raw regions
  post-build.sh                    Rootfs finalisation (kernel, modules, os-release)
  post-image.sh                    boot.scr compile, env image, genimage invocation
  uboot/linxdot.fragment           U-Boot Kconfig overrides (env, baud, bootcount)
  uboot/env.txt                    Default U-Boot env (boot_slot, altbootcmd)
  swupdate/sw-description.tmpl     SWUpdate manifest template
  blobs/                           Phase 1 vendor binaries (Git LFS)
  modules/5.15.104/                Prebuilt kernel modules (Git LFS)
  firmware/brcm/                   WiFi firmware (gitignored, licence)
  overlay/etc/fw_env.config        Linux-side U-Boot env locator
  overlay/etc/init.d/S*            Init scripts
  overlay/usr/sbin/ota-check       OTA agent CLI
package/docker-compose-v1/         Static aarch64 docker-compose binary
scripts/gen-signing-key.sh         One-time signing-key generator
tests/                             Static + runtime test suite
.github/workflows/build.yml        CI: validate, base-build, release
```

