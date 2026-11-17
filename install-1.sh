#!/bin/bash
#
# Artix Linux (dinit) + btrfs + snapper snapshots  --  stage 1
#
# Run as root from the Artix live ISO, booted in UEFI mode.
# It (optionally) partitions the disk, formats ESP + ROOT, creates btrfs
# subvolumes, installs a minimal system and then runs install-2.sh inside it.
#
# Layout: ESP (FAT32) + ROOT (btrfs). No separate HOME partition, no swap
# partition (swap is zram, set up in stage 2).

set -euo pipefail

# ---- Settings you may want to change ---------------------------------------
TIMEZONE="Europe/Warsaw"
LOCALE="en_US.UTF-8"
KEYMAP="pl"
BTRFS_OPTS="noatime,compress=zstd:3,discard=async"
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

confirm() {
    local reply
    read -rp "$1 [y/N]: " reply
    [[ $reply == [yY] ]]
}

ask_block_device() {
    local prompt="$1" var="$2" value
    while true; do
        read -rp "$prompt" value
        if [[ -b $value ]]; then
            printf -v "$var" '%s' "$value"
            return
        fi
        echo "'$value' is not a block device. Try again (e.g. /dev/nvme0n1p1)."
    done
}

ask_matching() {
    local prompt="$1" var="$2" regex="$3" hint="$4" value
    while true; do
        read -rp "$prompt" value
        if [[ $value =~ $regex ]]; then
            printf -v "$var" '%s' "$value"
            return
        fi
        echo "$hint"
    done
}

# Is 'k' a console keymap installed on the live system? (e.g. pl, us, de)
keymap_exists() {
    local k=$1
    if [[ ! -d /usr/share/kbd/keymaps ]]; then
        warn "Keymap database (/usr/share/kbd/keymaps) not found, accepting '$k' without verification."
        return 0
    fi
    # newer kbd: /usr/share/kbd/keymaps/xkb/pl.map.gz; older: /usr/share/kbd/keymaps/i386/qwerty/pl.map.gz
    # (compgen -G prints the matched path, so send it to /dev/null)
    compgen -G "/usr/share/kbd/keymaps/xkb/$k.map.gz"    >/dev/null && return 0
    compgen -G "/usr/share/kbd/keymaps/xkb/$k.map"       >/dev/null && return 0
    compgen -G "/usr/share/kbd/keymaps/*/*/$k.map.gz"    >/dev/null && return 0
    compgen -G "/usr/share/kbd/keymaps/*/*/$k.map"       >/dev/null && return 0
    return 1
}

# Is 'l' a locale present in /etc/locale.gen? (e.g. en_US.UTF-8)
locale_exists() {
    local l=$1
    grep -qE "^#?${l//./\\.} UTF-8$" /etc/locale.gen 2>/dev/null
}

ask_password() {
    local prompt="$1" var="$2" p1 p2
    while true; do
        read -rsp "$prompt: " p1; echo
        read -rsp "Repeat $prompt: " p2; echo
        if [[ -n $p1 && $p1 == "$p2" ]]; then
            printf -v "$var" '%s' "$p1"
            return
        fi
        echo "Empty or not matching, try again."
    done
}

# ---- Sanity checks -----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Run this script as root."
    exec sudo bash "$0" "$@"
fi
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode (this script needs UEFI)."
[[ -f $SCRIPT_DIR/install-2.sh ]] || die "install-2.sh must be in the same directory as this script."
[[ -f $SCRIPT_DIR/blitz ]] || die "blitz must be in the same directory as this script."

# Offline-capable ISO? (BlitzArt ISO: the complete system is inside, the
# installer can copy it to disk without downloading anything.)
OFFLINE_ISO=n
[[ -f /etc/blitzart-iso ]] && OFFLINE_ISO=y

if ! curl -sI --max-time 8 https://artixlinux.org >/dev/null 2>&1; then
    if [[ $OFFLINE_ISO == y ]]; then
        warn "No internet connection -- only the OFFLINE install mode will work."
    else
        die "No internet connection."
    fi
fi

# ---- Optional: wipe the target disk before partitioning --------------------------------------------
if confirm "Wipe the target disk first (blkdiscard -fv, erases the partition table and all data)?"; then
    ask_block_device "Disk to wipe (the WHOLE disk, e.g. /dev/nvme0n1): " wipe_disk
    echo "ALL data on $wipe_disk will be ERASED."
    read -rp "Type YES to wipe it: " answer
    if [[ $answer == YES ]]; then
        if blkdiscard -fv "$wipe_disk"; then
            echo "Disk $wipe_disk wiped."
        else
            warn "blkdiscard failed on $wipe_disk (the device may not support discard), continuing."
        fi
    else
        echo "Skipped, the disk was not wiped."
    fi
fi

# ---- Optional: remove leftover UEFI boot entries -----------------------------------------------------
if confirm "Remove UEFI boot entries with efibootmgr? (leftovers from previous installs)"; then
    efibootmgr || die "efibootmgr failed (no EFI variables accessible)."
    read -rp "Boot numbers to remove, space separated (e.g. 0001 0003, empty = skip): " -a boot_nums
    for n in ${boot_nums[@]:-}; do
        if [[ $n =~ ^[0-9a-fA-F]{4}$ ]]; then
            efibootmgr -b "$n" -B || warn "Could not remove Boot$n."
        else
            warn "'$n' is not a BootXXXX number, skipping."
        fi
    done
fi

# Clean up leftovers from a previous attempt
swapoff -a 2>/dev/null || true
if mountpoint -q /mnt; then umount -R /mnt; fi

# ---- Partitioning --------------------------------------------------------------
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS

if confirm "Partition a disk with cfdisk?"; then
    echo "Create a GPT table with two partitions:"
    echo "  1) ~1G   type 'EFI System'"
    echo "  2) rest  type 'Linux filesystem'"
    read -rp "Disk (e.g. /dev/nvme0n1): " disk
    [[ -b $disk ]] || die "'$disk' is not a block device."
    cfdisk "$disk"
    partprobe "$disk" 2>/dev/null || true
    udevadm settle
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PATH
fi

ask_block_device "ESP partition  (e.g. /dev/nvme0n1p1): " esp
ask_block_device "ROOT partition (e.g. /dev/nvme0n1p2): " root
[[ $esp != "$root" ]] || die "ESP and ROOT must be different partitions."

format_esp=n
if confirm "Format ESP as FAT32? (answer N only to reuse an ESP with another OS)"; then
    format_esp=y
fi

echo
echo "ROOT ($root) will be completely ERASED and formatted as btrfs."
read -rp "Type YES to continue: " answer
[[ $answer == YES ]] || die "Aborted."

# ---- System settings -------------------------------------------------------------
ask_password "Root password" root_password
ask_matching "Username: " username '^[a-z_][a-z0-9_-]{0,31}$' \
    "Use lowercase letters, digits, '_' or '-', starting with a letter."
ask_password "Password for $username" user_password
ask_matching "Hostname: " hostname_ '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$' \
    "Use letters, digits and '-'."

# ---- Keyboard layout (validated against the installed keymaps) ---------------------
while true; do
    read -rp "Keyboard layout [$KEYMAP] (examples: pl, us, de, fr): " km || break
    [[ -z $km ]] && { echo "Keeping $KEYMAP."; break; }
    if keymap_exists "$km"; then
        KEYMAP="$km"
        break
    fi
    echo "'$km' is not an available keymap. Type one of these (exact strings):"
    find /usr/share/kbd/keymaps/xkb /usr/share/kbd/keymaps/i386 -name '*.map.gz' 2>/dev/null \
        | awk -F/ '{n=$NF; sub(/\.map\.gz$/, "", n); print n}' | sort -u \
        | awk 'NR<=15 {printf "%s ", $0} END {print ""}' || true
done

# ---- System language (validated against /etc/locale.gen) ---------------------------
while true; do
    read -rp "System locale [$LOCALE] (examples: en_US.UTF-8, pl_PL.UTF-8, de_DE.UTF-8): " loc || break
    [[ -z $loc ]] && { echo "Keeping $LOCALE."; break; }
    # 'pl_PL' is accepted as 'pl_PL.UTF-8' when that entry exists
    if [[ $loc != *.* ]]; then
        grep -qE "^#?${loc//./\\.}\.UTF-8 UTF-8$" /etc/locale.gen 2>/dev/null && loc="$loc.UTF-8"
    fi
    if locale_exists "$loc"; then
        LOCALE="$loc"
        break
    fi
    echo "'$loc' is not an available locale. Type one of these (exact strings):"
    grep -E '^#?[a-z]{2,3}_[A-Z]{2,3}\.' /etc/locale.gen 2>/dev/null \
        | awk '{n=$1; sub(/^#/, "", n); print n}' | sort -u \
        | awk 'NR<=15 {printf "%s ", $0} END {print ""}' || true
done

install_nvidia=n
if confirm "Install NVIDIA drivers? (open kernel modules: GTX 16xx / RTX or newer only)"; then
    install_nvidia=y
fi

# ---- Install source -------------------------------------------------------------
# One flow, no online/offline choice:
#   - booted from a BlitzArt ISO -> the complete system is copied from the ISO
#     (offline; packages as of the build date), then configured;
#   - booted from a plain Artix ISO -> basestrap downloads the base system
#     (needs internet), then configured the same way.
# Everything that requires internet (extra repos, updates, dotfiles, hyprpm
# plugins) happens in stage 2 only when a network is actually available.
install_mode=online
if [[ $OFFLINE_ISO == y ]]; then
    install_mode=offline
    echo "BlitzArt ISO detected: the complete system will be copied from this media (no downloads)."
fi
if [[ $install_nvidia == y && $install_mode == offline ]]; then
    echo
    echo "NOTE: NVIDIA drivers are NOT on the ISO. They will not be installed now;"
    echo "      later, online, run:  sudo pacman -S linux-headers nvidia-open-dkms nvidia-utils"
fi

# ---- Package lists (online mode only -- offline copies the baked system) ----------
if [[ $install_mode == online ]]; then
sed -i -E \
    -e 's/^#(Color)/\1/' \
    -e 's/^#?ParallelDownloads.*/ParallelDownloads = 8/' \
    /etc/pacman.conf

pacman -Sy --noconfirm artix-keyring || warn "Could not refresh artix-keyring."

REQUIRED_PKGS=(
    base dinit elogind-dinit linux linux-firmware btrfs-progs
    grub efibootmgr sudo nano
    networkmanager networkmanager-dinit wpa_supplicant
    snapper cronie cronie-dinit ntp ntp-dinit
)
OPTIONAL_PKGS=(grub-btrfs dbus-dinit)
grep -q GenuineIntel /proc/cpuinfo && OPTIONAL_PKGS+=(intel-ucode)
grep -q AuthenticAMD /proc/cpuinfo && OPTIONAL_PKGS+=(amd-ucode)

missing=()
for p in "${REQUIRED_PKGS[@]}"; do
    pacman -Si "$p" &>/dev/null || missing+=("$p")
done
((${#missing[@]} == 0)) || die "Required packages not found in repositories: ${missing[*]}"

PKGS=("${REQUIRED_PKGS[@]}")
for p in "${OPTIONAL_PKGS[@]}"; do
    if pacman -Si "$p" &>/dev/null; then
        PKGS+=("$p")
    else
        warn "Optional package '$p' not found, skipping."
    fi
done

if [[ $install_nvidia == y ]]; then
    nvidia_pkgs=(linux-headers nvidia-open-dkms nvidia-utils)
    nvidia_ok=y
    for p in "${nvidia_pkgs[@]}"; do
        pacman -Si "$p" &>/dev/null || { warn "NVIDIA package '$p' not found."; nvidia_ok=n; }
    done
    if [[ $nvidia_ok == y ]]; then
        PKGS+=("${nvidia_pkgs[@]}")
    else
        warn "Skipping NVIDIA drivers. You can install them later."
        install_nvidia=n
    fi
fi
fi  # online mode

# ---- Format ----------------------------------------------------------------------
if [[ $format_esp == y ]]; then
    mkfs.fat -F 32 "$esp"
    fatlabel "$esp" ESP
fi
mkfs.btrfs -f -L ROOT "$root"

# ---- Subvolumes and mounting -----------------------------------------------------
mount "$root" /mnt
for sv in @ @home @snapshots @var_log @var_cache; do
    btrfs subvolume create "/mnt/$sv"
done
umount /mnt

mount -o "$BTRFS_OPTS,subvol=@" "$root" /mnt
declare -A SUBVOL_MOUNTS=(
    [@home]=/home
    [@snapshots]=/.snapshots
    [@var_log]=/var/log
    [@var_cache]=/var/cache
)
for sv in "${!SUBVOL_MOUNTS[@]}"; do
    mount --mkdir -o "$BTRFS_OPTS,subvol=$sv" "$root" "/mnt${SUBVOL_MOUNTS[$sv]}"
done
mount --mkdir "$esp" /mnt/boot/efi

# ---- Install base system -----------------------------------------------------------
if [[ $install_mode == offline ]]; then
    # OFFLINE install: the ISO rootfs IS a complete BlitzArt system. Copy it
    # onto the target (same technique as Artix's offline "unpack" install),
    # then strip the live-session bits. No package is downloaded.
    echo "==> Copying the system from this ISO to $root (this takes a few minutes)..."
    rsync -aAXH --numeric-ids -x \
        --exclude=/mnt \
        --exclude=/home \
        --exclude=/var/log \
        --exclude=/var/cache \
        --exclude=/tmp \
        / /mnt/
    # make sure essential top-level dirs exist on the target
    mkdir -p /mnt/proc /mnt/sys /mnt/dev /mnt/run /mnt/tmp
    chmod 1777 /mnt/tmp

    # Strip everything that belongs to the LIVE session only
    cat > /mnt/root/blitzart-offline-cleanup.sh << 'CLEANUP_EOF'
#!/bin/bash
# Strips live-session artifacts from the copied system (runs in chroot).
set -u
LIVEUSER=""
[[ -f /etc/artools/live.conf ]] && . /etc/artools/live.conf
pacman -R --noconfirm artix-live-dinit &>/dev/null || true
pacman -R --noconfirm artix-grub-live &>/dev/null || true
[[ -n $LIVEUSER ]] && userdel "$LIVEUSER" &>/dev/null || true
rm -f /etc/artools/live.conf /etc/blitzart-iso
# remove symlinks left dangling by the removals
find /etc/dinit.d/boot.d -maxdepth 1 -xtype l -delete 2>/dev/null || true
: > /etc/machine-id
rm -rf /home/* 2>/dev/null || true
exit 0
CLEANUP_EOF
    artix-chroot /mnt /bin/bash /root/blitzart-offline-cleanup.sh
    rm -f /mnt/root/blitzart-offline-cleanup.sh
else
    basestrap /mnt "${PKGS[@]}"
fi

fstabgen -U /mnt > /mnt/etc/fstab
# A fixed subvolid in fstab breaks rollbacks, keep only subvol=
sed -i -E 's/subvolid=[0-9]+,//' /mnt/etc/fstab

# ---- Hand over to stage 2 ----------------------------------------------------------
mkdir -p /mnt/install
chmod 700 /mnt/install
trap 'rm -rf /mnt/install' EXIT

cp "$SCRIPT_DIR/install-2.sh" /mnt/install/install-2.sh
cp "$SCRIPT_DIR/install-1.sh" /mnt/install/install-1.sh
cp "$SCRIPT_DIR/blitz" /mnt/install/blitz
if [[ -f $SCRIPT_DIR/blitzinstall ]]; then
    cp "$SCRIPT_DIR/blitzinstall" /mnt/install/blitzinstall
fi
if [[ -f $SCRIPT_DIR/install-dotfiles.sh ]]; then
    cp "$SCRIPT_DIR/install-dotfiles.sh" /mnt/install/install-dotfiles.sh
fi
chmod +x /mnt/install/install-2.sh

(
    umask 077
    {
        printf 'export ARTIX_%s=%q\n' TIMEZONE "$TIMEZONE"
        printf 'export ARTIX_%s=%q\n' LOCALE "$LOCALE"
        printf 'export ARTIX_%s=%q\n' KEYMAP "$KEYMAP"
        printf 'export ARTIX_%s=%q\n' HOSTNAME "$hostname_"
        printf 'export ARTIX_%s=%q\n' USERNAME "$username"
        printf 'export ARTIX_%s=%q\n' ROOT_PASSWORD "$root_password"
        printf 'export ARTIX_%s=%q\n' USER_PASSWORD "$user_password"
        printf 'export ARTIX_%s=%q\n' NVIDIA "$install_nvidia"
    } > /mnt/install/env.sh
)

artix-chroot /mnt /bin/bash /install/install-2.sh

rm -rf /mnt/install
trap - EXIT

umount -R /mnt
echo
echo "Installation finished."
if confirm "Reboot now? (remove the installation USB when the screen goes black)"; then
    reboot
fi
