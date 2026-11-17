# BlitzArt Linux

A scripted Artix Linux installer that turns a live ISO session into a fully configured **btrfs + snapper** system in minutes — without a separate home partition, without systemd, and without leaving the system unprotected from the very first boot.

Based on **Artix Linux (dinit)**. No display manager or window manager is installed, so you can choose your own desktop environment freely.

> **Roadmap:** This is currently an Artix-based installer, but the long-term plan is to evolve it into a standalone distribution with its own repositories and tooling.

## Features

- **Two-stage installation** — `install-1.sh` partitions, formats and prepares
  the system, then `install-2.sh` configures it inside `artix-chroot`. From a
  BlitzArt ISO the system is **copied from the media (offline install)** —
  nothing that can be offline is downloaded; only steps that truly need
  internet (extra repos, package upgrade, dotfiles, hyprpm plugins) run when
  a network is available.
- **btrfs root with subvolumes** — `@`, `@home`, `@snapshots`, `@var_log`, `@var_cache`, mounted with `noatime,compress=zstd:3,discard=async`.
- **Automatic snapshots** — snapper creates **pre/post snapshots around every pacman transaction**, plus hourly timeline snapshots with automatic cleanup. Every snapshot appears directly in the GRUB menu (`grub-btrfs`), so you can roll back without a live USB.
- **zram swap** — compressed RAM swap (half of physical memory) with tuned sysctl values, no swap partition needed.
- **Arch repositories** — enables `extra` and `multilib` from the official Arch mirrors via `artix-archlinux-support`, plus **Chaotic-AUR** and **BlackArch** (set up with automatic rollback if a repository fails to sync).
- **Optional NVIDIA drivers** — open kernel modules (`nvidia-open-dkms`) for GTX 16xx / RTX and newer.
- **zsh by default** — autosuggestions, syntax highlighting and completions preconfigured; a minimal `~/.zshrc` is created only if dotfiles don't provide one.
- **artix-update** — a safe system update helper inspired by Garuda's `garuda-update` (see below).
- **Optional dotfiles** — Hyprland / end-4 (illogical-impulse) desktop setup via `install-dotfiles.sh`.

## Requirements

- Artix Linux live ISO with **dinit**, booted in **UEFI mode** (a BIOS install is not supported)
- An internet connection
- Target disk: **ESP (FAT32) + ROOT (btrfs)**. The script can partition the disk for you with `cfdisk`, or you can reuse an existing ESP (shared with another OS) by answering `N` to the formatting question.
- `install-2.sh` and `artix-update` must be in the same directory as `install-1.sh`

## Installation

```bash
# 1. Boot the Artix live ISO (dinit variant), UEFI mode
# 2. Install git and clone this repository
pacman -Sy git
git clone https://github.com/nazwasadfh/artixinstall.git
cd artixinstall

# 3. Run stage 1 as root
./install-1.sh
```

The script will interactively ask for:

| Prompt | Notes |
|---|---|
| Partition disk with cfdisk? | Optional — GPT with ESP (~1 GiB) + Linux filesystem |
| ESP / ROOT partition paths | e.g. `/dev/nvme0n1p1` and `/dev/nvme0n1p2` |
| Format ESP? | Answer `N` only to reuse an ESP shared with another OS |
| Root password, username, user password, hostname | Input is validated |
| Install NVIDIA drivers? | Open modules — GTX 16xx / RTX or newer only |
| Install dotfiles? | Only if `install-dotfiles.sh` is present (asked in stage 2) |

After stage 2 finishes, you can reboot. On the first login, zsh checks for any services that could not be enabled during the chroot install and finishes setting them up automatically.

## Disk layout

```
ESP   (FAT32, ~1 GiB)  →  /boot/efi
ROOT  (btrfs)           →  subvolumes:
  @            →  /
  @home        →  /home
  @snapshots   →  /.snapshots
  @var_log     →  /var/log
  @var_cache   →  /var/cache
```

Swap is provided by zram, not a partition. The generated fstab intentionally omits a fixed `subvolid=` so that snapper rollbacks keep working.

## Rollback

- Every pacman install/upgrade/removal is wrapped in a snapper pre/post snapshot pair.
- Hourly timeline snapshots are kept (5 hourly, 7 daily, plus up to 10 numbered).
- Snapshots are listed in the GRUB menu at boot. Roll back from a live ISO with:

```bash
snapper -c root rollback
```

If a system update breaks something, reboot, pick the pre-update snapshot in GRUB, and roll back. You will not lose your `/home` — it lives in its own subvolume.

## artix-update

`artix-update` is installed to `/usr/local/bin/artix-update`. Use it instead of a plain `pacman -Syu`:

```bash
sudo artix-update            # snapshot → keyring refresh → full upgrade → post-check
sudo artix-update -a -f -c   # also AUR, Flatpak and cache cleanup
sudo artix-update --help
```

| Option | Description |
|---|---|
| `-m`, `--mirrors` | Refresh the mirror list (reflector on Arch, rankmirrors on Artix) |
| `-a`, `--aur` | Also update AUR packages (paru or yay, if installed) |
| `-f`, `--flatpak` | Also update Flatpak apps |
| `-c`, `--clean` | Clean the package cache (paccache, keep last 2 versions) |
| `-n`, `--news` | Show latest news from archlinux.org (Arch only) |
| `-S`, `--no-snapshot` | Skip the pre-update snapshot |
| `-y`, `--yes` | Do not ask for confirmation |

It handles the things that routinely break Arch-based systems: stale pacman locks, keyring refresh before the upgrade (never a partial `-Sy`), a snapshot beforehand, and a post-update summary of `.pacnew` files, orphaned packages, failed services and whether a reboot is required. Everything is logged to `/var/log/artix-update.log`.

AUR packages are always built as the invoking user, never as root.

## Dotfiles (optional)

If `install-dotfiles.sh` is present in the repository directory, stage 2 offers to install it. It:

1. Runs the [end-4 (illogical-impulse)](https://ii.clsty.link) installer for a Hyprland desktop,
2. Copies config from [nazwasadfh/dots](https://github.com/nazwasadfh/dots) (Hyprland, kitty, fastfetch, starship, zsh, easyeffects),
3. Installs the [LazyVim starter](https://github.com/LazyVim/starter) and a Quickshell fork (`end4-pC`).

Existing files are **backed up** as `*.bak-<timestamp>`, never deleted. The script is idempotent — unchanged files are skipped, so it is safe to run again. It can also be run standalone on an existing system:

```bash
sudo ./install-dotfiles.sh --user yourname
sudo ./install-dotfiles.sh --user yourname --no-ii   # skip the end-4 installer
```

## Building a real ISO

The long-term goal (standalone distribution) started: the repository now contains an
[artools profile](iso/README-iso.md) that builds a bootable **BlitzArt Linux live ISO**
(text-only live session, dinit, the complete system on board — the installer copies
it to disk offline). From the live ISO, installation is one command:

```bash
sudo blitzinstall
```

```bash
./make-iso.sh
```

## Repository files

| File | Purpose |
|---|---|
| `install-1.sh` | Stage 1 — partitioning, formatting, btrfs subvolumes, `basestrap`, chroot handover |
| `install-2.sh` | Stage 2 — config, repositories, GRUB, snapper, zram, services, branding |
| `artix-update` | Safe system update wrapper (also usable standalone on any Arch-based system) |
| `install-dotfiles.sh` | Optional dotfiles installer (Hyprland / end-4 / LazyVim) |
| `blitzinstall` | Wrapper that starts `install-1.sh` (on the ISO's PATH, installed into the target system too) |

## Customization

Edit the settings block at the top of `install-1.sh` before running:

```bash
TIMEZONE="Europe/Warsaw"
LOCALE="en_US.UTF-8"
KEYMAP="pl"
BTRFS_OPTS="noatime,compress=zstd:3,discard=async"
```

Snapper retention limits, snapshot descriptions and the `BlitzArt` branding (GRUB entry, `/etc/issue`, motd) are defined in `install-2.sh` if you want to rename things.

## Disclaimer

⚠️ The installer **erases the target ROOT partition without warning beyond one explicit confirmation**. Double-check device names — `lsblk` output is shown first. Use on real hardware at your own risk; keep backups of anything valuable.
