#!/bin/bash
# phase3_flash.sh — Phase 3 runbook §2: flash the CI image to LD1001 eMMC.
#
# Run after phase3_preflight.sh passes and the device is still in Loader mode.
# Streams Workbench Pi SLOT3 serial while rkdeveloptool writes over SLOT1 USB,
# so the post-reset boot (SPL → TF-A → U-Boot → kernel → login) shows up in
# the same pane as the rkdeveloptool progress.
#
# Usage: phase3_flash.sh [path/to/linxdot-basics-station.img]
# Override: PI_HOST, REMOTE_IMG, SER_HOST, SER_PORT, SER_BAUD

set -eu

IMG="${1:-${IMG:-./linxdot-basics-station.img}}"
PI_HOST="${PI_HOST:-pi@192.168.0.87}"
REMOTE_IMG="${REMOTE_IMG:-/tmp/linxdot-basics-station.img}"
SER_HOST="${SER_HOST:-192.168.0.87}"
SER_PORT="${SER_PORT:-4003}"
SER_BAUD="${SER_BAUD:-1500000}"

[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG" >&2; exit 1; }
case "$IMG" in
    *.xz) echo "ERROR: decompress first: xz -d $IMG" >&2; exit 1;;
esac

if ! python3 -c 'import serial.rfc2217' 2>/dev/null; then
    echo "ERROR: pyserial missing. Run: sudo apt-get install -y python3-serial" >&2
    exit 1
fi

ts() { date +%H:%M:%S; }
say() { echo "[$(ts) rk ] $*"; }

TAIL_PID=""
cleanup() {
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

python3 - "$SER_HOST" "$SER_PORT" "$SER_BAUD" <<'PY' &
import sys, time, serial
host, port, baud = sys.argv[1], sys.argv[2], int(sys.argv[3])
ser = serial.serial_for_url(f'rfc2217://{host}:{port}', baudrate=baud, timeout=1)
buf = b''
while True:
    data = ser.read(4096)
    if not data:
        continue
    buf += data
    while b'\n' in buf:
        line, buf = buf.split(b'\n', 1)
        text = line.decode('utf-8', errors='replace').rstrip('\r')
        print(f"[{time.strftime('%H:%M:%S')} ser] {text}", flush=True)
PY
TAIL_PID=$!
sleep 1

say "staging image to $PI_HOST:$REMOTE_IMG ($(du -h "$IMG" | cut -f1))"
scp -q "$IMG" "$PI_HOST:$REMOTE_IMG"

say "verifying Loader mode"
ssh -o BatchMode=yes "$PI_HOST" 'sudo rkdeveloptool ld' 2>&1 | sed "s|^|[$(ts) rk ] |"

say "writing eMMC: rkdeveloptool wl 0 (takes a few minutes)"
ssh -o BatchMode=yes "$PI_HOST" "sudo rkdeveloptool wl 0 $REMOTE_IMG" 2>&1 | sed "s|^|[$(ts) rk ] |"

say "resetting: rkdeveloptool rd"
ssh -o BatchMode=yes "$PI_HOST" 'sudo rkdeveloptool rd' 2>&1 | sed "s|^|[$(ts) rk ] |"

say "device rebooting — watch [ser] for source-built U-Boot → Linux login. Ctrl-C to exit."
wait "$TAIL_PID"
