#!/bin/bash
#
# make-iso.sh -- build the BlitzArt Linux live ISO with artools (buildiso).
#
# What it does:
#   1. installs the BlitzArt artools config into ~/.config/artools
#      (INITSYS=dinit, Arch [extra]/[multilib] enabled for the build chroots)
#   2. copies iso-profile/ into ~/artools-workspace/iso-profiles/
#      (that is where buildiso looks for profiles; overlays are dereferenced
#      there, so the installer scripts land on the ISO as real files)
#   3. smoke-tests the profile (buildiso -q, no root needed)
#   4. runs: sudo buildiso -p blitz -i dinit -w
#
# Result: ~/artools-workspace/iso/blitz/artix-blitz-dinit-<date>-x86_64.iso
#
# Usage:  ./make-iso.sh [--no-sync] [extra buildiso args...]
#         --no-sync  skip config/profile staging (build only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---- host sanity -----------------------------------------------------------------
grep -q 'artix' /etc/os-release 2>/dev/null \
    || die "This must run on an Artix host (artools + basestrap are Artix tools)."

command -v buildiso >/dev/null 2>&1 || die "buildiso not found. Install the 'artools-iso' package (pacman -S artools-iso)."
command -v yq       >/dev/null 2>&1 || die "yq not found. Install the 'go-yq' package (a artools-iso dependency)."

# Real (non-root) user home; buildiso runs as root but keeps USER_HOME.
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -n $REAL_HOME ]] || die "Could not resolve home of user '$REAL_USER'."

USER_CONF="$REAL_HOME/.config/artools"
WORKSPACE="$REAL_HOME/artools-workspace"
PROFILE_NAME="blitz"

# ---- stage configs + profile ------------------------------------------------------
sync_stage() {
    echo "==> Installing artools user config into $USER_CONF"
    mkdir -p "$USER_CONF/pacman.conf.d"
    install -m 644 "$SCRIPT_DIR/iso/artools-iso.conf"              "$USER_CONF/artools-iso.conf"
    install -m 644 "$SCRIPT_DIR/iso/pacman.conf.d/iso-x86_64.conf" "$USER_CONF/pacman.conf.d/iso-x86_64.conf"

    echo "==> Staging profile into $WORKSPACE/iso-profiles"
    mkdir -p "$WORKSPACE/iso-profiles"
    # copy (dereferencing symlinks), then fix exec bits on the copied scripts
    cp -rL "$SCRIPT_DIR/iso-profile/." "$WORKSPACE/iso-profiles/"
    chmod +x "$WORKSPACE/iso-profiles/$PROFILE_NAME/root-overlay/root/blitz-install/"* \
             "$WORKSPACE/iso-profiles/$PROFILE_NAME/root-overlay/usr/local/bin/blitz" \
             "$WORKSPACE/iso-profiles/$PROFILE_NAME/root-overlay/usr/local/bin/blitzinstall" 2>/dev/null || true
    # keep ownership sane so buildiso (running as root) can read everything
    chown -R "$(id -u "$REAL_USER"):$(id -g "$REAL_USER")" "$USER_CONF" "$WORKSPACE/iso-profiles"
}

no_sync=0
args=()
for a in "$@"; do
    case $a in --no-sync) no_sync=1 ;; *) args+=("$a") ;; esac
done
(( no_sync )) || sync_stage

# ---- smoke test (no root required) -------------------------------------------------
echo "==> Checking profile (buildiso -q)"
buildiso -p "$PROFILE_NAME" -i dinit -q || die "Profile check failed -- fix profile.yaml before building."

# ---- build -------------------------------------------------------------------------
echo
echo "==> Building the ISO (needs root; downloads packages on first run)"
echo "    Output: $WORKSPACE/iso/$PROFILE_NAME/"
sudo buildiso -p "$PROFILE_NAME" -i dinit -w "${args[@]+"${args[@]}"}"

echo
echo "Done. ISO should be in $WORKSPACE/iso/$PROFILE_NAME/"
echo "Test it:  sudo qemu-system-x86_64 -enable-kvm -m 4G -smp 4 \\"
echo "            -drive file=<iso>,format=raw,if=virtio -nic user,model=virtio-net-pci"
