# Lindot Hotspot - Documentation

## Overview

The Lindot Hotspot is a LoRa-based hotspot built around a single-board computer mounted in a metal enclosure. This repository contains documentation, reference datasheets, and hardware photos for the project.

## Hardware

### Main Board

The hotspot is built on a SBC (single-board computer) featuring:

- LoRa radio module
- Multiple USB ports
- SMA antenna connector (for LoRa antenna)
- GNSS connector
- Heatsink-cooled processor
- Enclosed in a metal housing for durability and RF shielding

### Audio Jack Connector

The board uses a **Tensility 54-00177** 4-conductor 3.5mm audio jack connector:

- **Type:** SMT mount, gold plated
- **Contacts:** 4 active (pins 5 and 6 are NC when unplugged)
- **Ratings:** 48V / 0.5A
- **Operating temperature:** -40 to 105 degC
- **Life cycle:** 5000 mating cycles
- **Housing:** PA9T, black, UL 94 V-0

Pin assignment (plugged):

| Pin | Connection |
|-----|------------|
| 1   | Tip        |
| 2   | Sleeve     |
| 3   | Ring 1     |
| 4   | Ring 2     |
| 5   | Switch     |
| 6   | Switch     |

See `Docs/54-00177.pdf` for the full datasheet including PCB layout dimensions and reflow soldering profile.

## Photos

- `Docs/IMG_4225.JPG` - Board mounted in enclosure (front view)
- `Docs/IMG_E4225.JPG` - Board mounted in enclosure (top view)
- `Docs/01-02-_2026_21-17-08.png` - 3.5mm jack pin diagram
- `Docs/01-02-_2026_21-17-19.png` - 3.5mm jack PCB layout
