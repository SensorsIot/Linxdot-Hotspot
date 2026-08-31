#!/bin/sh
# Exercise ota-check's version_newer() directly: the guard that stops a
# pulled or replaced release from walking a device backwards. Sourcing the
# real script would run the update, so the function is extracted and run in
# isolation -- this still tests the shipped code, not a copy.

set -e
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$REPO/board/linxdot/overlay/usr/sbin/ota-check"

[ -f "$SRC" ] || { echo "SKIP: ota-check not found"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Extract version_newer() through its closing brace.
sed -n '/^version_newer() {/,/^}/p' "$SRC" > "$WORK/fn.sh"
[ -s "$WORK/fn.sh" ] || { echo "FAIL: could not extract version_newer() from ota-check"; exit 1; }

fails=0
check() { # check <a> <b> <expect newer|not-newer>
    if (. "$WORK/fn.sh"; version_newer "$1" "$2"); then got=newer; else got=not-newer; fi
    if [ "$got" = "$3" ]; then
        echo "  OK: $1 vs $2 -> $got"
    else
        echo "FAIL: $1 vs $2 -> $got (expected $3)"
        fails=$((fails + 1))
    fi
}

echo "version_newer():"
check 2.0.2  2.0.0  newer          # normal upgrade
check 2.0.0  2.0.2  not-newer      # the pulled-release case
check 2.0.2  2.0.2  not-newer      # identical
check 1.0.10 1.0.9  newer          # lexical comparison would get this wrong
check 1.0.9  1.0.10 not-newer
check 2.0.0  1.7.1  newer          # major bump
check 1.7.1  2.0.0  not-newer
check 2.1    2.1.0  not-newer      # missing field reads as 0
check 2.1.1  2.1    newer
check 10.0.0 9.0.0  newer          # multi-digit major

[ "$fails" -eq 0 ] || { echo "FAIL: $fails case(s) wrong"; exit 1; }
echo "PASS: version_newer() correct in all cases"
