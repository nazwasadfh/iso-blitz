## Troubleshooting

- **`cp: cannot stat .../boot/memtest86+/memtest.bin`** — `prepare_boot_extras` w artools kopiuje bezwarunkowo `/boot/memtest86+/memtest.bin` z bootfs overlay (stacka nad rootfs). Pakiet `memtest86+` musi być zainstalowany w rootfs (jest w `packages-base` naszego `common.yaml`).  
- **`XDG_RUNTIME_DIR is not set`** — w `install-2.sh` dodano eksport `XDG_RUNTIME_DIR=/run/user/1000` do `~/.zshrc` oraz `mkdir -p $XDG_RUNTIME_DIR && chmod 700 $XDG_RUNTIME_DIR` w celu zapewnienia katalogu runtime dla usług systemd user (pipewire, hyprpm, dinit-user-spawn).  
- **Usługi użytkownika nie startują** — w `install-2.sh` dodano ponowne włączenie usług `dbus`, `pipewire`, `pipewire-pulse`, `wireplumber` po konfiguracji środowiska, aby `enable_service --user` działał poprawnie.  
- **Hyprpm `no such file or dir .../hyprpm`** — rozwiązano dzięki `XDG_RUNTIME_DIR`; symlink do `/run/user/1000/hyprpm` tworzony jest w runtime, gdy katalog istnieje.  
- **sddm nie startuje** — `enable_service sddm` tworzy symlink w `/etc/dinit.d/boot.d/`, a `dinit-user-spawn` uruchamia usługi z `/home/blitz/.config/dinit.d/boot.d/`.  

## Struktura

```text
iso/
  artools-iso.conf               # ~/.config/artools/artools-iso.conf
  pacman.conf.d/iso-x86_64.conf  # ~/.config/artools/pacman.conf.d/iso-x86_64.conf
iso-profile/
  common/common.yaml             # nasz (okrojony) zbiór pakietów wspólnych
  blitz/profile.yaml             # kompletny zestaw pakietów rootfs + usługi live
  blitz/root-overlay/...         # branding, instalator, marker /etc/blitzart-iso
make-iso.sh                      # całość w jednym poleceniu
README-iso.md                    # dokumentacja builda i modelu offline
README.md                        # główna dokumentacja
```