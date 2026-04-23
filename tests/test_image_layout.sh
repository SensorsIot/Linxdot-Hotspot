#!/bin/sh
# Post-build validation of the eMMC image partition layout.
# Run this against buildroot/output/images/linxdot-basics-station.img after a
# successful build. Verifies the A/B layout and env partition placement.
#
# Usage: IMAGE=path/to/linxdot-basics-station.img tests/test_image_layout.sh

set -e

IMAGE="${IMAGE:-buildroot/output/images/linxdot-basics-station.img}"

if [ ! -f "$IMAGE" ]; then
    echo "SKIP: image not found at $IMAGE (build first)"
    exit 0
fi

fail=0
err() { echo "FAIL: $*"; fail=$((fail + 1)); }

echo ">>> Checking $IMAGE"
echo

# ── Size sanity (should be >1GB with A/B, <4GB to fit the smallest eMMC) ────
SIZE=$(stat -c%s "$IMAGE")
SIZE_MB=$((SIZE / 1024 / 1024))
echo "Image size: ${SIZE_MB} MiB"
[ "$SIZE" -gt 1073741824 ] || err "image is smaller than 1GB — A/B layout should push past this"
[ "$SIZE" -lt 4294967296 ] || err "image exceeds 4GB — check rootfs/data partition sizes"

# ── Partition count (expect 5: boot_a, rootfs_a, boot_b, rootfs_b, data) ────
PARTITIONS=$(fdisk -l "$IMAGE" 2>/dev/null | grep -c "^$IMAGE")
echo "Partition count: $PARTITIONS (expected 5)"
[ "$PARTITIONS" -eq 5 ] || err "expected 5 partitions, got $PARTITIONS"

# ── boot_a partition present at 16 MiB offset ───────────────────────────────
BOOT_A_START=$(fdisk -l "$IMAGE" 2>/dev/null | awk -v img="$IMAGE" '$1 == img"1" {print $2}')
if [ -n "$BOOT_A_START" ]; then
    BOOT_A_BYTES=$((BOOT_A_START * 512))
    BOOT_A_MB=$((BOOT_A_BYTES / 1024 / 1024))
    echo "boot_a starts at sector $BOOT_A_START (${BOOT_A_MB} MiB)"
    [ "$BOOT_A_MB" -eq 16 ] || err "boot_a should start at 16 MiB, got ${BOOT_A_MB} MiB"
else
    err "could not read boot_a start sector"
fi

# ── Raw-region spot check: SPL magic at 32 KiB (start of u-boot-rockchip.bin) ─
IDB_MAGIC=$(dd if="$IMAGE" bs=1 skip=32768 count=4 2>/dev/null | od -An -t x1 | tr -d ' \n')
echo "Bytes at 32 KiB (idbloader): $IDB_MAGIC"
# Rockchip idbloader starts with "LDR " (0x4C 0x44 0x52 0x20) or Rockchip magic.
# Some idbloaders start differently; we just check it's not zero.
if [ "$IDB_MAGIC" = "00000000" ]; then
    err "idbloader region at 32 KiB is empty — U-Boot SPL missing"
fi

# ── Env partition signature check (optional — U-Boot env has a CRC32 prefix) ─
# We just verify the region isn't all zero.
ENV_HEAD=$(dd if="$IMAGE" bs=1 skip=14680064 count=16 2>/dev/null | od -An -t x1 | tr -d ' \n')
echo "Bytes at 14 MiB (uboot_env): $ENV_HEAD"
if [ "$ENV_HEAD" = "00000000000000000000000000000000" ]; then
    err "uboot_env region at 14 MiB is empty — mkenvimage output missing"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "OK: image layout checks passed"
else
    echo "FAILED: $fail check(s)"
    exit 1
fi
