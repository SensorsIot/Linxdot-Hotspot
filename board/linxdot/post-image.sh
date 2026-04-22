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
HOST_DIR="$(dirname "$BINARIES_DIR")/host"

# Prefer Buildroot host tools, fall back to system (used by the CI release job
# which assembles images from a pre-built rootfs without a Buildroot tree).
MKIMAGE="${HOST_DIR}/bin/mkimage"
[ -x "$MKIMAGE" ] || MKIMAGE=mkimage
MKENVIMAGE="${HOST_DIR}/bin/mkenvimage"
[ -x "$MKENVIMAGE" ] || MKENVIMAGE=mkenvimage

echo ">>> OpenLinxdot post-image: BINARIES_DIR=${BINARIES_DIR}"

# ── Compile boot.cmd → boot.scr ──
echo ">>> Compiling boot.cmd to boot.scr"
"$MKIMAGE" -A arm64 -T script -C none -n "OpenLinxdot boot" \
    -d "${BOARD_DIR}/boot.cmd" "${BINARIES_DIR}/boot.scr"

# ── Generate U-Boot env image (64K primary + 64K redundant) ──
echo ">>> Generating uboot-env.bin"
"$MKENVIMAGE" -s 0x10000 -o "${BINARIES_DIR}/uboot-env-primary.bin" \
    "${BOARD_DIR}/uboot/env.txt"
cat "${BINARIES_DIR}/uboot-env-primary.bin" "${BINARIES_DIR}/uboot-env-primary.bin" \
    > "${BINARIES_DIR}/uboot-env.bin"
rm -f "${BINARIES_DIR}/uboot-env-primary.bin"

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

echo ">>> OpenLinxdot image: ${BINARIES_DIR}/linxdot-basics-station.img"
echo ">>> OpenLinxdot post-image complete"
