#!/bin/sh
# Runner for all static tests. test_image_layout.sh is run only if IMAGE is set
# or the default image path exists.

set -e
cd "$(dirname "$0")/.."

echo "=== test_consistency.sh ==="
sh tests/test_consistency.sh
echo

echo "=== test_ota_state_machine.sh ==="
sh tests/test_ota_state_machine.sh
echo

echo "=== test_swu_packaging.sh ==="
sh tests/test_swu_packaging.sh
echo

if [ -n "${IMAGE:-}" ] || [ -f buildroot/output/images/linxdot-basics-station.img ]; then
    echo "=== test_image_layout.sh ==="
    sh tests/test_image_layout.sh
    echo
fi

echo "All tests passed."
