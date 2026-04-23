# Phase 3 Hardware Validation Runbook

Operational procedure for signing off Phase 3 (source-built U-Boot + TF-A + A/B layout) against FSD §3.3 exit criteria. Runs on a non-production LD1001.

**Scope:** BootROM pre-flight → flash the Phase 3 image → execute FSD test cases TC-3.3 through TC-3.6 on hardware. Does **not** cover Phase 4 OTA tests (TC-4.x) — those run once Phase 3 passes.

**Artefacts:** `linxdot-emmc-image` from a successful CI run (e.g. GitHub Actions run 24827994009) or a local build per FSD §7.1. The file inside is `linxdot-basics-station.img.xz`.

**Exit criteria (FSD §3.3 line 129):**
1. Device boots from Buildroot-built U-Boot to Linux login.
2. Deliberately-broken slot triggers `altbootcmd` rollback automatically.
3. `fw_setenv` / `fw_printenv` work from userspace.

Every test below carries a **pass criterion**. If any fails, stop and escalate — do not re-flash without root-causing.

---

## 0. Prerequisites

- LD1001 dedicated to testing (not deployed). A successful run wipes `/data` — back up `tc_key.txt` and `docker-compose.yml` first if the device was in service.
- Serial console access at **1,500,000 baud, 8N1** (`board/linxdot/blobs/` DTB declares `stdout-path = "serial2:1500000n8"`; console must stay at 1.5 Mbaud for Phase 3, per FSD §4.3 C-2).
- Either: a host with direct USB-C cable access to the LD1001 download port, or the Workbench Pi (`192.168.0.87` per memory) with a routed USB cable per FSD §7.3 Option B.
- `rkdeveloptool` built and installed on the flashing host. Verify with `rkdeveloptool -v`.
- Clone of `rockchip-linux/rkbin` checked out locally for the SPL loader used in the pre-flight step:
  ```
  git clone https://github.com/rockchip-linux/rkbin
  # Use bin/rk35/rk3566_spl_loader_v1.xx.bin (match the rkbin commit Buildroot pins — b4558da0)
  ```

---

## 1. Pre-flight — BootROM non-secure-lock verification

**Why this is first.** A secure-locked BootROM will reject an unsigned Buildroot-built SPL. Because Phase 3 writes a new bootloader to eMMC as its first action, a rejected SPL at boot = bricked device recoverable only via MaskROM (hardware short across TP points inside the sealed case). No mainline RK3566 reference board ships secure-locked, but Linxdot is a commercial product and this **cannot** be assumed.

The test is non-destructive: `db` loads into RAM, nothing is written to eMMC.

### 1.1 Put the device into MaskROM / Loader mode

1. Power down the LD1001.
2. Hold the **BT-Pair** button near the antenna connector while applying power; keep held for 5 s.
3. On the host: `rkdeveloptool ld`. Expect a `DevNo=1 Vid=0x2207,Pid=0x350a,LocationID=... Loader` (or `Maskrom`) line.

### 1.2 Try to run a generic rkbin SPL loader

```
sudo rkdeveloptool db rkbin/bin/rk35/rk3566_spl_loader_v1.18.bin
```

**Pass:** host returns `Downloading bootloader succeeded.` Device UART emits a short SPL banner and hangs awaiting next stage (expected — no OS follows).

**Fail modes:**
- `rkdeveloptool` reports `download bootloader failed` → BootROM rejected the loader. Stop.
- Device hangs silently with no UART output → possibly secure-locked. Stop.

If this step fails, **do not flash the Phase 3 image**. Escalate — the device may require signed images, which is outside Phase 3 scope.

### 1.3 Reset the device

Power-cycle. The device returns to its previous bootloader (vendor U-Boot on a Phase 1 device) since `db` wrote nothing to eMMC.

---

## 2. Flash the Phase 3 image

Follow **FSD §7.3**. Option A requires case-open; Option B uses the Workbench Pi with a pre-routed USB cable.

```
xz -d linxdot-basics-station.img.xz
sudo rkdeveloptool ld                           # confirm Loader mode
sudo rkdeveloptool wl 0 linxdot-basics-station.img
sudo rkdeveloptool rd                           # reset; device reboots into new image
```

**Pass:** `wl` reports 100 % write, `rd` returns success, device reboots.

---

## 3. TC-3.3 — Built U-Boot boots to Linux login

### Procedure

Capture serial console from the moment `rkdeveloptool rd` fires. Power-cycle if needed to observe a cold boot.

### Pass criteria

UART shows this sequence (abbreviated):

1. **BootROM** — brief identification line (`Rockchip bootloader` or similar).
2. **SPL** — `U-Boot SPL 2024.04 (...)`, DDR training output from the rk3568 TPL blob (`rk3568_ddr_1560MHz_v1.18`), `Trying to boot from MMC1`.
3. **TF-A BL31** — `NOTICE:  BL31: v2.12.0 ...`, `NOTICE:  BL31: Built : ...`.
4. **U-Boot proper** — `U-Boot 2024.04 (...)`, environment read from MMC at 0xE00000 (look for no `*** Warning - bad CRC, using default environment`).
5. **Slot-aware bootcmd** — loads `boot.scr` from partition 1 (slot A), sources it, loads `Image` + `rk3566-linxdot.dtb`.
6. **Kernel** — standard Linux boot to `localhost login:`.

All of: (a) TF-A v2.12.0 banner, (b) U-Boot 2024.04 banner, (c) no bad-CRC env warning, (d) login prompt reached — **all four required** for TC-3.3 to pass.

---

## 4. TC-3.4 — `fw_setenv` / `fw_printenv` from userspace

### Procedure

Log in at the serial console (`root` / `linxdot`).

```
fw_printenv boot_slot bootcount bootlimit upgrade_available
fw_setenv test_tc34 hello
fw_printenv test_tc34
fw_setenv test_tc34                # clears it
fw_printenv test_tc34 2>&1 | grep -q "not defined" && echo "cleared OK"
```

### Pass criteria

- First `fw_printenv` returns the four vars without error (values typically `boot_slot=A`, `bootcount=0` or low integer, `bootlimit=3`, `upgrade_available=0`).
- Write + read-back of `test_tc34` round-trips to `hello`.
- Clear + re-read prints `test_tc34 not defined` (normal for absent vars).
- `/etc/fw_env.config` offsets match the fragment (verify with `cat /etc/fw_env.config` — should show `/dev/mmcblk0 0xE00000 0x10000` and `0xE10000 0x10000`).

---

## 5. TC-3.5 — Healthy-slot transient resilience

### Procedure

Simulate crashes before the `S98confirm` commit on a healthy slot A. Goal: show `altbootcmd` **does not** flip slot when `upgrade_available=0` (FR-4.5).

At serial:
```
fw_setenv bootcount 2
fw_setenv upgrade_available 0
fw_printenv boot_slot upgrade_available bootcount bootlimit
reboot
```

Let U-Boot boot naturally. Then force another reboot before `S98confirm` runs (e.g. interrupt kernel boot with a hard power cycle):

```
# after next boot, immediately:
reboot -f
```

### Pass criteria

- After the simulated crashes (at least `bootlimit + 1` = 4 total reboots where `bootcount` >= `bootlimit`), `altbootcmd` fires at U-Boot prompt and you observe it in serial.
- `altbootcmd` takes the `upgrade_available=0` branch: resets `bootcount=0`, does **not** flip `boot_slot`.
- `fw_printenv boot_slot` still returns `A` after the storm.

If `boot_slot` flips to `B` with `upgrade_available=0`, that's a bug in `env.txt` altbootcmd — re-read FR-4.5, fix the condition.

---

## 6. TC-3.6 — Rollback on broken slot (the signature test)

### Procedure

Deliberately break slot B and verify U-Boot rolls back to A. `/data` is preserved across the break; no operator intervention needed.

At serial (slot A booted, session open):
```
# Corrupt rootfs_b so it cannot mount
dd if=/dev/urandom of=/dev/mmcblk0p4 bs=1M count=4 conv=fsync

# Arm a trial boot into B
fw_setenv boot_slot B
fw_setenv upgrade_available 1
fw_setenv bootcount 0
fw_printenv boot_slot upgrade_available bootcount
reboot
```

### Pass criteria

- U-Boot boots into slot B (observe `setenv bootpart 3` path in serial), kernel tries to mount `/dev/mmcblk0p4`, fails (filesystem corrupt), kernel panics or hangs.
- U-Boot's boot-count limit kicks in after `bootlimit` (3) failed attempts.
- On the 4th boot, U-Boot runs `altbootcmd`, which takes the `upgrade_available=1` branch:
  - Flips `boot_slot` from `B` to `A`.
  - Sets `upgrade_available=0`.
  - Resets `bootcount=0`.
  - Saves env, runs `bootcmd` → boots slot A.
- System reaches `localhost login:` on slot A without human intervention.
- Post-recovery: `fw_printenv boot_slot upgrade_available bootcount` → `A / 0 / 0 (or small int)`.

**This single test is the whole Phase 3 deliverable.** If TC-3.6 passes, Phase 3 has delivered its value — bootloader-level auto-rollback works without any userspace help.

### Cleanup

Re-write rootfs_b to a valid state (write a fresh `rootfs.ext4` to `/dev/mmcblk0p4`) before leaving the device in a healthy state. Or re-flash from scratch.

---

## 7. Sign-off

Phase 3 is closed when **all four** of the following hold:

- [ ] BootROM pre-flight (§1) passed (or explicitly waived with documented justification).
- [ ] TC-3.3, TC-3.4, TC-3.5, TC-3.6 each passed (§§3–6).
- [ ] Serial-console captures for all four TCs archived (e.g. `ssh log` redirected to file, or `screen` logfile). These are audit evidence for FR-4.x traceability.
- [ ] §11 backlog in `Docs/linxdot_fsd.md` has those four items moved from `[ ]` to `[x]`, and this runbook's open item is struck.

Phase 4 (TC-4.x — OTA) may then begin.

---

## 8. Known pitfalls during validation

- **Env CRC warning at first boot.** If U-Boot logs `*** Warning - bad CRC, using default environment`, the factory-flashed `uboot-env.bin` didn't land correctly or its CRC is wrong. Check genimage output for `uboot-env.bin` size (should be 128 KiB: two 64-KiB copies back-to-back from post-image.sh). Without the flashed env, `altbootcmd` is missing from compiled-in defaults — rollback won't work. This is the known defense-in-depth gap (§11.1 in the FSD).
- **Serial baud mismatch.** If you see garbled output, confirm the host terminal is at **1,500,000** baud, not 115,200. Vendor DTB hard-codes it (FSD §4.3 C-2).
- **U-Boot MMC numbering confusion.** U-Boot `mmc 0` maps to Linux `/dev/mmcblk0` on Phase 3 (not `mmcblk1` as in the Phase 1 vendor U-Boot). Don't apply Phase 1 debugging habits.
- **Data preservation.** `/data` survives everything in this runbook **except** a full `rkdeveloptool wl` re-flash (§2), which recreates the partition and erases `tc_key.txt`. Back up first.
