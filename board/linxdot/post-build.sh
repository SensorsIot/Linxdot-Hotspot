#!/bin/sh
#
# post-build.sh — Runs after Buildroot builds the target rootfs
#
# Arg $1 = TARGET_DIR (passed by Buildroot)
# Env BR2_EXTERNAL_LINXDOT_PATH set by Buildroot
# Post-script args ($2) = path to BR2_EXTERNAL (set via BR2_ROOTFS_POST_SCRIPT_ARGS)
#

set -e

TARGET_DIR="$1"
BR2_EXT="$2"
BOARD_DIR="${BR2_EXT}/board/linxdot"
BINARIES_DIR="${TARGET_DIR}/../images"

echo ">>> OpenLinxdot post-build: TARGET_DIR=${TARGET_DIR}"

# ── Copy prebuilt kernel and DTB to BINARIES_DIR for genimage ──
echo ">>> Copying prebuilt kernel Image and DTB"
cp "${BOARD_DIR}/blobs/Image" "${BINARIES_DIR}/"
cp "${BOARD_DIR}/blobs/rk3566-linxdot.dtb" "${BINARIES_DIR}/"

# ── Copy boot blobs for genimage ──
echo ">>> Copying boot blobs (idbloader, u-boot.itb)"
cp "${BOARD_DIR}/blobs/idbloader.img" "${BINARIES_DIR}/"
cp "${BOARD_DIR}/blobs/u-boot.itb" "${BINARIES_DIR}/"

# ── Install kernel modules ──
echo ">>> Installing kernel modules to rootfs"
MODULES_SRC="${BOARD_DIR}/modules/5.15.104"
MODULES_DST="${TARGET_DIR}/lib/modules/5.15.104"
if [ -d "${MODULES_SRC}" ]; then
    mkdir -p "${MODULES_DST}"
    cp -a "${MODULES_SRC}/"* "${MODULES_DST}/"
fi

# ── Install WiFi firmware (local only, not in git repo) ──
FW_SRC="${BOARD_DIR}/firmware/brcm"
FW_DST="${TARGET_DIR}/lib/firmware/brcm"
if [ -d "${FW_SRC}" ]; then
    echo ">>> Installing WiFi firmware from local directory"
    mkdir -p "${FW_DST}"
    cp -a "${FW_SRC}/"* "${FW_DST}/"
else
    echo ">>> WiFi firmware not found (${FW_SRC}), skipping"
fi

# ── Install LoRa concentrator reset script ──
echo ">>> Installing reset_lgw.sh.linxdot"
RESET_SRC="${BOARD_DIR}/reset_lgw.sh.linxdot"
RESET_DST="${TARGET_DIR}/opt/packet_forwarder/tools"
if [ -f "${RESET_SRC}" ]; then
    mkdir -p "${RESET_DST}"
    cp "${RESET_SRC}" "${RESET_DST}/"
    chmod +x "${RESET_DST}/reset_lgw.sh.linxdot"
fi

# ── Ensure init scripts are executable ──
echo ">>> Setting init script permissions"
chmod +x "${TARGET_DIR}"/etc/init.d/S* 2>/dev/null || true

# ── Create required directories ──
mkdir -p "${TARGET_DIR}/data"
mkdir -p "${TARGET_DIR}/var/log"
mkdir -p "${TARGET_DIR}/var/lib"
mkdir -p "${TARGET_DIR}/var/run"

echo ">>> OpenLinxdot post-build complete"
