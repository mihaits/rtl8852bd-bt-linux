#!/bin/bash
# Remove the patched btrtl module and firmware, restoring the stock driver.
set -euo pipefail

PKG=rtl8852bd-bt
VER=1.0
FW=/lib/firmware/rtl_bt/rtl8852bd_eco4.bin

[[ $EUID -eq 0 ]] || { echo "run as root (sudo ./uninstall.sh)"; exit 1; }

echo "==> Removing DKMS module"
dkms remove -m "$PKG" -v "$VER" --all 2>/dev/null || true
rm -rf "/usr/src/$PKG-$VER"

echo "==> Removing firmware"
rm -f "$FW"

echo "==> Reloading stock driver"
depmod -a
systemctl stop bluetooth 2>/dev/null || true
modprobe -r btusb btrtl 2>/dev/null || true
sleep 1
modprobe btusb 2>/dev/null || true

echo "Done. The stock btrtl is back in use; Bluetooth will not work on this"
echo "adapter again until you re-run install.sh."
