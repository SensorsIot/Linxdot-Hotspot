setenv bootargs "root=/dev/mmcblk1p2 rootfstype=ext4 rootwait ro console=ttyS2,1500000 panic=10"
if load mmc 0:1 ${kernel_addr_r} Image; then
    load mmc 0:1 ${fdt_addr_r} rk3566-linxdot.dtb
else
    load mmc 1:1 ${kernel_addr_r} Image
    load mmc 1:1 ${fdt_addr_r} rk3566-linxdot.dtb
fi
booti ${kernel_addr_r} - ${fdt_addr_r}
