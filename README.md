# Linxdot LoRa Gateway

[![Build](https://github.com/SensorsIot/Linxdot-Hotspot/actions/workflows/build.yml/badge.svg)](https://github.com/SensorsIot/Linxdot-Hotspot/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/SensorsIot/Linxdot-Hotspot?include_prereleases)](https://github.com/SensorsIot/Linxdot-Hotspot/releases)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

![LoRaWAN](https://img.shields.io/badge/LoRaWAN-Gateway-green)
![TTN](https://img.shields.io/badge/TTN-Compatible-blue)
![Platform](https://img.shields.io/badge/Platform-Linxdot_LD1001-orange)

Turn your **Linxdot LD1001** into a **LoRaWAN gateway** for [The Things Network](https://www.thethingsnetwork.org/).

## What is This?

OpenLinxdot is a custom firmware that connects your Linxdot hotspot to TTN (The Things Network) using the secure Basics Station protocol. No cloud subscriptions, no monthly fees — just a working LoRa gateway.

## Get Started

**[Quick Start Guide](Docs/QuickStart.md)** — Flash your device and connect to TTN in 10 minutes.

### TL;DR

1. Download `linxdot-basics-station.img.xz` from [Releases](https://github.com/SensorsIot/Linxdot-Hotspot/releases)
2. Flash with `rkdeveloptool` (hold BT-Pair button while powering on)
3. SSH in: `ssh root@<ip>` (password: `linxdot`)
4. Add your TTN API key: `echo 'NNSXS.your-key...' > /data/basicstation/tc_key.txt`
5. Restart: `/etc/init.d/S80dockercompose restart`

That's it. Your gateway is now on TTN.

## Downloads

| File | Description |
|------|-------------|
| [linxdot-basics-station.img.xz](https://github.com/SensorsIot/Linxdot-Hotspot/releases/latest) | Ready-to-flash firmware image |

## Requirements

- Linxdot LD1001 hotspot
- USB-C data cable
- Ethernet connection
- Linux computer for flashing (Raspberry Pi works great)
- Free [TTN account](https://console.cloud.thethings.network)

## Features

- Connects to TTN via secure WebSocket (no ports to open)
- Works behind NAT/firewalls
- Frequency plan downloaded from server
- Survives reboots — just add your key once
- EU868, US915, AU915, and other regions supported

## Support

- [Quick Start Guide](Docs/QuickStart.md) — Step-by-step setup
- [Troubleshooting](Docs/QuickStart.md#troubleshooting) — Common issues and fixes

## For Developers

Building from source or repurposing the hardware for other projects?

- [Hardware Reference](Docs/Hardware.md) — GPIO pinouts, serial console, technical specs
- [Build Process](Docs/BuildProcess.md) — Compiling OpenLinxdot from source

### Tech Stack

![Buildroot](https://img.shields.io/badge/Buildroot-2024.02-yellow)
![Kernel](https://img.shields.io/badge/Kernel-5.15.104-blue)
![Docker](https://img.shields.io/badge/Docker-Enabled-2496ED?logo=docker&logoColor=white)
![SX1302](https://img.shields.io/badge/LoRa-SX1302-green)
![RK3566](https://img.shields.io/badge/SoC-RK3566-red)

## License

MIT
