# LinxdotOS Build Process

Phase 1 implementation of a custom Buildroot appliance OS for the Linxdot LD1001 (RK3566).

## Overview

LinxdotOS replaces the entire CrankkOS userspace with a clean Buildroot rootfs while reusing the proven bootloader, kernel, and DTB from CrankkOS. This eliminates all Helium/Crankk traces and produces a minimal Docker server running the Basics Station TTN gateway stack.

### Boot Chain

```
BootROM
  → SPL / idbloader (Rockchip blob, DDR init, 1.5Mbaud)
    → U-Boot proper (u-boot.itb, 1.5Mbaud)
      → Linux 5.15.104 (console=ttyS2,115200)
        → BusyBox init
          → S00datapart  → S01mountall → S40network
          → S50sshd → S60dockerd → S80dockercompose
```

SPL and U-Boot output at 1.5Mbaud (appears as garbage on a 115200 terminal). The kernel, getty, and all userspace run at 115200. Phase 3 will rebuild U-Boot at 115200.

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

The boot partition also contained `boot.scr`, `initrd.gz`, and `uEnv.txt`. The original `uEnv.txt` set `console=ttyS2,1500000` — we replace this with our own `boot.cmd` at 115200.

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
| Docker | `BR2_PACKAGE_DOCKER_ENGINE` | Core requirement |
| SSH | Dropbear | Lightweight SSH daemon |
| Network | dhcpcd + wpa_supplicant | Ethernet DHCP + WiFi support |
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
setenv bootargs "root=/dev/mmcblk1p2 rootfstype=ext4 rootwait ro console=ttyS2,115200 panic=10 quiet loglevel=1"
load mmc 1:1 ${kernel_addr_r} Image
load mmc 1:1 ${fdt_addr_r} rk3566-linxdot.dtb
booti ${kernel_addr_r} - ${fdt_addr_r}
```

This is compiled to `boot.scr` by `post-image.sh` using `mkimage`. Key differences from CrankkOS:

- Console baud changed from 1500000 to **115200**
- Root filesystem mounted **read-only** (`ro`)
- No initrd (CrankkOS shipped `initrd.gz` — we boot directly)

## Step 6: Create Rootfs Overlay and Init Scripts

The overlay at `board/linxdot/overlay/` is copied on top of the Buildroot rootfs. It replaces CrankkOS's ~46 init scripts with 6.

### `etc/inittab`

```
::sysinit:/etc/init.d/rcS
ttyS2::respawn:/sbin/getty -L ttyS2 115200 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/etc/init.d/rcK
```

Changed from CrankkOS: getty on `ttyS2` at `115200` (was `ttylogin` at `1500000`).

### `etc/fstab`

Static mounts for proc, sysfs, devtmpfs, devpts, and tmpfs for `/tmp` and `/run`. The root device is mounted read-only. The data partition is mounted dynamically by `S00datapart`.

### Init Scripts

#### S00datapart — Data partition setup

1. Detects the disk device from `/proc/cmdline` root= parameter
2. Derives the data partition path (partition 3)
3. Runs `e2fsck -pf` for filesystem consistency
4. Runs `resize2fs` to expand to full eMMC (no-op after first boot)
5. Mounts to `/data`
6. On first boot, creates skeleton directories: `/data/docker`, `/data/overlay/{usr,var_log,var_lib}/{upper,work}`, `/data/basicstation`, `/data/etc`

#### S01mountall — Overlay filesystems

Mounts three overlayfs instances backed by `/data`:

| Mount point | Lower (ro rootfs) | Upper (rw on /data) |
|-------------|-------------------|---------------------|
| `/usr` | `/usr` | `/data/overlay/usr/upper` |
| `/var/log` | `/var/log` | `/data/overlay/var_log/upper` |
| `/var/lib` | `/var/lib` | `/data/overlay/var_lib/upper` |

Also mounts cgroupfs (cgroup2 on kernel 5.x) and bind-mounts `/data/docker-compose.yml` over `/etc/docker-compose.yml` if a user config exists.

#### S40network — Ethernet DHCP

1. Brings up loopback
2. Brings up `eth0` and waits up to 30 seconds for carrier (link detect via `/sys/class/net/eth0/carrier`)
3. Starts `dhcpcd -b eth0` for background DHCP

#### S50sshd — Dropbear SSH

Generates ECDSA and Ed25519 host keys on first boot, then starts Dropbear. Login: `root` / `crankk`.

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

## Step 7: Create docker-compose v1 Package

`package/docker-compose-v1/` is a Buildroot generic package that downloads the static `docker-compose` 1.29.2 aarch64 binary from the GitHub releases page and installs it to `/usr/bin/docker-compose`.

The package uses Buildroot's `generic-package` infrastructure with a custom extract step (the download is a single binary, not a tarball).

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

```sh
scp output/images/linxdot-basics-station.img pi@192.168.0.41:/tmp/

ssh pi@192.168.0.41 '
  sudo rkdeveloptool db /tmp/rk356x_spl_loader_ddr1056_v1.10.111.bin
  sudo rkdeveloptool wl 0 /tmp/linxdot-basics-station.img
  sudo rkdeveloptool rd
'
```

See [Flashing.md](Flashing.md) for the full procedure.

## Step 11: GitHub Actions CI

`.github/workflows/build.yml` runs on push to `ourOS` and on tags.

**Caching:**
- `buildroot/dl/` — source tarballs (avoids re-downloading ~1 GB)
- `~/.buildroot-ccache` — compiler cache (speeds up rebuilds)

**Build steps:**
1. Checkout with LFS
2. Install build dependencies
3. Download and extract Buildroot
4. `make BR2_EXTERNAL=.. linxdot_ld1001_defconfig`
5. `make -j$(nproc)`
6. Compress with `xz -9 -T0`
7. Upload as GitHub Actions artifact (30-day retention)
8. On tag push (`v*`): create GitHub Release with the image attached

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

After flashing, verify the following over serial (115200 baud) or SSH:

| Check | Command | Expected |
|-------|---------|----------|
| Boot to login | Serial console | Garbage during SPL/U-Boot, then clean kernel output + `linxdot login:` |
| Network | `ip addr show eth0` | DHCP address assigned |
| SSH | `ssh root@<ip>` | Password: `crankk` |
| Docker | `docker info` | storage driver: overlay2, data-root: `/data/docker` |
| Basics Station | `docker logs basicstation` | Shows gateway EUI (fails without TC_KEY — expected) |
| Read-only rootfs | `mount \| grep "on / "` | Shows `ro` |
| Persistent data | `echo test > /data/test && reboot` | File survives reboot |
| Overlay | `touch /usr/testfile && reboot` | File persists via overlayfs on `/data` |

## Future Phases

| Phase | Scope |
|-------|-------|
| **Phase 2** | Build Linux 6.1 LTS kernel from source (validate SPI, Ethernet, SDIO WiFi, I2C) |
| **Phase 3** | Build U-Boot + TF-A from source (console at 115200, full bootarg control) |
| **Phase 4** | Replace vendor DTB with curated in-tree DTS |
