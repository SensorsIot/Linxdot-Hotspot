# Linxdot Hotspot

![Platform](https://img.shields.io/badge/Platform-Rockchip_RK3566-blue)
![LoRa](https://img.shields.io/badge/LoRa-SX1302-green)
![OS](https://img.shields.io/badge/OS-CrankkOS_(Buildroot)-orange)
![Kernel](https://img.shields.io/badge/Kernel-5.15.104-yellow)
![Docker](https://img.shields.io/badge/Docker-Enabled-2496ED?logo=docker&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

Minimal Linux + Docker firmware for the **Linxdot LD1001** LoRa hotspot, based on a modified CrankkOS image with bug fixes for ethernet link detection and serial console.

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
├── Docs/
│   ├── Linxdot.md              # Hardware reference & image build docs
│   ├── Flashing.md             # Step-by-step flashing guide
│   ├── 54-00177.pdf            # Serial console jack datasheet
│   ├── IMG_4225.JPG            # Board photo (front)
│   ├── IMG_E4225.JPG           # Board photo (top)
│   ├── 01-02-_2026_21-17-08.png  # Jack pin diagram
│   └── 01-02-_2026_21-17-19.png  # Jack PCB layout
├── Images/
│   └── crankkos-linxdotrk3566-1.0.0.img.xz  # Firmware image (65 MB)
└── README.md
```

## :rocket: Quick Start

1. Connect the Linxdot via USB-C to a Raspberry Pi (or any Linux host with `rkdeveloptool`)
2. Put the device into Maskrom mode (erase flash or hold recovery button)
3. Flash the image:

```bash
rkdeveloptool db rk356x_spl_loader_ddr1056_v1.10.111.bin
xz -dk Images/crankkos-linxdotrk3566-1.0.0.img.xz
rkdeveloptool wl 0 Images/crankkos-linxdotrk3566-1.0.0.img
rkdeveloptool rd
```

See [Docs/Flashing.md](Docs/Flashing.md) for the full procedure including prerequisites and troubleshooting.

## :wrench: Image Modifications

The firmware is based on the original CrankkOS image with these fixes:

| Fix | Problem |
|-----|---------|
| :white_check_mark: Ethernet link detection | `mii-tool` replaced with `/sys/class/net/carrier` (RTL8211F doesn't support MII) |
| :white_check_mark: Serial console baud rate | Getty baud changed from 115200 to 1500000 to match kernel console |
| :white_check_mark: Docker containers | Replaced defunct Crankk services with Helium packet forwarder + gateway miner |
| :white_check_mark: Root password | Set to `crankk` |
| :white_check_mark: Crontab cleanup | Removed Crankk-specific jobs |

See [Docs/Linxdot.md](Docs/Linxdot.md) for full hardware documentation and image build details.

## :link: References

- [Linxdot MinimalDocker](https://github.com/metrafonic/Linxdot-MinimalDocker) - Original flashing tools
- [motionEyeOS](https://github.com/motioneye-project/motioneyeos) - CrankkOS is based on Calin Crisan's Buildroot platform
- [Rockchip RK3566](https://www.rock-chips.com/a/en/products/RK35_Series/2021/0113/1274.html)
- [Semtech SX1302](https://www.semtech.com/products/wireless-rf/lora-core/sx1302)
