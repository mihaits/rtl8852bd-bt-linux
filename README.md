# RTL8852BD Bluetooth for Linux

Makes the Realtek **RTL8852BD** Bluetooth radio (USB ID `0bda:b853`) work on Linux.
This chip ships in many RTL8852BE Wi-Fi/Bluetooth combo cards in 2024–2025 laptops;
Wi-Fi works out of the box, Bluetooth does not on any current kernel.

## Quick start

```bash
# 1. Confirm this is your chip — BOTH must match (see "Does this apply?" below)
lsusb | grep -i 0bda:b853               # the Bluetooth adapter is present
dmesg | grep -i "RTL: rom_version"      # must report  version=3

# 2. Download your laptop's Windows Bluetooth driver .exe (see "Get the firmware")

# 3. Install
git clone https://github.com/mihaits/rtl8852bd-bt-linux
cd rtl8852bd-bt-linux
sudo ./install.sh ~/Downloads/your-driver.exe
```

The installer extracts the firmware from that `.exe`, builds a DKMS module, and
brings the radio up. It persists across reboots and kernel updates. Not working or
want it gone? `sudo ./uninstall.sh` restores the stock driver.

**Requirements:** `dkms`, `build-essential`, `linux-headers-$(uname -r)`, `python3`,
and `innoextract` (for the `.exe`). `install.sh` installs anything missing on
apt-based systems.

---

## Does this apply to my machine?

Two checks — **both** must be true:

```bash
lsusb | grep -i 0bda:b853                     # the Bluetooth USB adapter
dmesg | grep -i "RTL: rom_version"            # must say  version=3
```

`0bda:b853` covers the whole RTL8852BE family, but this fix targets the specific
silicon cut that reports **`rom_version=3`** (a.k.a. "8852BD"). If yours reports a
different version, you have a different cut and this is not your fix.

The tell-tale symptom is Bluetooth silently dead — `hci0` never comes up, its
address is all-zeros, and `dmesg` shows **`didn't find patch for chip id 3`**.

<details>
<summary>Laptops reported to ship this chip</summary>

The `0bda:b853` / RTL8852BE combo is common in 2024–2025 laptops. Families reported
to ship it include **Lenovo** LOQ / IdeaPad / Legion / ThinkBook, **HP** Victus /
15-fc, **Acer** Nitro / Aspire, and **Asus** TUF / Vivobook. This is not a
compatibility guarantee — the same model can ship Intel or MediaTek radios in other
batches, and not every 8852BE unit is the `rom_version=3` cut. The two commands
above are the only reliable test.
</details>

## Get the firmware

**No firmware is included here** — it is proprietary Realtek code that cannot be
redistributed. You supply it from your own laptop's Windows driver. You need the file
`rtl8852bd_mp_chip_new.dat`, which is Realtek's firmware for the 8852BD chip (not
laptop-specific — any vendor's Realtek Bluetooth driver for a `0bda:b853` adapter has
a working copy: Dell, HP, Asus, or Realtek's own driver all do).

Go to your vendor's support site and download the **Bluetooth driver** for your model
— on Lenovo: *Support → your model → Drivers & Software → Bluetooth*. You'll get a
**Windows installer `.exe`** with a cryptic name like `53lo030fqufmvnj0.exe`.
**Don't run or rename it** — just note where it downloaded (e.g.
`~/Downloads/53lo030fqufmvnj0.exe`) and pass that path to `install.sh`. It runs
`innoextract` on the `.exe` for you; you don't extract anything by hand.

<details>
<summary>Optional: extract the <code>.dat</code> yourself instead of passing the <code>.exe</code></summary>

The `.exe` is an Inno Setup installer, so it unpacks on Linux — no Windows needed:

```bash
innoextract -s -d extracted ~/Downloads/53lo030fqufmvnj0.exe
find extracted -name 'rtl8852bd_mp_chip_new.dat'
head -c 8 path/to/rtl8852bd_mp_chip_new.dat    # sanity check -> should print  BTNIC003
```

Then pass that `.dat` to `install.sh` instead of the `.exe`.
</details>

## Install

```bash
git clone https://github.com/mihaits/rtl8852bd-bt-linux
cd rtl8852bd-bt-linux
sudo ./install.sh ~/Downloads/53lo030fqufmvnj0.exe     # your downloaded filename
```

`install.sh` takes **one argument** and decides what to do from the extension: a
`.exe` is unpacked with `innoextract` automatically; anything else is treated as an
already-extracted `.dat`:

```bash
sudo ./install.sh /path/to/rtl8852bd_mp_chip_new.dat
```

Either way it then builds the firmware, installs the DKMS module, clears a stale
rfkill block if present, reloads the driver, and verifies the result.

## Verify

```
$ hciconfig hci0
hci0:  Type: Primary  Bus: USB
       BD Address: XX:XX:XX:XX:XX:XX          # a real address, not all-zeros
       UP RUNNING

$ bluetoothctl scan on          # should list nearby devices
```

To confirm the patch is actually running, read the controller version — it changes
once the firmware is live:

```bash
sudo hcitool -i hci0 cmd 0x04 0x01
```

| | HCI ver | fw version |
|---|---|---|
| ROM (broken) | `0x0B` (BT 5.2) | `0x000B8852` |
| patched (working) | `0x0D` (BT 5.4) | `0x3C91950E` |

## Troubleshooting

**Bluetooth is off after a reboot / `hci0` is `DOWN` but `dmesg` looks clean.**
Almost always a stale rfkill block, not firmware:

```bash
rfkill list bluetooth
sudo rfkill unblock bluetooth
```

`systemd-rfkill` restores a *saved* block at every boot, so if the radio was disabled
while it was broken the block survives the fix. `install.sh` clears the saved state;
if it comes back, enable Bluetooth once in your desktop settings so the correct state
is saved on shutdown.

**`hciconfig` shows nothing.** Check the device is present and bound:
`lsusb | grep 0bda:b853` and `dmesg | grep -i bluetooth`.

**Module didn't build.** Make sure `linux-headers-$(uname -r)` matches your running
kernel, then `sudo dkms build -m rtl8852bd-bt -v 1.0` to see the error.

**Still on ROM firmware after install** (`0x000B8852` above). The download ran but the
patch did not launch — check `dmesg` for `eco4` errors and confirm your `.dat` is for
**8852BD**, not `rtl8852b_mp_chip_new.dat` or `rtl8852c_mp_chip_new.dat`.

## Uninstall

```bash
sudo ./uninstall.sh          # removes the module + firmware, restores stock btrtl
```

Kernel updates need no action — DKMS rebuilds the module automatically.

---

## Compatibility & caveats

This ships a **patched copy of the whole `btrtl` module** and lets DKMS build it
against your running kernel, replacing the in-tree `btrtl`. Worth knowing before you
install on an untested kernel:

- The **new code** (the eco-4 download) uses only long-stable kernel APIs — nothing
  version-fragile.
- The **base** `btrtl.c` is a snapshot of the module as of **kernel 6.8**, carried
  forward with two small compatibility shims so the same source builds on newer
  kernels: the `<asm/unaligned.h>` → `<linux/unaligned.h>` move (6.12) and the
  `hdev->quirks` bitmap → `hci_set_quirk()` accessor change (6.14). Both are keyed off
  the feature actually being present (`__has_include`, `#ifndef`) rather than a kernel
  version number, so a distro that backports either change is handled correctly.
- Because the module replaces the in-tree one, its exported symbols must stay
  ABI-compatible with the `btusb` your kernel already has. If a future kernel changes
  the internal `btrtl`↔`btusb` interface, this copy may fail to build or refuse to
  bind (symbol-version/CRC mismatch) — Bluetooth just won't come up and you should
  `./uninstall.sh`.
- No out-of-tree DKMS module is signed, so it won't load under **Secure Boot** unless
  you enroll a MOK. Disable Secure Boot or sign the module yourself.

**Tested — verified working on real hardware:**

| Distro | Kernel | Notes |
|---|---|---|
| Ubuntu 22.04.5 HWE | **6.8.0** (x86_64) | original target (Lenovo LOQ 15ARP10E) |
| Ubuntu 25.10 | **6.17.0** (x86_64) | built + bound cleanly via the 6.12/6.14 shims |

The module also builds cleanly across the 6.8 point-release series, and the shims
cover the whole 6.12+/6.14+ API range (so Ubuntu 24.04's newer HWE kernels are
expected to work too). Anything outside those points is **untested** but safe to try:
a failed build or bind is reversible with `./uninstall.sh`. Requires a distro that
ships `btusb`/`btrtl` as separate modules (effectively everything from the last
several years); x86_64 is what this was built and tested on, other architectures are
unverified.

## How it works

`btrtl` detects the chip, then fails silently — `dmesg` shows `didn't find patch for
chip id 3` and `hci0` never opens. This silicon revision reports `rom_version=3`, so
it needs a firmware patch with **eco 4**. The `rtl8852bu_fw.bin` in `linux-firmware`
contains only eco 1 and 2, so the parser extracts zero bytes and gives up. It's a
firmware-content gap, not a kernel bug — no mainline kernel or `linux-firmware`
release ships eco-4 for this cut. (The `Opcode 0xfcf0 failed: -16` you may see in the
logs is unrelated — a red herring.)

The eco-4 firmware *does* exist, in Realtek's Windows driver — but not in the
EPATCH/`RTBTCore` format `btrtl` expects. It ships as three independent records in a
`BTNIC003` container, each with its own RAM load address, pushed with a vendor
download protocol:

| opcode | meaning |
|---|---|
| `0xfc61` | read memory — `[0x21][addr:le32]` |
| `0xfc62` | **write memory** — `[0x21][dst:le32][value:le32]` |
| `0xfc20` | download fragment — `[index][data…]`, ≤252 B, index 1…0x7f wrapping |

The key detail: `0x801200cc` holds the address the controller streams `0xfc20`
fragments into. Each record's load address must be **written into that pointer**
before its fragments are sent:

```
for each record:
    fc62  [0x21][0x801200cc][record_load_addr]     # aim the download buffer
    fc20  [idx][data] ...                          # plain indices, no bit 7
fc20  [0x80]                                       # commit, once, at the end
```

Miss the pointer write and every record lands on the default buffer (`0x8010f720`).
All commands still return success, the firmware is resident, and the controller
answers HCI — but the code isn't where the entry point expects it, so the patch never
launches and the radio stays dead. That silent failure is what makes this chip so
confusing to debug.

`extract-firmware.py` repacks the `.dat` records into a small container (`E4RD` +
count + `[load][len][blob]` per record) that the patched `rtl_download_eco4()` in
`src/btrtl.c` reads.

One wrinkle if you're adapting this: the stock parser fails with a *different* errno
depending on which container `linux-firmware` shipped for your kernel — `-EINVAL` for
the v1 `Realtech` EPATCH format, `-ENODATA` for v2 `RTBTCore`. The hook accepts both,
scoped by chip ID so it cannot swallow unrelated failures.

## Upstreaming

This is a self-contained addition to `btrtl.c` and would be better in mainline. The
blocker is that the firmware itself is not in `linux-firmware`; Realtek would need to
publish eco-4 for 8852BD. Patches and reports welcome.

## License

`src/btrtl.c`, `src/btrtl.h`, `src/hci_codec.h` are derived from the Linux kernel and
remain **GPL-2.0**. The scripts in this repository are GPL-2.0 as well. No Realtek
firmware is included or redistributed.

## Disclaimer

**This is a fully "vibecoded" project.** It was researched, reverse-engineered, and
written end-to-end by AI — Claude Opus 4.8, with a bit of Fable 5 — driven by me
prompting and testing on the one machine I own. **I am not a driver developer or a
kernel maintainer**, and I can't vouch for this code the way someone who writes
Bluetooth drivers for a living could. It is provided **as is**, with no warranty of
any kind.

Concretely: it loads vendor-provided firmware onto your Bluetooth controller and
replaces an in-tree kernel module via DKMS; it is validated on one laptop across a
couple of kernels; and while a bad outcome is reversible (`./uninstall.sh` restores
the stock module), you run it at your own risk. Read the scripts before running them
as root — you should do that with anything off the internet, and doubly so here.

Unofficial, and not affiliated with Realtek or any laptop vendor.
