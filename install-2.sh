#!/bin/bash
#
# Artix Linux (dinit) + btrfs + snapper snapshots  --  stage 2
#
# Started by install-1.sh inside the new system (artix-chroot).
# Do not run it by hand on the live ISO.

set -euo pipefail
umask 022   # config files must stay readable (os-release, hooks, cron.d ...)

# shellcheck source=/dev/null
source /install/env.sh

log() { echo; echo "==> $*"; }

# ---- Network availability ----------------------------------------------------------
# The offline install copies a complete system from the ISO; everything that
# would download (repos, dotfiles, hyprpm plugins) is skipped without network.
NET_OK=n
if curl -sI --max-time 6 https://artixlinux.org >/dev/null 2>&1; then
    NET_OK=y
else
    echo "==> No internet: offline install. Packages already on the ISO are configured;"
    echo "    Chaotic-AUR/BlackArch, dotfiles and hyprpm plugins are skipped (add later, online)."
fi

# ensure_pkg <pkg> [<pkg>...]: install only what is missing, never online when
# offline. In the copied ISO system nearly everything is already installed.
ensure_pkg() {
    local p
    for p in "$@"; do
        pacman -Qi "$p" &>/dev/null && continue
        if [[ $NET_OK == y ]]; then
            pacman -S --noconfirm --needed "$p" \
                || echo "WARNING: could not install $p." >&2
        else
            echo "WARNING: offline and '$p' is not on the ISO, skipping (install online later)." >&2
        fi
    done
}

# ---- Question: dotfiles (only online -- the end-4 installer clones from git) -------
install_dotfiles=n
if [[ $NET_OK == y && -f /install/install-dotfiles.sh ]]; then
    read -rp "Install dotfiles? (y/N): " dotfiles_answer
    if [[ $dotfiles_answer == [yY] ]]; then
        install_dotfiles=y
    fi
elif [[ $NET_OK != y && -f /install/install-dotfiles.sh ]]; then
    echo "Dotfiles need internet -- skipped. Later, online, run: sudo install-dotfiles --user <name>"
fi

# Services that could not be enabled with dinitctl. dinit is not running inside the
# chroot, so only "dinitctl --offline enable" works here; starting happens at boot.
PENDING=()

# enable_service NAME [--user]
# Everything runs with --offline (dinit is not running inside the chroot). dinitctl
# finds the services in its default directories: /etc/dinit.d for system services
# and the user's ~/.config/dinit.d for user services.
enable_service() {
    local svc="$1" user=0 sdir=/etc/dinit.d
    [[ ${2:-} == --user ]] && user=1

    if (( user )); then
        # Run as the user, so that 'dinitctl --user' looks in the right $HOME
        local uhome; uhome="$(getent passwd "$ARTIX_USERNAME" | cut -d: -f6)"
        sdir="$uhome/.config/dinit.d"
        if runuser -u "$ARTIX_USERNAME" -- env HOME="$uhome" dinitctl --offline --user enable "$svc"; then
            return 0
        fi
        echo "WARNING: 'dinitctl --offline --user enable $svc' failed." >&2
    else
        if dinitctl --offline enable "$svc"; then
            return 0
        fi
        echo "WARNING: 'dinitctl --offline enable $svc' failed." >&2
    fi

    # Fallback: the same boot.d link that dinitctl would create
    if [[ -e $sdir/$svc ]]; then
        mkdir -p "$sdir/boot.d"
        ln -sf "../$svc" "$sdir/boot.d/$svc"
        (( user )) && chown -R "$ARTIX_USERNAME:$(id -gn "$ARTIX_USERNAME")" "$sdir"
    fi
    # Either way, check this service again at the first login
    PENDING+=("$svc")
}

# ---- Pacman ------------------------------------------------------------------
log "Pacman"
sed -i -E \
    -e 's/^#(Color)/\1/' \
    -e 's/^#?ParallelDownloads.*/ParallelDownloads = 8/' \
    /etc/pacman.conf

# ILoveCandy goes into the [options] section
if ! grep -q '^ILoveCandy' /etc/pacman.conf; then
    sed -i '/^\[options\]/a ILoveCandy' /etc/pacman.conf
fi

# Arch repositories (extra, multilib) + their GPG keys
ensure_pkg artix-archlinux-support
pacman-key --populate archlinux

if ! grep -q '^\[extra\]' /etc/pacman.conf; then
    cat >> /etc/pacman.conf << 'EOF'

#arch!
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch
EOF
fi

if [[ $NET_OK == y ]]; then
    pacman -Sy
fi

# grub-btrfs may only exist in the Arch repos: retry it now if stage 1 skipped it
if ! pacman -Qi grub-btrfs &>/dev/null && [[ $NET_OK == y ]] \
    && pacman -Si grub-btrfs &>/dev/null; then
    pacman -S --noconfirm --needed grub-btrfs
fi

# ---- zsh and its plugins (from the Arch [extra] repo) -----------------------------------------
log "zsh"
ensure_pkg zsh zsh-autosuggestions zsh-completions zsh-syntax-highlighting \
    zsh-history-substring-search fzf

# ---- Extra tools ------------------------------------------------------------------------------
log "Extra tools"
ensure_pkg ugrep bat curl wget

# ---- Hyprland + hyprpm (the plugin manager is its own package) ----------------------------------
log "Hyprland and hyprpm"
ensure_pkg hyprpm

# hyprpm compiles the plugins from source during 'hyprpm update', so a toolchain is needed
# (cmake, meson and cpio come in as dependencies of the hyprpm package itself)
ensure_pkg base-devel git

# ---- Third-party repositories: Chaotic-AUR, BlackArch (after the Arch repos) -------------------
log "Third-party repositories"

# add_repo <name> <config line>: appends the repo to pacman.conf and syncs it;
# if the sync fails the repo is removed again so that pacman keeps working.
add_repo() {
    local name="$1" line="$2"
    grep -q "^\[$name\]" /etc/pacman.conf && return 0
    printf '\n[%s]\n%s\n' "$name" "$line" >> /etc/pacman.conf
    if ! pacman -Sy; then
        echo "WARNING: could not sync [$name], removing it from pacman.conf." >&2
        sed -i "/^\[$name\]/,\$d" /etc/pacman.conf
        pacman -Sy || true
        return 1
    fi
}

if [[ $NET_OK != y ]]; then
    echo "No internet: Chaotic-AUR and BlackArch are not set up now."
    echo "Run later (online): see /etc/blitzart/README-repos"
    mkdir -p /etc/blitzart
    cat > /etc/blitzart/README-repos << 'EOF'
Chaotic-AUR and BlackArch were not configured during the (offline) install.
To add them later, online, either run the relevant section of install-2.sh
manually or follow:
  https://aur.chaotic.cx  (Chaotic-AUR)
  https://blackarch.org/downloads.html  (BlackArch, strap.sh)
EOF
    chmod 644 /etc/blitzart/README-repos
else

KEYSERVER=keyserver.ubuntu.com

# Chaotic-AUR (placed before BlackArch, as its documentation recommends)
CHAOTIC_KEY=3056513887B78AEB
if pacman-key --recv-keys "$CHAOTIC_KEY" --keyserver "$KEYSERVER" \
    && pacman-key --lsign-key "$CHAOTIC_KEY" \
    && pacman -U --noconfirm \
        https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst \
        https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst; then
    add_repo chaotic-aur 'Include = /etc/pacman.d/chaotic-mirrorlist' || true
else
    echo "WARNING: could not set up Chaotic-AUR (keys or packages), skipping it." >&2
fi

# BlackArch (installed the official way: strap.sh adds the keyring, the mirrorlist
# and the [blackarch] section to pacman.conf by itself)
strap="$(mktemp)"
if curl -fL -o "$strap" https://blackarch.org/strap.sh && chmod 755 "$strap"; then
    "$strap" || echo "WARNING: strap.sh failed, BlackArch may be missing." >&2
else
    echo "WARNING: could not download https://blackarch.org/strap.sh, skipping BlackArch." >&2
fi
rm -f "$strap"

fi  # NET_OK (third-party repositories)

# ---- Time, locale, keyboard ----------------------------------------------------
log "Time, locale and keyboard"
[[ -f /usr/share/zoneinfo/$ARTIX_TIMEZONE ]] || { echo "Unknown timezone $ARTIX_TIMEZONE" >&2; exit 1; }
ln -sf "/usr/share/zoneinfo/$ARTIX_TIMEZONE" /etc/localtime
hwclock --systohc || echo "WARNING: hwclock --systohc failed (ignored)." >&2

sed -i "s/^#\(${ARTIX_LOCALE} UTF-8\)/\1/" /etc/locale.gen
locale-gen
echo "LANG=$ARTIX_LOCALE" > /etc/locale.conf
echo "KEYMAP=$ARTIX_KEYMAP" > /etc/vconsole.conf

# ---- Hostname --------------------------------------------------------------------
log "Hostname"
echo "$ARTIX_HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $ARTIX_HOSTNAME.localdomain $ARTIX_HOSTNAME
EOF

# ---- Branding: BlitzArt Linux -----------------------------------------------------------
# ID stays "artix" on purpose (tools such as blitz rely on it);
# ID_LIKE=arch is what Arch-oriented installers look for.
log "Branding"
if [[ -L /etc/os-release ]]; then
    # /etc/os-release points into a package-owned file; use a real copy so the changes stay
    cp --remove-destination "$(readlink -f /etc/os-release)" /etc/os-release
fi

set_os_release() {
    local key="$1" value="$2"
    if grep -q "^${key}=" /etc/os-release; then
        sed -i "s|^${key}=.*|${key}=${value}|" /etc/os-release
    else
        sed -i "\$a ${key}=${value}" /etc/os-release
    fi
}
set_os_release NAME '"BlitzArt Linux"'
set_os_release PRETTY_NAME '"BlitzArt Linux"'
set_os_release ID_LIKE arch
set_os_release LOGO artix3
chmod 644 /etc/os-release

printf 'BlitzArt Linux (based on Artix Linux) \\r (\\l)\n\n' > /etc/issue
printf '\nBlitzArt Linux (based on Artix Linux)\n\n' > /etc/motd
chmod 644 /etc/issue /etc/motd

if grep -q '^GRUB_DISTRIBUTOR=' /etc/default/grub; then
    sed -i 's|^GRUB_DISTRIBUTOR=.*|GRUB_DISTRIBUTOR="BlitzArt"|' /etc/default/grub
else
    echo 'GRUB_DISTRIBUTOR="BlitzArt"' >> /etc/default/grub
fi

# ---- Users -----------------------------------------------------------------------
log "Users"
echo "root:$ARTIX_ROOT_PASSWORD" | chpasswd
# zsh is the default shell for the new user (and for users added later); root keeps bash
login_shell=/bin/bash
if [[ -x /usr/bin/zsh ]]; then
    login_shell=/usr/bin/zsh
    useradd -D -s /usr/bin/zsh
fi
useradd -m -G wheel -s "$login_shell" "$ARTIX_USERNAME"
echo "$ARTIX_USERNAME:$ARTIX_USER_PASSWORD" | chpasswd

mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# ---- Bootloader --------------------------------------------------------------------
log "GRUB"
if [[ $ARTIX_NVIDIA == y ]]; then
    sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia_drm.modeset=1"/' /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlitzArt --recheck \
    || grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=BlitzArt --recheck --removable

# ---- Snapper (root config created by hand, no dbus needed) -------------------------
log "Snapper"
TEMPLATE=/usr/share/snapper/config-templates/default
[[ -f $TEMPLATE ]] || { echo "Snapper template $TEMPLATE not found." >&2; exit 1; }

mkdir -p /etc/snapper/configs /etc/conf.d
cp "$TEMPLATE" /etc/snapper/configs/root
echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper

set_snapper() { sed -i "s|^$1=.*|$1=\"$2\"|" /etc/snapper/configs/root; }
set_snapper SUBVOLUME /
set_snapper FSTYPE btrfs
set_snapper TIMELINE_LIMIT_HOURLY 5
set_snapper TIMELINE_LIMIT_DAILY 7
set_snapper TIMELINE_LIMIT_WEEKLY 0
set_snapper TIMELINE_LIMIT_MONTHLY 0
set_snapper TIMELINE_LIMIT_YEARLY 0
set_snapper NUMBER_LIMIT 10
set_snapper NUMBER_LIMIT_IMPORTANT 5

# /.snapshots is the mounted @snapshots subvolume (see fstab)
chmod 750 /.snapshots

# Pre/post snapshots around every pacman transaction + refresh GRUB menu
cat > /usr/local/bin/snapper-pacman << 'EOF'
#!/bin/bash
# Called by pacman hooks: snapper-pacman pre|post
state=/run/pacman-snapper-pre
case "${1:-}" in
    pre)
        num=$(snapper --no-dbus -c root create --type pre --print-number \
              --cleanup-algorithm number --description "pacman" 2>/dev/null) \
            && echo "$num" > "$state" || true
        ;;
    post)
        if [[ -s $state ]]; then
            snapper --no-dbus -c root create --type post --pre-number "$(<"$state")" \
                --cleanup-algorithm number --description "pacman" >/dev/null 2>&1 || true
            rm -f "$state"
        fi
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
        ;;
esac
exit 0
EOF
chmod 755 /usr/local/bin/snapper-pacman

mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/00-snapper-pre.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Snapper: pre-transaction snapshot
When = PreTransaction
Exec = /usr/local/bin/snapper-pacman pre
EOF

cat > /etc/pacman.d/hooks/99-snapper-post.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Snapper: post-transaction snapshot and GRUB menu refresh
When = PostTransaction
Exec = /usr/local/bin/snapper-pacman post
EOF

# Hourly timeline snapshots + daily cleanup (cronie)
cat > /etc/cron.d/snapper << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
0 * * * * root snapper --no-dbus -c root create --cleanup-algorithm timeline --description timeline
30 3 * * * root snapper --no-dbus -c root cleanup timeline && snapper --no-dbus -c root cleanup number && grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/snapper

# ---- zram swap -----------------------------------------------------------------------
log "zram swap"
cat > /usr/local/bin/zram-swap << 'EOF'
#!/bin/bash
# zram-swap start|stop  --  compressed swap in RAM, half of the physical memory
set -u
case "${1:-}" in
    start)
        modprobe zram
        mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        dev=$(zramctl --find --size "$((mem_kb / 2))KiB" --algorithm zstd)
        mkswap --label zram "$dev" >/dev/null
        swapon --priority 100 "$dev"
        ;;
    stop)
        for dev in $(swapon --noheadings --raw --show=NAME | grep '^/dev/zram' || true); do
            swapoff "$dev"
            zramctl --reset "$dev"
        done
        ;;
    *)
        echo "usage: zram-swap start|stop" >&2
        exit 1
        ;;
esac
EOF
chmod 755 /usr/local/bin/zram-swap

cat > /etc/dinit.d/zram-swap << 'EOF'
type         = scripted
command      = /usr/local/bin/zram-swap start
stop-command = /usr/local/bin/zram-swap stop
restart      = false
EOF
chmod 644 /etc/dinit.d/zram-swap

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-zram.conf << 'EOF'
vm.swappiness = 180
vm.page-cluster = 0
EOF

# ---- Services ----------------------------------------------------------------------------
log "Enabling services"
enable_service NetworkManager
enable_service ntpd
enable_service cronie
enable_service zram-swap

# Display manager (sddm-dinit pulls in sddm itself)
log "Display manager"
ensure_pkg sddm-dinit
enable_service sddm

# User services for the desktop session (pipewire etc. run as the user through
# dinit-user-spawn). Offline installs get these too -- the packages are on the
# ISO. enable_service --user records anything that fails for the retry hook.
log "User services"
for usvc in dbus pipewire pipewire-pulse wireplumber; do
    enable_service "$usvc" --user
done

# === Konfiguracja środowiska użytkownika ===
# Upewniamy się, że XDG_RUNTIME_DIR jest ustawiony przy każdym loginie.
# To naprawia błędy "XDG_RUNTIME_DIR is not set" oraz błędy hyprpm.
user_zshrc="/home/$ARTIX_USERNAME/.zshrc"
grep -qx 'export XDG_RUNTIME_DIR=/run/user/1000' "$user_zshrc" \
    || { printf 'export XDG_RUNTIME_DIR=/run/user/1000\n' | cat - "$user_zshrc" > "$user_zshrc.tmp" && mv "$user_zshrc.tmp" "$user_zshrc"; }
printf '\n# Ensure runtime dir exists on login\nmkdir -p $XDG_RUNTIME_DIR\nchmod 700 $XDG_RUNTIME_DIR\n' >> "$user_zshrc"

# Włącz jeszcze raz usługi użytkownika (dla pewności)
for usvc in dbus pipewire pipewire-pulse wireplumber; do
    enable_service "$usvc" --user 2>/dev/null || true
done

# ---- Dotfiles (optional) -----------------------------------------------------------------------
if [[ $install_dotfiles == y ]]; then
    log "Dotfiles"
    install -m755 /install/install-dotfiles.sh /usr/local/bin/install-dotfiles

    # (/etc/os-release already has ID_LIKE=arch from the branding step; the end-4
    # installer needs it. It runs as $ARTIX_USERNAME, never as root.)
    /usr/local/bin/install-dotfiles --user "$ARTIX_USERNAME" \
        || echo "WARNING: dotfiles installation failed, see the messages above." >&2
fi

# ---- zsh config, and the first-login check for services that failed ---------------------------
user_home="$(getent passwd "$ARTIX_USERNAME" | cut -d: -f6)"
user_group="$(id -gn "$ARTIX_USERNAME")"

# Minimal ~/.zshrc, only when the dotfiles did not bring their own
if [[ -x /usr/bin/zsh && ! -e $user_home/.zshrc ]]; then
    cat > "$user_home/.zshrc" << 'ZSHRC_EOF'
# BlitzArt Linux - minimal zsh configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_DUPS
bindkey -e
autoload -Uz compinit && compinit
[[ -r /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] \
    && source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
# zsh-syntax-highlighting must be sourced last
[[ -r /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] \
    && source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
ZSHRC_EOF
    chown "$ARTIX_USERNAME:$user_group" "$user_home/.zshrc"
    chmod 644 "$user_home/.zshrc"
fi

# ---- oh-my-zsh (after zsh and the .zshrc are in place) ------------------------------------------
# The installer is downloaded first and run afterwards, as the user (it refuses root
# and installs into $HOME/.oh-my-zsh). --keep-zshrc: the .zshrc copied above stays as is.
if [[ $NET_OK == y && -x /usr/bin/zsh ]]; then
    log "oh-my-zsh"
    if [[ -d $user_home/.oh-my-zsh ]]; then
        echo "    ~/.oh-my-zsh already exists, leaving it alone."
    else
        omz_sh="$(mktemp)" || omz_sh=""
        if [[ -n ${omz_sh:-} ]] && curl -fsSL \
            https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$omz_sh"; then
            chmod 644 "$omz_sh"
            runuser -u "$ARTIX_USERNAME" -- env HOME="$user_home" USER="$ARTIX_USERNAME" \
                LOGNAME="$ARTIX_USERNAME" RUNZSH=no CHSH=no sh "$omz_sh" --keep-zshrc \
                || echo "WARNING: oh-my-zsh installation failed, see the messages above." >&2
            rm -f "$omz_sh"
        else
            echo "WARNING: could not download the oh-my-zsh installer, skipping." >&2
        fi
    fi
fi

# ---- config.json from nazwasadfh/dots + Hyprland plugins (hyprpm) ------------------------------
# Everything below runs as $ARTIX_USERNAME, never as root (hyprpm keeps its state in $HOME).
stamp="$(date +%Y%m%d-%H%M%S)"

as_user() {
    runuser -u "$ARTIX_USERNAME" -- env HOME="$user_home" USER="$ARTIX_USERNAME" LOGNAME="$ARTIX_USERNAME" "$@"
}

log "illogical-impulse config.json (nazwasadfh/dots)"
if [[ $NET_OK != y ]]; then
    echo "No internet: config.json skipped. Later, online: it comes with the dotfiles installer."
elif [[ ! -x /usr/bin/git ]]; then
    echo "WARNING: git is not installed, config.json skipped." >&2
else
    dots_tmp="$(as_user mktemp -d)" || dots_tmp=""
    if [[ -n ${dots_tmp:-} ]] && as_user git clone --depth 1 https://github.com/nazwasadfh/dots "$dots_tmp"; then
        if [[ -f $dots_tmp/config.json ]]; then
            ii_dir="$user_home/.config/illogical-impulse"
            as_user mkdir -p "$ii_dir"
            if [[ -e $ii_dir/config.json ]]; then
                as_user mv "$ii_dir/config.json" "$ii_dir/config.json.bak-$stamp"
                echo "    backed up the existing config.json"
            fi
            as_user cp "$dots_tmp/config.json" "$ii_dir/config.json"
            echo "    installed ~/.config/illogical-impulse/config.json"
        else
            echo "WARNING: config.json not found in nazwasadfh/dots, skipping." >&2
        fi
        as_user rm -rf "$dots_tmp"
    else
        echo "WARNING: could not clone nazwasadfh/dots, config.json skipped." >&2
        [[ -z ${dots_tmp:-} ]] || rm -rf "$dots_tmp"
    fi
fi



# ---- wpapermgr zsh init -------------------------------------------------------------------------
log "wpapermgr user.zsh"
wp_dir="$user_home/wpapermgr/zshinit"
if [[ -e $wp_dir/user.zsh ]]; then
    echo "    ~/wpapermgr/zshinit/user.zsh already exists, leaving it alone."
else
    as_user mkdir -p "$wp_dir"
    cat > "$wp_dir/user.zsh" << 'WPAPER_EOF'
alias p="sudo pacman -S"
alias r="sudo pacman -Rns"
alias cls="printf '\33[2J\033[3J\033[H'"
alias vim="/bin/nvim"
WPAPER_EOF
    chown "$ARTIX_USERNAME:$user_group" "$wp_dir/user.zsh"
    chmod 644 "$wp_dir/user.zsh"
    echo "    installed ~/wpapermgr/zshinit/user.zsh"
fi

if ((${#PENDING[@]})); then
    log "Some services could not be enabled: ${PENDING[*]}"
    echo "A check will run at the first zsh login until all of them are enabled and running."

    install -d -m 755 /etc/blitzart
    printf '%s\n' "${PENDING[@]}" > /etc/blitzart/pending-services
    chmod 644 /etc/blitzart/pending-services

    cat > /usr/local/bin/blitzart-services-retry << 'RETRY_EOF'
#!/bin/bash
# blitzart-services-retry
#
# Finishes the dinit services that could not be enabled while BlitzArt Linux was
# being installed. It is called from ~/.zshrc at every interactive login and removes
# that line again only when ALL of the services are enabled and running.
#
#   blitzart-services-retry              check, enable and start the pending services
#   blitzart-services-retry --install U  add the hook to the ~/.zshrc of user U (root only)
#   blitzart-services-retry --remove     give up: remove the hook from your ~/.zshrc

LIST=/etc/blitzart/pending-services
MARK='BLITZART-SERVICES-HOOK'
SELF=/usr/local/bin/blitzart-services-retry

# The system dinit can only be controlled by root
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

remove_hook() {
    local rc="${1:-$HOME/.zshrc}"
    if [[ -e $rc ]]; then
        sed -i --follow-symlinks "/$MARK/d" "$rc"
    fi
}

case "${1:-}" in
    --install)
        user="${2:?usage: $0 --install USER}"
        home="$(getent passwd "$user" | cut -d: -f6)"
        [[ -n $home ]] || { echo "No such user: $user" >&2; exit 1; }
        rc="$home/.zshrc"
        if [[ ! -e $rc ]]; then
            : > "$rc"
            chown "$user:$(id -gn "$user")" "$rc"
        fi
        grep -q "$MARK" "$rc" \
            || echo "[[ -o interactive && -t 0 ]] && $SELF  # $MARK" >> "$rc"
        exit 0
        ;;
    --remove)
        remove_hook
        echo "Check removed from ~/.zshrc."
        exit 0
        ;;
esac

# Nothing left to do
if [[ ! -s $LIST ]]; then
    remove_hook
    exit 0
fi
mapfile -t services < "$LIST"

echo "BlitzArt Linux: some dinit services could not be enabled during installation."
echo "Trying to enable and start them now (sudo password needed)..."
if [[ $EUID -ne 0 ]]; then
    sudo -v || { echo "Cancelled, I will ask again at the next login."; exit 1; }
fi

failed=()
for svc in "${services[@]}"; do
    [[ -n $svc ]] || continue
    as_root dinitctl enable "$svc" >/dev/null 2>&1 || true
    if ! as_root dinitctl is-started "$svc" >/dev/null 2>&1; then
        as_root dinitctl start "$svc" || true
    fi
    if as_root dinitctl is-started "$svc" >/dev/null 2>&1; then
        echo "  [ok]     $svc is running"
    else
        echo "  [FAILED] $svc"
        failed+=("$svc")
    fi
done

if ((${#failed[@]} == 0)); then
    remove_hook
    as_root rm -f "$LIST"
    echo "All services are running. The check was removed from ~/.zshrc."
else
    echo "Still failing: ${failed[*]}"
    echo "The check runs again at the next login (stop it with: blitzart-services-retry --remove)."
    exit 1
fi
RETRY_EOF
    chmod 755 /usr/local/bin/blitzart-services-retry
    /usr/local/bin/blitzart-services-retry --install "$ARTIX_USERNAME"
fi

# ---- Initramfs, first snapshot, GRUB menu ---------------------------------------------------
log "Initramfs"
mkinitcpio -P

log "First snapshot"
snapper --no-dbus -c root create --description "fresh install" \
    || echo "WARNING: could not create the first snapshot." >&2

log "GRUB config"
grub-mkconfig -o /boot/grub/grub.cfg

# ---- Optional: bring the system up to date (only needs internet) ---------------
# In the offline install the packages are as of the ISO build date; with a
# network, a full upgrade is offered now. Snapper hooks snapshot around it and
# it runs BEFORE hyprpm so plugins compile against the current Hyprland.
if [[ $NET_OK == y ]]; then
    log "System update (optional, online)"
    read -rp "Upgrade packages now (pacman -Syu)? (y/N): " update_answer
    if [[ $update_answer == [yY] ]]; then
        pacman -Syu --noconfirm \
            || echo "WARNING: system upgrade failed -- run 'blitz update' later." >&2
    else
        echo "Skipped. Remember: 'blitz update' is the safe way to upgrade later."
    fi
fi

# ---- blitz (system toolbox) --------------------------------------------------------------------
install -m755 /install/blitz /usr/local/bin/blitz
# blitzinstall: one command to (re)run the installer later. The wrapper is
# installed to /usr/local/bin and looks for install-1.sh there, in
# /root/blitz-install (live ISO), in /install (right now) and in
# /usr/local/lib/blitzart (where a persistent copy is stashed below).
if [[ -f /install/blitzinstall ]]; then
    install -m755 /install/blitzinstall /usr/local/bin/blitzinstall
fi
if [[ -f /install/install-1.sh ]]; then
    mkdir -p /usr/local/lib/blitzart
    install -m755 /install/install-1.sh /usr/local/lib/blitzart/install-1.sh
fi

log "Stage 2 finished"
if [[ $install_dotfiles == y ]]; then
    echo
    echo "Dotfiles were installed (end-4 installer first, your dotfiles on top)."
    echo "If something failed, log in as $ARTIX_USERNAME after the first boot and run:"
    echo "  sudo install-dotfiles"
fi
if ((${#PENDING[@]})); then
    echo
    echo "Services to check at the first login: ${PENDING[*]}"
    echo "Open a zsh session as $ARTIX_USERNAME; it asks for your sudo password and"
    echo "removes its own line from ~/.zshrc once all of them are running."
fi
echo
echo "blitz has been installed to /usr/local/bin/blitz."
echo "It is the toolbox for this system: 'blitz update' is the safe way to"
echo "upgrade (snapshot first, keyring refresh, full upgrade and a post-update"
echo "check), plus snapshot/restore, health, clean, mirrors, pacnew, btrfs,"
echo "boot, kernel and info commands. Everything is logged to /var/log/blitz.log."
echo "Run it with: blitz help   (or 'blitz <command> --help' for details)"
echo
echo "blitzinstall has been installed to /usr/local/bin/blitzinstall:"
echo "it re-runs the BlitzArt installer (install-1.sh) whenever you need it."

# ---- Hyprland plugins (hyprpm) - the very last step ----------------------------------------------
# run_as_user_step <description> <command...>: runs the command as $ARTIX_USERNAME.
# On failure: prints 'failed' and the command's output, then asks (R/i):
#   R = retry, i = ignore (continue with the rest of the installation).
run_as_user_step() {
    local desc="$1" out rc ans
    shift
    while :; do
        echo "==> $desc"
        rc=0
        out=$(as_user "$@" 2>&1) || rc=$?
        if (( rc == 0 )); then
            [[ -n $out ]] && printf '%s\n' "$out"
            return 0
        fi
        printf '==> FAILED: %s (exit %d)\n' "$desc" "$rc" >&2
        [[ -n $out ]] && printf '%s\n' "$out" >&2
        while :; do
            read -rp "(R/i) [R=retry, i=ignore]: " ans </dev/tty \
                || { echo "WARNING: no input available, ignoring." >&2; return 0; }
            case $ans in
                [Ii])    return 0 ;;
                ""|[Rr]) break ;;
                *)       echo "Please answer R or i." ;;
            esac
        done
    done
}

log "Hyprland plugins (hyprpm)"
if [[ $NET_OK != y ]]; then
    echo "No internet: hyprpm plugins skipped. Later, online, as your user:"
    echo "    hyprpm update && hyprpm add <plugin-repo> && hyprpm enable <plugin>"
elif [[ -x /usr/bin/hyprpm ]]; then
    echo "==> Running hyprpm update / add / enable as $ARTIX_USERNAME"
    run_as_user_step "hyprpm update" hyprpm update
    run_as_user_step "hyprpm add https://github.com/hyprwm/hyprland-plugins" \
        hyprpm add https://github.com/hyprwm/hyprland-plugins
    run_as_user_step "hyprpm add https://github.com/outfoxxed/hy3" \
        hyprpm add https://github.com/outfoxxed/hy3
    run_as_user_step "hyprpm add https://github.com/VirtCode/hypr-dynamic-cursors" \
        hyprpm add https://github.com/VirtCode/hypr-dynamic-cursors
    run_as_user_step "hyprpm add https://github.com/ManofJELLO/HyprWindowShade" \
        hyprpm add https://github.com/ManofJELLO/HyprWindowShade
    run_as_user_step "hyprpm add https://github.com/sandwichfarm/hyprflow" \
        hyprpm add https://github.com/sandwichfarm/hyprflow
    run_as_user_step "hyprpm enable hyprfocus"       hyprpm enable hyprfocus
    run_as_user_step "hyprpm enable hy3"             hyprpm enable hy3
    run_as_user_step "hyprpm enable dynamic-cursors" hyprpm enable dynamic-cursors
    run_as_user_step "hyprpm enable HyprWindowShade" hyprpm enable HyprWindowShade
    run_as_user_step "hyprpm enable hyprflow"        hyprpm enable hyprflow
else
    echo "WARNING: hyprpm not found (Hyprland not installed?), plugins skipped." >&2
fi
