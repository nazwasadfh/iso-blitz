#!/bin/bash
#
# install-dotfiles.sh -- installs the nazwasadfh/dots dotfiles on Arch/Artix
#
# Usage: install-dotfiles.sh [--user NAME] [--no-ii] [-h]
#   --user NAME   user who gets the dotfiles (default: the user who ran sudo)
#   --no-ii       skip the end-4 (illogical-impulse) installer
#   -h, --help    show this help
#
# Runs as root (re-executes itself with sudo otherwise). Packages are installed
# as root, but every file in the home directory is created by the target user,
# never by root. Existing files are moved to <name>.bak-<date>, never deleted.
# Safe to run again: unchanged files are skipped.

set -euo pipefail

DOTS_REPO="https://github.com/nazwasadfh/dots"
II_REPO="https://github.com/end-4/dots-hyprland"
LAZYVIM_REPO="https://github.com/LazyVim/starter"
QS_FORK_REPO="https://github.com/pctrade/end4-pC.git"
PACKAGES=(git curl neovim kitty fastfetch starship zsh easyeffects zip unzip ttf-victor-mono-nerd)

msg()  { printf '\n==> %s\n' "$*"; }
info() { printf '  -> %s\n' "$*"; }
warn() { printf '==> WARNING: %s\n' "$*" >&2; }
die()  { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }

confirm() {
    local reply
    read -rp "$1 [y/N]: " reply
    [[ $reply == [yY] ]]
}

# ---- Arguments ------------------------------------------------------------------
target_user=""
run_ii=1
args=("$@")
while (($#)); do
    case "$1" in
        --user)
            [[ $# -ge 2 ]] || die "--user needs a value."
            target_user="$2"; shift 2 ;;
        --no-ii)   run_ii=0; shift ;;
        -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "Unknown option: $1 (use --help)" ;;
    esac
done

# ---- Root / target user -----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Run as root or install sudo."
    exec sudo "$0" "${args[@]}"
fi

user="${target_user:-${SUDO_USER:-}}"
[[ -n $user && $user != root ]] || die "Pass the target user with --user NAME (not root)."
getent passwd "$user" >/dev/null || die "User '$user' does not exist."
home="$(getent passwd "$user" | cut -d: -f6)"
[[ -d $home ]] || die "Home directory '$home' of '$user' does not exist."

cd /
stamp="$(date +%Y%m%d-%H%M%S)"

# Run a command as the target user, with a correct environment
as_user() {
    runuser -u "$user" -- env HOME="$home" USER="$user" LOGNAME="$user" "$@"
}

# copy_item <path inside the dots repo> <destination relative to $HOME>
copy_item() {
    local src="$gitdir/$1" dest="$home/$2"
    if [[ ! -e $src ]]; then
        warn "'$1' not found in the dots repository, skipping."
        return 0
    fi
    if [[ -e $dest ]] && as_user diff -rq "$src" "$dest" >/dev/null 2>&1; then
        info "~/$2 is already up to date"
        return 0
    fi
    as_user mkdir -p "$(dirname "$dest")"
    if [[ -e $dest || -L $dest ]]; then
        as_user mv "$dest" "$dest.bak-$stamp"
        info "backed up ~/$2 -> ~/$2.bak-$stamp"
    fi
    as_user cp -a "$src" "$dest"
    info "installed ~/$2"
}

# ---- Packages -----------------------------------------------------------------------
msg "Installing packages"
to_install=()
for p in "${PACKAGES[@]}"; do
    if pacman -Si "$p" >/dev/null 2>&1; then
        to_install+=("$p")
    else
        warn "Package '$p' not found in the repositories, skipping."
    fi
done
((${#to_install[@]})) && pacman -S --needed --noconfirm "${to_install[@]}"

# ---- end-4 (illogical-impulse) installer ----------------------------------------------
II_CACHE="$home/.cache/dots-hyprland"                    # where the official installer clones too
II_SETUPS="$II_CACHE/sdata/subcmd-install/2.setups.sh"   # its dinit service-enabling script
II_ORIG=""

# The online installer (ii.clsty.link/get) clones the repo and immediately runs
# './setup install' - no way to patch between the two. So the clone is made here
# (to the same path), the service script is patched in place and setup is run directly.
#
# The chroot has no running dinit, so the dinitctl calls in the end-4 service script
# (2.setups.sh) get --offline added in place; no --services-dir is needed - dinitctl
# already looks in /etc/dinit.d for system services and in $HOME/.config/dinit.d
# for the user's own services (pipewire, wireplumber, pipewire-pulse).
ii_patch() {
    [[ -f $II_SETUPS ]] || return 0
    as_user cp -p "$II_SETUPS" "$II_SETUPS.blitz-orig" || return 0
    II_ORIG="$II_SETUPS.blitz-orig"
    as_user sed -i \
        -e 's|sudo dinitctl enable|sudo dinitctl --offline enable|g' \
        -e 's|dinitctl --user enable|dinitctl --offline --user enable|g' \
        "$II_SETUPS"
    info "Patched $(basename "$II_SETUPS"): dinitctl calls got --offline"
}

ii_restore() {
    if [[ -n $II_ORIG ]]; then
        as_user mv -f "$II_ORIG" "$II_SETUPS" 2>/dev/null || true
        II_ORIG=""
    fi
}

if ((run_ii)); then
    msg "Running the end-4 (illogical-impulse) installer as $user"
    if [[ ! -d $II_CACHE/.git ]]; then
        as_user git clone --recursive --shallow-submodules --depth 1 "$II_REPO" "$II_CACHE" \
            || die "Could not download $II_REPO."
    else
        as_user git -C "$II_CACHE" pull --ff-only origin main >/dev/null 2>&1 \
            || info "Could not update the existing dots-hyprland clone, using it as is."
    fi
    [[ -x $II_CACHE/setup ]] || die "The dots-hyprland clone has no ./setup."
    ii_patch
    if ! as_user "$II_CACHE/setup" install; then
        ii_restore
        confirm "The end-4 installer failed. Continue with the dotfiles anyway?" || die "Aborted."
    fi
    ii_restore
fi

# ---- Dotfiles ----------------------------------------------------------------------------
msg "Fetching dotfiles"
gitdir="$(as_user mktemp -d)"
trap 'rm -rf "$gitdir"; ii_restore' EXIT
as_user git clone --depth 1 "$DOTS_REPO" "$gitdir"

msg "Installing configuration for $user ($home)"
copy_item starship.toml                  .config/starship.toml
copy_item face.jpg                       face.jpg
copy_item hypr                           .config/hypr
copy_item fastfetch                      .config/fastfetch
copy_item kitty                          .config/kitty
copy_item .zshrc                         .zshrc
copy_item superduper.json                .local/share/easyeffects/output/superduper.json
copy_item img_0946.jpg                   Photos/wall.jpg

# ---- LazyVim ---------------------------------------------------------------------------------
msg "Neovim (LazyVim starter)"
nvim_dir="$home/.config/nvim"
if [[ -e $nvim_dir ]]; then
    info "~/.config/nvim already exists, leaving it alone."
else
    as_user git clone --depth 1 "$LAZYVIM_REPO" "$nvim_dir"
    as_user rm -rf "$nvim_dir/.git"
    info "installed ~/.config/nvim"
fi

# ---- Quickshell fork --------------------------------------------------------------------------
msg "Quickshell config (end4-pC)"
qs_dir="$home/.config/quickshell/end4-pC"
if [[ -e $qs_dir ]]; then
    info "~/.config/quickshell/end4-pC already exists, leaving it alone."
else
    as_user mkdir -p "$home/.config/quickshell"
    as_user git clone --depth 1 "$QS_FORK_REPO" "$qs_dir"
    info "installed ~/.config/quickshell/end4-pC"
fi

msg "Dotfiles installed for $user"
info "Replaced files were backed up as *.bak-$stamp"
info "Your shell is still bash. To use the .zshrc: chsh -s /usr/bin/zsh $user"
