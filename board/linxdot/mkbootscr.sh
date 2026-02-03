#!/bin/bash
#
# mkbootscr.sh - Create legacy U-Boot boot.scr without sub-header
#
# Usage: mkbootscr.sh input.cmd output.scr
#
# This creates a boot.scr compatible with older U-Boot (2017.09) which
# doesn't support the 8-byte sub-header added by mkimage 2021+.

set -e

INPUT="$1"
OUTPUT="$2"

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
    echo "Usage: $0 input.cmd output.scr"
    exit 1
fi

# Read script data
SCRIPT_DATA=$(cat "$INPUT")
SCRIPT_SIZE=${#SCRIPT_DATA}

# Create temporary file for the image
TMP=$(mktemp)
trap "rm -f $TMP" EXIT

# Build the 64-byte header
{
    # Magic number (0x27051956)
    printf '\x27\x05\x19\x56'

    # Header CRC placeholder (will be zeroed - U-Boot often ignores for scripts)
    printf '\x00\x00\x00\x00'

    # Timestamp (current time)
    TIMESTAMP=$(date +%s)
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $((TIMESTAMP >> 24 & 0xff)) \
        $((TIMESTAMP >> 16 & 0xff)) \
        $((TIMESTAMP >> 8 & 0xff)) \
        $((TIMESTAMP & 0xff)))"

    # Data size (big-endian)
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $((SCRIPT_SIZE >> 24 & 0xff)) \
        $((SCRIPT_SIZE >> 16 & 0xff)) \
        $((SCRIPT_SIZE >> 8 & 0xff)) \
        $((SCRIPT_SIZE & 0xff)))"

    # Load address (0)
    printf '\x00\x00\x00\x00'

    # Entry point (0)
    printf '\x00\x00\x00\x00'

    # Data CRC placeholder (zeroed)
    printf '\x00\x00\x00\x00'

    # OS: Linux (5), Arch: ARM (2), Type: Script (6), Comp: None (0)
    printf '\x05\x02\x06\x00'

    # Image name (32 bytes, null-padded)
    printf '%-32s' "" | tr ' ' '\0'

} > "$TMP"

# Append script data
printf '%s' "$SCRIPT_DATA" >> "$TMP"

# Copy to output
cp "$TMP" "$OUTPUT"

echo "Created $OUTPUT ($(stat -c%s "$OUTPUT") bytes, script: $SCRIPT_SIZE bytes)"
