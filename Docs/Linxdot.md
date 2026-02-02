# Linxdot LD1001 (RK3566 R01) - Hardware Reference

## Overview

The Linxdot LD1001 is a LoRa hotspot built around the Rockchip RK3566 SoC. The board is mounted in a metal enclosure with a heatsink on the processor. Originally designed for the Helium network, it now runs a configurable Semtech UDP packet forwarder for TTN, ChirpStack, or any compatible LoRa network server.

- **Device tree model:** `Linxdot RK3566 R01`
- **Product name:** Linxdot LD1001
- **Form factor:** Metal enclosure (~100x100mm) with passive heatsink

## Gateway Configuration

The device runs a single Docker container (`pktfwd`) with the Semtech UDP packet forwarder, preconfigured for TTN EU1.

### Default Settings

| Setting       | Default Value                     |
|---------------|-----------------------------------|
| `SERVER_HOST` | `eu1.cloud.thethings.network`     |
| `SERVER_PORT` | `1700`                            |
| `REGION`      | `EU868`                           |
| `VENDOR`      | `linxdot`                         |

### Gateway EUI

The gateway EUI is derived from the SX1302 concentrator chip and is unique per device. It is logged on startup:

```
INFO: concentrator EUI: 0x0016c001f140b34d
```

Use this EUI (without the `0x` prefix) to register the gateway on TTN or ChirpStack.

### Changing the Network Server

SSH into the device and edit `/etc/docker-compose.yml`:

```yaml
environment:
  VENDOR: linxdot
  REGION: EU868
  SERVER_HOST: eu1.cloud.thethings.network
  SERVER_PORT: 1700
```

Replace `SERVER_HOST` and `SERVER_PORT` with your target server:

| Network Server | `SERVER_HOST`                      | `SERVER_PORT` |
|----------------|------------------------------------|---------------|
| TTN EU1        | `eu1.cloud.thethings.network`      | `1700`        |
| TTN US1        | `nam1.cloud.thethings.network`     | `1700`        |
| TTN AU1        | `au1.cloud.thethings.network`      | `1700`        |
| ChirpStack     | `<your-chirpstack-host>`           | `1700`        |

Then restart the container:

```bash
cd /etc && docker compose restart pktfwd
```

### Changing the Region

To use a different frequency plan, edit the `REGION` environment variable in `/etc/docker-compose.yml`. Supported values: `EU868`, `US915`, `AU915`, `AS923`, `KR920`, `IN865`, `CN470`, `RU864`.

### How It Works

On container startup, `setup_server.sh` runs before the packet forwarder and:

1. Patches `server_address`, `serv_port_up`, and `serv_port_down` in all `global_conf.json` files to match `SERVER_HOST` and `SERVER_PORT`
2. Resets the SX1302 concentrator via GPIO, then reads the hardware EUI using `chip_id` and patches `gateway_ID` to match

The standard Semtech `lora_pkt_fwd` binary then starts and forwards packets via UDP.

### Verifying Operation

```bash
docker logs -f pktfwd
```

You should see:
1. `setup_server: configuring server_address=...` confirming the server was patched
2. Concentrator initialization messages
3. Periodic `PUSH_ACK` and `PULL_ACK` messages confirming connectivity to the server


## Basics Station (Alternative to UDP Packet Forwarder)

An alternative **Basics Station** image (`crankkos-linxdotrk3566-1.0.0-basicstation.img.xz`) is available that connects to TTN over WebSocket/TLS instead of Semtech UDP. This provides authenticated, encrypted, NAT-friendly connectivity with server-side frequency plan management.

See [BasicsStation.md](BasicsStation.md) for complete setup instructions including TTN registration, API key configuration, concentrator reset, and troubleshooting.

## System on Chip

| Property | Value |
|----------|-------|
| SoC | Rockchip RK3566 |
| CPU | 4x ARM Cortex-A55 (ARMv8.2-A) |
| GPU | Mali-G52 (not used) |
| NPU | RKNN (not used) |
| BogoMIPS | 48.00 per core |
| Features | fp, asimd, aes, pmull, sha1, sha2, crc32, atomics |
| Interrupt controller | GICv3, 320 SPIs |
| DMA | 2x PL330 DMAC (8 channels each, 32 peripherals) |
| Timer | ARM arch_sys_counter @ 24 MHz |

## Memory

| Property | Value |
|----------|-------|
| Total RAM | 2,020,016 KB (~2 GB DDR4) |
| Address range | 0x00200000 - 0x7FFFFFFF |
| CMA reserved | 16 MB |

## Storage (eMMC)

| Property | Value |
|----------|-------|
| Controller | Rockchip SDHCI (fe310000.mmc) |
| Mode | HS200 |
| Device | AT2Y1B |
| Capacity | 28.9 GiB (30,302,208 blocks) |
| CID | `ec01004154325931422b802d00b9b800` |

### Partition Layout

| Partition | Device | Size | Mount | Filesystem |
|-----------|--------|------|-------|------------|
| Boot | mmcblk1p1 | 30 MB | /boot | vfat |
| Root | mmcblk1p2 | 500 MB | / | ext4 (ro) |
| Data | mmcblk1p3 | 27.9 GB | /data | ext4 |

The rootfs is mounted read-only. Writable directories (`/usr`, `/var/log`, `/var/lib`) use overlayfs backed by `/data`.

Boot partitions `mmcblk1boot0` and `mmcblk1boot1` are 4 MB each. There is also a 4 MB RPMB partition.

## Power Management

### Primary PMIC: RK809

- **I2C bus:** i2c-0, address 0x20
- **Chip ID:** 0x8090
- **RTC:** Integrated (registered as rtc0)

Regulated supplies from RK809:

| Rail | Source |
|------|--------|
| vdd_logic | vcc-sys |
| vdd_gpu | vcc-sys |
| vcc_ddr | vcc-sys |
| vdd_npu | vcc-sys |
| vcc_1v8 | vcc-sys |
| vdda0v9_image | vcc-sys |
| vdda_0v9 | vcc-sys |
| vdda0v9_pmu | vcc-sys |
| vccio_acodec | vcc-sys |
| vccio_sd | vcc-sys |
| vcc3v3_pmu | vcc-sys |
| vcca_1v8 | vcc-sys |
| vcca1v8_pmu | vcc-sys |
| vcca1v8_image | vcc-sys |
| vcc_3v3 | vcc-sys |
| vcc3v3_sw2 | vcc-sys |

### CPU Voltage Regulator: TCS4525

- **I2C bus:** i2c-0, address 0x1C
- **Type:** FAN53555-compatible (Option[12] Rev[15])
- **Rail:** vdd_cpu, supplied by vcc-sys

### Power Input

- **Input:** 12V DC (vcc12v-dcin)
- **USB 5V:** vcc5v0-usb, supplied by vcc12v-dcin
- **USB 2.0 host:** vcc5v0-usb20-host, supplied by vcc5v0-usb

### Dedicated Supplies

| Rail | Source | Purpose |
|------|--------|---------|
| vcc3v3-lora | vcc3v3_sw2 | LoRa concentrator |
| vcc3v3-gnss | vcc-sys | GNSS module |
| vcc3v3-sdmmc | vcc-sys | SD card slot |

## Ethernet

| Property | Value |
|----------|-------|
| Controller | rk_gmac-dwmac (Synopsys DWMAC4/5) |
| Base address | 0xfe010000 |
| User ID / Synopsys ID | 0x30 / 0x51 |
| Interface mode | RGMII |
| PHY | Realtek RTL8211F Gigabit Ethernet |
| PHY address | stmmac-1:01 |
| TX delay | 0x4f |
| RX delay | 0x25 |
| Features | RX checksum offload, TX checksum insertion, TSO, WoL, IEEE 1588-2008 timestamps |
| DMA width | 32 bits |
| Link speed | 1 Gbps (may downshift to 100 Mbps depending on cable quality) |

**Note:** The RTL8211F PHY does not support the legacy `mii-tool` interface. Link detection must use `/sys/class/net/eth0/carrier` or `ethtool`.

## WiFi + Bluetooth

| Property | Value |
|----------|-------|
| Chip | Broadcom BCM43430 |
| WiFi driver | brcmfmac |
| WiFi interface | SDIO (mmc2, non-removable) |
| WiFi firmware | BCM43430/1 v7.45.96.24 (Jun 13 2018) |
| Bluetooth | BCM43430A1 HCI UART |
| BT firmware | (001.002.009) build 0000 |

The WiFi SDIO runs at 50 MHz high-speed mode. Bluetooth firmware file `BCM43430A1.hcd` is not included in the image (non-critical if BT is unused).

## LoRa Concentrator

| Property | Value |
|----------|-------|
| Chip | Semtech SX1302 |
| Bus | SPI0 (spi0.0) |
| Kernel modalias | `spi:sx1301` (legacy name) |
| Power supply | vcc3v3-lora (from vcc3v3_sw2) |
| Antenna | External, via SMA connector on enclosure |
| Reset | GPIO-based LDO reset (see `reset_lgw.sh.linxdot`) |

The SX1302 concentrator connects via SPI bus 0, chip select 0. Note that the device tree registers it as `sx1301` for compatibility, but the actual chip is an SX1302.

SPI0 CS1 is defined in the device tree but fails to register (`cs1 >= max 1`), indicating only one SPI device is used.

## Serial Ports (UART)

| Port | Address | IRQ | Base baud | Function |
|------|---------|-----|-----------|----------|
| ttyS1 | 0xfe650000 | 35 | 1,500,000 | Bluetooth HCI (serial0) |
| ttyS2 | 0xfe660000 | 36 | 1,500,000 | **Console** (kernel + getty) |
| ttyS3 | 0xfe670000 | 37 | 1,500,000 | Available |

All UARTs are 16550A compatible.

### Serial Console Access

The serial console (ttyS2) is exposed via a **Tensility 54-00177** 3.5mm 4-conductor audio jack on the board edge.

- **Baud rate:** 1,500,000 (1.5 Mbaud)
- **Settings:** 8N1 (8 data bits, no parity, 1 stop bit)
- **Kernel command line:** `console=ttyS2,1500000`

See `Docs/54-00177.pdf` for the audio jack datasheet and pinout.

A standard FTDI USB-to-serial adapter with a 3.5mm TRRS cable can be used for console access. Use `picocom -b 1500000 /dev/ttyUSB0` or equivalent.

## I2C Buses

| Bus | Controller | Devices |
|-----|-----------|---------|
| i2c-0 | rk3x-i2c | TCS4525 (0x1C), RK809 (0x20) |
| i2c-3 | rk3x-i2c | STTS751 temperature sensor (0x72) |
| i2c-5 | rk3x-i2c | Microchip ECC608 secure element (0x60) |

### Temperature Sensor: STTS751

- **I2C bus:** i2c-3, address 0x72
- **Function:** Board temperature monitoring

### Secure Element: Microchip ATECC608

- **I2C bus:** i2c-5, address 0x60 (96 decimal)
- **Function:** Cryptographic key storage for Helium/Crankk identity
- **Slot 0:** Gateway keypair (`GW_KEYPAIR=ecc://i2c-5:96?slot=0`)
- **Slot 15:** Onboarding key (`GW_ONBOARDING=ecc://i2c-5:96?slot=15`)

## USB

| Controller | Type | Address | Bus |
|-----------|------|---------|-----|
| EHCI #1 | USB 2.0 | 0xfd800000 | Bus 1, 1 port |
| EHCI #2 | USB 2.0 | 0xfd880000 | Bus 2, 1 port |
| OHCI #1 | USB 1.1 | 0xfd840000 | Bus 3, 1 port |
| OHCI #2 | USB 1.1 | 0xfd8c0000 | Bus 4, 1 port |

The USB-C port on the board is used for both flashing (Maskrom/Loader mode via Rockchip USB protocol) and USB host connectivity.

## GPIO

5 GPIO banks are available:

| Bank | Address | Node |
|------|---------|------|
| GPIO0 | 0xfdd60000 | gpio0 |
| GPIO1 | 0xfe740000 | gpio1 |
| GPIO2 | 0xfe750000 | gpio2 |
| GPIO3 | 0xfe760000 | gpio3 |
| GPIO4 | 0xfe770000 | gpio4 |

## Thermal Monitoring

| Zone | Temperature (typical idle) |
|------|---------------------------|
| cpu-thermal | ~29 C |
| gpu-thermal | ~27 C |

## Boot Process

1. RK3566 BootROM loads SPL from eMMC boot partition (or enters Maskrom mode if no valid bootloader)
2. SPL (`rk356x_spl_loader_ddr1056_v1.10.111.bin`) initializes DDR and loads U-Boot
3. U-Boot loads kernel from mmcblk1p1
4. Kernel mounts mmcblk1p2 as read-only rootfs
5. Init (BusyBox) starts services, mounts overlays from mmcblk1p3
6. Docker starts `pktfwd` container (UDP packet forwarder for TTN/ChirpStack)

### Kernel Command Line

```
root=/dev/mmcblk1p2 rootfstype=ext4 rootwait ro rootflags=noload console=ttyS2,1500000 panic=10 hung_task_panic=1 quiet loglevel=1
```

## Software

| Component | Details |
|-----------|---------|
| OS | CrankkOS (Buildroot-based) |
| Kernel | Linux 5.15.104 (aarch64) |
| Compiler | aarch64-none-linux-gnu-gcc 10.3.1 |
| Init | BusyBox |
| Container runtime | Docker with docker-compose |
| SSH | Dropbear |

## Connectors (External)

| Connector | Type | Function |
|-----------|------|----------|
| Ethernet | RJ45 | Gigabit Ethernet (RTL8211F) |
| USB-C | USB Type-C | Power input / Flashing / USB host |
| LoRa antenna | SMA female | SX1302 LoRa antenna |
| GNSS antenna | U.FL / SMA | GPS/GNSS (if populated) |
| Serial console | 3.5mm TRRS | UART ttyS2 @ 1.5 Mbaud |

## Photos

- `Docs/IMG_4225.JPG` - Board mounted in enclosure (front view showing heatsink, SMA connector, USB ports)
- `Docs/IMG_E4225.JPG` - Board mounted in enclosure (top view)
- `Docs/01-02-_2026_21-17-08.png` - 3.5mm audio jack pin diagram
- `Docs/01-02-_2026_21-17-19.png` - 3.5mm audio jack PCB layout

## Firmware Image

The firmware image `Images/crankkos-linxdotrk3566-1.0.0.img.xz` is not built from source. It is a modified
version of the original CrankkOS base image.

### Base Image

Downloaded from the Crankk CDN:

```
https://crkk1.spaces.crankk.net/crankkos-linxdotrk3566-1.0.0.img.xz
```

CrankkOS is a Buildroot-based Linux distribution created by
[Calin Crisan](https://github.com/ccrisan) (known for
[motionEyeOS](https://github.com/motioneye-project/motioneyeos)).
It uses the same architecture: read-only rootfs with overlayfs on a data partition,
BusyBox init, Dropbear SSH, and Docker.

### Modifications

The image was mounted on a Linux host using loop devices and modified in-place:

```bash
losetup --find --show --partscan crankkos-linxdotrk3566-1.0.0.img
mount /dev/loop0p2 /mnt    # partition 2 = rootfs
```

The following files were changed:

| File | Change | Reason |
|------|--------|--------|
| `/etc/docker-compose.yml` | Single `pktfwd` container with configurable `SERVER_HOST`/`SERVER_PORT` for TTN/ChirpStack | Original Crankk/Helium services replaced with generic UDP packet forwarder |
| `/opt/packet_forwarder/setup_server.sh` | Startup script patching server address, port, and gateway EUI | Makes forwarder configurable via environment variables |
| `/opt/packet_forwarder/tools/reset_lgw.sh.linxdot` | Added SX1302 LDO reset script | Required by packet forwarder to initialize the LoRa concentrator |
| `/usr/share/dataskel/etc/shadow` | Set root password to `crankk` | CrankkOS templates overlay passwords from dataskel |
| `/etc/crontabs/root` | Removed Crankk-specific cron jobs, kept logrotate | Clean up unused scheduled tasks |
| `/etc/inittab` | Changed getty baud from `115200` to `1500000` | Must match kernel console baud rate, otherwise no login prompt on serial |
| `/etc/init.d/S40network` | Replaced `mii-tool` with `/sys/class/net/eth0/carrier` checks; increased link timeout from 10s to 30s | RTL8211F PHY on DWMAC4/5 does not support legacy MII interface |

After modification:

```bash
umount /mnt
losetup -d /dev/loop0
xz -9 crankkos-linxdotrk3566-1.0.0.img
```

The resulting file keeps the original filename but contains the fixes above.
The uncompressed image is a raw disk image (3 partitions) written directly to
eMMC via `rkdeveloptool wl 0`. See `Docs/Flashing.md` for the full procedure.

## References

- [Linxdot MinimalDocker](https://github.com/metrafonic/Linxdot-MinimalDocker) - Flashing tools and base image
- [Rockchip RK3566 datasheet](https://www.rock-chips.com/a/en/products/RK35_Series/2021/0113/1274.html)
- [Semtech SX1302 datasheet](https://www.semtech.com/products/wireless-rf/lora-core/sx1302)
- [Realtek RTL8211F datasheet](https://www.realtek.com/en/component/zoo/category/network-interface-controllers-10-100-1000m-gigabit-ethernet-phys-rtl8211f-i-cg)
