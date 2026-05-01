#!/bin/sh
# Linxdot SX1302 reset — power-cycle GPIO 23/17 and pulse RESET on GPIO 15.
#
# Layer 1 of the basicstation self-healing stack: this script is the truthful
# detector. It refuses to lie about success — every sysfs write is checked
# and the final GPIO state is read back. Any mismatch → exit non-zero so the
# orchestrator (S80dockercompose) can retry or escalate.
set -eu

POWER_GPIO=23
EXTRA_GPIO=17
RESET_GPIO=15

log()   { echo "reset.sh: $*"; }
fatal() { echo "reset.sh: FATAL $*" >&2; exit 1; }

export_gpio() {
    pin=$1
    if [ ! -d "/sys/class/gpio/gpio$pin" ]; then
        echo "$pin" > /sys/class/gpio/export \
            || fatal "cannot export gpio$pin (sysfs busy or unavailable)"
    fi
    [ -d "/sys/class/gpio/gpio$pin" ] \
        || fatal "gpio$pin missing from sysfs after export"
    echo out > "/sys/class/gpio/gpio$pin/direction" \
        || fatal "cannot set gpio$pin direction=out"
}

write_gpio() {
    pin=$1; val=$2
    echo "$val" > "/sys/class/gpio/gpio$pin/value" \
        || fatal "cannot write gpio$pin=$val"
}

verify_gpio() {
    pin=$1; expected=$2
    actual=$(cat "/sys/class/gpio/gpio$pin/value") \
        || fatal "cannot read gpio$pin"
    [ "$actual" = "$expected" ] \
        || fatal "gpio$pin readback=$actual, expected $expected"
}

cmd=${1:-cycle}

case "$cmd" in
    start)
        log "start: powering on concentrator"
        export_gpio "$POWER_GPIO"
        export_gpio "$EXTRA_GPIO"
        export_gpio "$RESET_GPIO"

        write_gpio "$POWER_GPIO" 1
        write_gpio "$EXTRA_GPIO" 1
        sleep 1

        write_gpio "$RESET_GPIO" 1
        sleep 0.1
        write_gpio "$RESET_GPIO" 0
        sleep 0.1

        verify_gpio "$POWER_GPIO" 1
        verify_gpio "$EXTRA_GPIO" 1
        verify_gpio "$RESET_GPIO" 0
        log "start: OK (power=1 extra=1 reset=0)"
        ;;
    stop)
        log "stop: powering off concentrator"
        export_gpio "$POWER_GPIO"
        export_gpio "$EXTRA_GPIO"

        write_gpio "$POWER_GPIO" 0
        write_gpio "$EXTRA_GPIO" 0

        verify_gpio "$POWER_GPIO" 0
        verify_gpio "$EXTRA_GPIO" 0
        log "stop: OK (power=0 extra=0)"
        ;;
    cycle|*)
        log "cycle: full power-cycle + reset pulse"
        export_gpio "$POWER_GPIO"
        export_gpio "$EXTRA_GPIO"
        export_gpio "$RESET_GPIO"

        write_gpio "$POWER_GPIO" 0
        write_gpio "$EXTRA_GPIO" 0
        sleep 1

        write_gpio "$POWER_GPIO" 1
        write_gpio "$EXTRA_GPIO" 1
        sleep 1

        write_gpio "$RESET_GPIO" 1
        sleep 0.1
        write_gpio "$RESET_GPIO" 0
        sleep 0.1

        verify_gpio "$POWER_GPIO" 1
        verify_gpio "$EXTRA_GPIO" 1
        verify_gpio "$RESET_GPIO" 0
        log "cycle: OK (power=1 extra=1 reset=0)"
        ;;
esac

exit 0
