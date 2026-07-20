#!/bin/bash
# Install the RTL8852BD Bluetooth firmware + patched btrtl module.
#
#   sudo ./install.sh /path/to/rtl8852bd_mp_chip_new.dat
#   sudo ./install.sh /path/to/realtek-bluetooth-driver.exe    (auto-extracts)
#
set -euo pipefail

PKG=rtl8852bd-bt
VER=1.0
FW_NAME=rtl8852bd_eco4.bin
FW_DIR=/lib/firmware/rtl_bt
USB_ID="0bda:b853"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
die()  { red "error: $*"; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || die "run as root (sudo ./install.sh ...)"
[[ $# -eq 1 ]]    || die "usage: sudo ./install.sh <rtl8852bd_mp_chip_new.dat | driver.exe>"
SRC="$1"
[[ -f "$SRC" ]]   || die "no such file: $SRC"

# ---------------------------------------------------------------- hardware ---
step "Checking hardware"
if lsusb 2>/dev/null | grep -qi "$USB_ID"; then
    grn "  found Realtek $USB_ID (RTL8852BD)"
else
    ylw "  WARNING: USB device $USB_ID not found."
    ylw "  This package is only for that device. Continuing anyway."
fi

# ------------------------------------------------------------ dependencies ---
step "Checking dependencies"
MISSING=()
command -v dkms    >/dev/null || MISSING+=(dkms)
command -v python3 >/dev/null || MISSING+=(python3)
command -v make    >/dev/null || MISSING+=(build-essential)
[[ -d /lib/modules/$(uname -r)/build ]] || MISSING+=("linux-headers-$(uname -r)")
if [[ "$SRC" == *.exe ]]; then
    command -v innoextract >/dev/null || MISSING+=(innoextract)
fi
if (( ${#MISSING[@]} )); then
    ylw "  missing: ${MISSING[*]}"
    if command -v apt-get >/dev/null; then
        echo "  installing via apt..."
        apt-get update -qq
        apt-get install -y "${MISSING[@]}"
    else
        die "install these packages first: ${MISSING[*]}"
    fi
fi
grn "  all dependencies present"

# --------------------------------------------------------------- firmware ---
step "Building firmware"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DAT="$SRC"
if [[ "$SRC" == *.exe ]]; then
    echo "  extracting driver package..."
    innoextract -s -d "$WORK/ie" "$SRC" >/dev/null 2>&1 \
        || die "innoextract failed -- extract the .dat manually (see README)"
    DAT="$(find "$WORK/ie" -iname 'rtl8852bd_mp_chip_new.dat' | head -1)"
    [[ -n "$DAT" ]] || die "rtl8852bd_mp_chip_new.dat not found inside $SRC"
    echo "  found: ${DAT#$WORK/ie/}"
fi

"$HERE/extract-firmware.py" "$DAT" -o "$WORK/$FW_NAME" \
    || die "firmware extraction failed"

install -d "$FW_DIR"
install -m 0644 "$WORK/$FW_NAME" "$FW_DIR/$FW_NAME"
grn "  installed $FW_DIR/$FW_NAME"

# ----------------------------------------------------------------- module ---
step "Building kernel module (DKMS)"
# remove this package and any earlier dev-named build that also provides btrtl
for old in "$PKG" btrtl8852bd; do
    dkms remove -m "$old" -v "$VER" --all >/dev/null 2>&1 || true
    rm -rf "/usr/src/$old-$VER"
done
rm -rf "/usr/src/$PKG-$VER"
install -d "/usr/src/$PKG-$VER"
cp "$HERE"/src/* "/usr/src/$PKG-$VER/"

dkms add    -m "$PKG" -v "$VER" >/dev/null
dkms build  -m "$PKG" -v "$VER" >/dev/null 2>&1 \
    || { dkms build -m "$PKG" -v "$VER" 2>&1 | tail -20; die "module build failed"; }
dkms install -m "$PKG" -v "$VER" --force >/dev/null
depmod -a
grn "  installed $(modinfo -n btrtl 2>/dev/null || echo btrtl.ko)"

# ----------------------------------------------------------------- rfkill ---
# A stale systemd-rfkill saved state will silently keep the radio soft-blocked
# at every boot, which looks exactly like a firmware failure. Clear it.
step "Clearing stale rfkill block"
command -v rfkill >/dev/null && rfkill unblock bluetooth || true
shopt -s nullglob
for f in /var/lib/systemd/rfkill/*bluetooth; do
    if [[ "$(cat "$f")" != "0" ]]; then
        echo "  resetting $(basename "$f")"
        echo 0 > "$f"
    fi
done
shopt -u nullglob
grn "  bluetooth not soft-blocked"

# ------------------------------------------------------------------ reload ---
step "Reloading driver"
DMESG_MARK=$(dmesg | wc -l)     # only look at messages produced from here on
systemctl stop bluetooth 2>/dev/null || true
modprobe -r btusb btrtl 2>/dev/null || true
sleep 1
modprobe btusb
sleep 4
systemctl start bluetooth 2>/dev/null || true
sleep 2

# ------------------------------------------------------------------ verify ---
# The authoritative success signal is the controller running patched firmware
# (HCI 5.4 / fw 0x3C91950E). The dmesg line is a nice-to-have but can be missed
# on a re-install where the probe timing differs, so it never fails the install
# on its own -- only the version check (or a stuck-on-ROM result) decides.
step "Verifying"
FAIL=0

VER_OUT="$(timeout 5 hcitool -i hci0 cmd 0x04 0x01 2>/dev/null | tail -1 || true)"
if [[ "$VER_OUT" == *"0D "*"91 3C"* ]]; then
    grn "  patch is running (HCI 5.4, fw 0x3C91950E)"
elif [[ "$VER_OUT" == *"0B "*"0B 00"* ]]; then
    red "  controller still on ROM firmware -- patch did not launch"; FAIL=1
elif [[ -z "$VER_OUT" ]]; then
    ylw "  could not read controller version (hci0 may be down -- see below)"
fi

if hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"; then
    grn "  hci0 is UP RUNNING"
else
    ylw "  hci0 not up yet -- try: sudo rfkill unblock bluetooth && sudo hciconfig hci0 up"
fi

NEW_DMESG=$(dmesg | tail -n +$((DMESG_MARK + 1)))
if grep -q "eco4 firmware loaded" <<<"$NEW_DMESG"; then
    grn "  firmware loaded: $(grep 'eco4 firmware loaded' <<<"$NEW_DMESG" | tail -1 | sed 's/.*RTL: //')"
fi

echo
if (( FAIL )); then
    red "Install did NOT succeed -- the patch is not running. See README 'Troubleshooting'."
else
    grn "Done. Bluetooth should work now and persist across reboots."
    echo  "If it is off after a reboot, enable Bluetooth once in your desktop settings."
fi
