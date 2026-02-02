setenv bootargs "root=/dev/mmcblk1p2 rootfstype=ext4 rootwait ro console=ttyS2,115200 panic=10 quiet loglevel=1"
load mmc 1:1 ${kernel_addr_r} Image
load mmc 1:1 ${fdt_addr_r} rk3566-linxdot.dtb
booti ${kernel_addr_r} - ${fdt_addr_r}
