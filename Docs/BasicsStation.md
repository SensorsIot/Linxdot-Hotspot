# Basics Station Setup

Connect your Linxdot LD1001 to The Things Network (TTN) using the secure Basics Station protocol.

For flashing the image, see [Flashing.md](Flashing.md).

## What You Need

- Linxdot LD1001 flashed with LinxdotOS (`linxdot-basics-station.img.xz`)
- Ethernet cable plugged into the Linxdot
- A free account on [TTN](https://console.cloud.thethings.network/)

## Step 1: Find the Gateway EUI

After flashing, the Linxdot boots and the `basicstation` container starts automatically. It will fail because it does not have an API key yet, but it will print the Gateway EUI in the logs.

SSH into the Linxdot:

```
ssh root@<linxdot-ip>
Password: linxdot
```

Then run:

```
docker logs basicstation 2>&1 | grep "gateway EUI"
```

You will see something like:

```
Gateway EUI: 0016C001F140B34D
```

or

```
gateway EUI `0016C001F140B34D` is not registered
```

Write down the EUI (16 hex characters). You need it in the next step.

## Step 2: Register the Gateway on TTN

1. Log in to [TTN Console](https://console.cloud.thethings.network/)
2. Pick your region (Europe = `eu1`, North America = `nam1`, Australia = `au1`)
3. Go to **Gateways** in the left menu
4. Click **Register gateway**
5. Paste the Gateway EUI from Step 1
6. Pick the **Frequency plan** for your country (e.g. `Europe 863-870 MHz (SF7-SF12 for RX2)`)
7. Click **Register gateway**

## Step 3: Create an API Key

Still on the TTN Console, on your gateway page:

1. Click **API Keys** in the left menu
2. Click **Add API key**
3. Give it a name (e.g. `LNS key`)
4. Tick the box **Link as Gateway to a Gateway Server for traffic exchange, ...**
5. Click **Create API key**
6. **Copy the key now** — it starts with `NNSXS.` and you will not be able to see it again

## Step 4: Set the API Key on the Linxdot

SSH into the Linxdot (if not already connected):

```
ssh root@<linxdot-ip>
Password: linxdot
```

Copy the config file to the writable partition and open it in the editor:

```
cp /etc/docker-compose.yml /data/docker-compose.yml
vi /data/docker-compose.yml
```

Find the line:

```
      TC_KEY: "${TC_KEY}"
```

Replace `${TC_KEY}` with your actual key. It should look like:

```
      TC_KEY: "NNSXS.JHUUDOX...your-full-key-here..."
```

Save and exit (`Esc`, then `:wq`).

The init script automatically uses `/data/docker-compose.yml` if it exists, so your settings will persist across reboots.

## Step 5: Restart the Container

Restart the basicstation container to apply the new API key:

```
docker-compose -f /data/docker-compose.yml down
docker-compose -f /data/docker-compose.yml up -d
```

The init script automatically resets the LoRa concentrator before starting the container. If you see errors about the concentrator not initializing, power cycle the Linxdot (unplug power, wait 5 seconds, replug).

## Step 6: Check That It Works

Wait about 2 minutes for the Linxdot to boot, then SSH in again:

```
ssh root@<linxdot-ip>
docker logs basicstation
```

Look for these lines:

```
[TCE:INFO] Connecting to INFOS: wss://eu1.cloud.thethings.network:8887
[S00:INFO] Concentrator started (2s354ms)
```

On the TTN Console, your gateway should now show **Connected**.

## Changing the Region

If you are not in Europe, edit `/data/docker-compose.yml` and change `TTS_REGION`:

| Region | Value |
|--------|-------|
| Europe | `eu1` |
| North America | `nam1` |
| Australia | `au1` |

Then restart:

```
docker-compose -f /data/docker-compose.yml down
docker-compose -f /data/docker-compose.yml up -d
```

## Settings Persistence

Your `/data/docker-compose.yml` is automatically used by the init script on every boot. Settings persist across reboots without any additional setup.

## Troubleshooting

**"gateway EUI is not registered"** — You have not registered this EUI on TTN yet. Go to Step 2.

**"Failed to set SX1250_0 in STANDBY_RC mode"** — The LoRa radio did not reset properly. Unplug and replug the Linxdot power cable.

**"Missing configuration, either force key-less CUPS..."** — The API key is not set. Go to Step 4.

**Container keeps restarting** — Run `docker logs basicstation` to see the error. Usually one of the above three issues.

## Why Basics Station Instead of UDP

| | UDP Packet Forwarder | Basics Station |
|-|----------------------|----------------|
| Security | Unencrypted UDP | Encrypted WebSocket (TLS) |
| Authentication | None | API key |
| Firewall | Needs port 1700 open | Works behind NAT, no ports to open |
| Frequency plan | Set manually on the device | Downloaded from the server |

## Technical Reference

### Docker Compose Configuration

The image ships with this `/etc/docker-compose.yml`:

```yaml
services:
  basicstation:
    image: xoseperez/basicstation:latest
    container_name: basicstation
    restart: always
    privileged: true
    network_mode: host
    environment:
      MODEL: SX1302
      INTERFACE: SPI
      DEVICE: /dev/spidev0.0
      RESET_GPIO: 0
      GATEWAY_EUI_SOURCE: chip
      TTS_REGION: eu1
      TC_KEY: "${TC_KEY}"
    volumes:
      - /data/basicstation:/config
```

| Variable | Value | Description |
|----------|-------|-------------|
| `MODEL` | `SX1302` | Concentrator chip model |
| `INTERFACE` | `SPI` | Bus interface to the concentrator |
| `DEVICE` | `/dev/spidev0.0` | SPI device path on the Linxdot |
| `RESET_GPIO` | `0` | Disabled — concentrator reset is handled by power cycling the board |
| `GATEWAY_EUI_SOURCE` | `chip` | EUI is derived from the concentrator hardware |
| `TTS_REGION` | `eu1` | TTN cluster (`eu1`, `nam1`, `au1`) |
| `TC_KEY` | (required) | TTN LNS API key (starts with `NNSXS.`) |

### Read-Only Rootfs

LinxdotOS mounts the root filesystem read-only. The writable data partition is at `/data`.

The init script `/etc/init.d/S80dockercompose` automatically checks for `/data/docker-compose.yml` and uses it if present, otherwise falls back to `/etc/docker-compose.yml`. Simply copy and edit the config:

```
cp /etc/docker-compose.yml /data/docker-compose.yml
vi /data/docker-compose.yml
```

Your changes persist across reboots automatically.

### Concentrator Reset (GPIO)

The SX1302 LoRa concentrator on the Linxdot requires three GPIOs to be toggled in sequence before it can communicate over SPI:

| GPIO | Function |
|------|----------|
| 23 | Concentrator power enable |
| 17 | Concentrator extra power/enable |
| 15 | SX1302 reset line |

The sequence is: power off (GPIOs 23+17 low), wait, power on (GPIOs 23+17 high), wait, then pulse reset (GPIO 15 high then low).

The script `/opt/packet_forwarder/tools/reset_lgw.sh.linxdot` performs this sequence. LinxdotOS runs this script automatically via `/etc/init.d/S80dockercompose` before starting the basicstation container.

If the automatic reset fails (e.g., EUI shows as derived from eth0 instead of the chip), **power cycle the entire board** to reset all GPIOs to their default state.

### Gateway EUI

Basics Station derives the gateway EUI from the concentrator chip, but it may produce a different EUI than the `chip_id` tool. This is because `chip_id` reads the raw SX1302 EUI, while Basics Station may apply its own derivation (e.g., inserting `FFFE` bytes). Always use the EUI shown in `docker logs basicstation` when registering on TTN.

### LNS vs CUPS

This setup uses the **LNS** (LoRa Network Server) protocol — a direct WebSocket connection to TTN for packet exchange. The alternative is **CUPS** (Configuration and Update Server), which adds remote configuration management and certificate rotation. CUPS is intended for fleet management of many gateways and is not needed for a single device.

The `TC_KEY` environment variable provides the LNS authentication token. For CUPS, you would use `CUPS_KEY` instead (not covered here).

## References

- [xoseperez/basicstation-docker](https://github.com/xoseperez/basicstation-docker) — Docker image
- [LoRa Basics Station documentation](https://doc.sm.tc/station) — Semtech protocol specification
- [TTN Gateway docs](https://www.thethingsindustries.com/docs/gateways/) — TTN setup guide
- [Linxdot.md](Linxdot.md) — Hardware reference for the Linxdot LD1001
