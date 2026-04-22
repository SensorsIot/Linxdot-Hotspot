# OTA Updates

OpenLinxdot uses A/B slots with U-Boot-level auto-rollback. Updates are pulled from GitHub Releases over Ethernet — no USB, no physical access.

## Partition layout

```
idbloader  @ 32K     raw
u-boot.itb @ 8M      raw
uboot_env  @ 14M     raw (128K = 64K primary + 64K redundant)
p1 boot_a  @ 16M     vfat 30M   (Image + DTB + boot.scr)
p2 rootfs_a          ext4 500M
p3 boot_b            vfat 30M
p4 rootfs_b          ext4 500M
p5 data              ext4 512M  (shared, /data, preserved across updates)
```

## Flow

1. `S99otacheck` runs 60 s after boot, calls `/usr/sbin/ota-check`.
2. `ota-check` fetches `manifest.json` from `releases/latest/download/` — if `version` is newer than `/etc/os-release VERSION_ID`, downloads the `.swu`.
3. `swupdate -i update.swu -e stable,linxdot-ld1001,target-<INACTIVE>` writes the new rootfs + boot image to the inactive slot and sets U-Boot env: `boot_slot=<INACTIVE>`, `upgrade_available=1`, `bootcount=0`.
4. Reboot. U-Boot boots the target slot. `CONFIG_BOOTCOUNT_LIMIT` auto-increments `bootcount` on each try.
5. If services come up healthy, `S98confirm` sets `upgrade_available=0` and `bootcount=0` — the update is committed.
6. If `bootcount > bootlimit` before `S98confirm` runs, U-Boot runs `altbootcmd`, which flips `boot_slot` back, clears `upgrade_available`, and resets. Old slot boots.

## Refuses to flip on healthy-slot transient failures

`altbootcmd` only swaps slots when `upgrade_available=1`. A healthy slot that hits `bootlimit` from unrelated crashes just has its `bootcount` reset — the slot doesn't change. Tested in `tests/test_ota_state_machine.sh` scenario 3.

## Manual trigger

```
ssh root@<device>
ota-check
```

Same flow, runs in foreground. Useful when you don't want to reboot just to pull an update.

## Signing keys

OTA bundles should be signed. One-time setup:

```
sh scripts/gen-signing-key.sh
gh secret set OTA_SIGNING_KEY < ./ota-signing.key
mkdir -p board/linxdot/overlay/etc/swupdate
cp ./ota-signing.pub board/linxdot/overlay/etc/swupdate/public.pem
git add board/linxdot/overlay/etc/swupdate/public.pem
git commit -m "ota: add signing public key"
shred -u ./ota-signing.key
```

CI signs `sw-description` when the `OTA_SIGNING_KEY` secret is present. Devices reject unsigned bundles when `/etc/swupdate/public.pem` exists; absence of the key file falls back to accepting unsigned (development mode).

## Releasing

`git tag v1.2.3 && git push --tags`. CI produces:
- `linxdot-basics-station.img.xz` — factory image for first-time provisioning via `rkdeveloptool`
- `linxdot-basics-station-1.2.3.swu` — OTA bundle (+ `sw-description.sig` if signed)
- `manifest.json` — `{ version, url, sha256 }` polled by devices

## Migrating existing devices to A/B

Devices flashed with the pre-A/B image cannot receive OTA. One-time migration:

1. Back up `/data/basicstation/tc_key.txt` via SSH.
2. Reflash via `rkdeveloptool` using the A/B-layout `.img.xz`.
3. Restore `tc_key.txt`. Future updates arrive over Ethernet.

## Rollback diagnosis

From the running device:

```
fw_printenv boot_slot bootcount upgrade_available
logread | grep ota            # /var/log messages tagged 'ota'
```

- `boot_slot` changed but the version didn't → rollback fired.
- `upgrade_available=1` stuck → `S98confirm` didn't commit; check Docker / Basics Station status.
- Can't boot either slot → `rkdeveloptool` USB recovery required (disassembly).

## What's NOT updated by OTA

- `idbloader.img` and `u-boot.itb` — bootloader stays frozen post-factory-flash. Updating these has no fallback slot and would risk bricking. Requires a new factory image + `rkdeveloptool` to change.
- The U-Boot env default content — changes to `env.txt` only take effect on devices reflashed with a new factory image.
