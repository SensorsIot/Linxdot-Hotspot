#!/bin/sh
# Static cross-file consistency checks.
#
# The U-Boot env storage location is defined in three places that must agree:
#   - U-Boot compiled-in config (linxdot.fragment): CONFIG_ENV_OFFSET, SIZE, REDUND
#   - Linux fw_setenv/fw_printenv config (overlay/etc/fw_env.config)
#   - Reserved genimage partition (genimage.cfg uboot_env)
# A mismatch between any of these causes silent env corruption on first boot.

set -e

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
FRAG="$REPO/board/linxdot/uboot/linxdot.fragment"
FWENV="$REPO/board/linxdot/overlay/etc/fw_env.config"
GENIMG="$REPO/board/linxdot/genimage.cfg"
ENV_TXT="$REPO/board/linxdot/uboot/env.txt"

fail=0

note() { echo "  $*"; }
err()  { echo "FAIL: $*"; fail=$((fail + 1)); }

# ── Extract U-Boot env offsets from config fragment ─────────────────────────
FRAG_OFFSET=$(sed -n 's/^CONFIG_ENV_OFFSET=\(0x[0-9A-Fa-f]*\)$/\1/p' "$FRAG")
FRAG_SIZE=$(sed -n 's/^CONFIG_ENV_SIZE=\(0x[0-9A-Fa-f]*\)$/\1/p' "$FRAG")
FRAG_REDUND=$(sed -n 's/^CONFIG_ENV_OFFSET_REDUND=\(0x[0-9A-Fa-f]*\)$/\1/p' "$FRAG")

[ -z "$FRAG_OFFSET" ] && err "CONFIG_ENV_OFFSET not found in $FRAG"
[ -z "$FRAG_SIZE" ]   && err "CONFIG_ENV_SIZE not found in $FRAG"
[ -z "$FRAG_REDUND" ] && err "CONFIG_ENV_OFFSET_REDUND not found in $FRAG"

note "linxdot.fragment: offset=$FRAG_OFFSET size=$FRAG_SIZE redund=$FRAG_REDUND"

# ── Compare with fw_env.config (two non-comment lines) ──────────────────────
FW_LINES=$(grep -v '^#' "$FWENV" | grep -v '^[[:space:]]*$')
FW_PRIMARY=$(echo "$FW_LINES" | sed -n '1p')
FW_REDUND=$(echo  "$FW_LINES" | sed -n '2p')

FW_PRIM_OFFSET=$(echo "$FW_PRIMARY"  | awk '{print $2}')
FW_PRIM_SIZE=$(echo   "$FW_PRIMARY"  | awk '{print $3}')
FW_RED_OFFSET=$(echo  "$FW_REDUND"   | awk '{print $2}')
FW_RED_SIZE=$(echo    "$FW_REDUND"   | awk '{print $3}')

eq_hex() { [ "$(printf '%d' "$1")" = "$(printf '%d' "$2")" ]; }

if ! eq_hex "$FRAG_OFFSET" "$FW_PRIM_OFFSET"; then
    err "fragment CONFIG_ENV_OFFSET ($FRAG_OFFSET) != fw_env.config primary offset ($FW_PRIM_OFFSET)"
fi
if ! eq_hex "$FRAG_SIZE" "$FW_PRIM_SIZE"; then
    err "fragment CONFIG_ENV_SIZE ($FRAG_SIZE) != fw_env.config primary size ($FW_PRIM_SIZE)"
fi
if ! eq_hex "$FRAG_REDUND" "$FW_RED_OFFSET"; then
    err "fragment CONFIG_ENV_OFFSET_REDUND ($FRAG_REDUND) != fw_env.config redund offset ($FW_RED_OFFSET)"
fi
if ! eq_hex "$FRAG_SIZE" "$FW_RED_SIZE"; then
    err "fragment CONFIG_ENV_SIZE ($FRAG_SIZE) != fw_env.config redund size ($FW_RED_SIZE)"
fi

# ── Compare with genimage.cfg uboot_env partition ───────────────────────────
# genimage.cfg uses suffix units (14M, 128K) — convert to bytes.
parse_suffix() {
    case "$1" in
        *K) echo "$(( ${1%K} * 1024 ))" ;;
        *M) echo "$(( ${1%M} * 1024 * 1024 ))" ;;
        0x*) printf '%d' "$1" ;;
        *)  echo "$1" ;;
    esac
}

GI_OFFSET=$(awk '/partition uboot_env/,/^[[:space:]]*}/' "$GENIMG" | sed -n 's/.*offset = \([^[:space:]]*\).*/\1/p')
GI_SIZE=$(awk   '/partition uboot_env/,/^[[:space:]]*}/' "$GENIMG" | sed -n 's/.*size = \([^[:space:]]*\).*/\1/p')

[ -z "$GI_OFFSET" ] && err "uboot_env offset not found in $GENIMG"
[ -z "$GI_SIZE" ]   && err "uboot_env size not found in $GENIMG"

GI_OFFSET_B=$(parse_suffix "$GI_OFFSET")
GI_SIZE_B=$(parse_suffix "$GI_SIZE")
FRAG_OFFSET_B=$(printf '%d' "$FRAG_OFFSET")
FRAG_SIZE_B=$(printf '%d' "$FRAG_SIZE")

[ "$GI_OFFSET_B" = "$FRAG_OFFSET_B" ] || \
    err "genimage uboot_env offset ($GI_OFFSET → $GI_OFFSET_B B) != fragment CONFIG_ENV_OFFSET ($FRAG_OFFSET → $FRAG_OFFSET_B B)"

# Partition must be at least 2× env size (primary + redundant)
expected_partition=$((FRAG_SIZE_B * 2))
[ "$GI_SIZE_B" -ge "$expected_partition" ] || \
    err "genimage uboot_env size ($GI_SIZE → $GI_SIZE_B B) < 2× CONFIG_ENV_SIZE ($expected_partition B)"

# ── env.txt must declare the vars boot.cmd / altbootcmd reference ───────────
for key in boot_slot bootcount bootlimit upgrade_available altbootcmd; do
    grep -q "^${key}=" "$ENV_TXT" || err "env.txt is missing required key: $key"
done

# ── sw-description.tmpl partition paths must match the A/B genimage layout ──
# The critical invariant: target-B writes to the INACTIVE slot when current is
# A, i.e. rootfs_b (p4) and boot_b (p3). target-A writes when current is B.
SWDESC="$REPO/board/linxdot/swupdate/sw-description.tmpl"
if [ -f "$SWDESC" ]; then
    # target-B must reference p3 (boot_b) and p4 (rootfs_b)
    awk '/target-B:/,/target-A:/' "$SWDESC" | grep -q 'mmcblk1p3' \
        || err "sw-description target-B must write to /dev/mmcblk1p3 (boot_b)"
    awk '/target-B:/,/target-A:/' "$SWDESC" | grep -q 'mmcblk1p4' \
        || err "sw-description target-B must write to /dev/mmcblk1p4 (rootfs_b)"
    # target-A must reference p1 (boot_a) and p2 (rootfs_a)
    awk '/target-A:/,/^\}/' "$SWDESC" | grep -q 'mmcblk1p1' \
        || err "sw-description target-A must write to /dev/mmcblk1p1 (boot_a)"
    awk '/target-A:/,/^\}/' "$SWDESC" | grep -q 'mmcblk1p2' \
        || err "sw-description target-A must write to /dev/mmcblk1p2 (rootfs_a)"
    # both targets must set upgrade_available=1
    count=$(grep -c 'upgrade_available";[[:space:]]*value[[:space:]]*=[[:space:]]*"1"' "$SWDESC")
    [ "$count" -eq 2 ] || err "sw-description must set upgrade_available=1 in both target-A and target-B (found $count)"
fi

# ── altbootcmd in env.txt must reference both slots and clear upgrade_available
ALT=$(sed -n 's/^altbootcmd=//p' "$ENV_TXT")
echo "$ALT" | grep -q 'boot_slot B'            || err "altbootcmd must set boot_slot B in the A→B branch"
echo "$ALT" | grep -q 'boot_slot A'            || err "altbootcmd must set boot_slot A in the B→A branch"
echo "$ALT" | grep -q 'upgrade_available 0'    || err "altbootcmd must clear upgrade_available"
echo "$ALT" | grep -q 'bootcount 0'            || err "altbootcmd must clear bootcount"

# ── Result ──────────────────────────────────────────────────────────────────
if [ "$fail" -eq 0 ]; then
    echo "OK: consistency checks passed"
else
    echo ""
    echo "FAILED: $fail check(s)"
    exit 1
fi
