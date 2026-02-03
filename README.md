# Linxdot Hotspot

![Platform](https://img.shields.io/badge/Platform-Rockchip_RK3566-blue)
![LoRa](https://img.shields.io/badge/LoRa-SX1302-green)
![OS](https://img.shields.io/badge/OS-LinxdotOS_(Buildroot)-orange)
![Kernel](https://img.shields.io/badge/Kernel-5.15.104-yellow)
![Docker](https://img.shields.io/badge/Docker-Enabled-2496ED?logo=docker&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

Custom **LinxdotOS** firmware for the **Linxdot LD1001** LoRa hotspot. A minimal Buildroot-based Linux + Docker system running **LoRa Basics Station** (WebSocket/TLS) for **TTN**, **ChirpStack**, or any compatible LoRa network server.

## :zap: Hardware

| Component | Details |
|-----------|---------|
| :computer: SoC | Rockchip RK3566, 4x Cortex-A55 @ 1.8 GHz |
| :floppy_disk: RAM | 2 GB DDR4 |
| :package: Storage | 28.9 GB eMMC (AT2Y1B) |
| :globe_with_meridians: Ethernet | Gigabit (RTL8211F, RGMII) |
| :satellite: WiFi/BT | Broadcom BCM43430 (SDIO) |
| :signal_strength: LoRa | Semtech SX1302 concentrator (SPI) |
| :lock: Security | Microchip ATECC608 secure element (I2C) |
| :electric_plug: Power | 12V DC input |
| :desktop_computer: Console | 3.5mm TRRS audio jack, 1.5 Mbaud |

## :open_file_folder: Repository Contents

```
.
├── board/linxdot/             # Buildroot board support
│   ├── overlay/               # Rootfs overlay (init scripts, configs)
│   ├── blobs/                 # Prebuilt kernel, DTB, bootloader (Git LFS)
│   ├── modules/               # Kernel modules (Git LFS)
│   └── genimage.cfg           # Partition layout
├── configs/
│   └── linxdot_ld1001_defconfig  # Buildroot defconfig
├── Docs/
│   ├── Linxdot.md             # Hardware reference & gateway config
│   ├── BasicsStation.md       # Basics Station setup guide (TTN)
│   ├── Flashing.md            # Step-by-step flashing guide
│   └── BuildProcess.md        # Build documentation
├── Images/                    # Built images (CI artifacts)
└── README.md
```

## :rocket: Quick Start

1. Download the latest image from [GitHub Releases](https://github.com/SensorsIot/Linxdot-Hotspot/releases) or [Actions Artifacts](https://github.com/SensorsIot/Linxdot-Hotspot/actions)
2. Connect the Linxdot via USB-C to a Raspberry Pi (or any Linux host with `rkdeveloptool`)
3. Put the device into Loader/Maskrom mode (hold BT-Pair button while powering on)
4. Flash the image:

```bash
xz -dk linxdot-basics-station.img.xz
sudo rkdeveloptool ld                    # Verify device detected
sudo rkdeveloptool wl 0 linxdot-basics-station.img
sudo rkdeveloptool rd                    # Reboot
```

5. SSH into the device:

```bash
ssh root@<linxdot-ip>
# Password: linxdot
```

See [Docs/Flashing.md](Docs/Flashing.md) for the full procedure and [Docs/BasicsStation.md](Docs/BasicsStation.md) for TTN setup.

## :hammer_and_wrench: Building

LinxdotOS is built using Buildroot with a BR2_EXTERNAL tree:

```bash
# Clone this repo
git clone https://github.com/SensorsIot/Linxdot-Hotspot.git
cd Linxdot-Hotspot

# Download Buildroot
wget https://buildroot.org/downloads/buildroot-2024.02.8.tar.xz
tar xf buildroot-2024.02.8.tar.xz
mv buildroot-2024.02.8 buildroot

# Configure and build
cd buildroot
make BR2_EXTERNAL=$(pwd)/.. linxdot_ld1001_defconfig
make -j$(nproc)

# Output image
ls -lh output/images/linxdot-basics-station.img
```

See [Docs/BuildProcess.md](Docs/BuildProcess.md) for detailed build documentation.

## :gear: Features

| Feature | Description |
|---------|-------------|
| LoRa Basics Station | Secure WebSocket/TLS connection to TTN or ChirpStack |
| Docker + Compose | Container runtime with docker-compose v2 |
| Read-only rootfs | Ext4 with overlayfs on `/data` partition |
| NTP time sync | Automatic time synchronization |
| Dropbear SSH | Lightweight SSH daemon |
| Gigabit Ethernet | DHCP client (dhcpcd) |

## :link: References

- [LoRa Basics Station](https://doc.sm.tc/station) - Semtech protocol documentation
- [TTN Gateway Guide](https://www.thethingsindustries.com/docs/gateways/) - The Things Network setup
- [Buildroot](https://buildroot.org/) - Embedded Linux build system
- [Rockchip RK3566](https://www.rock-chips.com/a/en/products/RK35_Series/2021/0113/1274.html)
- [Semtech SX1302](https://www.semtech.com/products/wireless-rf/lora-core/sx1302)
