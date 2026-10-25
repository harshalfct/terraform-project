#!/usr/bin/env bash
set -Eeuo pipefail

. /etc/os-release
if [[ "$VERSION_ID" != "24.04" || "$(dpkg --print-architecture)" != "amd64" ]]; then
  echo "Build this package bundle on Ubuntu 24.04 amd64 to match the database AMI."
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root (or with sudo)."
  exit 1
fi

apt-get update
apt-get install --download-only --reinstall -y mysql-server awscli

OUTPUT="${1:-mysql-packages.tar.gz}"
STAGING="$(mktemp -d)"
trap 'find "$STAGING" -maxdepth 1 -type f -delete; rmdir "$STAGING"' EXIT
find /var/cache/apt/archives -maxdepth 1 -type f -name '*.deb' -exec cp {} "$STAGING/" \;

if ! find "$STAGING" -maxdepth 1 -type f -name '*.deb' -print -quit | grep -q .; then
  echo "No Debian packages were downloaded for the MySQL package bundle."
  exit 1
fi

tar -czf "$OUTPUT" -C "$STAGING" .
echo "Created package bundle: $OUTPUT"
