# Budowanie ISO BlitzArt Linux (artools / buildiso)

**Własny live ISO BlitzArt Linux** — tekstowy (boot do konsoli, jak profil
`base` w Artix), ale z **kompletnym systemem w środku**: desktop (Hyprland +
sddm + pipewire), narzędzia, branding, `blitz`. Dzięki temu instalator robi
**instalację offline**: kopiuje system z ISO na dysk (rsync rootfs — ta sama
technika, której używa offline-unpack Calamares w Artixie). Nie pobiera nic,
co da się mieć offline. To, co **wymaga** internetu (repo Chaotic-AUR i
BlackArch, aktualizacja pakietów, dotfiles end-4, oh-my-zsh, pluginy hyprpm),
odpalane jest automatycznie **tylko wtedy, gdy sieć jest dostępna** — bez
żadnego wyboru trybu; bez sieci te kroki są pomijane z instrukcją "jak zrobić
później online".

Profil jest samodzielny (własny `common.yaml` — pełna kontrola nad listą
pakietów) i nie używa Calamares.

## Wymagania

- Host z **Artix Linux** (x86_64), połączenie z internetem
- Pakiety: `artools-iso` (pociąga m.in. `go-yq`, `squashfs-tools`, `libisoburn`)
  ```bash
  sudo pacman -S artools-iso
  ```
- ~20 GB wolnego miejsca (`~/artools-workspace` + chrooty w `/var/lib/artools`)

## Szybki start

```bash
./make-iso.sh
```

Skrypt:

1. instaluje konfigurację artools do `~/.config/artools/`
   (`INITSYS=dinit`, build-chroot z włączonymi repo Arch `[extra]`/`[multilib]`),
2. kopiuje `iso-profile/` do `~/artools-workspace/iso-profiles/`
   (symlinki do instalatora są dereferencowane — na ISO lądują jako zwykłe
   pliki w `/root/blitz-install/`, `blitz` trafia do `/usr/local/bin/`),
3. robi smoke-test profilu (`buildiso -q`, bez roota),
4. uruchamia `sudo buildiso -p blitz -i dinit -w`.

Wynik: `~/artools-workspace/iso/blitz/artix-blitz-dinit-<data>-x86_64.iso`.
Rozmiar: kompletne jądro + desktop + firmware → spodziewaj się ~3–4 GB
squashfs (kompresja zstd:15).

Test w QEMU:

```bash
sudo qemu-system-x86_64 -enable-kvm -m 4G -smp 4 \
    -drive file=<iso>,format=raw,if=virtio -nic user,model=virtio-net-pci
```

## Sesja live i instalacja

Sesja live jest **tekstowa**: boot do konsoli, login `blitz` / hasło `blitz`
(lub root / `blitz`), sieć przez NetworkManager (jeśli jest). **W sesji live
nic graficznego się nie uruchamia** — pakiety desktopu są w obrazie, ale sddm
nie jest na liście usług live.

Instalacja (jedno polecenie — `blitzinstall` to wrapper startujący
`install-1.sh`):

```bash
sudo blitzinstall
```

Przepływ (jeden, bez podziału online/offline):

1. pytania interaktywne: dysk, hasła, user, hostname, keymap, locale, NVIDIA;
2. **system kopiowany z ISO** (`rsync` rootfs → btrfs subvolume'y `@`, `@home`,
   `@snapshots`, `@var_log`, `@var_cache`) — zero pobierania;
3. czyszczenie artefaktów sesji live (usunięcie `artix-live-dinit`,
   `artix-grub-live`, live usera, live.conf, `machine-id`);
4. etap 2 w chroot: fstab, snapper + hooky, zram, GRUB, branding, usługi
   (dinit), `blitz` — wszystko offline;
5. **jeśli jest internet**: Chaotic-AUR + BlackArch, pytanie o `pacman -Syu`
   (przed hyprpm, żeby pluginy trafiły w aktualną wersję Hyprlanda), dotfiles,
   oh-my-zsh, config.json, pluginy hyprpm. Bez internetu: pominięte z jasnym
   komunikatem (notatka ląduje w `/etc/blitzart/README-repos`, a dotfiles
   później: `sudo install-dotfiles --user <name>`).

## Struktura

```
iso/
  artools-iso.conf               # ~/.config/artools/artools-iso.conf
  pacman.conf.d/iso-x86_64.conf  # ~/.config/artools/pacman.conf.d/iso-x86_64.conf
iso-profile/
  common/common.yaml             # nasz (okrojony) zbiór pakietów wspólnych
  blitz/profile.yaml             # kompletny zestaw pakietów rootfs + usługi live
  blitz/root-overlay/...         # branding, instalator, marker /etc/blitzart-iso
make-iso.sh                      # całość w jednym poleceniu
```

Ważne szczegóły:

- Profil nie ma warstwy `livefs` — ISO bootuje bezpośrednio squashfs rootfsa
  (jak profil `base` Artix). Dlatego overlay nazywa się `root-overlay`
  (`live-overlay` byłby zignorowany przy braku livefs).
- `-w` w buildiso kopiuje buildowy `pacman.conf` do rootfs — skopiowany system
  ma od razu `[extra]`/`[multilib]`.
- Kamera usług: pakiety `-dinit` nie włączają się same (`add_svc_dinit` tylko
  dokleja symlinki z listy `services` profilu) — dlatego live nie startuje
  sddm, a w systemie zainstalowanym włącza go `install-2.sh`
  (`enable_service`), razem z usługami użytkownika (dbus/pipewire).
- Offline instalacja działa też **bez internetu w całości**; tryb online
  (`basestrap`) zostaje jako fallback, gdy skrypty uruchamiasz z **zwykłego**
  ISO Artix — wtedy detekcja markera `/etc/blitzart-iso` wybiera starą drogę.
- Nazwa pliku ISO zawsze zaczyna się od `artix-…` — zaszyte w artools
  (`gen_iso_fn`); plik można przemianować, branding w środku mówi "BlitzArt
  Linux".

## Troubleshooting

- **Błędy podpisów PGP przy pakietach z [extra]** — chroot budowania startuje
  z keyringiem Artix; jeśli pacman odmówi, sprawdź czy na hoście masz
  `archlinux-keyring` (`sudo pacman-key --populate archlinux`) i odśwież.
  Ewentualnie wyłącz na chwilę sekcje `[extra]`/`[multilib]` w
  `iso/pacman.conf.d/iso-x86_64.conf`.
- **"Package not found"** — nazwa zniknęła z repo; popraw listę w
  `iso-profile/blitz/profile.yaml` lub `iso-profile/common/common.yaml`.
- **Chrooty**: pełne czyszczenie co build (`clean_first=true` domyślnie).
  Szybsze iteracje: `./make-iso.sh -c` (nie czyści chrootów) albo etapowo
  `buildiso -p blitz -i dinit -x` → `-s` → `-b` → `-z`.

## Kolejne kroki (droga B — samodzielna dystrybucja)

1. Wyciągnąć konfigurację z `install-2.sh` do pakietów w **własnym repo**
   (`blitz`, `blitz-branding`, `blitz-zram-swap`, `blitz-snapper-hooks`, …),
2. dodać repo `[blitz]` do `iso/pacman.conf.d/iso-x86_64.conf`,
3. własny motyw GRUB (zamiast `artix-grub-theme`) i własny `artix-grub-live`,
4. docelowo CI (Gitea Actions / GitHub Actions) budujące ISO co tydzień.
