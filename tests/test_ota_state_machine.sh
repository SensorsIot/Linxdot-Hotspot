#!/bin/sh
# Simulates U-Boot's CONFIG_BOOTCOUNT_LIMIT + altbootcmd behavior for the
# Linxdot OTA state machine, then verifies the outcome against a table of
# scenarios. This is the closest we can get to testing boot logic without
# actually booting U-Boot on hardware.
#
# The simulator models a single "attempt cycle": U-Boot auto-increments
# bootcount; if >bootlimit, altbootcmd runs (flipping slot if
# upgrade_available=1) and resets bootcount; then userspace boots. If the
# boot reaches S99confirm (boot_ok=1), it resets bootcount and clears
# upgrade_available. Otherwise, state is left for the next cycle.

set -e

# simulate_boot <bootcount> <bootlimit> <boot_slot> <upgrade_available> <boot_ok>
# Prints: new_bootcount new_boot_slot new_upgrade_available altbootcmd_fired
simulate_boot() {
    bc=$1; bl=$2; slot=$3; upg=$4; ok=$5
    alt_fired=0

    # U-Boot bootcount auto-increment (CONFIG_BOOTCOUNT_LIMIT)
    bc=$((bc + 1))

    if [ "$bc" -gt "$bl" ]; then
        # altbootcmd fires
        alt_fired=1
        if [ "$upg" = "1" ]; then
            if [ "$slot" = "A" ]; then slot=B; else slot=A; fi
            upg=0
        fi
        bc=0
        # altbootcmd does `run bootcmd` — simulated by falling through to userspace.
    fi

    if [ "$ok" = "1" ]; then
        # S99confirm: cleared flags late in boot
        bc=0
        upg=0
    fi

    echo "$bc $slot $upg $alt_fired"
}

fail=0
case_n=0

check() {
    case_n=$((case_n + 1))
    desc=$1; expected=$2; got=$3
    if [ "$expected" = "$got" ]; then
        printf "  ok  %2d  %s\n" "$case_n" "$desc"
    else
        printf "  FAIL %2d %s\n       expected: %s\n       got:      %s\n" \
            "$case_n" "$desc" "$expected" "$got"
        fail=$((fail + 1))
    fi
}

# ── Scenarios ────────────────────────────────────────────────────────────────

# 1. Healthy boot from fresh state.
check "fresh boot, slot A, healthy" \
    "0 A 0 0" \
    "$(simulate_boot 0 3 A 0 1)"

# 2. Transient boot hang on healthy slot — does NOT flip slot.
check "healthy slot, single bad boot (bootcount 0→1)" \
    "1 A 0 0" \
    "$(simulate_boot 0 3 A 0 0)"

# 3. Healthy slot with enough bad boots to trip altbootcmd — must NOT flip.
check "healthy slot at bootlimit, altbootcmd resets bootcount, slot stays" \
    "0 A 0 1" \
    "$(simulate_boot 3 3 A 0 0)"

# 4. Healthy slot post-altbootcmd, then boot succeeds.
check "healthy slot recovers after spurious altbootcmd" \
    "0 A 0 1" \
    "$(simulate_boot 3 3 A 0 1)"

# 5. OTA trial boot succeeds first try — commits.
check "OTA trial boot, slot B, success — commits" \
    "0 B 0 0" \
    "$(simulate_boot 0 3 B 1 1)"

# 6. OTA trial boot fails once — stays in trial mode.
check "OTA trial, slot B, single fail (still in trial)" \
    "1 B 1 0" \
    "$(simulate_boot 0 3 B 1 0)"

# 7. OTA trial boot exhausts retries — rolls back to A.
check "OTA trial, slot B, exhausted — rolls back to A" \
    "0 A 0 1" \
    "$(simulate_boot 3 3 B 1 0)"

# 8. OTA trial from slot B fails on boot that clears bootcount (mixed).
#    After the rollback, the kernel must not reach S99confirm since ok=0.
check "OTA rollback path, boot still fails after flip" \
    "0 A 0 1" \
    "$(simulate_boot 3 3 B 1 0)"

# 9. OTA trial from slot A (reverse direction).
check "OTA trial, slot A, exhausted — rolls back to B" \
    "0 B 0 1" \
    "$(simulate_boot 3 3 A 1 0)"

# 10. Edge: bootlimit of 1 — first fail triggers immediate rollback.
check "bootlimit=1, OTA trial, fail — immediate rollback" \
    "0 A 0 1" \
    "$(simulate_boot 1 1 B 1 0)"

# ── Result ──────────────────────────────────────────────────────────────────
echo
if [ "$fail" -eq 0 ]; then
    echo "OK: $case_n OTA state-machine scenarios passed"
else
    echo "FAILED: $fail of $case_n scenarios"
    exit 1
fi
