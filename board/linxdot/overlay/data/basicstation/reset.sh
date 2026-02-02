#!/bin/sh
# Linxdot SX1302 reset: power cycle GPIOs 23+17, then toggle reset on GPIO 15

for pin in 23 17 15; do
    echo $pin > /sys/class/gpio/export 2>/dev/null
    echo out > /sys/class/gpio/gpio$pin/direction
done

# Power off
echo 0 > /sys/class/gpio/gpio23/value
echo 0 > /sys/class/gpio/gpio17/value
sleep 1

# Power on
echo 1 > /sys/class/gpio/gpio23/value
echo 1 > /sys/class/gpio/gpio17/value
sleep 1

# Reset pulse on GPIO 15
echo 1 > /sys/class/gpio/gpio15/value
sleep 1
echo 0 > /sys/class/gpio/gpio15/value
sleep 1
