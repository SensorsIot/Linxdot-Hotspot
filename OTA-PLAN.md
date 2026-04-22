# OTA Implementation Plan

**Branch:** `OTA`
**Goal:** Deliver Ethernet-only over-the-air updates for the Linxdot LD1001, with bootloader-level auto-rollback on failure. No physical access (USB, buttons) required for any normal update.

**Status:** Code-complete for Phase 3 + Phase 4 layer. Runtime behaviour documented in `Docs/OTA.md`. Awaiting:
- Task 18 — BootROM secure-mode verification on hardware
- Task 8 — A/B rollback validation on hardware
- Task 16 — end-to-end OTA trial on hardware
- Task 10 — operator runs `scripts/gen-signing-key.sh` and uploads `OTA_SIGNING_KEY` to GitHub Actions secrets (unsigned `.swu` builds work but are dev-mode only)

---

## Why this needs two phases

The current boot stack uses vendor U-Boot 2017.09, which has known limitations documented in `CLAUDE.md`:

- `boot.scr` doesn't execute — boot currently goes through `extlinux.conf`, patched in by `post-image.sh:45-62`.
- No writable env partition in `genimage.cfg` — U-Boot runs on its compiled-in default env, so `fw_setenv` from Linux has no target.
- No scripted boot logic → no `bootcount` / `altbootcmd` → no bootloader-level rollback.

Auto-rollback on kernel panic is the single most important property of this OTA system. Without it, a bad update = truck roll with a screwdriver. We therefore build the bootloader first (Phase 3), then stack OTA on top (Phase 4).

---

## Phase 3 — Bootloader foundation

**Deliverable:** A device that boots from Buildroot-built U-Boot + TF-A, has a writable env partition, uses a scripted `boot.scr` with A/B slot selection, and demonstrably rolls back when the active slot fails to boot.

| # | Task | Notes |
|---|---|---|
| 1 | Investigate RK3566 mainline U-Boot + TF-A support | Verify upstream support for RK3566 / Linxdot peripherals. Identify any board-specific DTS or driver gaps. |
| 2 | Enable TF-A build | `BR2_TARGET_ARM_TRUSTED_FIRMWARE=y`, pin known-good version, produce BL31. |
| 3 | Enable U-Boot build | `BR2_TARGET_UBOOT=y`, produce `idbloader.img` + `u-boot.itb` in-tree. Removes dependency on `board/linxdot/blobs/`. |
| 4 | Add env partition to `genimage.cfg` | Raw partition, typically 64K primary + 64K redundant, at a fixed offset before `/data`. Add `/etc/fw_env.config` in overlay. |
| 5 | Migrate boot flow to `boot.scr` | Replace the extlinux.conf hack in `post-image.sh` with a proper compiled `boot.cmd` → `boot.scr`. |
| 6 | Add A/B slot layout to `genimage.cfg` | `boot_a`, `rootfs_a`, `boot_b`, `rootfs_b`, `data`, `env`. Factory image populates B with a copy of A so both slots are bootable on first power-up. |
| 7 | Configure bootcount + altbootcmd | Default env: `bootlimit=3`, `bootcount=0`, `upgrade_available=0`, `boot_slot=A`. `altbootcmd` flips slot, clears `upgrade_available`, saves env, resets. |
| 8 | Test A/B rollback on hardware | Install broken kernel in slot B, flip slot, verify U-Boot increments `bootcount`, exceeds `bootlimit`, runs `altbootcmd`, boots A. **Phase 3 exit criterion.** |

**Phase 3 gate:** task 8 must pass on real hardware before starting Phase 4. If rollback doesn't work, OTA is unsafe to ship.

**Bonus deliverables from Phase 3** (not required, but fall out naturally):
- 115200 baud console (vendor DTB constraint lifted once we own U-Boot + optionally the DTS).
- Deterministic MMC numbering (no more "U-Boot `mmc 0` = Linux `mmcblk1`" gotcha).
- Clean path to Phase 2 (kernel from source) later.

---

## Phase 4 — OTA layer

**Deliverable:** Tagged GitHub Releases publish a signed `.swu` update bundle alongside the factory image. Devices pick up updates at reboot (or via manual `ota-check` CLI), apply to the inactive slot, and U-Boot handles commit or rollback.

| # | Task | Notes |
|---|---|---|
| 9 | Enable SWUpdate in defconfig | `BR2_PACKAGE_SWUPDATE`, `BR2_PACKAGE_SWUPDATE_GET_ROOT_FROM_UBOOT_ENV`, `BR2_PACKAGE_U_BOOT_TOOLS`, `BR2_PACKAGE_CURL`. Enable signed-bundle verification. |
| 10 | Generate signing keypair | One-time. Public half → overlay (`/etc/swupdate/public.pem`). Private half → GitHub Actions secret `OTA_SIGNING_KEY`. Document rotation. |
| 11 | Write `sw-description` template | libconfig syntax declaring `rootfs.ext4`, `Image`, `rk3566-linxdot.dtb`, `boot.scr` with sha256s, target partitions selected by U-Boot env, HW compat string, version. |
| 12 | `S99confirm` init script | Runs late, gates on Basics Station TTN connectivity (or timeout fallback), then `fw_setenv upgrade_available 0 && fw_setenv bootcount 0`. |
| 13 | `S99ota-check` boot-time updater | Runs after `S99confirm`, only if `upgrade_available=0`. Fetches `manifest.json` from `releases/latest/download/`, compares version, downloads `.swu`, invokes `swupdate -i`, reboots. Runs in background so Basics Station isn't delayed. |
| 14 | `ota-check` CLI | Same logic callable over SSH. Lets operators update without rebooting first. |
| 15 | CI extensions | In `release` job: produce `.swu` via `cpio`, sign with `OTA_SIGNING_KEY`, generate `manifest.json`, upload alongside `.img.xz`. |
| 16 | End-to-end hardware test | Publish v1.0.1 from v1.0.0 device, verify apply + reboot + confirm. Then publish deliberately-broken v1.0.2, verify rollback. **Phase 4 exit criterion.** |
| 17 | Documentation | `BuildProcess.md` (U-Boot, env, A/B layout), `QuickStart.md` (`ota-check` CLI), new `Docs/OTA.md` (signing keys, migration, rollback diagnosis). |

---

## Delivery order and checkpoints

```
┌─ Phase 3 ───────────────────────────────────────┐
│ 1 → 2 → 3 → {4, 5} → 6 → 7 → 8 (hardware gate)   │
└──────────────────────────────────────────────────┘
                        │
                        ▼
┌─ Phase 4 ───────────────────────────────────────┐
│ 9 → 10 → 11 → {12, 13, 14} → 15 → 16 → 17        │
└──────────────────────────────────────────────────┘
```

Hardware validation after Phase 3 (task 8) is a hard gate. Phase 4 work is not useful if rollback isn't proven.

---

## Key risks and mitigations

| Risk | Mitigation |
|---|---|
| Mainline U-Boot doesn't support a Linxdot-specific peripheral (eMMC timing, GPIO, PMIC) | Task 1 investigates before we commit. Fallback: patch U-Boot with vendor-derived bits, document clearly. |
| Bricking the device during Phase 3 testing | Phase 3 is not over-the-air — USB/rkdeveloptool is still available during development. Hardware access is acceptable at this stage; we're locking the door behind ourselves as the last step. |
| Partition-layout change breaks existing factory-flashed devices | Existing devices need a one-time reflash to migrate to A/B layout. Document this in release notes for the version that introduces A/B. `/data` is preserved across reflash (it's partition 3 today and will remain the last partition). |
| Private signing key leaks | Rotate key (task 17 includes rotation procedure). Devices only trust the baked-in public key — a leaked private key can't push updates to already-deployed devices until they're reflashed with a new public key. Consider publishing a revocation manifest at some point. |
| Slow/flaky Ethernet during download | SWUpdate verifies sha256 before writing; partial downloads fail cleanly. `upgrade_available` never gets set, next reboot retries. |
| U-Boot env corruption | Use the redundant-env pair (primary + backup). U-Boot falls back to the good copy automatically. |

---

## Migration path for existing devices

Devices already running the current single-slot image cannot receive OTA. Path:

1. User downloads the first A/B release as `.img.xz` from the Release page.
2. Reflash via `rkdeveloptool` one final time.
3. `/data` is recreated but re-initialized on first boot (existing `S00datapart` logic). **User must back up `/data/basicstation/tc_key.txt` before reflashing if they want to preserve their TTN key.**
4. From that point on, updates are Ethernet-only.

This is a one-time cost, documented loudly in the release notes.

---

## Investigation results (task 1 — complete)

**Mainline U-Boot support:** solid since v2023.10. Buildroot 2024.02 LTS has all necessary plumbing.

**Concrete starting points confirmed:**
- **U-Boot defconfig base:** `quartz64-a-rk3566_defconfig` → fork to `linxdot-ld1001-rk3566_defconfig`. Quartz64-A is the most-copied RK3566 reference (LPDDR4 + eMMC, matches LD1001 profile).
- **TF-A:** `BR2_TARGET_ARM_TRUSTED_FIRMWARE=y`, `BR2_TARGET_ATF_PLATFORM=rk3568`. There is no separate `rk3566` platform in TF-A — every mainline RK3566 board uses `PLAT=rk3568`, which is the documented pattern.
- **DDR init blob:** `BR2_PACKAGE_ROCKCHIP_RKBIN=y`, point `ROCKCHIP_TPL` at `rk3568_ddr_1560MHz_v1.xx.bin`. Proprietary, unavoidable on RK356x.
- **U-Boot defconfig additions for OTA:** `CONFIG_BOOTCOUNT_LIMIT`, `CONFIG_BOOTCOUNT_ENV`, `CONFIG_ENV_IS_IN_MMC`, `CONFIG_CMD_BOOTCOUNT`, `CONFIG_BAUDRATE=1500000`.
- **Output format:** Buildroot emits `u-boot-rockchip.bin` (combined idbloader + itb) since U-Boot ~v2023.10. Older split `idbloader.img` + `u-boot.itb` flow still supported — keep split layout to match current `genimage.cfg` offsets (32K / 8M).

**Vendor DTB unaffected:** U-Boot's DTB is only for U-Boot itself. Kernel 5.15.104 keeps `rk3566-linxdot.dtb` as-is.

**Answered open questions:**
- Env storage: `CONFIG_ENV_IS_IN_MMC` with a dedicated raw partition between u-boot.itb (8M) and the first boot partition (16M) — ~1–2 MB available.
- BootROM / idbloader format: works with Buildroot-built idbloader **provided LD1001 BootROM is in non-secure mode** — see critical risk below.
- TF-A: rebuild from source (vendor BL31 not suitable for mainline U-Boot). `PLAT=rk3568`.
- Kernel: stays on vendor 5.15.104 through Phase 3 — confirmed the right scope call.

**Critical risk identified — hardware verification required before flashing:**
If the LD1001 BootROM is locked to secure mode, flashing unsigned mainline SPL/TPL bricks the device into MaskROM recovery. No mainline RK3566 board has shipped secure-locked, but Linxdot is a commercial gateway and this must be confirmed before task 3 flash-tests. Added as task 18.

**Additional gotchas to plan for:**
- 1,500,000 baud console is not a stock U-Boot preset — need `CONFIG_BAUDRATE=1500000` plus UART2 clock verification in the Linxdot U-Boot DTS.
- Board DTS required for U-Boot (`arch/arm/dts/rk3566-linxdot.dts` + `-u-boot.dtsi`) — pinmux for eMMC and UART2 is mandatory.
- BootROM expects idbloader at sector 64 (0x40 = 32 KiB), u-boot.itb at sector 16384 (0x4000 = 8 MiB). Current `genimage.cfg` already matches.

**Prior art:** None for LD1001 specifically. NebraLtd's helium-linxdot-rk3566 uses the same vendor U-Boot 2017.09 blob. Closest usable references: Kwiboo's [u-boot-build rk356x CI recipes](https://github.com/Kwiboo/u-boot-build/blob/main/.github/workflows/rk356x.yml) and Armbian's Radxa ZERO 3 port. Budget 1–2 weeks of bring-up; most of it will be MaskROM recovery cycles if the device supports it.

**Key source documents:**
- [U-Boot: doc/board/rockchip/rockchip.rst](https://github.com/u-boot/u-boot/blob/master/doc/board/rockchip/rockchip.rst)
- [TF-A: docs/plat/rockchip.rst](https://github.com/ARM-software/arm-trusted-firmware/blob/master/docs/plat/rockchip.rst)
- [Buildroot: boot/uboot/uboot.mk](https://github.com/buildroot/buildroot/blob/master/boot/uboot/uboot.mk)

---

## What's explicitly out of scope

- Updating `idbloader.img` or `u-boot.itb` via OTA. Even after Phase 3, bootloader updates remain manual-only unless we add a redundant bootloader slot. Keeping them frozen post-factory-flash is the right default for a no-button device.
- Push-based updates (SWUpdate `suricatta` mode). Polling GitHub Releases is enough.
- Delta updates. Full rootfs every time — simpler, signatures cover the whole bundle.
- A web UI for updates. CLI + automatic boot-time check is sufficient.
