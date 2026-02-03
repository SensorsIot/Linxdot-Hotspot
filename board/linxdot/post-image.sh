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

# ── Create extlinux.conf for U-Boot ──
# NOTE: extlinux is more reliable than boot.scr on vendor U-Boot 2017.09
echo ">>> Creating extlinux.conf"
mkdir -p "${BINARIES_DIR}/extlinux"
cat > "${BINARIES_DIR}/extlinux/extlinux.conf" << 'EOF'
default linxdot
timeout 3

label linxdot
    kernel /Image
    fdt /rk3566-linxdot.dtb
    append root=/dev/mmcblk1p2 rootfstype=ext4 rootwait ro console=ttyS2,1500000 panic=10
EOF

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

# ── Add extlinux directory to boot partition in final image ──
# genimage doesn't create subdirectories in vfat properly, so we patch after
echo ">>> Adding extlinux directory to boot partition"
BOOT_OFFSET=$((16 * 1024 * 1024))  # 16MB offset
BOOT_SIZE=$((30 * 1024 * 1024))    # 30MB size

# Extract boot.vfat from final image
dd if="${BINARIES_DIR}/linxdot-basics-station.img" of="${BINARIES_DIR}/boot.vfat.tmp" \
    bs=1M skip=16 count=30 status=none

# Create extlinux directory and copy config
MTOOLS_SKIP_CHECK=1 mmd -i "${BINARIES_DIR}/boot.vfat.tmp" ::extlinux 2>/dev/null || true
MTOOLS_SKIP_CHECK=1 mcopy -i "${BINARIES_DIR}/boot.vfat.tmp" \
    "${BINARIES_DIR}/extlinux/extlinux.conf" ::extlinux/

# Write modified boot.vfat back to final image
dd if="${BINARIES_DIR}/boot.vfat.tmp" of="${BINARIES_DIR}/linxdot-basics-station.img" \
    bs=1M seek=16 conv=notrunc status=none

rm -f "${BINARIES_DIR}/boot.vfat.tmp"

echo ">>> LinxdotOS image: ${BINARIES_DIR}/linxdot-basics-station.img"
echo ">>> LinxdotOS post-image complete"
