# LinxdotOS Build Process

Phase 1 implementation of a custom Buildroot appliance OS for the Linxdot LD1001 (RK3566).

## Overview

LinxdotOS replaces the entire CrankkOS userspace with a clean Buildroot rootfs while reusing the proven bootloader, kernel, and DTB from CrankkOS. This eliminates all Helium/Crankk traces and produces a minimal Docker server running the Basics Station TTN gateway stack.

### Boot Chain

```
BootROM
  → SPL / idbloader (Rockchip blob, DDR init, 1.5Mbaud)
    → U-Boot proper (u-boot.itb, 1.5Mbaud)
      → Linux 5.15.104 (console=ttyS2,1500000)
        → BusyBox init
          → S00datapart  → S01mountall → S40network
          → S50sshd → S60dockerd → S80dockercompose
```

SPL and U-Boot output at 1.5Mbaud. The vendor kernel and DTB (`stdout-path = "serial2:1500000n8"`) require the console at 1.5Mbaud — **changing to 115200 results in no kernel output**. Phase 3 (rebuild U-Boot + kernel) will allow changing the console baud rate.

## Step 1: Extract Files from CrankkOS Image

The existing CrankkOS pktfwd image was mounted and the following files extracted.

### Partition Layout (source image)

```
Device   Boot  Start      End  Sectors  Size  Type
img1     *     40960   102399    61440   30M   W95 FAT16 (LBA)   ← boot
img2          204800  1228799  1024000  500M   Linux              ← rootfs
```

### Mount and Copy

```sh
# Mount boot partition (FAT16 at sector 40960)
sudo mount -o loop,offset=$((40960*512)),ro \
  crankkos-linxdotrk3566-1.0.0-pktfwd.img /tmp/crankk-boot

# Mount root partition (ext4 at sector 204800)
sudo losetup -f --show -o $((204800*512)) --sizelimit $((1024000*512)) \
  crankkos-linxdotrk3566-1.0.0-pktfwd.img
sudo mount -o ro /dev/loop1 /tmp/crankk-root
```

### Boot Blobs (raw dd from image)

| File | Source | Size |
|------|--------|------|
| `idbloader.img` | Sectors 64–8063 (SPL + DDR init) | 4.0 MB |
| `u-boot.itb` | Sectors 16384–32767 (TF-A + U-Boot) | 8.4 MB |

```sh
dd if=crankkos.img of=board/linxdot/blobs/idbloader.img bs=512 skip=64 count=8000
dd if=crankkos.img of=board/linxdot/blobs/u-boot.itb bs=512 skip=16384 count=16384
```

### Kernel and DTB (from boot partition)

| File | Source Path | Size |
|------|-------------|------|
| `Image` | `/tmp/crankk-boot/Image` | 22.3 MB |
| `rk3566-linxdot.dtb` | `/tmp/crankk-boot/rk3566-linxdot.dtb` | 43 KB |

The boot partition also contained `boot.scr`, `initrd.gz`, and `uEnv.txt`. The original `uEnv.txt` set `console=ttyS2,1500000` — we replace this with our own `boot.cmd` (also at 1500000 to match the vendor DTB `stdout-path`).

### Kernel Modules (from rootfs)

Copied from `/tmp/crankk-root/lib/modules/5.15.104/` to `board/linxdot/modules/5.15.104/`. Includes drivers for:

- Broadcom WiFi (`brcmfmac`, `brcmutil`, `cfg80211`, `mac80211`)
- USB serial (`ftdi_sio`, `cp210x`, `ch341`)
- Networking (`bonding`, `tun`, `bridge`, netfilter modules)
- Block/storage (`zram`, USB mass storage)
- SPI (`spi-gpio`)

### WiFi Firmware (local only)

Copied from `/tmp/crankk-root/lib/firmware/brcm/` to `board/linxdot/firmware/brcm/`. Not committed to the public repo due to Broadcom licensing. The `firmware/` directory is in `.gitignore`.

| File | Purpose |
|------|---------|
| `brcmfmac43430-sdio.bin` | WiFi driver firmware |
| `brcmfmac43430-sdio.linxdot,r01.txt` | Board-specific NVRAM config |
| `brcmfmac43430-sdio.AP6212.txt` | Alternative NVRAM config |
| `BCM43430A1.hcd` | Bluetooth firmware |

### LoRa Reset Script

Copied `/tmp/crankk-root/opt/packet_forwarder/tools/reset_lgw.sh.linxdot` to `board/linxdot/`. This script toggles GPIOs 23, 17, and 15 to power-cycle and reset the SX1302 concentrator.

## Step 2: Create BR2_EXTERNAL Skeleton

Buildroot's external tree mechanism keeps all customisation outside the Buildroot source tree. Three files define it:

### `external.desc`

```
name: LINXDOT
desc: LinxdotOS - Custom Buildroot appliance OS for Linxdot LD1001
```

The `name` field sets the `BR2_EXTERNAL_LINXDOT_PATH` variable used throughout the config.

### `Config.in`

```kconfig
source "$BR2_EXTERNAL_LINXDOT_PATH/package/docker-compose-v1/Config.in"
```

### `external.mk`

```makefile
include $(sort $(wildcard $(BR2_EXTERNAL_LINXDOT_PATH)/package/*/*.mk))
```

## Step 3: Create Buildroot Defconfig

`configs/linxdot_ld1001_defconfig` — key choices:

| Setting | Value | Rationale |
|---------|-------|-----------|
| Architecture | `BR2_aarch64` | RK3566 is ARMv8 Cortex-A55 |
| Toolchain | glibc + C++ | Required by Docker engine |
| Init | BusyBox | Lightweight, matches CrankkOS |
| Kernel | **not built** | Phase 1 uses prebuilt 5.15.104 |
| U-Boot | **not built** | Phase 1 uses extracted bootloader |
| Rootfs | ext4, 500 MB, read-only | Matches CrankkOS partition size |
| Docker | `BR2_PACKAGE_DOCKER_ENGINE`, `BR2_PACKAGE_DOCKER_CLI` | Core requirement |
| SSH | Dropbear | Lightweight SSH daemon |
| Network | dhcpcd + wpa_supplicant | Ethernet DHCP + WiFi support |
| NTP | `BR2_PACKAGE_NTP` | Time synchronization (required for TLS) |
| Filesystem | e2fsprogs (resize2fs) | First-boot partition expansion |

The defconfig also enables ccache and host tools (genimage, dosfstools, mtools, uboot-tools) needed by the image generation scripts.

## Step 4: Create Genimage Partition Layout

`board/linxdot/genimage.cfg` defines the eMMC image layout:

```
 Offset    Content              In partition table?
 ──────    ───────              ───────────────────
 32 KiB    idbloader.img        No (raw)
  8 MiB    u-boot.itb           No (raw)
 16 MiB    P1 boot (FAT, 30MB)  Yes, type 0x0E
           P2 rootfs (ext4)     Yes, type 0x83
           P3 data (ext4, 64MB) Yes, type 0x83
```

The data partition is created at 64 MB in the image. On first boot, `S00datapart` runs `resize2fs` to expand it to fill all remaining eMMC space (~27 GB on the LD1001).

## Step 5: Create Boot Script

`board/linxdot/boot.cmd`:

```
setenv bootargs "root=/dev/mmcblk1p2 rootfstype=ext4 rootwait ro console=ttyS2,1500000 panic=10"
if load mmc 0:1 ${kernel_addr_r} Image; then
    load mmc 0:1 ${fdt_addr_r} rk3566-linxdot.dtb
else
    load mmc 1:1 ${kernel_addr_r} Image
    load mmc 1:1 ${fdt_addr_r} rk3566-linxdot.dtb
fi
booti ${kernel_addr_r} - ${fdt_addr_r}
```

This is compiled to `boot.scr` by `post-image.sh` using `mkimage`. Key differences from CrankkOS:

- Root filesystem mounted **read-only** (`ro`)
- No initrd (CrankkOS shipped `initrd.gz` — we boot directly)
- Fallback logic tries `mmc 0` then `mmc 1` (see caveat below)

### Important: U-Boot vs Kernel MMC Numbering

**U-Boot and the Linux kernel use different MMC device numbering.** This is a critical detail:

| Context | eMMC device | Source |
|---------|------------|--------|
| U-Boot `mmc` command | `mmc 0` (sdhci@fe310000) | U-Boot's own probe order |
| Linux kernel `/dev/` | `mmcblk1` | DTB alias: `mmc1 = "/mmc@fe310000"` |

The DTB `aliases` section defines `mmc0 = "/mmc@fe2b0000"` (SD card slot), `mmc1 = "/mmc@fe310000"` (eMMC), and `mmc2 = "/mmc@fe2c0000"` (SDIO/WiFi). U-Boot probes in a different order and assigns eMMC as device 0.

Therefore: **U-Boot loads files with `load mmc 0:1`** but the **kernel root must be `root=/dev/mmcblk1p2`**.

### Console Baud Rate

The vendor DTB contains `chosen { stdout-path = "serial2:1500000n8"; }`. The vendor kernel (5.15.104) respects this and only produces console output at 1,500,000 baud. Setting `console=ttyS2,115200` in bootargs results in **no kernel output** on the serial port. The getty must also run at 1500000 to match.

## Step 6: Create Rootfs Overlay and Init Scripts

The overlay at `board/linxdot/overlay/` is copied on top of the Buildroot rootfs. It replaces CrankkOS's ~46 init scripts with 6.

### `etc/inittab`

```
::sysinit:/etc/init.d/rcS
ttyS2::respawn:/sbin/getty -L ttyS2 1500000 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/etc/init.d/rcK
```

Getty runs at 1,500,000 baud to match the vendor kernel/DTB console speed.

### `etc/fstab`

Static mounts for proc, sysfs, devtmpfs, devpts, and tmpfs for `/tmp` and `/run`. The root device is mounted read-only. The data partition is mounted dynamically by `S00datapart`.

### Init Scripts

#### S00datapart — Pseudo-filesystems and data partition setup

**Must run first.** Mounts essential pseudo-filesystems before anything else:

1. Mounts `/proc`, `/sys`, `/dev`, `/dev/pts`, `/tmp` (tmpfs), `/run` (tmpfs)
2. Detects the disk device from `/proc/cmdline` root= parameter
3. Derives the data partition path (partition 3)
4. Runs `e2fsck -pf` for filesystem consistency
5. Runs `resize2fs` to expand to full eMMC (no-op after first boot)
6. Mounts to `/data`
7. On first boot, creates skeleton directories: `/data/docker`, `/data/overlay/{usr,var_log,var_lib,etc}/{upper,work}`, `/data/basicstation`, `/data/etc`

**Lesson learned:** BusyBox init runs `rcS` (which executes init scripts) *before* mounting fstab entries. Without early `/proc` mount, `/proc/cmdline` is unavailable and the data partition detection fails, cascading into read-only filesystem errors for all subsequent services.

#### S01mountall — Overlay filesystems

Ensures `/var/run` is writable (mounts tmpfs if not already a symlink to `/run`), then mounts four overlayfs instances backed by `/data`:

| Mount point | Lower (ro rootfs) | Upper (rw on /data) |
|-------------|-------------------|---------------------|
| `/usr` | `/usr` | `/data/overlay/usr/upper` |
| `/var/log` | `/var/log` | `/data/overlay/var_log/upper` |
| `/var/lib` | `/var/lib` | `/data/overlay/var_lib/upper` |
| `/etc` | `/etc` | `/data/overlay/etc/upper` |

The `/etc` overlay allows Dropbear to persist SSH host keys and services to modify config files at runtime on the read-only rootfs.

Also mounts cgroupfs (cgroup2 on kernel 5.x) and bind-mounts `/data/docker-compose.yml` over `/etc/docker-compose.yml` if a user config exists.

**Lesson learned:** Without `/var/run` as tmpfs, both `dhcpcd` and `dropbear` fail to create their PID files and socket directories, preventing networking and SSH.

#### S40network — Ethernet DHCP

1. Brings up loopback
2. Brings up `eth0` and waits up to 30 seconds for carrier (link detect via `/sys/class/net/eth0/carrier`)
3. Starts `dhcpcd -b eth0` for background DHCP

#### S50sshd — Dropbear SSH

Generates ECDSA and Ed25519 host keys on first boot, then starts Dropbear. Login: `root` / `linxdot`.

#### S60dockerd — Docker daemon

Starts `dockerd` with:
- `--data-root /data/docker` (persistent storage on data partition)
- `--storage-driver overlay2`
- Socket at `/var/run/docker.sock`

#### S80dockercompose — Basics Station container

1. Waits up to 60 seconds for Docker socket to become available
2. Runs `docker-compose pull` then `docker-compose up -d`
3. Uses `/data/docker-compose.yml` if present, otherwise `/etc/docker-compose.yml`

### `etc/docker-compose.yml`

Basics Station config using the `xoseperez/basicstation` image:

| Variable | Value | Description |
|----------|-------|-------------|
| `MODEL` | `SX1302` | Concentrator chip |
| `INTERFACE` | `SPI` | Bus to concentrator |
| `DEVICE` | `/dev/spidev0.0` | SPI device path |
| `RESET_GPIO` | `0` | Disabled (reset via power cycle) |
| `GATEWAY_EUI_SOURCE` | `chip` | EUI from concentrator hardware |
| `TTS_REGION` | `eu1` | TTN cluster |
| `TC_KEY` | `${TC_KEY}` | Set by user in `/data/docker-compose.yml` |

## Step 7: Create docker-compose Package

`package/docker-compose-v1/` is a Buildroot generic package that downloads the static `docker-compose` v2.32.4 aarch64 binary from the GitHub releases page and installs it to `/usr/bin/docker-compose`.

The package uses Buildroot's `generic-package` infrastructure with a custom extract step (the download is a single binary, not a tarball). Despite the directory name `docker-compose-v1`, it ships **v2** which is a drop-in replacement (same CLI interface, same YAML format).

**Lesson learned:** The original docker-compose v1 (1.29.2) `aarch64` binary was removed from GitHub releases, causing a 404 download error in CI. Docker Compose v2 static binaries are actively maintained and available.

## Step 8: Create post-build.sh

Runs after Buildroot assembles the target rootfs (`TARGET_DIR`). Actions:

1. Copies prebuilt `Image` and `rk3566-linxdot.dtb` from `blobs/` to `BINARIES_DIR`
2. Copies `idbloader.img` and `u-boot.itb` to `BINARIES_DIR`
3. Installs kernel modules from `modules/5.15.104/` into the rootfs
4. Copies WiFi firmware from local `firmware/brcm/` if present (skips if absent)
5. Installs `reset_lgw.sh.linxdot` to `/opt/packet_forwarder/tools/`
6. Ensures all init scripts are executable
7. Creates required mount points (`/data`, `/var/log`, `/var/lib`, `/var/run`)

## Step 9: Create post-image.sh

Runs after the rootfs image (`rootfs.ext4`) is generated. Actions:

1. Compiles `boot.cmd` → `boot.scr` using `mkimage`
2. Runs `genimage` with `genimage.cfg` to assemble the final `linxdot-basics-station.img`

## Step 10: Build

```sh
# Download Buildroot 2024.02.8 LTS
wget https://buildroot.org/downloads/buildroot-2024.02.8.tar.xz
tar xf buildroot-2024.02.8.tar.xz
mv buildroot-2024.02.8 buildroot

# Configure with BR2_EXTERNAL pointing to our tree
cd buildroot
make BR2_EXTERNAL=$(pwd)/.. linxdot_ld1001_defconfig

# Build (first build downloads all sources and builds the cross-toolchain)
make -j$(nproc)

# Output image
ls -lh output/images/linxdot-basics-station.img
```

### Flashing via Raspberry Pi

The Linxdot is connected to a Raspberry Pi via USB-C for flashing. The device must be in Loader or Maskrom mode (hold the boot button while power cycling, or enter via `rkdeveloptool rd`).

```sh
scp output/images/linxdot-basics-station.img pi@192.168.0.41:/tmp/

ssh pi@192.168.0.41 '
  sudo rkdeveloptool ld                    # Verify device is detected
  sudo rkdeveloptool wl 0 /tmp/linxdot-basics-station.img
  sudo rkdeveloptool rd                    # Reboot device
'
```

**Note:** When flashing in Loader mode (not Maskrom), there is no need to download a separate SPL loader binary — `rkdeveloptool wl 0` writes the entire image including the idbloader region.

See [Flashing.md](Flashing.md) for the full procedure.

## Step 11: GitHub Actions CI

`.github/workflows/build.yml` runs on push to `ourOS` and on tags.

**Caching:**
- `buildroot/dl/` — source tarballs (avoids re-downloading ~1 GB)
- `~/.buildroot-ccache` — compiler cache (speeds up rebuilds)

**Build steps:**
1. Checkout with LFS
2. Install build dependencies
3. Download and extract Buildroot (with cache-aware logic, see caveat below)
4. `make BR2_EXTERNAL=.. linxdot_ld1001_defconfig`
5. `make -j$(nproc)`
6. Compress with `xz -9 -T0`
7. Upload as GitHub Actions artifact (30-day retention)
8. On tag push (`v*`): create GitHub Release with the image attached

**Lesson learned (CI caching):** The `buildroot/dl/` cache creates the `buildroot/` parent directory as a side effect. A naive `if [ ! -d buildroot ]` check then skips the Buildroot download, leaving an empty directory with no Makefile. The fix is to check `if [ ! -f buildroot/Makefile ]` and use `rsync` to merge the extracted Buildroot into the existing directory (preserving the cached `dl/` contents).

## Repository Structure

```
Linxdot-Hotspot/
├── external.desc                    # BR2_EXTERNAL descriptor
├── external.mk                      # Include custom packages
├── Config.in                        # Top-level Kconfig
├── configs/
│   └── linxdot_ld1001_defconfig     # Buildroot defconfig
├── board/
│   └── linxdot/
│       ├── genimage.cfg             # Partition layout
│       ├── post-build.sh            # Install prebuilt kernel/modules/firmware
│       ├── post-image.sh            # mkimage boot.scr + genimage
│       ├── boot.cmd                 # U-Boot boot script
│       ├── reset_lgw.sh.linxdot     # LoRa concentrator GPIO reset
│       ├── blobs/                   # Extracted vendor binaries (Git LFS)
│       │   ├── idbloader.img
│       │   ├── u-boot.itb
│       │   ├── Image
│       │   └── rk3566-linxdot.dtb
│       ├── modules/                 # Kernel modules (Git LFS)
│       │   └── 5.15.104/
│       ├── firmware/                # WiFi firmware (.gitignored)
│       │   └── brcm/
│       └── overlay/                 # Rootfs overlay
│           └── etc/
│               ├── inittab
│               ├── fstab
│               ├── docker-compose.yml
│               └── init.d/
│                   ├── S00datapart
│                   ├── S01mountall
│                   ├── S40network
│                   ├── S50sshd
│                   ├── S60dockerd
│                   └── S80dockercompose
├── package/
│   └── docker-compose-v1/           # Static aarch64 binary package
├── .github/workflows/
│   └── build.yml                    # CI build + release
├── .gitattributes                   # Git LFS tracking rules
├── .gitignore                       # Excludes buildroot/, firmware/
├── Docs/                            # Documentation (unchanged)
├── Images/                          # Legacy CrankkOS images (unchanged)
└── README.md                        # Project README (unchanged)
```

## Verification Checklist

After flashing, verify the following over serial (1500000 baud) or SSH:

| Check | Command | Expected |
|-------|---------|----------|
| Boot to login | Serial console @ 1500000 | SPL/U-Boot output, then kernel boot messages + `buildroot login:` |
| Network | `ip addr show eth0` | DHCP address assigned |
| SSH | `ssh root@<ip>` | Password: `linxdot` |
| Docker | `docker info` | storage driver: overlay2, data-root: `/data/docker` |
| Basics Station | `docker logs basicstation` | Shows gateway EUI (fails without TC_KEY — expected) |
| Read-only rootfs | `mount \| grep "on / "` | Shows `ro` |
| Persistent data | `echo test > /data/test && reboot` | File survives reboot |
| Overlay | `touch /usr/testfile && reboot` | File persists via overlayfs on `/data` |
| /proc mounted | `cat /proc/cmdline` | Shows kernel boot parameters |
| /var/run writable | `ls /var/run/` | Contains dhcpcd/, dropbear.pid, docker.sock |
| NTP time sync | `ntpq -p` or `date` | Correct current time |
| Concentrator reset | `docker logs basicstation` | Shows `EUI Source: chip` (not `eth0`) |

## Known Issues

### boot.scr Execution Failure (Vendor U-Boot)

The vendor U-Boot (2017.09) fails to execute the generated `boot.scr` script, displaying garbage characters:

```
## Executing script at 00c00000
Unknown command '�����...'
SCRIPT FAILED: continuing...
```

**Analysis:** The `boot.scr` file in the image is correctly formatted (verified via hex dump). The issue appears to be a compatibility problem between:
- The `mkimage` tool used during the build (from Buildroot's host tools)
- The vendor U-Boot's script parsing

**Workaround:** Boot manually from the U-Boot prompt:

```
setenv bootargs root=/dev/mmcblk1p2 rootfstype=ext4 rootwait ro console=ttyS2,1500000 panic=10
load mmc 0:1 ${kernel_addr_r} Image
load mmc 0:1 ${fdt_addr_r} rk3566-linxdot.dtb
booti ${kernel_addr_r} - ${fdt_addr_r}
```

**Permanent fix:** Requires Phase 3 (rebuild U-Boot from source) to ensure the script format matches.

### Gateway EUI Source

The Basics Station container must read the Gateway EUI from the SX1302 concentrator chip, not the Ethernet MAC. If `docker logs basicstation` shows `EUI Source: eth0`, the concentrator was not properly reset before the container started.

**Fix:** The `S80dockercompose` init script now runs the concentrator reset automatically. If the EUI still shows `eth0`, manually reset:

```bash
docker-compose -f /data/docker-compose.yml down
/opt/packet_forwarder/tools/reset_lgw.sh.linxdot stop
/opt/packet_forwarder/tools/reset_lgw.sh.linxdot start
docker-compose -f /data/docker-compose.yml up -d
```

## Future Phases

| Phase | Scope |
|-------|-------|
| **Phase 2** | Build Linux 6.1 LTS kernel from source (validate SPI, Ethernet, SDIO WiFi, I2C). This will allow changing the console baud rate to 115200 by modifying the DTB `stdout-path`. |
| **Phase 3** | Build U-Boot + TF-A from source (console at 115200, deterministic mmc numbering, full bootarg control) |
| **Phase 4** | Replace vendor DTB with curated in-tree DTS |
