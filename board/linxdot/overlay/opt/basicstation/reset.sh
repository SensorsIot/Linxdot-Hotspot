#!/bin/sh
# Linxdot SX1302 reset: power cycle GPIOs 23+17, then toggle reset on GPIO 15

POWER_GPIO=23
EXTRA_GPIO=17
RESET_GPIO=15

setup_gpio() {
    pin=$1
    if [ ! -d /sys/class/gpio/gpio$pin ]; then
        echo $pin > /sys/class/gpio/export 2>/dev/null
    fi
    echo out > /sys/class/gpio/gpio$pin/direction
}

case "$1" in
    start)
        # Setup all GPIOs
        for pin in $POWER_GPIO $EXTRA_GPIO $RESET_GPIO; do
            setup_gpio $pin
        done

        # Power on
        echo 1 > /sys/class/gpio/gpio$POWER_GPIO/value
        echo 1 > /sys/class/gpio/gpio$EXTRA_GPIO/value
        sleep 1

        # Reset pulse on GPIO 15
        echo 1 > /sys/class/gpio/gpio$RESET_GPIO/value
        sleep 0.1
        echo 0 > /sys/class/gpio/gpio$RESET_GPIO/value
        sleep 0.1
        ;;
    stop)
        # Setup GPIOs if needed
        for pin in $POWER_GPIO $EXTRA_GPIO; do
            setup_gpio $pin
        done

        # Power off
        echo 0 > /sys/class/gpio/gpio$POWER_GPIO/value
        echo 0 > /sys/class/gpio/gpio$EXTRA_GPIO/value
        ;;
    *)
        # Default: full reset cycle (power off, power on, reset pulse)
        for pin in $POWER_GPIO $EXTRA_GPIO $RESET_GPIO; do
            setup_gpio $pin
        done

        # Power off
        echo 0 > /sys/class/gpio/gpio$POWER_GPIO/value
        echo 0 > /sys/class/gpio/gpio$EXTRA_GPIO/value
        sleep 1

        # Power on
        echo 1 > /sys/class/gpio/gpio$POWER_GPIO/value
        echo 1 > /sys/class/gpio/gpio$EXTRA_GPIO/value
        sleep 1

        # Reset pulse
        echo 1 > /sys/class/gpio/gpio$RESET_GPIO/value
        sleep 0.1
        echo 0 > /sys/class/gpio/gpio$RESET_GPIO/value
        sleep 0.1
        ;;
esac

exit 0
