# Flashing the Linxdot RK3566

This guide covers flashing a minimal Linux + Docker image onto the Linxdot LD1001 (RK3566) hotspot miner.

## Overview

The Linxdot LD1001 uses a Rockchip RK3566 SoC with 2GB RAM and 32GB eMMC. Flashing is done over USB-C using the Rockchip `rkdeveloptool` while the device is in Maskrom mode.

The image is based on CrankkOS 1.0.0 (a Buildroot system), modified to:

- Replace the Crankk container with a Helium packet forwarder and gateway miner
- Fix ethernet link detection (replaced `mii-tool` with `/sys/class/net/carrier` check)
- Fix serial console getty baud rate (1500000 to match kernel console)
- Set a default root password

## Prerequisites

### Hardware

- Linxdot LD1001 (RK3566 variant, identifiable by the BT-Pair button near the antenna connector)
- USB-C **data** cable (not charge-only)
- A Linux computer (Raspberry Pi, PC, etc.) with a USB port
- Power supply for the Linxdot
- Ethernet cable (for post-flash network access)

### Software

Install `rkdeveloptool` on your Linux machine:

```bash
# Debian/Ubuntu (apt)
sudo apt-get install rkdeveloptool

# Or build from source
git clone https://github.com/rockchip-linux/rkdeveloptool
cd rkdeveloptool
autoreconf -i
./configure
make
sudo cp rkdeveloptool /usr/local/bin/
```

### Files

- `crankkos-linxdotrk3566-1.0.0.img.xz` - The OS image (included in this repo)
- `rk356x_spl_loader_ddr1056_v1.10.111.bin` - Rockchip bootloader, download from [linxdot-rockchip-flash](https://github.com/fernandodev/linxdot-rockchip-flash)

## Flashing Procedure

### Step 1: Enter Loader Mode

1. Connect the USB-C cable between the Linxdot and your computer
2. With the Linxdot **powered off**, press and hold the **BT-Pair** button
3. While holding the button, plug in the power cable
4. Hold for approximately 5-8 seconds

Verify the device is detected:

```bash
lsusb | grep Rockchip
# Should show: Fuzhou Rockchip Electronics Company USB download gadget

sudo rkdeveloptool ld
# Should show: DevNo=1 Vid=0x2207,Pid=0x350a,LocationID=xxx Loader
```

### Step 2: Erase the Flash

```bash
sudo rkdeveloptool ef
```

Wait for "Erasing flash complete." This erases the entire eMMC.

### Step 3: Power Cycle into Maskrom Mode

1. Unplug the Linxdot power cable (keep USB-C connected)
2. Hold the BT-Pair button
3. Replug the power cable while holding the button
4. Hold for ~5 seconds

Verify Maskrom mode:

```bash
sudo rkdeveloptool ld
# Should show: DevNo=1 Vid=0x2207,Pid=0x350a,LocationID=xxx Maskrom
```

### Step 4: Flash the Bootloader

```bash
sudo rkdeveloptool db rk356x_spl_loader_ddr1056_v1.10.111.bin
# Should show: Downloading bootloader succeeded.
```

### Step 5: Write the Image

Decompress the image first if needed:

```bash
xz -d crankkos-linxdotrk3566-1.0.0.img.xz
```

Then write it:

```bash
sudo rkdeveloptool wl 0 crankkos-linxdotrk3566-1.0.0.img
# Progress will show up to 100%
```

### Step 6: Verify and Reset

```bash
sudo rkdeveloptool td
# Should show: Test Device OK.

sudo rkdeveloptool rd
# Should show: Reset Device OK.
```

The device will now reboot into the new image.

## Post-Flash Setup

### First Boot

- Connect an ethernet cable to the Linxdot
- The device will obtain an IP via DHCP
- First boot may take 1-2 minutes as it sets up the data partition and pulls Docker images

### SSH Access

```bash
ssh root@<linxdot-ip>
# Default password: crankk
```

Change the password immediately:

```bash
passwd
```

### Serial Console

The serial console is available at **1500000 baud** on the 3.5mm audio jack (ttyS2):

```bash
picocom -b 1500000 /dev/ttyUSB0
```

### WiFi Configuration

Edit `/data/etc/wpa_supplicant.conf`:

```
update_config=1
ctrl_interface=/var/run/wpa_supplicant
network={
    scan_ssid=1
    ssid="your_ssid"
    psk="your_password"
}
```

Reboot to apply.

### Docker Services

Two containers run automatically:

| Container | Image | Purpose |
|-----------|-------|---------|
| `pktfwd` | `ghcr.io/heliumdiy/sx1302_hal:sha-87d8931` | LoRa packet forwarder (SX1302) |
| `miner` | `quay.io/team-helium/miner:gateway-latest` | Helium gateway miner |

Check status:

```bash
docker ps
```

Check Helium animal name:

```bash
docker exec miner helium_gateway key info
```

### Region Configuration

The default region is EU868. To change it, edit `/etc/docker-compose.yml` and update `REGION` and `GW_REGION` to your region (e.g., `US915`, `AU915`).

### Tailscale (Optional)

```bash
docker run -d \
  --name tailscaled \
  --restart always \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  -e TS_AUTHKEY="tskey-auth-xxxxxxxx" \
  -e TS_EXTRA_ARGS="--advertise-exit-node" \
  -e TS_STATE_DIR="/var/lib/tailscale" \
  -v /var/lib:/var/lib \
  -v /dev/net/tun:/dev/net/tun \
  tailscale/tailscale:latest
```

## Troubleshooting

### "no link" on Wired Network

The original CrankkOS uses `mii-tool` for link detection which doesn't work with the RK3566 ethernet PHY. The patched image in this repo uses `/sys/class/net/carrier` instead. If you are using an unpatched image, you can fix this by editing `/etc/init.d/S40network` and replacing all `mii-tool` calls with carrier file checks.

### Can't Enter Flash Mode

- Ensure you are pressing the **BT-Pair** button (small button near the antenna SMA connector)
- The USB-C cable must support data transfer (not charge-only)
- Try holding the button for longer (up to 10 seconds)
- If the device was previously erased, it may enter Maskrom mode automatically without the button

### Serial Console Shows No Login Prompt

The original CrankkOS runs the serial getty at 115200 baud while the kernel console is at 1500000 baud. The patched image fixes this. If using an unpatched image, edit `/etc/inittab` and change the getty baud rate to 1500000.

### Docker Compose Fails on First Boot

This usually means the device had no network during boot. Ensure ethernet is connected before powering on. After fixing the network, restart docker-compose:

```bash
cd /etc && docker-compose up -d
```

## Image Modifications

The image was built by modifying the base CrankkOS 1.0.0 image. The changes made:

1. **`/etc/docker-compose.yml`** - Replaced Crankk container with Helium pktfwd + miner
2. **`/opt/packet_forwarder/tools/reset_lgw.sh.linxdot`** - Added LDO reset script for SX1302
3. **`/usr/share/dataskel/etc/shadow`** - Set root password to `crankk`
4. **`/etc/crontabs/root`** - Cleaned up crontab (logrotate only)
5. **`/etc/inittab`** - Fixed serial getty baud rate (115200 -> 1500000)
6. **`/etc/init.d/S40network`** - Replaced `mii-tool` with `/sys/class/net/carrier` for link detection, increased link negotiation timeout

## Credits

- [crankkio](https://github.com/crankkio) - Original CrankkOS Buildroot image
- [metrafonic/Linxdot-MinimalDocker](https://github.com/metrafonic/Linxdot-MinimalDocker) - Docker compose and modification guide
- [fernandodev/linxdot-rockchip-flash](https://github.com/fernandodev/linxdot-rockchip-flash) - Linux flashing guide and bootloader
- [heliumdiy/sx1302_hal](https://github.com/heliumdiy/sx1302_hal) - Packet forwarder Docker image
