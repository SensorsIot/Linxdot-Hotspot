#!/bin/sh
#
# post-image.sh — Runs after rootfs image is built
#
# Arg $1 = BINARIES_DIR (passed by Buildroot)
# Post-script args ($2) = path to BR2_EXTERNAL (set via BR2_ROOTFS_POST_SCRIPT_ARGS)
#

set -e

BINARIES_DIR="$1"
BR2_EXT="$2"
BOARD_DIR="${BR2_EXT}/board/linxdot"

echo ">>> LinxdotOS post-image: BINARIES_DIR=${BINARIES_DIR}"

# ── Compile boot.cmd → boot.scr ──
# NOTE: mkimage 2021+ adds 8-byte sub-header that vendor U-Boot 2017.09 can't parse.
# We use our own script to create legacy-compatible format.
echo ">>> Compiling boot.scr (legacy format for vendor U-Boot 2017.09)"
chmod +x "${BOARD_DIR}/mkbootscr.sh"
"${BOARD_DIR}/mkbootscr.sh" "${BOARD_DIR}/boot.cmd" "${BINARIES_DIR}/boot.scr"

# ── Run genimage to produce the final eMMC image ──
echo ">>> Running genimage"
GENIMAGE_CFG="${BOARD_DIR}/genimage.cfg"
GENIMAGE_TMP="${BUILD_DIR:-$(dirname "$BINARIES_DIR")/build}/genimage.tmp"

rm -rf "${GENIMAGE_TMP}"

genimage \
    --rootpath "${TARGET_DIR:-$(dirname "$BINARIES_DIR")/target}" \
    --tmppath "${GENIMAGE_TMP}" \
    --inputpath "${BINARIES_DIR}" \
    --outputpath "${BINARIES_DIR}" \
    --config "${GENIMAGE_CFG}"

echo ">>> LinxdotOS image: ${BINARIES_DIR}/linxdot-basics-station.img"
echo ">>> LinxdotOS post-image complete"
