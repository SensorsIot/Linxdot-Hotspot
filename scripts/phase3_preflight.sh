#!/bin/bash
# phase3_preflight.sh — BootROM non-secure-lock pre-flight for Phase 3 runbook §1.
#
# Runs from the devcontainer. Tails the LD1001 serial console (Workbench Pi
# SLOT3, RFC2217 :4003 @ 1.5M baud) in one pane while driving rkdeveloptool
# over SSH against SLOT1 USB. Non-destructive: `db` writes the SPL to RAM only.
#
# Prerequisites:
#   - python3-serial installed locally (apt-get install -y python3-serial)
#   - SSH key auth to $PI_HOST
#   - Passwordless sudo for rkdeveloptool on the Workbench Pi
#   - rkbin checked out on the Pi; path via $SPL (default /home/pi/rkbin/...)
#
# Put the LD1001 in Loader mode before running (hold BT-Pair + power, 5 s).
# A pass looks like:
#   [rk ] Downloading bootloader succeeded.
#   [ser] <short SPL banner, then silence>

set -eu

PI_HOST="${PI_HOST:-pi@192.168.0.87}"
SPL="${SPL:-/home/pi/rkbin/bin/rk35/rk356x_usbplug_v1.17.bin}"
SER_HOST="${SER_HOST:-192.168.0.87}"
SER_PORT="${SER_PORT:-4003}"
SER_BAUD="${SER_BAUD:-1500000}"

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
ser = serial.serial_for_url(f'rfc2217://{host}:{port}', baudrate=baud, timeout=0.3)
buf = b''
last_emit = time.monotonic()
def emit(b):
    text = b.decode('utf-8', errors='replace').rstrip('\r\n')
    if text:
        print(f"[{time.strftime('%H:%M:%S')} ser] {text}", flush=True)
while True:
    data = ser.read(4096)
    if data:
        # MaskROM emits CR-only spinner animation; treat CR as a line break too
        buf += data.replace(b'\r', b'\n')
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            emit(line)
        last_emit = time.monotonic()
    elif buf and time.monotonic() - last_emit > 0.5:
        emit(buf)
        buf = b''
        last_emit = time.monotonic()
PY
TAIL_PID=$!

# Give the RFC2217 socket a moment to attach before we trigger any UART output
sleep 1

say "probing device: rkdeveloptool ld"
if ! ssh -o BatchMode=yes "$PI_HOST" 'sudo rkdeveloptool ld' 2>&1 | sed "s|^|[$(ts) rk ] |"; then
    say "ERROR: ssh/rkdeveloptool ld failed — check PI_HOST and Loader-mode button"
    exit 2
fi

say "loading USB plug into RAM: rkdeveloptool db $SPL"
DB_OUT=$(ssh -o BatchMode=yes "$PI_HOST" "sudo rkdeveloptool db $SPL" 2>&1 || true)
echo "$DB_OUT" | sed "s|^|[$(ts) rk ] |"
case "$DB_OUT" in
    *"Downloading bootloader succeeded"*)
        say "PASS: usbplug accepted by BootROM — non-secure confirmed on this unit." ;;
    *"does not support this operation"*)
        say "PASS (already-Loader): device is past BootROM with a usbplug already running."
        say "      Non-secure is evidence-cleared per FSD §5 (vendor SPL Verified-boot: 0)." ;;
    *)
        say "FAIL: unexpected db result. Do NOT flash. Inspect output above."
        exit 3 ;;
esac

say "watching serial 5 s for any banner, then exiting..."
sleep 5
