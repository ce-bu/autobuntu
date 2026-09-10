# autobuntu

Builds a bootable USB that installs a fully customized Ubuntu on a new PC
**with no internet connection**.

---

## Install

```bash
./build.sh deps               # 1. one-time: install build tools
$EDITOR config.env            # 2. user, password, disks, options
$EDITOR packages.list         # 3. packages you want on the target PC
./build.sh build              # 4. download + assemble  (long, ~10 GB)
./build.sh test               # 5. optional: try the install in QEMU
./build.sh usb /dev/sdX       # 6. write the stick (asks to confirm)
```

Then plug the stick into the new PC, boot from it, and walk away. The install is
unattended and reboots into the finished system: Ubuntu, your packages, KDE,
Rust, Brave and VS Code — all installed offline.

> **Every internal disk gets wiped.** See [Defaults worth
> knowing](#defaults-worth-knowing) before booting a machine you care about.

Re-run only what changed: `./build.sh packages && ./build.sh iso` after editing
`packages.list`, or just `./build.sh iso` after editing `config.env`.

---

## Commands

| Command | Description |
| --- | --- |
| `deps` | Install the build-host dependencies. |
| `download` | Fetch the base Ubuntu ISO into `cache/`, verify its checksum. |
| `packages` | Download the `.deb` payload, Rust and `.vsix`; build the local repo. |
| `iso` | Generate the autoinstall config, patch GRUB, assemble the ISO. |
| `build` | `download` + `packages` + `iso`. The default. |
| `usb /dev/sdX` | Write the ISO to a USB stick. |
| `test` | Boot the ISO in QEMU with networking blocked. |
| `clean` | Remove `work/` and `out/`; `cache/` is kept. |

Add `--skip-checksum` to any command to skip SHA256 verification of downloads.

---

## Files

```
build.sh         the whole tool
config.env       settings          (auto-created)
packages.list    packages to install on the target PC   (auto-created)
extensions.list  VS Code extensions                     (auto-created)
cache/           downloads: ISO, debs, Rust, .vsix — survives `clean`
work/            staging tree
out/             the finished ISO + QEMU test disk
```

`packages.list` is one package per line, `#` for comments. Only top-level names
are needed; dependencies are resolved and downloaded automatically.

---

## Settings (`config.env`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `UBUNTU_VERSION` / `UBUNTU_CODENAME` | `26.04` / `resolute` | **Must match each other.** |
| `UBUNTU_FLAVOUR` / `UBUNTU_ARCH` | `desktop` / `amd64` | Base ISO to customize. |
| `TARGET_HOSTNAME` | `offline-pc` | Hostname. |
| `TARGET_USERNAME` / `TARGET_PASSWORD` | — | First user; the password is hashed at build time. |
| `TARGET_LOCALE` / `TARGET_KEYBOARD` / `TARGET_TIMEZONE` | `en_US.UTF-8` / `us` / `UTC` | Localization. |
| `SUDO_NOPASSWD` | `yes` | `sudo` without a password prompt. |
| `DESKTOP_ENVIRONMENT` | `kde` | `kde`, `gnome` or `none`. |
| `STORAGE_LAYOUT` / `TARGET_DISK` | `lvm` / *(empty)* | Empty picks the largest disk. |
| `POOL_ALL_DISKS` / `POOL_WIPE_NONEMPTY` | `yes` / `yes` | Merge all internal disks into one volume. |
| `INCLUDE_BRAVE` / `INCLUDE_VSCODE` | `yes` / `yes` | Ship Brave / VS Code from their own apt repos. |
| `INCLUDE_RUST` / `RUST_VERSION` / `RUST_PROFILE` | `yes` / `latest` / `complete` | Offline Rust toolchain. |
| `INCLUDE_RECOMMENDS` | `yes` | Include `Recommends` (bigger ISO). |
| `QEMU_DISK_SIZE` / `QEMU_MEMORY` / `QEMU_CPUS` | `64G` / `8192` / `4` | Test VM sizing. Less than 8 GB of RAM makes the live installer fail. |
| `KERNEL_EXTRA_PARAMS` | *(empty)* | Extra boot parameters, e.g. `console=ttyS0,115200 console=tty0` to log the install to `out/qemu/serial.log`. |

Any of them also works as an environment variable: `INCLUDE_RUST=no ./build.sh build`.

---

## Defaults worth knowing

- **All internal disks are erased.** The largest disk is installed to, and every
  other internal disk is added to the same LVM volume group — existing
  filesystems and operating systems included. Set `POOL_ALL_DISKS=no` to touch
  only the install disk, or `POOL_WIPE_NONEMPTY=no` to absorb just empty disks.
  This is concatenation, not RAID: one dead disk loses the volume.
- **The USB stick is never touched**, on two counts: the installer excludes its
  own boot media, and pooling skips removable/USB devices.
- **KDE is the default session**, installed on top of the ISO's GNOME. Both stay
  available from the login screen. This adds ~2 GB to the ISO.
- **Passwordless sudo** is on. Convenient for a lab box, weak on a shared one.
- **Rust** is the latest stable, `complete` profile, in `/opt/rust` and on
  `PATH` for everyone. `rustup` cannot be used offline, so the standalone
  component tarballs are shipped and unpacked instead.
- **Brave and VS Code** come from their own apt repos: packages are pulled into
  the offline repo at build time, and the repo definitions are added to the
  target afterwards so it keeps getting updates once online. VS Code extensions
  from `extensions.list` are shipped as `.vsix` and installed offline.

---

## How it works

1. The official Ubuntu ISO is downloaded and checksum-verified.
2. Your packages are resolved against the **target** release's archive in an
   isolated apt root, so the full dependency tree is downloaded even if the
   build host already has those packages, or runs a different Ubuntu version.
   The result becomes a local apt repository.
3. An autoinstall (cloud-init `nocloud`) answer file is generated, and GRUB is
   patched to boot straight into it.
4. Everything is repacked into a hybrid ISO that boots on BIOS and UEFI.
5. On the target, a post-install script installs the local repo with `apt-get`,
   unpacks Rust and the extensions, and pools the spare disks.

`./build.sh test` runs the whole thing in QEMU with `-netdev user,restrict=on`,
so anything secretly needing internet fails in the VM rather than in front of
the real machine. UEFI/OVMF is auto-detected, KVM is used when available, and
`TEST_FRESH_DISK=no` keeps the previous disk. The guest console is written to
`out/qemu/serial.log`.

---

## Requirements

A recent Ubuntu/Debian machine with `sudo` and ~25 GB free. `./build.sh deps`
installs the rest: `xorriso`, `curl`, `gpg`, `dpkg-dev`, `unzip`,
`ubuntu-keyring`, `whois`, `qemu-system-x86`, `qemu-utils`, `ovmf`.

Notes: the ISO's "Check disc for defects" reports a mismatch because files were
replaced — booting is unaffected. To skip the download, drop an ISO into
`cache/` under its official name.

