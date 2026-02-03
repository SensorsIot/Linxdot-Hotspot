# OpenLinxdot Quick Start

Get your Linxdot LD1001 connected to The Things Network in 10 minutes.

## What You Need

- Linxdot LD1001 hotspot
- USB-C data cable (not charge-only)
- Ethernet cable
- Linux computer (Raspberry Pi, PC, or VM)
- Free TTN account at [console.cloud.thethings.network](https://console.cloud.thethings.network)

## Step 1: Download the Image

Get the latest `linxdot-basics-station.img.xz` from:

**[GitHub Releases](https://github.com/SensorsIot/Linxdot-Hotspot/releases)**

Decompress it:

```bash
xz -d linxdot-basics-station.img.xz
```

## Step 2: Install Flashing Tool

```bash
sudo apt-get install rkdeveloptool
```

## Step 3: Put Device in Flash Mode

1. Connect USB-C cable between Linxdot and your computer
2. With power **disconnected**, press and hold the **BT-Pair** button (small button near the antenna connector)
3. While holding the button, connect the power cable
4. Hold for 5 seconds, then release

Verify detection:

```bash
sudo rkdeveloptool ld
```

You should see: `DevNo=1 Vid=0x2207,Pid=0x350a,LocationID=xxx Loader`

## Step 4: Flash the Image

```bash
sudo rkdeveloptool wl 0 linxdot-basics-station.img
sudo rkdeveloptool rd
```

The device will reboot. Connect the ethernet cable now.

## Step 5: Find the Gateway EUI

Wait 2 minutes for first boot, then SSH into the device:

```bash
ssh root@<device-ip>
# Password: linxdot
```

Get the Gateway EUI:

```bash
/etc/init.d/S80dockercompose status
docker logs basicstation 2>&1 | grep "Station EUI"
```

Note the 16-character EUI (e.g., `0016C001F140B34D`).

## Step 6: Register on TTN

1. Log in to [TTN Console](https://console.cloud.thethings.network)
2. Select your region (Europe = `eu1`)
3. Go to **Gateways** → **Register gateway**
4. Enter the Gateway EUI from Step 5
5. Select your frequency plan (e.g., `Europe 863-870 MHz`)
6. Click **Register gateway**

## Step 7: Create API Key

On your gateway page in TTN Console:

1. Click **API keys** → **Add API key**
2. Name it (e.g., `LNS`)
3. Check **Link as Gateway to a Gateway Server...**
4. Click **Create API key**
5. **Copy the key now** (starts with `NNSXS.`) — you won't see it again

## Step 8: Configure the Gateway

SSH into the Linxdot and add your API key:

```bash
ssh root@<device-ip>

# Add your key (replace with your actual key)
echo 'NNSXS.YOUR-KEY-HERE...' > /data/basicstation/tc_key.txt

# Start the gateway
/etc/init.d/S80dockercompose restart
```

## Step 9: Verify Connection

Check the status:

```bash
/etc/init.d/S80dockercompose status
```

You should see:
```
TC_KEY: configured (98 chars)
Reset script: OK
Docker containers:
  basicstation: Up
```

On TTN Console, your gateway should show **Connected**.

## Changing Region

If you're not in Europe, edit the region:

```bash
vi /data/docker-compose.yml
```

Change `TTS_REGION` to your region:

| Region | Value |
|--------|-------|
| Europe | `eu1` |
| North America | `nam1` |
| Australia | `au1` |

Then restart:

```bash
/etc/init.d/S80dockercompose restart
```

## Troubleshooting

**Can't enter flash mode**
- Ensure you're pressing the BT-Pair button (near antenna connector)
- Try a different USB-C cable (must support data, not just charging)
- Hold the button longer (up to 10 seconds)

**No network after boot**
- Connect ethernet before powering on
- Check your router's DHCP leases for the device IP

**"TC_KEY: NOT CONFIGURED"**
- You haven't added your API key yet — go to Step 8

**"Failed to set SX1250_0 in STANDBY_RC mode"**
- Power cycle the device (unplug power, wait 5 seconds, replug)
- Then run: `/etc/init.d/S80dockercompose restart`

**Gateway not showing on TTN**
- Verify the EUI matches what you registered
- Check the API key is correct (no extra spaces or newlines)
- Run `docker logs basicstation` to see connection errors

## Default Credentials

| Access | Username | Password |
|--------|----------|----------|
| SSH | `root` | `linxdot` |

Change the password after first login:

```bash
passwd
```

## Serial Console (Optional)

For debugging without network, connect via the 3.5mm audio jack:

- **Baud rate:** 1,500,000 (1.5 Mbaud)
- **Settings:** 8N1

```bash
picocom -b 1500000 /dev/ttyUSB0
```

## Next Steps

- [Hardware Reference](Hardware.md) — GPIO pinouts, serial console wiring, technical specs
- [Build Process](BuildProcess.md) — Building OpenLinxdot from source
