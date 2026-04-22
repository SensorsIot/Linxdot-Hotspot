# boot.cmd — loads kernel + DTB from the active slot's boot partition.
#
# Slot selection (A vs B) is done by U-Boot's compiled-in bootcmd
# (see board/linxdot/uboot/linxdot.fragment). When this script is sourced,
# ${bootpart} is already set: 1 for slot A, 3 for slot B.
#
# Bootcount auto-increment and rollback are handled by CONFIG_BOOTCOUNT_LIMIT
# and altbootcmd (see board/linxdot/uboot/env.txt) — not here.

if test "${boot_slot}" = "B"; then
    setenv rootdev /dev/mmcblk0p4
else
    setenv rootdev /dev/mmcblk0p2
fi

setenv bootargs "root=${rootdev} rootfstype=ext4 rootwait ro console=ttyS2,1500000 panic=10"

load mmc 0:${bootpart} ${kernel_addr_r} Image
load mmc 0:${bootpart} ${fdt_addr_r} rk3566-linxdot.dtb

booti ${kernel_addr_r} - ${fdt_addr_r}
