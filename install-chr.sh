#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# MikroTik CHR Automatic Installer
# Ubuntu/Debian -> Latest RouterOS v7 Stable
#
# WARNING:
# This script automatically ERASES the system disk.
# There is NO confirmation prompt.
# =========================================================

WORK="/dev/shm/chr-installer"

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

# =========================================================
# ROOT CHECK
# =========================================================

[[ $EUID -eq 0 ]] || die "Run this script as root."

# =========================================================
# ARCHITECTURE CHECK
# =========================================================

ARCH="$(uname -m)"

[[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]] ||
    die "Only x86_64/amd64 is supported."

# =========================================================
# OS CHECK
# =========================================================

[[ -x /usr/bin/apt-get ]] ||
    die "Ubuntu/Debian with apt-get is required."

# =========================================================
# SYSRQ CHECK
# =========================================================

[[ -w /proc/sysrq-trigger ]] ||
    die "/proc/sysrq-trigger is unavailable."

# =========================================================
# BIOS / SEABIOS SAFETY CHECK
#
# This installer is intentionally limited to the same
# BIOS/SeaBIOS VPS profile that was successfully tested.
# =========================================================

if [[ -d /sys/firmware/efi ]]; then
    die "UEFI detected. This installer is restricted to BIOS/SeaBIOS VPS."
fi

# =========================================================
# REQUIRED SYSTEM COMMANDS
# =========================================================

for cmd in \
    findmnt \
    lsblk \
    readlink \
    df \
    stat \
    blockdev \
    awk \
    grep \
    sha256sum \
    swapon \
    swapoff
do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "Missing required command: $cmd"
done

# =========================================================
# DETECT CURRENT ROOT DEVICE
# =========================================================

ROOT_SRC="$(findmnt -n -o SOURCE /)"

ROOT_SRC="$(
    readlink -f "$ROOT_SRC" 2>/dev/null ||
    printf '%s' "$ROOT_SRC"
)"

[[ -b "$ROOT_SRC" ]] ||
    die "Root filesystem is not on a directly detectable block device: $ROOT_SRC"

ROOT_TYPE="$(
    lsblk -dn -o TYPE "$ROOT_SRC" |
    head -n1 |
    tr -d ' '
)"

# =========================================================
# DETECT PARENT SYSTEM DISK
#
# Example:
# /dev/vda1 -> /dev/vda
# /dev/sda1 -> /dev/sda
# /dev/nvme0n1p1 -> /dev/nvme0n1
# =========================================================

case "$ROOT_TYPE" in

    part)

        PKNAME="$(
            lsblk -dn -o PKNAME "$ROOT_SRC" |
            head -n1 |
            tr -d ' '
        )"

        [[ -n "$PKNAME" ]] ||
            die "Could not detect parent disk of $ROOT_SRC"

        DISK="/dev/$PKNAME"
        ;;

    disk)

        DISK="$ROOT_SRC"
        ;;

    *)

        die "Unsupported root storage type: $ROOT_TYPE. LVM/RAID/mapper is not supported."
        ;;

esac

[[ -b "$DISK" ]] ||
    die "Detected target disk does not exist: $DISK"

# =========================================================
# TARGET DISK SANITY CHECK
# =========================================================

DISK_SIZE="$(blockdev --getsize64 "$DISK")"

(( DISK_SIZE >= 512*1024*1024 )) ||
    die "Detected disk is suspiciously small: $DISK"

# =========================================================
# VERIFY /dev/shm IS ACTUALLY RAM
# =========================================================

SHM_FS="$(
    findmnt -n -o FSTYPE /dev/shm 2>/dev/null ||
    true
)"

[[ "$SHM_FS" == "tmpfs" ]] ||
    die "/dev/shm is not tmpfs. Refusing live installation."

# =========================================================
# INSTALL REQUIRED PACKAGES
# =========================================================

echo
echo "==> Installing required tools..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    busybox-static \
    >/dev/null

[[ -x /bin/busybox ]] ||
    die "busybox-static installation failed."

# =========================================================
# DETECT LATEST ROUTEROS v7 STABLE
# =========================================================

echo
echo "==> Detecting latest MikroTik RouterOS v7 Stable..."

VERSION_RESPONSE="$(
    curl \
        -fsSL \
        --retry 5 \
        --retry-all-errors \
        --connect-timeout 15 \
        --max-time 30 \
        "https://upgrade.mikrotik.com/routeros/NEWESTa7.stable" \
        2>/dev/null ||
        true
)"

VERSION="$(
    printf '%s\n' "$VERSION_RESPONSE" |
    awk 'NR==1 {print $1}'
)"

# =========================================================
# FALLBACK STABLE SERVER
# =========================================================

if [[ ! "$VERSION" =~ ^7\.[0-9]+(\.[0-9]+)?$ ]]; then

    echo "==> Primary version server failed."
    echo "==> Trying MikroTik download server..."

    VERSION_RESPONSE="$(
        curl \
            -fsSL \
            --retry 5 \
            --retry-all-errors \
            --connect-timeout 15 \
            --max-time 30 \
            "https://download.mikrotik.com/routeros/NEWESTa7.stable" \
            2>/dev/null ||
            true
    )"

    VERSION="$(
        printf '%s\n' "$VERSION_RESPONSE" |
        awk 'NR==1 {print $1}'
    )"

fi

# =========================================================
# VERSION SAFETY VALIDATION
#
# Allows:
# 7.24
# 7.24.4
#
# Rejects beta / rc / garbage.
# =========================================================

[[ "$VERSION" =~ ^7\.[0-9]+(\.[0-9]+)?$ ]] ||
    die "Could not safely determine latest RouterOS Stable."

echo
echo "=========================================="
echo " MikroTik CHR Automatic Installer"
echo "=========================================="
echo
echo "RouterOS : $VERSION"
echo "Root FS  : $ROOT_SRC"
echo "Disk     : $DISK"
echo "Disk Size: $(lsblk -dn -o SIZE "$DISK" | tr -d ' ')"
echo

# =========================================================
# PREPARE RAM WORKSPACE
# =========================================================

rm -rf "$WORK"

mkdir -m 700 -p "$WORK"

ZIP="$WORK/chr.zip"
IMG="$WORK/chr-${VERSION}.img"
BB="$WORK/busybox"
STAGE2="$WORK/stage2.sh"

BASE="https://download.mikrotik.com"

URL="${BASE}/routeros/${VERSION}/chr-${VERSION}.img.zip"

# =========================================================
# DOWNLOAD CHR DIRECTLY INTO RAM
# =========================================================

echo "==> Downloading official CHR ${VERSION} into RAM..."
echo

curl \
    -fL \
    --retry 5 \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 300 \
    -o "$ZIP" \
    "$URL" ||
    die "CHR ${VERSION} download failed."

[[ -s "$ZIP" ]] ||
    die "Downloaded CHR archive is empty."

# =========================================================
# VERIFY ZIP INTEGRITY
# =========================================================

echo
echo "==> Checking CHR ZIP integrity..."

unzip -t "$ZIP" >/dev/null ||
    die "CHR ZIP integrity test failed."

echo "==> ZIP integrity: OK"

# =========================================================
# FIND IMAGE INSIDE ZIP
# =========================================================

IMG_NAME="$(
    unzip -Z1 "$ZIP" |
    awk '/\.img$/ {print; exit}'
)"

[[ -n "$IMG_NAME" ]] ||
    die "CHR .img file not found inside archive."

EXPECTED_SIZE="$(
    unzip -l "$ZIP" |
    awk '/\.img$/ {print $1; exit}'
)"

[[ "$EXPECTED_SIZE" =~ ^[0-9]+$ ]] ||
    die "Could not determine CHR image size."

# =========================================================
# CHECK AVAILABLE RAM
# =========================================================

AVAIL="$(
    df -B1 --output=avail /dev/shm |
    tail -n1 |
    tr -d ' '
)"

NEEDED=$((EXPECTED_SIZE + 64*1024*1024))

(( AVAIL >= NEEDED )) ||
    die "Not enough free RAM in /dev/shm."

# =========================================================
# EXTRACT IMAGE COMPLETELY INTO RAM
# =========================================================

echo
echo "==> Extracting CHR image into RAM..."

unzip -p "$ZIP" "$IMG_NAME" > "$IMG"

SIZE="$(stat -c '%s' "$IMG")"

[[ "$SIZE" -eq "$EXPECTED_SIZE" ]] ||
    die "Extracted CHR image size mismatch."

echo "==> Image size verification: OK"

# ZIP is no longer needed.
rm -f "$ZIP"

# =========================================================
# CALCULATE SOURCE IMAGE HASH
# =========================================================

EXPECTED_HASH="$(
    sha256sum "$IMG" |
    awk '{print $1}'
)"

[[ "$EXPECTED_HASH" =~ ^[0-9a-f]{64}$ ]] ||
    die "Could not calculate CHR SHA256."

echo
echo "==> Source image SHA256:"
echo "$EXPECTED_HASH"

# =========================================================
# COPY STATIC BUSYBOX INTO RAM
#
# This is critical:
# after Ubuntu is overwritten, installer commands continue
# executing entirely from RAM.
# =========================================================

cp -f /bin/busybox "$BB"

chmod 700 "$BB"

if ! ldd "$BB" 2>&1 |
    grep -Eq 'not a dynamic executable|statically linked'
then
    die "BusyBox is not static."
fi

echo
echo "==> Static BusyBox: OK"

# =========================================================
# DISABLE SWAP
# =========================================================

if swapon --noheadings --show 2>/dev/null | grep -q .; then

    echo
    echo "==> Disabling swap..."

    swapoff -a ||
        die "Could not disable swap."

fi

# =========================================================
# DISPLAY NETWORK INFORMATION BEFORE UBUNTU DISAPPEARS
# =========================================================

echo
echo "=========================================="
echo " Installation checks passed"
echo "=========================================="
echo
echo "RouterOS : $VERSION"
echo "Target   : $DISK"
echo "IMG Size : $SIZE bytes"
echo
echo "Current IPv4:"
ip -4 -br addr 2>/dev/null || true
echo
echo "Current routes:"
ip -4 route 2>/dev/null || true
echo

# =========================================================
# CREATE STAGE 2
#
# Stage 2 executes exclusively using:
#
#   /dev/shm
#   static BusyBox
#   Linux kernel
#
# No Ubuntu binaries are required after disk overwrite.
# =========================================================

cat > "$STAGE2" <<'STAGE2_EOF'
#!/bin/ash

set -eu

BB="$WORK/busybox"

echo
echo "=========================================="
echo " RAM-only installation stage"
echo "=========================================="
echo

# =====================================================
# FLUSH ALL EXISTING WRITES
# =====================================================

echo "==> Flushing filesystem writes..."

"$BB" sync

echo s > /proc/sysrq-trigger

"$BB" sleep 2

# =====================================================
# REMOUNT FILESYSTEMS READ-ONLY
# =====================================================

echo "==> Switching filesystems to read-only..."

echo u > /proc/sysrq-trigger

"$BB" sleep 3

# =====================================================
# VERIFY ROOT REALLY BECAME READ-ONLY
# =====================================================

ROOT_OPTIONS="$(
    "$BB" awk '$2=="/" {print $4; exit}' /proc/mounts
)"

case ",$ROOT_OPTIONS," in

    *,ro,*)
        echo "==> Root filesystem: READ-ONLY"
        ;;

    *)
        echo
        echo "=========================================="
        echo "ERROR: ROOT FILESYSTEM IS STILL WRITABLE"
        echo "=========================================="
        echo
        echo "Installation stopped before disk overwrite."
        echo

        while :; do
            "$BB" sleep 3600
        done
        ;;

esac

# =====================================================
# WRITE CHR IMAGE
# =====================================================

echo
echo "==> Writing MikroTik CHR $VERSION to $DISK..."
echo

"$BB" dd \
    if="$IMG" \
    of="$DISK" \
    bs=4M

# =====================================================
# FLUSH CHR IMAGE TO PHYSICAL/VIRTUAL DISK
# =====================================================

echo
echo "==> Flushing CHR image to disk..."

"$BB" sync

"$BB" sleep 3

# =====================================================
# READ EXACT IMAGE SIZE BACK FROM DISK
# =====================================================

echo
echo "==> Verifying written disk..."
echo

COUNT=$(( (SIZE + 1048575) / 1048576 ))

READ_LINE="$(
    "$BB" dd \
        if="$DISK" \
        bs=1M \
        count="$COUNT" \
        2>/dev/null |
    "$BB" head \
        -c "$SIZE" |
    "$BB" sha256sum
)"

set -- $READ_LINE

READ_HASH="$1"

echo "Source SHA256 : $EXPECTED_HASH"
echo "Disk SHA256   : $READ_HASH"
echo

# =====================================================
# BIT-FOR-BIT VERIFICATION
# =====================================================

if [ "$READ_HASH" != "$EXPECTED_HASH" ]; then

    echo
    echo "=========================================="
    echo " DISK VERIFICATION FAILED"
    echo "=========================================="
    echo
    echo "DO NOT POWER OFF."
    echo "DO NOT REBOOT."
    echo
    echo "Written disk does not match CHR source."
    echo

    while :; do
        "$BB" sleep 3600
    done

fi

# =====================================================
# FINAL SYNC
# =====================================================

"$BB" sync

"$BB" sleep 2

# =====================================================
# SUCCESS
# =====================================================

echo
echo "=========================================="
echo " CHR $VERSION INSTALLED SUCCESSFULLY"
echo " Disk verification: OK"
echo "=========================================="
echo
echo "ما رفتیم بای 👋"
echo "Power off then power on"
echo

# =====================================================
# IMPORTANT:
#
# Never return to the overwritten Ubuntu environment.
# Keep the RAM shell alive until VPS is power-cycled.
# =====================================================

while :; do
    "$BB" sleep 3600
done

STAGE2_EOF

chmod 700 "$STAGE2"

# =========================================================
# EXPORT VARIABLES FOR RAM INSTALLER
# =========================================================

export \
    WORK \
    IMG \
    DISK \
    SIZE \
    EXPECTED_HASH \
    VERSION

# =========================================================
# START INSTALLATION AUTOMATICALLY
#
# FROM THIS POINT THERE IS NO CONFIRMATION.
# =========================================================

echo
echo "==> All checks passed."
echo "==> Starting MikroTik CHR installation automatically..."
echo

# Move cwd away from the disk that is about to disappear.
cd /dev/shm

# Permanently replace Bash with static BusyBox shell in RAM.
exec "$BB" ash "$STAGE2"
