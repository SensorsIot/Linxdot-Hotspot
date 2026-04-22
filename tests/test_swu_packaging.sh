#!/bin/sh
# Dry-run the SWUpdate bundle packaging using dummy image content, then verify
# the resulting .swu is a valid CPIO archive containing the expected entries.
# Exercises the exact pipeline that CI runs on tagged releases, minus signing.

set -e
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
TMPL="$REPO/board/linxdot/swupdate/sw-description.tmpl"

[ -f "$TMPL" ] || { echo "SKIP: sw-description template not found"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Dummy "images" — we're testing packaging, not content.
dd if=/dev/urandom of="$WORK/rootfs.ext4" bs=1K count=16 status=none
dd if=/dev/urandom of="$WORK/boot.vfat"   bs=1K count=16 status=none

SHA_ROOTFS=$(sha256sum "$WORK/rootfs.ext4" | cut -d' ' -f1)
SHA_BOOT=$(  sha256sum "$WORK/boot.vfat"   | cut -d' ' -f1)
VERSION="9.9.9-test"

sed -e "s|@VERSION@|$VERSION|g" \
    -e "s|@SHA_ROOTFS@|$SHA_ROOTFS|g" \
    -e "s|@SHA_BOOT@|$SHA_BOOT|g" \
    "$TMPL" > "$WORK/sw-description"

# Verify substitution happened
grep -q "@VERSION@"   "$WORK/sw-description" && { echo "FAIL: @VERSION@ not substituted"; exit 1; }
grep -q "$SHA_ROOTFS" "$WORK/sw-description" || { echo "FAIL: rootfs sha not inserted"; exit 1; }
grep -q "$SHA_BOOT"   "$WORK/sw-description" || { echo "FAIL: boot sha not inserted"; exit 1; }
grep -q "$VERSION"    "$WORK/sw-description" || { echo "FAIL: version not inserted"; exit 1; }

# Pack (same cpio invocation CI uses)
( cd "$WORK"
  printf 'sw-description\nrootfs.ext4\nboot.vfat\n' \
    | cpio -o -H newc --quiet > update.swu ) \
    || { echo "FAIL: cpio packaging"; exit 1; }

# Verify .swu contents
ENTRIES=$(cpio -t --quiet < "$WORK/update.swu" 2>/dev/null | tr '\n' ' ')
case "$ENTRIES" in
    *"sw-description"*"rootfs.ext4"*"boot.vfat"*)
        ;;
    *)
        echo "FAIL: .swu entries in wrong order or missing: $ENTRIES"
        exit 1
        ;;
esac

# sw-description MUST be the first entry (SWUpdate requirement).
FIRST=$(cpio -t --quiet < "$WORK/update.swu" 2>/dev/null | head -1)
[ "$FIRST" = "sw-description" ] \
    || { echo "FAIL: first .swu entry must be sw-description, got '$FIRST'"; exit 1; }

SIZE=$(stat -c%s "$WORK/update.swu")
echo "OK: .swu packaged ($SIZE bytes, entries: $ENTRIES)"
