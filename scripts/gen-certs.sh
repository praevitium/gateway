#!/usr/bin/env bash
# Generate a self-signed TLS cert for local HTTPS development.
#
# Writes certs/fullchain.pem + certs/privkey.pem with a SAN covering localhost,
# 127.0.0.1, ::1, and $SERVER_NAME. Browsers will warn (untrusted issuer) —
# accept the exception for dev, or import certs/fullchain.pem into your trust
# store. For production, drop a real cert in certs/ under the same two names.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR/../certs"
SERVER_NAME="${SERVER_NAME:-localhost}"
DAYS="${DAYS:-825}"

mkdir -p "$CERT_DIR"

if [[ -f "$CERT_DIR/privkey.pem" && -f "$CERT_DIR/fullchain.pem" && "${FORCE:-}" != "1" ]]; then
  echo "certs already exist in $CERT_DIR — set FORCE=1 to regenerate" >&2
  exit 0
fi

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$CERT_DIR/privkey.pem" \
  -out "$CERT_DIR/fullchain.pem" \
  -days "$DAYS" \
  -subj "/C=US/ST=Colorado/O=Rocky Mountain Outlaws/CN=$SERVER_NAME" \
  -addext "subjectAltName=DNS:$SERVER_NAME,DNS:localhost,IP:127.0.0.1,IP:::1"

chmod 600 "$CERT_DIR/privkey.pem"

echo "Wrote self-signed cert (valid ${DAYS} days) for '$SERVER_NAME' to $CERT_DIR"
