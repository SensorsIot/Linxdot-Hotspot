---
name: linxdot-flash
description: Flash firmware and debug Linxdot device via Pi gateway at 192.168.0.41
triggers:
  - flash linxdot
  - flash the device
  - put in loader mode
  - serial console
  - console debug
  - watch boot
  - reboot linxdot
allowed-tools: Bash, Read
---

# Linxdot Flash & Debug Skill

Flash firmware images and debug the Linxdot device via a Raspberry Pi gateway.

## Setup

- **Pi Gateway**: 192.168.0.41 (user: pi, SSH key auth)
- **Serial Console**: /dev/ttyUSB0 at 1500000 baud (FTDI adapter)
- **Flash Tool**: rkdeveloptool (Rockchip USB loader)
- **Linxdot Default**: root/linxdot

## Commands

### Check if device is in loader mode
```bash
ssh -i ~/.ssh/id_ed25519 pi@192.168.0.41 "sudo rkdeveloptool ld"
```
Expected: `DevNo=1 Vid=0x2207,Pid=0x350a,LocationID=102 Loader`

### Flash an image
```bash
# Transfer image to Pi
scp -i ~/.ssh/id_ed25519 /path/to/image.img pi@192.168.0.41:/tmp/

# Flash (device must be in loader mode)
ssh -i ~/.ssh/id_ed25519 pi@192.168.0.41 "sudo rkdeveloptool wl 0 /tmp/image.img"

# Reboot after flash
ssh -i ~/.ssh/id_ed25519 pi@192.168.0.41 "sudo rkdeveloptool rd"
```

### Watch serial console
```bash
ssh -i ~/.ssh/id_ed25519 pi@192.168.0.41 'sudo timeout 60 picocom -b 1500000 /dev/ttyUSB0 --noreset 2>&1'
```

### Send commands to U-Boot
```bash
ssh -i ~/.ssh/id_ed25519 pi@192.168.0.41 '(
sleep 1
echo "your command here"
sleep 2
) | sudo picocom -b 1500000 /dev/ttyUSB0 --noreset -x 5000 2>&1'
```

### Manual boot from U-Boot prompt
```bash
ssh -i ~/.ssh/id_ed25519 pi@192.168.0.41 '(
sleep 1
echo "setenv bootargs root=/dev/mmcblk1p2 rootfstype=ext4 rootwait console=ttyS2,1500000"
sleep 1
echo "load mmc 0:1 0x00280000 Image"
sleep 3
echo "load mmc 0:1 0x0a100000 rk3566-linxdot.dtb"
sleep 1
echo "booti 0x00280000 - 0x0a100000"
sleep 30
) | sudo picocom -b 1500000 /dev/ttyUSB0 --noreset 2>&1'
```

### Connect to booted Linxdot via SSH
```bash
sshpass -p 'linxdot' ssh -o StrictHostKeyChecking=no root@<LINXDOT_IP> "command"
```

## Typical Workflow

1. **Download artifact** from GitHub Actions
2. **Decompress**: `xz -d linxdot-basics-station.img.xz`
3. **Put device in loader mode** (hold recovery button + power, or `reboot loader` from Linux)
4. **Verify loader mode**: Check rkdeveloptool ld
5. **Transfer image** to Pi
6. **Flash image** with rkdeveloptool wl
7. **Reboot** with rkdeveloptool rd
8. **Watch console** for boot progress
9. **SSH in** once booted

## Notes

- Device gets IP via DHCP (check Pi's ARP table: `ip neigh`)
- Boot uses extlinux.conf (not boot.scr)
- Console baud rate: 1500000
- U-Boot timeout: ~3 seconds
