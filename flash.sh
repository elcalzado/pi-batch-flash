#!/usr/bin/env bash
#
# flash.sh: batch-flash rpiboot-capable Raspberry Pi targets with the latest Raspberry
# Pi OS Lite (64-bit) plus a per-unit cloud-init config: a hostname and a matching
# passwordless, SSH-key-only user.
#
# Batch mode names units <host>-<N>; a single unit is named exactly <host>.
#
# Usage:
#   sudo ./flash.sh [--ssh-file PATH] <host> <user> [start_n]
#
#   With start_n  -> BATCH mode: loops, naming units <host>-<N>, <host>-<N+1>, ...
#   Without       -> SINGLE mode: flashes ONE unit named exactly <host>, then exits.
#
# Examples:
#   sudo ./flash.sh --ssh-file ~/.ssh/id_ed25519.pub pi user 47      # batch
#   sudo ./flash.sh pi user                                          # single
#
set -uo pipefail

# Resolve ~ to the invoking user's home even under sudo (so ~/usbboot etc. point
# at your home, not /root).
if [[ -n "${SUDO_USER:-}" ]]; then
  _h="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  [[ -n "$_h" ]] && { HOME="$_h"; export HOME; }
  unset _h
fi

### ============ EDIT THESE (if needed) ============
USBBOOT_DIR=~/usbboot                          # clone of raspberrypi/usbboot
GADGET="$USBBOOT_DIR/mass-storage-gadget64"
IMG=~/raspios_lite_arm64_latest.img.xz         # local image cache
IMG_URL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"

# First-boot regional settings (cloud-init)
LOCALE="en_US.UTF-8"                            # a locale code
TIMEZONE="America/Los_Angeles"                  # IANA time-zone name
KEYBOARD="us"                                   # keyboard layout code

# Supplementary groups for the created user. This is the Raspberry Pi OS built-in
# default set. The user's own group <user>-<N> is added on top automatically as the
# account's primary group.
USER_GROUPS="adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,netdev,lpadmin,gpio,i2c,spi,render,input"
### ================================================

usage() {
  cat <<'USAGE'
Usage: sudo ./flash.sh [--ssh-file PATH] <host> <user> [start_n]

Arguments:
  host       (required) hostname (see start_n)
  user       (required) username (see start_n)
  start_n    (optional) starting integer N (> 0).
             Given   -> BATCH mode: loops, naming units <host>-<N>, <host>-<N+1>, ...
             Omitted -> SINGLE mode: flashes ONE unit named exactly <host> (no
                        number), then exits.

Options:
  --ssh-file PATH  public key to install (default: ~/.ssh/id_ed25519.pub, then
                   ~/.ssh/id_rsa.pub). This key is the only login method; the
                   user is created with no password.
  -h, --help       show this help

Examples:
  sudo ./flash.sh --ssh-file ~/.ssh/id_ed25519.pub pi user 47      # batch
  sudo ./flash.sh pi user                                          # single
USAGE
}

# ---- parse args ----
SSH_FILE=""
POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-file)   SSH_FILE="${2:-}"; shift 2;;
    --ssh-file=*) SSH_FILE="${1#*=}"; shift;;
    -h|--help)    usage; exit 0;;
    --)           shift; while [[ $# -gt 0 ]]; do POS+=("$1"); shift; done;;
    -*)           echo "Unknown option: $1" >&2; usage; exit 1;;
    *)            POS+=("$1"); shift;;
  esac
done

case ${#POS[@]} in
  2) HOST_PREFIX="${POS[0]}"; USER_PREFIX="${POS[1]}"; LOOP=0 ;;
  3) HOST_PREFIX="${POS[0]}"; USER_PREFIX="${POS[1]}"; START_N="${POS[2]}"; LOOP=1 ;;
  *) echo "Error: need host and user (start_n is optional)." >&2; usage; exit 1 ;;
esac
if [[ "$LOOP" -eq 1 ]]; then
  [[ "$START_N" =~ ^[1-9][0-9]*$ ]] || { echo "Error: start_n must be an integer > 0." >&2; exit 1; }
fi

# ---- resolve tools ----
RPIBOOT="$(command -v rpiboot || echo "$USBBOOT_DIR/rpiboot")"
RPI_IMAGER="$(command -v rpi-imager || true)"

# ---- preflight ----
[[ $EUID -eq 0 ]]      || { echo "Run with sudo."; exit 1; }
[[ -n "$RPI_IMAGER" ]] || { echo "rpi-imager not found (install rpi-imager)."; exit 1; }
[[ -x "$RPIBOOT" ]]    || { echo "rpiboot not found at $RPIBOOT."; exit 1; }
[[ -d "$GADGET" ]]     || { echo "Gadget dir not found: $GADGET"; exit 1; }

# ---- resolve SSH public key ----
if [[ -z "$SSH_FILE" ]]; then
  for cand in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    [[ -f "$cand" ]] && { SSH_FILE="$cand"; break; }
  done
fi
[[ -n "$SSH_FILE" && -f "$SSH_FILE" ]] || {
  echo "Error: no SSH public key. Pass --ssh-file PATH or create ~/.ssh/id_ed25519.pub." >&2; exit 1; }

# Build the YAML list of authorized keys (supports one or more keys in the file).
ssh_keys_yaml=""
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  ssh_keys_yaml+="      - ${line}"$'\n'
done < "$SSH_FILE"
ssh_keys_yaml="${ssh_keys_yaml%$'\n'}"
[[ -n "$ssh_keys_yaml" ]] || { echo "Error: $SSH_FILE has no usable key lines." >&2; exit 1; }

# ---- download the OS image once ----
if [[ ! -f "$IMG" ]]; then
  echo "Downloading latest Raspberry Pi OS Lite (64-bit)..."
  curl -fL --retry 3 -o "$IMG" "$IMG_URL" || { echo "Download failed."; exit 1; }
fi

list_usb_disks() { lsblk -dpno NAME,TRAN | awk '$2=="usb"{print $1}' | sort -u; }

biggest() {  # from device names on stdin, echo the one with the largest size
  local dev best="" bestsz=0 sz
  while read -r dev; do
    [[ -z "$dev" ]] && continue
    sz=$(lsblk -dbno SIZE "$dev" 2>/dev/null | head -n1); [[ -z "$sz" ]] && sz=0
    (( sz > bestsz )) && { bestsz=$sz; best=$dev; }
  done
  echo "$best"
}

wait_new_disk() {  # $1 = snapshot before; echoes the biggest newly-appeared USB disk
  local before="$1" after new
  for _ in $(seq 1 60); do
    after="$(list_usb_disks)"
    new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
    if [[ -n "$new" ]]; then
      sleep 3                       # let all LUNs (eMMC + NVMe) settle
      after="$(list_usb_disks)"
      new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
      printf '%s\n' "$new" | biggest; return 0
    fi
    sleep 1
  done
  return 1
}

flash_unit() {  # $1 = /dev/sdX , $2 = hostname , $3 = username
  local dev="$1" host="$2" usr="$3" part="${1}1" mnt
  echo ">>> [$host] writing image to $dev"
  "$RPI_IMAGER" --cli "$IMG" "$dev" || { echo ">>> [$host] rpi-imager failed"; return 1; }

  blockdev --rereadpt "$dev" 2>/dev/null || partprobe "$dev" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  local ok=0; for _ in $(seq 1 15); do [[ -b "$part" ]] && { ok=1; break; }; sleep 1; done
  [[ $ok -eq 1 ]] || { echo ">>> [$host] boot partition $part not found"; return 1; }

  mnt="$(mktemp -d)"
  mount "$part" "$mnt" || { echo ">>> [$host] mount failed"; rmdir "$mnt"; return 1; }

cat > "$mnt/user-data" <<EOF
#cloud-config
hostname: ${host}
manage_etc_hosts: true
locale: ${LOCALE}
timezone: ${TIMEZONE}
keyboard:
  model: pc105
  layout: "${KEYBOARD}"

users:
  - name: ${usr}
    groups: ${usr},${USER_GROUPS}
    shell: /bin/bash
    lock_passwd: true
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
${ssh_keys_yaml}

enable_ssh: true
ssh_pwauth: false
EOF
  printf 'instance-id: %s\n' "$host" > "$mnt/meta-data"
  sync; umount "$mnt" && rmdir "$mnt"
  echo ">>> [$host] config written; done"
}

run_bg() {  # $1 = /dev/sdX , $2 = hostname , $3 = username
  local dev="$1" host="$2" usr="$3" log="/tmp/${2}.log"
  if flash_unit "$dev" "$host" "$usr" >"$log" 2>&1; then echo "[OK]   $host on $dev  (log: $log)"
  else echo "[FAIL] $host on $dev  (log: $log)"; fi
}

# ---- rpiboot one target and set DEV to its /dev/sdX (returns 1 if none appears) ----
DEV=""
prep_one() {
  local before
  before="$(list_usb_disks)"
  echo "Put the target into rpiboot mode and power it on..."
  "$RPIBOOT" -d "$GADGET"                 # loads gadget, exits when target re-appears as USB storage
  DEV="$(wait_new_disk "$before")" || return 1
}

echo "host=$HOST_PREFIX  user=$USER_PREFIX  key=$SSH_FILE"

if [[ "$LOOP" -eq 0 ]]; then
  # ---- SINGLE unit: exact name, no suffix, no loop ----
  echo "Single unit -> hostname/user = ${HOST_PREFIX}/${USER_PREFIX}"
  if ! prep_one; then
    echo "No new USB disk detected — check cabling/power/boot mode."; exit 1
  fi
  echo "Detected $DEV — flashing ${HOST_PREFIX}."
  if flash_unit "$DEV" "$HOST_PREFIX" "$USER_PREFIX"; then
    echo "[OK]   ${HOST_PREFIX} on $DEV"
  else
    echo "[FAIL] ${HOST_PREFIX} on $DEV"; exit 1
  fi
else
  # ---- BATCH: loop, naming units <host>-<N>, flashing each in the background ----
  N="$START_N"
  echo "Batch from N=$START_N. Insert targets ONE AT A TIME. Type q to finish (do not Ctrl-C mid-flash)."
  while true; do
    read -rp "Press Enter to prep ${HOST_PREFIX}-${N} (or q to finish): " ans
    [[ "$ans" == "q" ]] && break
    if ! prep_one; then
      echo "No new USB disk detected — check cabling/power/boot mode. Skipping."; continue
    fi
    host="${HOST_PREFIX}-${N}"; usr="${USER_PREFIX}-${N}"
    echo "Detected $DEV for ${host} — flashing in background. Label this unit ${host}."
    run_bg "$DEV" "$host" "$usr" &
    N=$((N+1))
  done
  echo "Waiting for in-progress flashes to finish (do NOT unplug)..."
  wait
  echo "All units done."
fi