# pi-batch-flash

Batch-flash rpiboot-capable Raspberry Pi targets with the latest **Raspberry Pi OS Lite (64-bit)** and a per-unit cloud-init config. Each unit gets hostname `<host>-<N>` and a matching **passwordless, SSH-key-only** user `<user>-<N>`.

Flashes run in the background, so you overlap them while connecting modules one at a time.

> **NOTE:** You will probably need to use a powered USB hub to flash more than one unit at a time. When tested on a RPi 4, both units would shut off if they were flashing simultaneously.

## How it works

1. `rpiboot -d mass-storage-gadget64` loads the fast Linux gadget onto the target, exposing its NVMe/eMMC as USB mass storage on the host.
2. `rpi-imager --cli` writes the OS image to that block device and verifies it.
3. The script mounts the boot partition and writes cloud-init `user-data` + `meta-data` (hostname, user, key, locale/timezone/keyboard). On first boot the target applies them.

### Why the config is written directly (not via rpi-imager's flags)

The latest OS (Trixie) uses cloud-init for first-boot setup, and only rpi-imager 2.0+ can customize it while older versions fail silently and leave a raw OS. Writing the cloud-init files ourselves works regardless of the installed rpi-imager version. The files written are the same modern cloud-init format rpi-imager 2.0 generates; the one deliberate difference is that the account is **key-only with no password**.

## Requirements

**Host** (the machine running the script): a Raspberry Pi (or any Linux box) with

- `rpiboot` (built from [raspberrypi/usbboot](https://github.com/raspberrypi/usbboot)) and its `mass-storage-gadget64`
- `rpi-imager`
- internet access, to download the OS image once

**Targets**: any rpiboot-capable Pi.

## Install

```bash
sudo apt update
sudo apt install -y git build-essential libusb-1.0-0-dev pkg-config rpi-imager
git clone --recurse-submodules https://github.com/raspberrypi/usbboot ~/usbboot
cd ~/usbboot && make && make install
```

## Configure

The `EDIT THESE` block near the top of `flash.sh` holds the paths and the first-boot defaults. The paths use `~/`, and the script resolves `~` to the invoking user's home **even under sudo**, so they follow whoever runs it instead of pointing at `/root`:

```bash
USBBOOT_DIR=~/usbboot
IMG=~/raspios_lite_arm64_latest.img.xz

LOCALE="en_US.UTF-8"
TIMEZONE="America/Los_Angeles"
KEYBOARD="us"

USER_GROUPS="adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,netdev,lpadmin,gpio,i2c,spi,render,input"
```

`LOCALE` / `TIMEZONE` / `KEYBOARD` become the unit's regional settings on first boot. `USER_GROUPS` is the Raspberry Pi OS built-in default group set; the account's own group `<user>-<N>` is added on top automatically as its primary group. Hostname, user, starting number, and SSH key are passed on the command line.

## Usage

```
sudo ./flash.sh [--ssh-file PATH] <host> <user> [start_n]
```

| Argument | Meaning |
|----------|---------|
| `host` | (required) hostname — a prefix in batch mode, the exact name in single mode |
| `user` | (required) username — a prefix in batch mode, the exact name in single mode |
| `start_n` | (optional) starting integer N (> 0). **Given** → batch mode (loops, names units `<host>-<N>`, `<host>-<N+1>`, …). **Omitted** → single mode (flashes one unit named exactly `<host>`, then exits). |
| `--ssh-file PATH` | public key to install (default: `~/.ssh/id_ed25519.pub`, then `~/.ssh/id_rsa.pub`) |

## Provisioning workflow

1. Run the command above. It downloads the image once (if not cached), then prompts.
2. Press **Enter**, then put one target into rpiboot mode and power it on.
3. The script detects the **largest new USB disk**, starts the flash in the **background**, and immediately prompts for the next one.
4. Watch any unit: `tail -f /tmp/<host>.log`.
5. Type **`q`** when done. *don't* Ctrl-C, it can interrupt a running flash. The script waits for the stragglers.

Label each physical unit with the hostname the script prints for it.

In **single mode** (no `start_n`) there's no loop or `q`: it prepares one target, flashes it in the foreground, prints `[OK]`/`[FAIL]`, and exits with a matching status.

## Verify a flashed unit

Boot the module, put it on Ethernet, and:

```bash
ssh <user>@<host>.local
hostname     # -> <host>
whoami       # -> <user>
sudo whoami  # -> root, no password prompt
```

`.local` works via mDNS from macOS, Linux, and Windows.

## BOOT_ORDER

If the Raspberry Pi you're provisioning doesn't have an nRPIBOOT jumper, modify, boot into it once, and modify its BOOT_ORDER through `sudo -E rpi-eeprom-config --edit`.

See [boot-order-fields](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#boot_order-fields) to determine the correct configuration.

## What gets written to each unit

`user-data` on the boot (FAT32) partition:

```yaml
#cloud-config
hostname: <host>
manage_etc_hosts: true
locale: en_US.UTF-8
timezone: America/Los_Angeles
keyboard:
  model: pc105
  layout: "us"

users:
  - name: <user>
    groups: <user>,adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,netdev,lpadmin,gpio,i2c,spi,render,input
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - <contents of your --ssh-file>

enable_ssh: true
ssh_pwauth: false
```

plus `meta-data` with a unique `instance-id` so cloud-init re-runs on each freshly flashed drive.
