# OpenLinxdot — Functional Specification Document (FSD)

## 1. System Overview

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
  → Linux 5.15.104 → BusyBox init → S00datapart..S98confirm..S99otacheck
  → dockerd → docker-compose → basicstation → WebSocket TLS → TTN LNS
```

## 2. System Architecture

### 2.1 Logical Architecture

| Subsystem | Role |
|---|---|
| **Bootloader** (idbloader + U-Boot + TF-A BL31) | Loads kernel, implements A/B slot selection and automatic rollback on failure. |
| **Kernel + DTB** | Vendor Linux 5.15.104 binary with Rockchip vendor DTB (Phase 1–3). Built from source in Phase 2+. |
| **BusyBox init** | Runs the small set of init scripts (S00–S99) that mount filesystems, set up networking, start services. |
| **Overlayfs** | Preserves writes to `/usr`, `/var/log`, `/var/lib`, `/etc` on the read-only rootfs, backed by `/data`. |
| **Docker engine** | Runs exactly one container: `xoseperez/basicstation`. |
| **Basics Station** | LoRaWAN packet forwarder, connects to TTN via WebSocket+TLS. |
| **OTA agent** (Phase 4) | `ota-check` CLI + `S99otacheck` init hook. Fetches GitHub Release manifest, downloads `.swu`, hands to SWUpdate. |
| **SWUpdate** (Phase 4) | Writes inactive A/B slot, sets U-Boot env flags for trial boot. |
| **Confirm gate** (Phase 4) | `S98confirm` waits for Basics Station to reach TTN, then clears trial flags; U-Boot otherwise rolls back. |

### 2.2 Hardware / Platform Architecture

Target hardware is fully documented in `Docs/Hardware.md` (reference manual). Summary:

- **SoC:** Rockchip RK3566, quad-core ARM Cortex-A55 @ 1.8 GHz, aarch64.
- **Memory:** 2 GiB LPDDR4.
- **Storage:** 28.9 GiB eMMC (plenty of headroom — A/B layout uses ~1.6 GiB).
- **LoRa:** Semtech SX1302 concentrator on SPI (`/dev/spidev0.0`).
- **Network:** Gigabit Ethernet (Realtek RTL8211F). WiFi + BT present but not used by default.
- **Serial console:** UART2 @ **1,500,000 baud** on 3.5 mm TRRS jack. Exposed remotely via the Workbench Pi at `rfc2217://192.168.0.87:4003`.
- **USB:** USB-C behind the case, wired to the RK3566 USB2.0 controller — enables Rockchip download mode for `rkdeveloptool` flashing. Accessible from serial via `rockusb` / `download` commands without any physical button.
- **BootROM:** confirmed **non-secure** (see `Docs/Hardware.md § BootROM secure-mode status`).

### 2.3 Software Architecture

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
7. If `upgrade_available=1`, `S98confirm` waits for Basics Station to reach TTN, then clears flags.
8. If boot attempts exceed `bootlimit` without clearing flags, U-Boot runs `altbootcmd` → slot flips, device boots old slot.

## 3. Implementation Phases

### 3.1 Phase 1 — Infrastructure Foundation (complete)

**Scope:** Replace CrankkOS userspace with a clean Buildroot rootfs while keeping the vendor bootloader, kernel, and DTB as binary blobs. Produce a flashable single-slot image.

**Deliverables:**
- Buildroot defconfig with Docker + Basics Station stack.
- Minimal init scripts (S00datapart, S01mountall, S40network, S50sshd, S60dockerd, S80dockercompose).
- CI pipeline that builds, packages, and publishes a `.img.xz` on tag.
- Persistent MAC derived from eMMC CID.

**Exit criteria:** Device flashes via `rkdeveloptool`, boots, obtains DHCP lease, connects to TTN once `TC_KEY` is configured, survives power cycles.

### 3.2 Phase 2 — Kernel from source (planned)

**Scope:** Replace the vendor Linux 5.15.104 binary with an in-tree-built mainline kernel (6.1 LTS or later) with RK3566 support.

**Deliverables:** Buildroot-built kernel with SPI, Ethernet, SDIO WiFi, I2C, USB all functional. Ability to change console baud rate (via DTB `stdout-path`).

**Exit criteria:** Device boots self-built kernel, all peripherals function at parity with Phase 1, Basics Station reaches TTN.

### 3.3 Phase 3 — Bootloader from source (in progress, branch `OTA`)

**Scope:** Replace vendor U-Boot 2017.09 (which lacks writable env and has a `boot.scr` execution bug) with mainline U-Boot 2024.04+ on `quartz64-a-rk3566_defconfig` base, plus an EL3 monitor (BL31) compatible with the vendor 5.15 kernel.

> **BL31 sourcing note (2026-04-23).** We originally scoped TF-A BL31 from source (v2.12.0, PLAT=rk3568). Hardware validation on the Workbench LD1001 proved that the vendor 5.15 kernel hangs silently after `Starting kernel ...` on that BL31 — consistent with the kernel calling Rockchip-vendor SIP SMCs that upstream TF-A v2.12.0 does not implement. Phase 3 therefore uses rkbin's prebuilt `rk3568_bl31_v1.43.elf` (the canonical version referenced by rkbin's own `RKTRUST/RK3568TRUST.ini`). The TF-A source build is kept enabled because `BR2_TARGET_UBOOT_NEEDS_ATF_BL31` force-selects it, but its output is unused — U-Boot's make opts link rkbin's BL31 instead. This will be revisited when Phase 2 (mainline kernel) lands and vendor SMCs are no longer required. See Constants (§10.1).

**Deliverables:**
- `BR2_TARGET_UBOOT` + `BR2_TARGET_ARM_TRUSTED_FIRMWARE` + `BR2_PACKAGE_ROCKCHIP_RKBIN` enabled in defconfig.
- `board/linxdot/uboot/linxdot.fragment` with OTA-specific U-Boot config (1.5 Mbaud, env in MMC at 0xE00000, `CONFIG_BOOTCOUNT_LIMIT`, slot-aware bootcmd).
- `board/linxdot/uboot/env.txt` default env with `altbootcmd`.
- `board/linxdot/boot.cmd` compiled to `boot.scr`.
- `genimage.cfg` updated to GPT + A/B layout.

**Exit criteria:** Device boots from built U-Boot; deliberately-broken slot triggers `altbootcmd` rollback automatically; `fw_setenv` / `fw_printenv` work from userspace.

### 3.4 Phase 4 — OTA update layer (in progress, branch `OTA`)

**Scope:** Layer SWUpdate + signed `.swu` bundles + boot-time polling of GitHub Releases on top of Phase 3.

**Deliverables:**
- SWUpdate enabled with signature verification against `/etc/swupdate/public.pem`.
- `sw-description` template declaring `target-A` / `target-B` selections (writes to the inactive slot, sets `boot_slot` + `upgrade_available=1`).
- `/usr/sbin/ota-check` CLI: fetch manifest, compare version, download `.swu`, invoke SWUpdate, reboot.
- `S99otacheck` boot-time hook (runs 60 s post-boot in background).
- `S98confirm` health gate.
- CI extensions: produce signed `.swu`, emit `manifest.json` with `{ version, url, sha256 }`, upload alongside factory image.

**Exit criteria:** Tagged release on GitHub is picked up by a deployed device within one boot cycle; healthy update commits, broken update rolls back without human intervention.

### 3.5 Phase 5 — Curated in-tree DTS (planned)

**Scope:** Replace vendor `rk3566-linxdot.dtb` with an in-tree DTS the community can audit and modify. Enables full bootarg control and removes the last vendor binary.

**Exit criteria:** All peripherals functional from in-tree DTS, no vendor DTB required.

## 4. Functional Requirements

### 4.1 Functional Requirements (FR)

#### Gateway function
- **FR-1.1** [Must]: The system shall run exactly one Basics Station container configured for SX1302 on SPI at `/dev/spidev0.0`.
- **FR-1.2** [Must]: The system shall read the LoRaWAN gateway EUI from the SX1302 concentrator chip (not from `eth0`).
- **FR-1.3** [Must]: The system shall connect to a TTN cluster via WebSocket+TLS using the Basics Station LNS protocol.
- **FR-1.4** [Must]: The system shall use the TC (Thing Configuration) key from `/data/basicstation/tc_key.txt` to authenticate with TTN.
- **FR-1.5** [Should]: The system shall support at minimum the TTN regions `eu1`, `nam1`, `au1` by changing `TTS_REGION` in `/data/docker-compose.yml`.

#### Provisioning & configuration
- **FR-2.1** [Must]: On first boot the system shall create `/data/basicstation/tc_key.txt` as a placeholder template until the operator populates it.
- **FR-2.2** [Must]: The system shall derive a stable Ethernet MAC address from the eMMC CID so DHCP leases survive reflashes.
- **FR-2.3** [Must]: The system shall obtain an IPv4 address via DHCP on `eth0`.
- **FR-2.4** [Should]: The system shall synchronise time via NTP before TLS connections are attempted.

#### Over-the-Air updates (Phase 4)
- **FR-3.1** [Must]: The system shall poll `https://github.com/SensorsIot/Linxdot-Hotspot/releases/latest/download/manifest.json` 60 seconds after boot and compare the `version` field against `/etc/os-release VERSION_ID`.
- **FR-3.2** [Must]: The operator shall be able to trigger an update check manually via `ssh root@<device> ota-check` without rebooting.
- **FR-3.3** [Must]: When a newer version is available the system shall download the `.swu` bundle, verify its sha256 against the manifest, and apply it to the currently-inactive A/B slot via SWUpdate.
- **FR-3.4** [Must]: After staging an update the system shall set `boot_slot=<inactive>`, `upgrade_available=1`, `bootcount=0` in the U-Boot environment and reboot.
- **FR-3.5** [Must]: If `/etc/swupdate/public.pem` is present the system shall refuse to apply `.swu` bundles whose `sw-description` signature does not verify against it.
- **FR-3.6** [Must]: Before staging a new update the system shall verify `upgrade_available=0` (current slot committed); if still `1`, `ota-check` shall refuse to run.
- **FR-3.7** [Should]: `ota-check` shall log all actions and errors to `logger -t ota` (syslog).

#### Rollback (Phase 4)
- **FR-4.1** [Must]: `S98confirm` shall detect trial-boot state (`upgrade_available=1`) and wait up to 120 s for Basics Station to appear as a running Docker container before committing the slot.
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

### 4.2 Non-Functional Requirements (NFR)

- **NFR-1.1** [Must]: A successful OTA update (download, apply, commit) shall complete in under 5 minutes on a typical home broadband connection.
- **NFR-1.2** [Must]: A failed trial boot shall roll back to the prior slot without any operator action.
- **NFR-1.3** [Must]: The root filesystem shall be mounted read-only; all persistent writes shall be confined to `/data`.
- **NFR-2.1** [Must]: OTA bundles shall be cryptographically signed (RSA-4096) in production deployments.
- **NFR-2.2** [Must]: The system shall not embed signing private keys in the rootfs.
- **NFR-2.3** [Should]: The system shall not expose any unauthenticated network service other than SSH and the Basics Station outbound WebSocket.
- **NFR-3.1** [Should]: Boot to "Basics Station connected to TTN" shall complete in under 2 minutes on warm boot.
- **NFR-4.1** [Should]: The build system shall be fully reproducible from the `BR2_EXTERNAL` tree plus a pinned Buildroot LTS version.
- **NFR-4.2** [Should]: Reproducibility: Phase 3+ builds all security-critical components (U-Boot, TF-A, BL31) from source with pinned versions. The Rockchip DDR TPL blob is the only proprietary component and cannot be replaced on RK356x.

### 4.3 Constraints

- **C-1** The RK3566 BootROM expects the SPL (idbloader) at eMMC sector 64 (32 KiB) and the FIT image (U-Boot + BL31) at sector 16384 (8 MiB). These offsets are fixed by silicon. Phase 3+ writes a single unified `u-boot-rockchip.bin` at offset 32 KiB whose internal layout places both sub-parts at the required absolute offsets.
- **C-2** The vendor DTB (`rk3566-linxdot.dtb`) declares `stdout-path = "serial2:1500000n8"`; while this DTB is used, console must remain at 1.5 Mbaud. Phase 5 (in-tree DTS) lifts this constraint.
- **C-3** A Rockchip DDR init blob from rkbin (`rk3568_ddr_*_v1.xx.bin`) is unavoidable on RK356x — fully FOSS boot is not possible.
- **C-4** The bootloader blob (`u-boot-rockchip.bin`, covering SPL + FIT with BL31 + U-Boot) is **not** updated by OTA. It remains as first written at factory-flash time. Updating it would require a new factory image and `rkdeveloptool`. This is intentional: there is no redundant bootloader slot, so a bad bootloader write would brick the device.
- **C-5** Devices flashed with the pre-A/B (Phase 1) image cannot receive OTA updates. A one-time `rkdeveloptool` reflash with the A/B image is required to migrate. `/data` is recreated on reflash; `tc_key.txt` must be backed up beforehand.
- **C-6** WiFi firmware (`firmware/brcm/`) is not distributable under the Broadcom licence and must be extracted from a CrankkOS image locally before building a WiFi-capable variant.

## 5. Risks, Assumptions & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Mainline U-Boot lacks a Linxdot-specific peripheral quirk | Medium | High | Start from `quartz64-a-rk3566_defconfig`, iterate; keep vendor U-Boot blob as fallback until Phase 3 validated on hardware. |
| OTA bundle signature mismatch bricks all deployed devices after key rotation | Low | High | Ship new public key in firmware image *before* rotating the private key; rotation procedure documented in § 7.5. |
| Partial `.swu` download corrupts slot | Low | Low | SWUpdate verifies sha256 of each image before committing; `upgrade_available` is not set on failed download. |
| `S98confirm` health gate false-negative (Basics Station slow to connect) | Medium | Medium | 120 s wait; can be tuned in the init script. Worst-case outcome is a rollback to the prior known-good slot, which is recoverable. |
| Private signing key leaks | Low | High | Key stored only in GitHub Actions secret (`OTA_SIGNING_KEY`). Rotation procedure in § 7.5. Devices only trust the baked-in public key. |
| `host-tools.tar.gz` bundles runner libc via unfiltered `ldd` (base-build job) and the release job `sudo cp`s it into `/usr/local/lib/` + runs `ldconfig` | High (already observed 2026-04-23) | High | genimage's only non-system dep is `libconfuse2`; filter `ldd` to non-system libs **or** drop the bundle and `apt-get install libconfuse2` on the release runner. Never replay the release install step inside the devcontainer — Debian trixie's `/bin/sh` will SIGFPE against an Ubuntu 22.04 libc (`GLIBC_2.38 not found`). See § 7.2. |
| EL3 is now a Rockchip vendor binary (`rk3568_bl31_v1.43.elf` from rkbin) instead of TF-A v2.12.0 built from source | Medium | Medium | Accepted for Phase 3 to unblock vendor 5.15 kernel (see §3.3). Pin the exact rkbin file path in defconfig + Buildroot snapshot. No CVE response channel; mitigation is to revisit once Phase 2 (mainline kernel) removes the dependency on Rockchip-vendor SIP SMCs and source TF-A can be re-adopted. |

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

## 6. Interface Specifications

### 6.1 External Interfaces

| Interface | Direction | Protocol | Endpoint |
|---|---|---|---|
| TTN LNS | Outbound | Basics Station over WebSocket+TLS | `wss://<cluster>.cloud.thethings.network` |
| OTA manifest poll | Outbound | HTTPS GET | `https://github.com/SensorsIot/Linxdot-Hotspot/releases/latest/download/manifest.json` |
| OTA bundle download | Outbound | HTTPS GET | URL from manifest `url` field |
| SSH | Inbound | SSH (Dropbear) | TCP 22 |
| Serial console | Bidirectional | UART (8N1, 1.5 Mbaud) | ttyS2 @ 3.5 mm TRRS jack, also `rfc2217://192.168.0.87:4003` via Workbench |
| Device provisioning (flashing) | Inbound | Rockchip USB (rkusb) | USB-C on device, Loader or Maskrom mode |

### 6.2 Internal Interfaces

- **U-Boot ↔ Linux**: `/etc/fw_env.config` tells `libubootenv` where the env partition lives (`/dev/mmcblk0` @ `0xE00000`, 64 KiB, redundant at `0xE10000`). Must match `CONFIG_ENV_OFFSET` / `CONFIG_ENV_SIZE` / `CONFIG_ENV_OFFSET_REDUND` in `board/linxdot/uboot/linxdot.fragment`.
- **OTA agent ↔ SWUpdate**: `ota-check` invokes `swupdate -i update.swu -e stable,linxdot-ld1001,target-<B|A>`.
- **SWUpdate ↔ U-Boot env**: via `libubootenv`'s bootloader handler to set `boot_slot`, `upgrade_available`, `bootcount`.
- **Basics Station ↔ SX1302**: SPI on `/dev/spidev0.0` (via Docker device passthrough).
- **Docker ↔ persistent storage**: `/data/docker` (data-root), not `/var/lib/docker`.

### 6.3 Data Models / Schemas

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

## 7. Operational Procedures

### 7.1 Build

```
cd buildroot   # Buildroot 2024.02.8 extracted here
make BR2_EXTERNAL=$(pwd)/.. linxdot_ld1001_defconfig
make -j$(nproc)
# Output: output/images/linxdot-basics-station.img
```

First build takes ~1 hour (downloads toolchain, all source tarballs). Subsequent builds use ccache and `buildroot/dl/` cache.

### 7.2 Release (maintainer)

1. `git tag v1.2.3 && git push --tags`.
2. CI pipeline (see `.github/workflows/build.yml`):
   - Validate: shell syntax, OTA static tests (`tests/test_consistency.sh`, `tests/test_ota_state_machine.sh`).
   - `detect-changes`: compare hash of base-affecting files against stored hash from `base-latest` release.
   - `base-build` (only if changed, ~1 h): full Buildroot rebuild → uploads `rootfs.tar.xz` + `host-tools.tar.gz` to `base-latest` prerelease.
   - `release` (~3 min): download cached base, apply overlay, run `post-build.sh` + `post-image.sh`, validate image, build signed `.swu` if `OTA_SIGNING_KEY` secret is set, emit `manifest.json`, upload `.img.xz` + `.swu` + `manifest.json` to the tagged release.

> **Do NOT replay the `release` job's "Install host tools" step locally (especially inside the devcontainer).** `host-tools.tar.gz` is currently built with an unfiltered `ldd` loop (`.github/workflows/build.yml` Bundle host tools step) that includes `libc.so.6` and `ld-linux-x86-64.so.2` from the Ubuntu 22.04 runner. The release job then `sudo cp`s them into `/usr/local/lib/` and runs `ldconfig`, which fatally downgrades the libc seen by `/bin/sh` on any newer distro (symptom: `Floating point exception` + `GLIBC_2.38 not found`, container fails to start). `genimage`'s only non-apt dependency is `libconfuse2` — install that instead. This CI behaviour is tracked in the risk table (§5).

### 7.3 First-time flashing

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

### 7.4 Migration from pre-A/B (Phase 1 → Phase 3+)

Single-slot Phase 1 devices **cannot** receive OTA. One-time reflash required:

1. `ssh root@<device>` and back up `/data/basicstation/tc_key.txt` (and any custom `/data/docker-compose.yml`).
2. Follow § 7.3 with the first A/B-layout release image.
3. Re-populate `/data/basicstation/tc_key.txt` with the saved key.
4. All subsequent updates arrive via OTA — no further case-opens.

### 7.5 OTA signing key lifecycle

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

### 7.6 Manual OTA trigger

```
ssh root@<device> ota-check
```

Same logic as boot-time `S99otacheck` — no reboot required. Refuses to run if `upgrade_available=1` (current slot not yet committed).

### 7.7 Region change

```
ssh root@<device>
vi /data/docker-compose.yml       # change TTS_REGION: eu1 / nam1 / au1
/etc/init.d/S80dockercompose restart
```

### 7.8 Recovery procedures

| Situation | Action |
|---|---|
| Device boots old slot unexpectedly | Check `fw_printenv boot_slot bootcount upgrade_available`. If `boot_slot` differs from last known + logs show OTA attempt, rollback fired — diagnose via `logger -t ota` entries. |
| `upgrade_available=1` stuck after successful TTN connection | `S98confirm` didn't run or crashed. Manually: `fw_setenv upgrade_available 0; fw_setenv bootcount 0`. |
| Neither slot boots | U-Boot recovery. If U-Boot is healthy, interrupt with Ctrl-C at serial, `rockusb 0 mmc 0`, reflash via `rkdeveloptool`. |
| Corrupt U-Boot env | Env is redundant (primary + backup). If both corrupted, default env is used (device still boots slot A but lacks rollback state). `fw_setenv` writes fresh values on next boot. |
| `rkdeveloptool` needed but case is sealed | Enter download mode from serial: Ctrl-C to U-Boot, `rockusb 0 mmc 0` (requires pre-routed USB cable per § 7.3 Option B). |

## 8. Verification & Validation

### 8.1 Phase 1 verification

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

### 8.2 Phase 3 verification

| Test ID | Feature | Procedure | Expected |
|---|---|---|---|
| TC-3.1 | Static env consistency | `sh tests/test_consistency.sh` on CI | Offsets agree across fragment, fw_env.config, genimage.cfg |
| TC-3.2 | OTA state machine | `sh tests/test_ota_state_machine.sh` | All 10 simulated scenarios pass (healthy boots, transient hangs, trial-boot commit, rollback both directions, bootlimit edge) |
| TC-3.3 | Built U-Boot boots | Flash built image, observe serial | Reaches Linux login using Buildroot-produced `u-boot-rockchip.bin` (unified SPL + FIT + BL31) |
| TC-3.4 | `fw_setenv` from Linux | `fw_setenv test_var hello; fw_printenv test_var` on device | Writes and reads back correctly |
| TC-3.5 | Healthy-slot transient resilience | Force enough reboots to exceed `bootlimit` without committing (simulate crash before `S98confirm` on slot A) | `altbootcmd` fires, resets `bootcount`, slot remains A (not flipped) |
| TC-3.6 | Rollback on broken slot | Install garbage to rootfs_b, `fw_setenv boot_slot B upgrade_available 1 bootcount 0`, reboot | U-Boot tries B, fails N times, `altbootcmd` flips to A, device boots A |

### 8.3 Phase 4 verification

| Test ID | Feature | Procedure | Expected |
|---|---|---|---|
| TC-4.1 | SWU packaging | `sh tests/test_swu_packaging.sh` | CPIO archive built, `sw-description` is first entry, sha256 placeholders substituted |
| TC-4.2 | Image layout | `IMAGE=... sh tests/test_image_layout.sh` | 5 partitions, boot_a at 16 MiB, non-empty SPL region at 32 KiB and env region at 14 MiB |
| TC-4.3 | Signature required | Generate keypair, sign release, flash; publish unsigned release next | Device refuses unsigned bundle, `swupdate` logs signature failure |
| TC-4.4 | End-to-end happy path | Device on v0.1.0, publish v0.1.1, wait 60 s after boot | `S99otacheck` fetches manifest, downloads, writes inactive slot, reboots; `S98confirm` commits; `fw_printenv boot_slot` matches target, `os-release VERSION_ID=0.1.1` |
| TC-4.5 | End-to-end rollback | Device on v0.1.1 (committed), publish deliberately-broken v0.1.2 | Device attempts v0.1.2, fails, `altbootcmd` rolls back to v0.1.1 within `bootlimit` cycles |
| TC-4.6 | Manual trigger | `ssh root@<device> ota-check` | Same flow as boot-time, runs in foreground |

### 8.4 Traceability Matrix

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
| FR-3.1 | Must | TC-4.4 | Covered |
| FR-3.2 | Must | TC-4.6 | Covered |
| FR-3.3 | Must | TC-4.1, TC-4.4 | Covered |
| FR-3.4 | Must | TC-3.2, TC-4.4 | Covered |
| FR-3.5 | Must | TC-4.3 | Covered |
| FR-3.6 | Must | TC-3.2 | Covered |
| FR-3.7 | Should | TC-4.4 (logs visible) | Covered |
| FR-4.1 | Must | TC-4.4 | Covered |
| FR-4.2 | Must | TC-3.4, TC-4.4 | Covered |
| FR-4.3 | Must | TC-3.2 | Covered |
| FR-4.4 | Must | TC-3.2, TC-3.5 | Covered |
| FR-4.5 | Must | TC-3.5 | Covered |
| FR-4.6 | Must | TC-3.6, TC-4.5 | Covered |
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

## 9. Troubleshooting

| Symptom | Likely cause | Diagnostic | Corrective action |
|---|---|---|---|
| Can't enter flash mode | Wrong button / charge-only cable | Check USB enumeration on host (`lsusb`) | Use BT-Pair button + data cable; try longer hold (up to 10 s) |
| No network after boot | Ethernet unplugged before boot, or DHCP slow | `ip addr show eth0`; check router leases | Plug Ethernet before powering; reboot |
| `TC_KEY: NOT CONFIGURED` | `tc_key.txt` placeholder still in place | `cat /data/basicstation/tc_key.txt` | Replace file with real key; `/etc/init.d/S80dockercompose restart` |
| `EUI Source: eth0` (not `chip`) | Concentrator not reset before container start | `docker logs basicstation` | `/opt/packet_forwarder/tools/reset_lgw.sh.linxdot start`; `docker-compose restart` |
| Gateway not connecting to TTN | Bad API key, wrong region, firewall | `docker logs basicstation` | Verify key and region; open outbound 443 |
| OTA never triggers | Device still on Phase 1 single-slot image | `fw_printenv` returns error | Migrate per § 7.4 |
| OTA triggers but rolls back | New slot fails health gate | Serial console during trial boot: check kernel panic, init errors, Docker failures | Fix underlying issue in firmware, re-release |
| `upgrade_available=1` stuck | `S98confirm` didn't run or crashed | `logger -t ota` entries | `fw_setenv upgrade_available 0; fw_setenv bootcount 0` |
| Can't boot either slot | Bootloader broken or both slots corrupted | Serial console for U-Boot output | `rockusb` from U-Boot prompt; reflash via `rkdeveloptool` |

## 10. Appendix

### 10.1 Constants

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

### 10.2 Extraction from CrankkOS (historical, Phase 1 bring-up)

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

### 10.3 Useful commands

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

### 10.4 Repository layout

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

## 11. Open Items / Backlog

Consolidated list of work remaining per phase. Close an item by deleting its line (with the commit that closes it). Cross-reference FR/NFR/TC IDs where applicable; the state flags are:

- **`[ ]`** open — not started or not yet verified
- **`[~]`** in progress / partial
- **`[x]`** done (keep briefly for visibility, prune when a phase closes)

### 11.1 Phase 3 — Bootloader from source

**Software / CI (closed):**
- [x] TF-A v2.12.0 pinned; rk3568 plat builds
- [x] U-Boot 2024.04 on `quartz64-a-rk3566` with `linxdot.fragment` (baud, env, bootcount, slot-aware bootcmd)
- [x] Unified `u-boot-rockchip.bin` flow (SPL + FIT + BL31)
- [x] rkbin DDR TPL pinned to `rk3568_ddr_1560MHz_v1.18.bin`
- [x] CI end-to-end green (base-build + release) — run 24827994009, 2026-04-23
- [x] TC-3.1 consistency tests (`tests/test_consistency.sh`) — runs in CI validate
- [x] TC-3.2 state machine simulation (`tests/test_ota_state_machine.sh`) — runs in CI validate

**Hardware validation (open — FSD §3.3 exit criteria):**
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

### 11.2 Phase 4 — OTA update layer

**Software scaffolding (present — verified end-to-end on rc12+):**
- [x] `ota-check` script (FR-3.1, FR-3.2, FR-3.3, FR-3.7) — in `board/linxdot/overlay/usr/sbin/ota-check`.
- [x] `S99otacheck` boot-time hook (FR-3.1) — in overlay init.d.
- [x] `S98confirm` health gate (FR-4.1, FR-4.2) — in overlay init.d (configurable via `/data/ota.conf`).
- [x] `sw-description.tmpl` (FR-3.3, FR-3.5) — in `board/linxdot/swupdate/`. Flat 2-level layout (`software.stable.target-{A,B}`).
- [~] `scripts/gen-signing-key.sh` (FR-3.5, signing-key lifecycle) — keypair generator (CI integration pending — gates TC-4.3).
- [x] CI `.swu` build + `manifest.json` (with `size` field for pre-flight) emission — exercised on rc11→rc12.

**Hardware validation (in progress on Workbench LD1001):**
- [x] **TC-4.1** SWU packaging static test (`tests/test_swu_packaging.sh`) — CI green from rc1 onward.
- [x] **TC-4.2** Image-layout partition check (`tests/test_image_layout.sh`) — CI green from rc1 onward.
- [ ] **TC-4.3** Signature required — pending keypair deployment + `CONFIG_SIGNED_IMAGES=y`.
- [~] **TC-4.4** End-to-end happy path — SWUpdate apply path PROVEN end-to-end on rc11→rc12 (slot B booted with VERSION_ID=0.4.0-rc12, boot env staged correctly). Auto-commit blocked by two latent bugs fixed in `e3e77d8` (rc13): S98confirm `pgrep`/busybox mismatch and overlayfs slot-portability — full sign-off pending rc13→rc14 retest.
- [ ] **TC-4.5** End-to-end rollback — pending TC-4.4 close.
- [x] **TC-4.6** Manual trigger (`ssh root@<device> ota-check`) — exercised in rc7 / rc11; flow matches FR-3.2.

**Session-6 learnings captured in code (commits `c36c7e8`, `09cf861`, `a983d88`, `aa01e4f`, `b3ccf3e`, `fc79f0d`, `0e4cbf5`, `e3e77d8`):**

The Phase 4 hardware bring-up peeled four nested SWUpdate-config bugs and two userspace bugs, none of which any prior CI signal caught. Each got a matching test_consistency.sh check on the way out so the same drift is caught at PR-time instead of "swupdate rejects bundle on hardware" time.

- **SWUpdate Kconfig name discipline.** Upstream's bootloader Kconfig is just `CONFIG_UBOOT` (not `CONFIG_BOOTLOADER_UBOOT`); `CONFIG_LIBCONFIG=y` requires `HAVE_LIBCONFIG` from a Buildroot-level `BR2_PACKAGE_LIBCONFIG=y`. `olddefconfig` silently drops misnamed symbols — an earlier swupdate.config shipped with `BOOTLOADER_NONE=y, SSL_IMPL_NONE=y, no LIBCONFIG`, so swupdate parsed nothing and rejected every bundle. *No build-time error, no runtime hint until you read the trace and see "Registered bootloaders: none loaded".*
- **Selector splits at FIRST comma only, then joins with `.`.** SWUpdate's `parse_image_selector` (`core/parser.c`) takes `-e <set>,<mode>` and assigns `set = first segment`, `mode = entire remainder including any further commas`. The libconfig parser then constructs path `software.<set>.<mode>` and runs a single `config_lookup` (`corelib/parsing_library_libconfig.c::find_root_libconfig` → `mstrcat(nodes, ".")`). A nested `software.stable.linxdot-ld1001.target-B` group is unreachable from selector `stable,linxdot-ld1001,target-B` — that asks for `software → stable → "linxdot-ld1001,target-B"` (a single key with embedded comma). Flatten sw-description so `<mode>` is a single libconfig key.
- **Bootloader plugin ≠ bootloader handler.** `CONFIG_UBOOT=y` registers the libubootenv-backed *plugin* that knows how to talk to the U-Boot env. It does NOT register an *image handler* for `bootenv:` sections in sw-description. `core/parser.c:184` requires `find_handler("uboot")` or `find_handler("bootenv")` before accepting any bundle that touches the bootloader env — both come from `handlers/boot_handler.c`, gated on a separate `CONFIG_BOOTLOADERHANDLER=y`. Without it, parse-time error is `"bootloader support absent but sw-description has bootloader section!"` even though `print_registered_bootloaders` says `uboot loaded`.
- **busybox userspace lacks `pgrep`.** `S98confirm`'s health check called `pgrep dockerd >/dev/null 2>&1`. Buildroot's busybox ships `pidof` but not `pgrep`. Result: `pgrep` returned 127 (command not found), shell saw non-zero, `is_healthy` returned false, S98confirm logged "FAILED" and queued a rollback after the 60 s timeout — even though dockerd was running fine. `pidof dockerd >/dev/null 2>&1` is the busybox-friendly fix. Static check now greps every overlay shell script for a stray `pgrep`.
- **Overlayfs slot-portability needs `index=off,xino=off,redirect_dir=off`.** A/B layouts share one /data partition (overlay upper) but flip between two rootfs partitions (overlay lower) at every commit. With default `index=on/xino=on`, overlayfs caches origin file-handle hints from the FIRST mount's lowerdir; on slot-B's first boot the lowerdir is a different ext4 fs with different inodes, and the kernel rejects the mount with `failed to verify upper root origin / err=-116 (ESTALE)`. /usr, /var/lib, /etc all stay read-only and S98confirm can't even rewrite scripts. Fix in `S01mountall::mount_overlay` adds the three `*_off` options. Static check requires both `index=off` and `xino=off` in any `mount -t overlay` line (multi-line continuation handled).
- **`/var/log -> ../tmp` symlink + S01mountall overlay collision** (rc5). Mounting an overlay at `/var/log` resolves through the symlink onto `/tmp`, replacing the S00datapart tmpfs with a `/data`-backed overlay. 500 MB OTA downloads then fill `/data`'s 487 MiB. `S01mountall` no longer overlays `/var/log` — log files live in tmpfs and are intentionally lost across reboots. `ota-check` also gained a pre-flight check: refuse to download if `/tmp` free space < `manifest.size` (the `size` field added to `manifest.json` for this).
- **Concurrent `ota-check` race on `/tmp/update.swu`.** Boot-time `S99otacheck` (60 s after boot) and a manual `ota-check` both `rm -f /tmp/update.swu` before curl — the second invocation can unlink while the first is still curling, manifesting as `curl: (23) Failure writing output to destination`. Open: `flock` or PID guard around the download. Today's TC-4.4 retry succeeded on the second manual run after the boot job finished.
- **Vendor 5.15 kernel rejects genimage's metadata_csum'd `data.ext4`.** First boot of any fresh image hits `EXT4-fs error (mmcblk1p5): iget: checksum invalid` and `mount failed`. `S00datapart`'s `e2fsck -pf` + `resize2fs` recovers it on subsequent boots, but the FIRST boot of a fresh image lands without `/data` mounted (and therefore without overlays). Open: pass `-O ^metadata_csum,^metadata_csum_seed` to genimage's mke2fs invocation, or have `S00datapart` `mkfs.ext4 -F` if the first mount fails.
- **CI base hash must cover every file the release job re-applies.** The base-hash list in `.github/workflows/build.yml` gates the cached-rootfs reuse, but the release job re-applies `board/linxdot/overlay/`, `board/linxdot/swupdate/sw-description.tmpl`, `board/linxdot/genimage.cfg`, and `board/linxdot/post-image.sh` on every run — these are NOT in the base hash by design (they're part of the fast release pass), so they pick up changes without a 40-min full rebuild. `swupdate.config` IS in the base hash (it gates Buildroot's `make swupdate` recompile). Drift-debugging takeaway: when a fix to an overlay file appears not to take effect, the release log's "Applying overlay…" line is the source of truth, not the base build.
- **`swupdate.config` is the source of truth for the swupdate binary.** The buildroot package wrapper passes the kconfig file through `make olddefconfig` and links against host libs gated by `BR2_PACKAGE_*` env vars (HAVE_LIBSSL/HAVE_LIBCONFIG/HAVE_LIBUBOOTENV). Misnamed kconfig symbols are silently dropped; missing BR2 packages disable the corresponding feature even if the swupdate-side symbol is set. The pairing of the two has to be right for the binary to actually have the feature compiled in.

### 11.3 Phase 5 — Curated in-tree DTS (not started)

- [ ] Replace vendor `rk3566-linxdot.dtb` with in-tree DTS covering all peripherals (eth, WiFi, SPI for SX1302, eMMC, USB, UART2 @ 1.5 Mbaud).
- [ ] Remove C-2 console-baud constraint once DTS is in-tree.

### 11.4 Housekeeping

- [x] Hardware validation runbook — `Docs/phase3_hardware_validation.md`.
- [ ] Prune Phase 1 vendor blobs from `board/linxdot/blobs/` (`idbloader.img`, `u-boot.itb`) once Phase 3 is hardware-validated and the branch merges — currently kept as a rollback fallback for the pre-A/B migration path (C-5, §7.4).
- [ ] Migrate CLAUDE.md to describe the merged (Phase 3+) baseline once `OTA` → `main`.

