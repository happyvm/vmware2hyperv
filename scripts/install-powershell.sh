#!/usr/bin/env bash
set -euo pipefail

if command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell already installed: $(pwsh --version)"
  exit 0
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Error: this script requires root privileges (run as root or install sudo)." >&2
    exit 1
  fi
else
  SUDO=""
fi

$SUDO apt-get update
$SUDO apt-get install -y wget apt-transport-https software-properties-common

source /etc/os-release
UBUNTU_VERSION="${VERSION_ID:-22.04}"

TMP_DEB="$(mktemp /tmp/packages-microsoft-prod.XXXXXX.deb)"
cleanup() {
  rm -f "$TMP_DEB"
}
trap cleanup EXIT

if ! wget -q "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VERSION}/packages-microsoft-prod.deb" -O "$TMP_DEB"; then
  echo "Falling back to Ubuntu 22.04 Microsoft package feed."
  wget -q "https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb" -O "$TMP_DEB"
fi

$SUDO dpkg -i "$TMP_DEB"
$SUDO apt-get update
$SUDO apt-get install -y powershell

pwsh --version
