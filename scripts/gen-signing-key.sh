#!/bin/sh
# Generate an OpenLinxdot OTA signing keypair.
#
# Run once by the repository maintainer. Private half goes to a GitHub Actions
# secret; public half is committed into the rootfs overlay so deployed devices
# can verify updates.

set -e
OUT_DIR="${OUT_DIR:-.}"
mkdir -p "$OUT_DIR"

KEY="$OUT_DIR/ota-signing.key"
PUB="$OUT_DIR/ota-signing.pub"

if [ -f "$KEY" ]; then
    echo "ERROR: $KEY already exists — refusing to overwrite" >&2
    exit 1
fi

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$KEY"
openssl rsa -in "$KEY" -pubout -out "$PUB"
chmod 600 "$KEY"

cat <<EOF

Keypair generated:
  $KEY  (PRIVATE — keep secret)
  $PUB  (public)

Next steps:
  1. Upload the private key to GitHub Actions secrets as OTA_SIGNING_KEY:
       gh secret set OTA_SIGNING_KEY < $KEY

  2. Install the public key into the rootfs overlay and commit it:
       mkdir -p board/linxdot/overlay/etc/swupdate
       cp $PUB board/linxdot/overlay/etc/swupdate/public.pem
       git add board/linxdot/overlay/etc/swupdate/public.pem
       git commit -m "ota: add signing public key"

  3. Once uploaded and committed, remove the local private key:
       shred -u $KEY

Rotation: generate a new pair, commit the new public key, push a release with
the new firmware. Old-key-signed updates verify only against the old key; new
releases will be signed with the new key and accepted only by devices running
firmware that carries the new public key.
EOF
