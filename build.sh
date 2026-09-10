#!/usr/bin/env bash
#
# autobuntu - build a fully offline, unattended Ubuntu installer ISO/USB.
#
#   ./build.sh deps          install build-host dependencies
#   ./build.sh download      fetch (and verify) the base Ubuntu ISO
#   ./build.sh packages      download the offline .deb payload + build local repo
#   ./build.sh iso           assemble the customized ISO
#   ./build.sh build         download + packages + iso   (default)
#   ./build.sh usb /dev/sdX  write the ISO to a USB stick
#   ./build.sh test          boot the ISO in QEMU against a scratch disk
#   ./build.sh clean         remove work/ and out/ (keeps cache/)
#
# Options:
#   --skip-checksum          do not verify downloaded ISO / Rust checksums
#
# Configuration lives in config.env (auto-created), packages in packages.list.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# --------------------------------------------------------------------------
# Defaults (override in config.env or via the environment)
# --------------------------------------------------------------------------
: "${UBUNTU_VERSION:=26.04}"
: "${UBUNTU_CODENAME:=resolute}"
: "${UBUNTU_FLAVOUR:=desktop}"          # desktop | live-server
: "${UBUNTU_ARCH:=amd64}"
: "${UBUNTU_MIRROR:=http://archive.ubuntu.com/ubuntu}"
: "${RELEASE_BASE_URL:=https://releases.ubuntu.com/${UBUNTU_VERSION}}"

: "${CACHE_DIR:=${SCRIPT_DIR}/cache}"   # downloaded ISO / debs, survives clean
: "${WORK_DIR:=${SCRIPT_DIR}/work}"     # staging tree
: "${OUT_DIR:=${SCRIPT_DIR}/out}"       # finished artifacts
: "${PACKAGES_FILE:=${SCRIPT_DIR}/packages.list}"
: "${EXTENSIONS_FILE:=${SCRIPT_DIR}/extensions.list}"
: "${CONFIG_FILE:=${SCRIPT_DIR}/config.env}"

# Target system identity
: "${TARGET_HOSTNAME:=offline-pc}"
: "${TARGET_USERNAME:=user}"
: "${TARGET_PASSWORD:=user}"        # hashed at build time; change it
: "${TARGET_REALNAME:=user}"
: "${TARGET_LOCALE:=en_US.UTF-8}"
: "${TARGET_KEYBOARD:=us}"
: "${TARGET_TIMEZONE:=UTC}"
: "${SUDO_NOPASSWD:=yes}"               # let the first user run sudo without a password
: "${DESKTOP_ENVIRONMENT:=kde}"         # kde | gnome | none
: "${KERNEL_EXTRA_PARAMS:=}"            # e.g. 'console=ttyS0,115200 console=tty0' to log the install to serial

# Storage. The installer NEVER touches the USB stick it booted from.
: "${STORAGE_LAYOUT:=lvm}"              # direct | lvm  (lvm is required for pooling)
: "${TARGET_DISK:=}"                    # e.g. /dev/nvme0n1; empty = largest disk
: "${POOL_ALL_DISKS:=yes}"              # add every other internal disk to the volume group
: "${POOL_WIPE_NONEMPTY:=yes}"          # pool them even when they already contain data

: "${INCLUDE_RECOMMENDS:=yes}"          # pull Recommends into the offline repo
: "${INCLUDE_BRAVE:=yes}"               # Brave browser from its own apt repo
: "${INCLUDE_VSCODE:=yes}"              # VS Code from the Microsoft apt repo
: "${SKIP_CHECKSUM:=no}"                # skip integrity checks on downloads
: "${INCLUDE_RUST:=yes}"                # ship an offline Rust toolchain
: "${RUST_VERSION:=latest}"             # 'latest' resolves the current stable release
: "${RUST_PROFILE:=complete}"           # minimal | default | complete
: "${RUST_PREFIX:=/opt/rust}"
: "${RUST_DIST_URL:=https://static.rust-lang.org/dist}"

# QEMU test settings
# The payload is copied to the target before it is installed, so the test disk
# needs room for the live filesystem + the payload + everything it unpacks.
: "${QEMU_DISK_SIZE:=64G}"
# The live session runs from a RAM overlay; 4G is not enough for a 26.04 desktop.
: "${QEMU_MEMORY:=8192}"
: "${QEMU_CPUS:=4}"

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1' - run: $0 deps"
}

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# --------------------------------------------------------------------------
# Derived paths
# --------------------------------------------------------------------------
init_paths() {
  ISO_NAME="ubuntu-${UBUNTU_VERSION}-${UBUNTU_FLAVOUR}-${UBUNTU_ARCH}.iso"
  BASE_ISO="${CACHE_DIR}/${ISO_NAME}"
  OUTPUT_ISO="${OUT_DIR}/autobuntu-${UBUNTU_VERSION}-${UBUNTU_FLAVOUR}-${UBUNTU_ARCH}.iso"
  # ISO 9660 volume ids allow only A-Z, 0-9 and '_'.
  VOLID="AUTOBUNTU_${UBUNTU_VERSION//./_}"

  STAGE_DIR="${WORK_DIR}/stage"         # everything here is merged into the ISO
  NOCLOUD_DIR="${STAGE_DIR}/nocloud"
  PAYLOAD_DIR="${STAGE_DIR}/offline"
  REPO_DIR="${PAYLOAD_DIR}/repo"
  GRUB_DIR="${WORK_DIR}/grub"
  APT_ROOT="${CACHE_DIR}/aptroot-${UBUNTU_CODENAME}-${UBUNTU_ARCH}"
  DEB_CACHE="${APT_ROOT}/var/cache/apt/archives"
}

load_config() {
  if [[ -f ${CONFIG_FILE} ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi
  init_paths
  configure_extra_repos
}

# --------------------------------------------------------------------------
# Third-party apt repositories
# --------------------------------------------------------------------------
# Their packages are pulled into the offline repo at build time; the repo
# definition is also installed on the target so it keeps receiving updates once
# the machine is online.
register_repo() {
  REPO_NAMES+=("$1")
  REPO_KEY_URLS+=("$2")
  REPO_KEYRINGS+=("$3")
  REPO_SUITES+=("$4 $5 $6")
  shift 6
  REPO_PACKAGES+=("$*")
}

configure_extra_repos() {
  REPO_NAMES=(); REPO_KEY_URLS=(); REPO_KEYRINGS=(); REPO_SUITES=(); REPO_PACKAGES=()

  if [[ ${INCLUDE_BRAVE} == yes ]]; then
    register_repo brave-browser \
      https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
      /usr/share/keyrings/brave-browser-archive-keyring.gpg \
      https://brave-browser-apt-release.s3.brave.com/ stable main \
      brave-browser
  fi

  if [[ ${INCLUDE_VSCODE} == yes ]]; then
    register_repo vscode \
      https://packages.microsoft.com/keys/microsoft.asc \
      /etc/apt/keyrings/packages.microsoft.gpg \
      https://packages.microsoft.com/repos/code stable main \
      code
  fi
}

extra_repo_packages() {
  local pkgs
  for pkgs in ${REPO_PACKAGES[@]+"${REPO_PACKAGES[@]}"}; do
    printf '%s\n' ${pkgs}
  done
}

fetch_repo_keys() {
  [[ ${#REPO_NAMES[@]} -gt 0 ]] || return 0
  mkdir -p "${APT_ROOT}/etc/apt/keyrings" "${PAYLOAD_DIR}/keyrings"

  local i name dest tmp
  for i in "${!REPO_NAMES[@]}"; do
    name="${REPO_NAMES[i]}"
    dest="${APT_ROOT}/etc/apt/keyrings/${name}.gpg"
    tmp="${dest}.download"

    curl -fsSL -o "${tmp}" "${REPO_KEY_URLS[i]}" ||
      die "could not fetch the signing key for ${name}"
    if head -c 30 "${tmp}" | grep -q -- '-----BEGIN PGP'; then
      gpg --dearmor < "${tmp}" > "${dest}"
    else
      mv "${tmp}" "${dest}"
    fi
    rm -f "${tmp}"
    cp "${dest}" "${PAYLOAD_DIR}/keyrings/${name}.gpg"
  done
}

# name <TAB> keyring path on the target <TAB> sources.list line
write_repo_manifest() {
  : > "${PAYLOAD_DIR}/repos.tsv"
  local i
  for i in ${REPO_NAMES[@]+"${!REPO_NAMES[@]}"}; do
    printf '%s\t%s\tdeb [arch=%s signed-by=%s] %s\n' \
      "${REPO_NAMES[i]}" "${REPO_KEYRINGS[i]}" \
      "${UBUNTU_ARCH}" "${REPO_KEYRINGS[i]}" "${REPO_SUITES[i]}" \
      >> "${PAYLOAD_DIR}/repos.tsv"
  done
}

# --------------------------------------------------------------------------
# Scaffolding
# --------------------------------------------------------------------------
write_default_config() {
  [[ -f ${CONFIG_FILE} ]] && return 0
  log "Creating default ${CONFIG_FILE##*/}"
  cat > "${CONFIG_FILE}" <<EOF
# autobuntu configuration - edit freely, values override build.sh defaults.
UBUNTU_VERSION=${UBUNTU_VERSION}
UBUNTU_CODENAME=${UBUNTU_CODENAME}
UBUNTU_FLAVOUR=${UBUNTU_FLAVOUR}
UBUNTU_ARCH=${UBUNTU_ARCH}
UBUNTU_MIRROR=${UBUNTU_MIRROR}

TARGET_HOSTNAME=${TARGET_HOSTNAME}
TARGET_USERNAME=${TARGET_USERNAME}
TARGET_PASSWORD=${TARGET_PASSWORD}
TARGET_REALNAME="${TARGET_REALNAME}"
TARGET_LOCALE=${TARGET_LOCALE}
TARGET_KEYBOARD=${TARGET_KEYBOARD}
TARGET_TIMEZONE=${TARGET_TIMEZONE}
SUDO_NOPASSWD=${SUDO_NOPASSWD}
DESKTOP_ENVIRONMENT=${DESKTOP_ENVIRONMENT}

STORAGE_LAYOUT=${STORAGE_LAYOUT}
TARGET_DISK=${TARGET_DISK}
POOL_ALL_DISKS=${POOL_ALL_DISKS}
POOL_WIPE_NONEMPTY=${POOL_WIPE_NONEMPTY}

INCLUDE_RECOMMENDS=${INCLUDE_RECOMMENDS}
SKIP_CHECKSUM=${SKIP_CHECKSUM}
INCLUDE_RUST=${INCLUDE_RUST}
RUST_VERSION=${RUST_VERSION}
RUST_PROFILE=${RUST_PROFILE}
RUST_PREFIX=${RUST_PREFIX}
EOF
}

write_default_packages() {
  [[ -f ${PACKAGES_FILE} ]] && return 0
  log "Creating default ${PACKAGES_FILE##*/}"
  cat > "${PACKAGES_FILE}" <<'EOF'
# Packages installed on the target machine, fully offline.
# One package per line; '#' comments and blank lines are ignored.
# Every dependency is resolved and downloaded at build time.
build-essential
curl
git
htop
vim
tmux
vlc
EOF
}

read_packages() {
  [[ -f ${PACKAGES_FILE} ]] || die "package list not found: ${PACKAGES_FILE}"
  read_list "${PACKAGES_FILE}"
}

read_list() {
  [[ -f $1 ]] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -v '^$' || true
}

write_default_extensions() {
  [[ -f ${EXTENSIONS_FILE} ]] && return 0
  log "Creating default ${EXTENSIONS_FILE##*/}"
  cat > "${EXTENSIONS_FILE}" <<'EOF'
# VS Code extensions, downloaded as .vsix at build time and installed offline.
# Format: <publisher>.<extension-name>, one per line.
rust-lang.rust-analyzer
vadimcn.vscode-lldb
tamasfe.even-better-toml
drzix.hc-zenburn-vscode
EOF
}

# The ISO already carries GNOME; an extra desktop is added from the offline repo
# and both stay selectable at the login screen.
desktop_packages() {
  case "${DESKTOP_ENVIRONMENT}" in
    kde)   printf '%s\n' kubuntu-desktop sddm ;;
    gnome) printf '%s\n' ubuntu-desktop ;;
    none)  ;;
    *)     die "unknown DESKTOP_ENVIRONMENT '${DESKTOP_ENVIRONMENT}' (kde|gnome|none)" ;;
  esac
}

display_manager() {
  case "${DESKTOP_ENVIRONMENT}" in
    kde)   printf '%s\t%s\t%s\n' sddm /usr/bin/sddm plasma ;;
    gnome) printf '%s\t%s\t%s\n' gdm3 /usr/sbin/gdm3 ubuntu ;;
    *)     printf '\t\t\n' ;;
  esac
}

target_packages() {
  {
    read_packages
    desktop_packages
    extra_repo_packages
    # Needed on the target to unpack .vsix bundles without network access.
    [[ -s ${EXTENSIONS_FILE} ]] && echo unzip
    [[ ${POOL_ALL_DISKS} == yes ]] && echo lvm2
  } | awk 'NF && !seen[$0]++'
}

# --------------------------------------------------------------------------
# Step: host dependencies
# --------------------------------------------------------------------------
cmd_deps() {
  log "Installing build-host dependencies"
  as_root apt-get update
  as_root apt-get install -y \
    xorriso curl ca-certificates gpg dpkg-dev unzip \
    ubuntu-keyring whois qemu-system-x86 qemu-utils ovmf
}

# --------------------------------------------------------------------------
# Step: download base ISO
# --------------------------------------------------------------------------
cmd_download() {
  require_cmd curl
  mkdir -p "${CACHE_DIR}"

  if [[ -f ${BASE_ISO} ]]; then
    info "Base ISO already cached: ${BASE_ISO}"
  else
    log "Downloading ${ISO_NAME}"
    curl -fL --progress-bar -C - -o "${BASE_ISO}.part" \
      "${RELEASE_BASE_URL}/${ISO_NAME}" ||
      die "download failed - check UBUNTU_VERSION/UBUNTU_FLAVOUR, or drop the ISO at ${BASE_ISO}"
    mv "${BASE_ISO}.part" "${BASE_ISO}"
  fi

  verify_iso
}

verify_iso() {
  if [[ ${SKIP_CHECKSUM} == yes ]]; then
    warn "--skip-checksum: not verifying ${ISO_NAME}"
    return 0
  fi

  local sums="${CACHE_DIR}/SHA256SUMS-${UBUNTU_VERSION}"
  if ! curl -fsL -o "${sums}" "${RELEASE_BASE_URL}/SHA256SUMS"; then
    warn "could not fetch SHA256SUMS - skipping integrity check"
    return 0
  fi
  log "Verifying ISO checksum"
  ( cd "${CACHE_DIR}" && grep -F "*${ISO_NAME}" "${sums##*/}" | sha256sum -c - ) \
    || die "checksum mismatch for ${BASE_ISO} - delete it and retry"
}

# --------------------------------------------------------------------------
# Step: offline package payload
# --------------------------------------------------------------------------
# Debs are resolved against a throw-away APT root with an empty dpkg status
# file, so the complete dependency tree of the *target* release is downloaded
# even when the build host already has those packages installed (or runs a
# different Ubuntu version entirely).
apt_root_opts() {
  local recommends=false
  [[ ${INCLUDE_RECOMMENDS} == yes ]] && recommends=true

  APT_OPTS=(
    -o "Dir::Etc::sourcelist=${APT_ROOT}/etc/apt/sources.list"
    -o "Dir::Etc::sourceparts=/dev/null"
    -o "Dir::Etc::preferences=${APT_ROOT}/etc/apt/preferences"
    -o "Dir::Etc::preferencesparts=/dev/null"
    -o "Dir::State=${APT_ROOT}/var/lib/apt"
    -o "Dir::State::status=${APT_ROOT}/var/lib/dpkg/status"
    -o "Dir::Cache=${APT_ROOT}/var/cache/apt"
    -o "Dir::Log=${APT_ROOT}/var/log/apt"
    -o "APT::Architecture=${UBUNTU_ARCH}"
    -o "APT::Architectures::=${UBUNTU_ARCH}"
    -o "Acquire::Languages=none"
    -o "APT::Install-Recommends=${recommends}"
  )
  [[ $EUID -eq 0 ]] && APT_OPTS+=(-o "APT::Sandbox::User=root")
  return 0
}

setup_apt_root() {
  mkdir -p \
    "${APT_ROOT}/etc/apt" \
    "${APT_ROOT}/var/lib/apt/lists/partial" \
    "${APT_ROOT}/var/lib/dpkg" \
    "${APT_ROOT}/var/cache/apt/archives/partial" \
    "${APT_ROOT}/var/log/apt"
  : > "${APT_ROOT}/var/lib/dpkg/status"

  local keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
  local signed_by=""
  [[ -f ${keyring} ]] && signed_by="[signed-by=${keyring}] "

  cat > "${APT_ROOT}/etc/apt/sources.list" <<EOF
deb ${signed_by}${UBUNTU_MIRROR} ${UBUNTU_CODENAME} main restricted universe multiverse
deb ${signed_by}${UBUNTU_MIRROR} ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb ${signed_by}${UBUNTU_MIRROR} ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

  local i
  for i in ${REPO_NAMES[@]+"${!REPO_NAMES[@]}"}; do
    printf 'deb [arch=%s signed-by=%s] %s\n' \
      "${UBUNTU_ARCH}" "${APT_ROOT}/etc/apt/keyrings/${REPO_NAMES[i]}.gpg" \
      "${REPO_SUITES[i]}" >> "${APT_ROOT}/etc/apt/sources.list"
  done
}

download_debs() {
  local -a packages
  mapfile -t packages < <(target_packages)
  [[ ${#packages[@]} -gt 0 ]] || die "no packages listed in ${PACKAGES_FILE}"

  fetch_repo_keys
  setup_apt_root
  apt_root_opts

  log "Refreshing package index for ${UBUNTU_CODENAME}"
  apt-get "${APT_OPTS[@]}" update >/dev/null ||
    die "apt update failed - is UBUNTU_CODENAME=${UBUNTU_CODENAME} correct?"

  log "Downloading ${#packages[@]} package(s) + dependencies"
  apt-get "${APT_OPTS[@]}" -y --download-only --reinstall install "${packages[@]}" ||
    die "package download failed"
}

build_local_repo() {
  require_cmd dpkg-scanpackages
  log "Building local apt repository"
  rm -rf "${REPO_DIR}"
  mkdir -p "${REPO_DIR}"

  local deb count=0
  for deb in "${DEB_CACHE}"/*.deb; do
    [[ -e ${deb} ]] || die "no .deb files were downloaded"
    ln -f "${deb}" "${REPO_DIR}/" 2>/dev/null || cp "${deb}" "${REPO_DIR}/"
    count=$((count + 1))
  done

  ( cd "${REPO_DIR}" && dpkg-scanpackages --multiversion . > Packages 2>/dev/null )
  gzip -9kf "${REPO_DIR}/Packages"
  info "${count} packages, $(du -sh "${REPO_DIR}" | cut -f1) total"

  # Top-level names to install on the target; deps are pulled from the repo.
  target_packages > "${PAYLOAD_DIR}/packages.list"
}

# --------------------------------------------------------------------------
# Step: offline Rust toolchain
# --------------------------------------------------------------------------
# rustup cannot install anything without network, so the standalone component
# tarballs of the stable channel are shipped and unpacked on the target.
rust_triple() {
  case "${UBUNTU_ARCH}" in
    amd64) echo x86_64-unknown-linux-gnu ;;
    arm64) echo aarch64-unknown-linux-gnu ;;
    *) die "no Rust host triple known for arch '${UBUNTU_ARCH}'" ;;
  esac
}

resolve_rust_version() {
  if [[ ${RUST_VERSION} != latest ]]; then
    echo "${RUST_VERSION}"
    return 0
  fi
  local version
  version=$(curl -fsSL "${RUST_DIST_URL}/channel-rust-stable.toml" |
    sed -n '/^\[pkg\.rust\]/,/^\[pkg\./{s/^version = "\([^ "]*\).*/\1/p}' | head -n1)
  [[ -n ${version} ]] || die "could not resolve the latest stable Rust version"
  echo "${version}"
}

# Component tarballs per profile. 'rust' is the combined package (rustc, cargo,
# rust-std, rust-docs, rustfmt, clippy); the rest are separate downloads.
# miri is omitted: it is part of the complete profile but only ships on nightly.
rust_component_files() {
  local version="$1" triple="$2"
  printf '%s\n' "rust-${version}-${triple}.tar.xz"
  [[ ${RUST_PROFILE} == complete ]] || return 0
  printf '%s\n' \
    "rust-src-${version}.tar.xz" \
    "rust-analyzer-${version}-${triple}.tar.xz" \
    "llvm-tools-${version}-${triple}.tar.xz" \
    "rustc-dev-${version}-${triple}.tar.xz"
}

verify_sha256() {
  local file="$1" url="$2" expected actual
  [[ ${SKIP_CHECKSUM} == yes ]] && return 0
  expected=$(curl -fsSL "${url}" | awk '{print $1; exit}') || return 0
  [[ -n ${expected} ]] || return 0
  actual=$(sha256sum "${file}" | awk '{print $1}')
  [[ ${expected} == "${actual}" ]]
}

fetch_rust_component() {
  local file="$1" required="$2" dest="${RUST_CACHE}/${file}"

  if [[ ! -f ${dest} ]]; then
    if ! curl -fL --progress-bar -o "${dest}.part" "${RUST_DIST_URL}/${file}"; then
      rm -f "${dest}.part"
      [[ ${required} == required ]] && die "failed to download ${file}"
      warn "Rust component unavailable for this release, skipping: ${file}"
      return 1
    fi
    mv "${dest}.part" "${dest}"
  fi

  if ! verify_sha256 "${dest}" "${RUST_DIST_URL}/${file}.sha256"; then
    rm -f "${dest}"
    die "checksum mismatch for ${file}"
  fi
  return 0
}

fetch_rust() {
  [[ ${INCLUDE_RUST} == yes ]] || return 0

  local version triple
  version=$(resolve_rust_version)
  triple=$(rust_triple)
  RUST_CACHE="${CACHE_DIR}/rust/${version}"
  mkdir -p "${RUST_CACHE}" "${PAYLOAD_DIR}/rust"

  log "Fetching Rust ${version} (stable, ${RUST_PROFILE} profile) for ${triple}"

  local -a files manifest=()
  mapfile -t files < <(rust_component_files "${version}" "${triple}")

  local file required=required
  for file in "${files[@]}"; do
    if fetch_rust_component "${file}" "${required}"; then
      [[ -f ${PAYLOAD_DIR}/rust/${file} ]] || cp "${RUST_CACHE}/${file}" "${PAYLOAD_DIR}/rust/"
      manifest+=("${file}")
    fi
    required=optional   # only the combined 'rust' tarball is mandatory
  done

  printf '%s\n' "${manifest[@]}" > "${PAYLOAD_DIR}/rust/MANIFEST"
  printf '%s\n' "${version}" > "${PAYLOAD_DIR}/rust/VERSION"
  info "${#manifest[@]} component tarball(s), $(du -sh "${PAYLOAD_DIR}/rust" | cut -f1)"
}

cmd_packages() {
  require_cmd apt-get
  mkdir -p "${PAYLOAD_DIR}"
  download_debs
  build_local_repo
  write_repo_manifest
  fetch_rust
  fetch_extensions
  write_payload_installer
}

# --------------------------------------------------------------------------
# Step: VS Code extensions
# --------------------------------------------------------------------------
# .vsix bundles are plain zip files, so they can be fetched now and unpacked on
# the target without contacting the marketplace.
vsix_version() {
  unzip -p "$1" extension/package.json 2>/dev/null |
    grep -m1 '"version"' |
    sed -e 's/.*"version\"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

fetch_extensions() {
  local -a extensions
  mapfile -t extensions < <(read_list "${EXTENSIONS_FILE}")
  [[ ${#extensions[@]} -gt 0 ]] || return 0
  require_cmd unzip

  local vsix_cache="${CACHE_DIR}/vsix"
  mkdir -p "${vsix_cache}" "${PAYLOAD_DIR}/vsix"
  log "Fetching ${#extensions[@]} VS Code extension(s)"

  local ext publisher name cached version count=0
  for ext in "${extensions[@]}"; do
    publisher="${ext%%.*}"
    name="${ext#*.}"
    if [[ -z ${publisher} || -z ${name} || ${publisher} == "${ext}" ]]; then
      warn "skipping malformed extension id: ${ext}"
      continue
    fi

    cached="${vsix_cache}/${ext}.vsix"
    if [[ ! -f ${cached} ]]; then
      if ! curl -fL --compressed --progress-bar -o "${cached}.part" \
        "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${publisher}/vsextensions/${name}/latest/vspackage"; then
        rm -f "${cached}.part"
        warn "could not download extension ${ext}, skipping"
        continue
      fi
      mv "${cached}.part" "${cached}"
    fi

    version="$(vsix_version "${cached}")"
    if [[ -z ${version} ]]; then
      rm -f "${cached}"
      warn "${ext} is not a valid .vsix, skipping"
      continue
    fi

    # VS Code expects the extension directory to be <publisher>.<name>-<version>.
    cp "${cached}" "${PAYLOAD_DIR}/vsix/${ext}-${version}.vsix"
    info "${ext} ${version}"
    count=$((count + 1))
  done

  info "${count} extension(s) staged"
}

# --------------------------------------------------------------------------
# Step: autoinstall config + in-target provisioning script
# --------------------------------------------------------------------------
hash_password() {
  if command -v mkpasswd >/dev/null 2>&1; then
    mkpasswd -m sha-512 "${TARGET_PASSWORD}"
  elif command -v openssl >/dev/null 2>&1; then
    openssl passwd -6 "${TARGET_PASSWORD}"
  else
    die "need 'mkpasswd' (whois package) or 'openssl' to hash the password"
  fi
}

write_autoinstall() {
  log "Generating autoinstall configuration"
  mkdir -p "${NOCLOUD_DIR}"
  local pw_hash
  pw_hash="$(hash_password)"

  [[ ${POOL_ALL_DISKS} != yes || ${STORAGE_LAYOUT} == lvm ]] ||
    die "POOL_ALL_DISKS=yes requires STORAGE_LAYOUT=lvm"

  # Subiquity excludes the booted install media from 'match' on its own.
  local disk_match="        size: largest"
  [[ -n ${TARGET_DISK} ]] && disk_match="        path: ${TARGET_DISK}"

  printf 'instance-id: autobuntu-%s\nlocal-hostname: %s\n' \
    "$(date +%Y%m%d%H%M%S)" "${TARGET_HOSTNAME}" > "${NOCLOUD_DIR}/meta-data"
  : > "${NOCLOUD_DIR}/vendor-data"

  cat > "${NOCLOUD_DIR}/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: ${TARGET_LOCALE}
  timezone: ${TARGET_TIMEZONE}
  keyboard:
    layout: ${TARGET_KEYBOARD}
  # No network during installation: never block waiting for a link.
  network:
    version: 2
    ethernets:
      all-en:
        match:
          name: "en*"
        dhcp4: true
        optional: true
  apt:
    fallback: offline-install
    geoip: false
    preserve_sources_list: false
  storage:
    layout:
      name: ${STORAGE_LAYOUT}
      match:
${disk_match}
  identity:
    hostname: ${TARGET_HOSTNAME}
    realname: "${TARGET_REALNAME}"
    username: ${TARGET_USERNAME}
    password: "${pw_hash}"
  ssh:
    install-server: false
  updates: security
  late-commands:
    - mkdir -p /target/opt/autobuntu
    - cp -a /cdrom/offline/. /target/opt/autobuntu/
    - curtin in-target --target=/target -- bash /opt/autobuntu/install.sh
    - rm -rf /target/opt/autobuntu
  shutdown: reboot
EOF
}

write_payload_installer() {
  mkdir -p "${PAYLOAD_DIR}"

  local dm dm_path session
  IFS=$'\t' read -r dm dm_path session < <(display_manager)

  # Header carries build-time values; body is quoted so it stays verbatim.
  cat > "${PAYLOAD_DIR}/install.sh" <<EOF
#!/bin/bash
# Runs inside the freshly installed system (curtin in-target), without network.
set -euo pipefail

PAYLOAD=/opt/autobuntu
TARGET_USER=${TARGET_USERNAME}
RUST_PREFIX=${RUST_PREFIX}
SUDO_NOPASSWD=${SUDO_NOPASSWD}
DISPLAY_MANAGER=${dm}
DISPLAY_MANAGER_PATH=${dm_path}
DEFAULT_SESSION=${session}
POOL_ALL_DISKS=${POOL_ALL_DISKS}
POOL_WIPE_NONEMPTY=${POOL_WIPE_NONEMPTY}
LOG=/var/log/autobuntu-install.log
EOF

  cat >> "${PAYLOAD_DIR}/install.sh" <<'EOF'
exec > >(tee -a "$LOG") 2>&1

echo "== autobuntu offline provisioning: $(date -Is)"

install_offline_packages() {
  local list="${PAYLOAD}/packages.list"
  [[ -s ${list} ]] || { echo "no packages to install"; return 0; }

  local sources=/etc/apt/sources.list.d/autobuntu-offline.sources
  cat > "$sources" <<SRC
Types: deb
URIs: file:${PAYLOAD}/repo
Suites: ./
Trusted: yes
SRC

  # Ignore the network sources entirely: the local repo is the only origin.
  local -a apt_opts=(
    -o Acquire::Retries=0
    -o Dir::Etc::sourcelist=/dev/null
    -o Dir::Etc::sourceparts=/etc/apt/sources.list.d
  )

  local -a packages
  mapfile -t packages < <(grep -v '^[[:space:]]*$' "$list")

  DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" update
  DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" install -y "${packages[@]}"

  rm -f "$sources"
  apt-get clean
}

install_rust() {
  local dir="${PAYLOAD}/rust"
  [[ -s ${dir}/MANIFEST ]] || return 0

  echo "== installing Rust $(cat "${dir}/VERSION") into ${RUST_PREFIX}"
  local tarball tmp
  while read -r tarball; do
    [[ -n ${tarball} && -f ${dir}/${tarball} ]] || continue
    echo "-- ${tarball}"
    tmp="$(mktemp -d)"
    tar -xJf "${dir}/${tarball}" -C "$tmp" --strip-components=1
    "$tmp/install.sh" --prefix="${RUST_PREFIX}" --disable-ldconfig
    rm -rf "$tmp"
  done < "${dir}/MANIFEST"

  cat > /etc/profile.d/rust.sh <<PROFILE
export PATH="${RUST_PREFIX}/bin:\$PATH"
export RUST_SRC_PATH="${RUST_PREFIX}/lib/rustlib/src/rust/library"
PROFILE
  chmod 0644 /etc/profile.d/rust.sh
  echo "${RUST_PREFIX}/lib" > /etc/ld.so.conf.d/rust.conf
  ldconfig
}

configure_sudo() {
  [[ ${SUDO_NOPASSWD} == yes ]] || return 0
  id "$TARGET_USER" >/dev/null 2>&1 || return 0

  echo "== granting passwordless sudo to ${TARGET_USER}"
  local file=/etc/sudoers.d/90-autobuntu-nopasswd
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" > "$file"
  chmod 0440 "$file"
  # A malformed drop-in can lock sudo out entirely, so never keep an invalid one.
  visudo -cf "$file" >/dev/null || { rm -f "$file"; echo "invalid sudoers, removed"; return 1; }
}

configure_desktop() {
  [[ -n ${DISPLAY_MANAGER} ]] || return 0

  if [[ -x ${DISPLAY_MANAGER_PATH} ]]; then
    echo "== default display manager: ${DISPLAY_MANAGER}"
    echo "${DISPLAY_MANAGER_PATH}" > /etc/X11/default-display-manager
    echo "${DISPLAY_MANAGER} shared/default-x-display-manager select ${DISPLAY_MANAGER}" |
      debconf-set-selections
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure "${DISPLAY_MANAGER}" || true
    systemctl set-default graphical.target || true
  else
    echo "${DISPLAY_MANAGER} is not installed, keeping the shipped display manager"
  fi

  # Preselect the session for the first user; every other installed desktop
  # stays available from the login screen's session menu.
  if [[ -n ${DEFAULT_SESSION} ]] && id "$TARGET_USER" >/dev/null 2>&1; then
    install -d -m 0755 /var/lib/AccountsService/users
    cat > "/var/lib/AccountsService/users/${TARGET_USER}" <<ACCT
[User]
Session=${DEFAULT_SESSION}
XSession=${DEFAULT_SESSION}
SystemAccount=false
ACCT
    chmod 0600 "/var/lib/AccountsService/users/${TARGET_USER}"
  fi
}

install_extra_repos() {
  local manifest="${PAYLOAD}/repos.tsv"
  [[ -s ${manifest} ]] || return 0

  echo "== registering third-party apt repositories"
  local name keyring line
  while IFS=$'\t' read -r name keyring line; do
    [[ -n ${name} ]] || continue
    if [[ -f ${PAYLOAD}/keyrings/${name}.gpg ]]; then
      install -D -o root -g root -m 0644 "${PAYLOAD}/keyrings/${name}.gpg" "${keyring}"
    fi
    printf '%s\n' "${line}" > "/etc/apt/sources.list.d/${name}.list"
    echo "-- ${name}"
  done < "$manifest"
}

install_vscode_extensions() {
  local dir="${PAYLOAD}/vsix"
  [[ -d ${dir} ]] || return 0
  id "$TARGET_USER" >/dev/null 2>&1 || return 0

  local home
  home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n ${home} ]] || return 0
  local extdir="${home}/.vscode/extensions"
  install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 "$extdir"

  echo "== installing VS Code extensions"
  local vsix base
  for vsix in "$dir"/*.vsix; do
    [[ -e ${vsix} ]] || break
    base="$(basename "$vsix" .vsix)"

    # The CLI is preferred, but it can fail in a chroot; unpacking the bundle
    # into the extensions directory is equivalent as far as VS Code is concerned.
    if command -v code >/dev/null 2>&1 &&
       runuser -u "$TARGET_USER" -- env HOME="$home" \
         code --install-extension "$vsix" --force >/dev/null 2>&1; then
      echo "-- ${base} (cli)"
    elif command -v unzip >/dev/null 2>&1; then
      rm -rf "${extdir}/${base}" "${extdir}/.tmp-${base}"
      unzip -qq "$vsix" 'extension/*' -d "${extdir}/.tmp-${base}"
      mv "${extdir}/.tmp-${base}/extension" "${extdir}/${base}"
      rm -rf "${extdir}/.tmp-${base}"
      echo "-- ${base} (unpacked)"
    else
      echo "-- ${base}: no way to install, skipped"
      continue
    fi
  done

  chown -R "$TARGET_USER:$TARGET_USER" "${home}/.vscode"
}

# Adds every *internal* spare disk to the root volume group and grows the root
# filesystem over them. Removable and USB devices are skipped, so the installer
# stick can never be swallowed by the pool.
disk_is_poolable() {
  local disk="$1" dev="/dev/$1"

  [[ -r /sys/block/${disk}/removable ]] || return 1
  [[ $(cat "/sys/block/${disk}/removable") == 0 ]] || return 1

  local tran
  tran="$(lsblk -dnro TRAN "$dev" 2>/dev/null || true)"
  case "$tran" in usb | "") return 1 ;; esac

  # Anything mounted, or already a PV, is off limits.
  lsblk -nro MOUNTPOINT "$dev" 2>/dev/null | grep -q . && return 1
  pvs --noheadings -o pv_name 2>/dev/null | grep -qw "$dev" && return 1

  if [[ ${POOL_WIPE_NONEMPTY} != yes ]]; then
    lsblk -nro FSTYPE,PARTTYPE "$dev" 2>/dev/null | grep -q '[^[:space:]]' && return 1
  fi
  return 0
}

pool_extra_disks() {
  [[ ${POOL_ALL_DISKS} == yes ]] || return 0
  command -v pvcreate >/dev/null 2>&1 || { echo "lvm2 missing, not pooling disks"; return 0; }

  local root_src vg lv
  root_src="$(findmnt -no SOURCE / || true)"
  vg="$(lvs --noheadings -o vg_name --select "lv_path=${root_src}" 2>/dev/null | tr -d ' ' || true)"
  lv="$(lvs --noheadings -o lv_name --select "lv_path=${root_src}" 2>/dev/null | tr -d ' ' || true)"
  if [[ -z ${vg} || -z ${lv} ]]; then
    echo "root is not on LVM (${root_src}), not pooling disks"
    return 0
  fi

  echo "== pooling spare disks into volume group ${vg}"
  local disk added=0
  while read -r disk; do
    disk_is_poolable "$disk" || continue
    echo "-- adding /dev/${disk}"
    wipefs -a "/dev/${disk}"
    pvcreate -ff -y "/dev/${disk}"
    vgextend "${vg}" "/dev/${disk}"
    added=$((added + 1))
  done < <(lsblk -dnro NAME,TYPE | awk '$2 == "disk" { print $1 }')

  if [[ ${added} -eq 0 ]]; then
    echo "no spare disks found"
    return 0
  fi

  lvextend -l +100%FREE "/dev/${vg}/${lv}"
  case "$(findmnt -no FSTYPE /)" in
    xfs) xfs_growfs / ;;
    *)   resize2fs "/dev/${vg}/${lv}" ;;
  esac
  echo "${added} disk(s) added to ${vg}"
}

install_offline_packages
install_rust
configure_sudo
configure_desktop
install_extra_repos
install_vscode_extensions
pool_extra_disks

echo "== autobuntu offline provisioning finished"
EOF

  chmod +x "${PAYLOAD_DIR}/install.sh"
}

# --------------------------------------------------------------------------
# Step: bootloader
# --------------------------------------------------------------------------
patch_bootloader() {
  log "Patching bootloader for unattended autoinstall"
  mkdir -p "${GRUB_DIR}"
  rm -f "${GRUB_DIR}/grub.cfg"

  xorriso -osirrox on -indev "${BASE_ISO}" \
    -extract /boot/grub/grub.cfg "${GRUB_DIR}/grub.cfg" >/dev/null 2>&1 ||
    die "could not extract /boot/grub/grub.cfg from ${BASE_ISO}"
  chmod u+w "${GRUB_DIR}/grub.cfg"

  # ';' has to be escaped for the grub parser.
  export KERNEL_PARAMS="autoinstall ds=nocloud\\;s=/cdrom/nocloud/${KERNEL_EXTRA_PARAMS:+ ${KERNEL_EXTRA_PARAMS}}"

  awk '
    /^[[:space:]]*linux[[:space:]]+\/casper\/vmlinuz/ {
      if (index($0, "autoinstall") == 0) {
        if (index($0, " ---") > 0) sub(/ ---/, " " ENVIRON["KERNEL_PARAMS"] " ---")
        else $0 = $0 " " ENVIRON["KERNEL_PARAMS"]
      }
    }
    /^[[:space:]]*set[[:space:]]+timeout=/ { $0 = "set timeout=3" }
    { print }
  ' "${GRUB_DIR}/grub.cfg" > "${GRUB_DIR}/grub.cfg.new"

  grep -q 'autoinstall' "${GRUB_DIR}/grub.cfg.new" ||
    die "failed to inject kernel parameters into grub.cfg"
  mv "${GRUB_DIR}/grub.cfg.new" "${GRUB_DIR}/grub.cfg"
}

# --------------------------------------------------------------------------
# Step: assemble ISO
# --------------------------------------------------------------------------
cmd_iso() {
  require_cmd xorriso
  [[ -f ${BASE_ISO} ]] || die "base ISO missing - run: $0 download"
  [[ -d ${REPO_DIR} ]] || die "offline payload missing - run: $0 packages"

  write_autoinstall
  write_payload_installer
  patch_bootloader

  mkdir -p "${OUT_DIR}"
  rm -f "${OUTPUT_ISO}"

  log "Assembling ${OUTPUT_ISO##*/}"
  # 'replay' reproduces the original El Torito / GPT boot records, so the
  # result stays bootable on BIOS and UEFI when dd'd to a USB stick.
  xorriso -indev "${BASE_ISO}" \
          -outdev "${OUTPUT_ISO}" \
          -boot_image any replay \
          -volid "${VOLID}" \
          -compliance no_emul_toc \
          -joliet on \
          -map "${NOCLOUD_DIR}" /nocloud \
          -map "${PAYLOAD_DIR}" /offline \
          -map "${GRUB_DIR}/grub.cfg" /boot/grub/grub.cfg \
          -- >/dev/null

  log "Done: ${OUTPUT_ISO} ($(du -h "${OUTPUT_ISO}" | cut -f1))"
  info "Write it with: $0 usb /dev/sdX     or try it first with: $0 test"
}

cmd_build() {
  cmd_download
  cmd_packages
  cmd_iso
}

# --------------------------------------------------------------------------
# Step: write to USB
# --------------------------------------------------------------------------
cmd_usb() {
  local device="${1:-}"
  [[ -n ${device} ]] || die "usage: $0 usb /dev/sdX"
  [[ -b ${device} ]] || die "not a block device: ${device}"
  [[ -f ${OUTPUT_ISO} ]] || die "ISO not built - run: $0 build"

  lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT "${device}" || true
  warn "ALL DATA ON ${device} WILL BE DESTROYED."
  local confirm
  read -r -p "Type the device path again to confirm: " confirm
  [[ ${confirm} == "${device}" ]] || die "aborted"

  log "Writing ${OUTPUT_ISO##*/} to ${device}"
  as_root dd if="${OUTPUT_ISO}" of="${device}" bs=64M status=progress oflag=sync
  as_root sync
  log "USB stick ready"
}

# --------------------------------------------------------------------------
# Step: QEMU test run
# --------------------------------------------------------------------------
find_ovmf() {
  local code vars
  for code in /usr/share/OVMF/OVMF_CODE_4M.fd \
              /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [[ -f ${code} ]] || continue
    vars="${code/CODE/VARS}"
    [[ -f ${vars} ]] || continue
    OVMF_CODE="${code}"
    OVMF_VARS_SRC="${vars}"
    return 0
  done
  return 1
}

cmd_test() {
  require_cmd qemu-system-x86_64
  require_cmd qemu-img
  [[ -f ${OUTPUT_ISO} ]] || die "ISO not built - run: $0 build"

  local test_dir="${OUT_DIR}/qemu"
  local disk="${test_dir}/target.qcow2"
  mkdir -p "${test_dir}"

  if [[ ${TEST_FRESH_DISK:-yes} == yes || ! -f ${disk} ]]; then
    log "Creating scratch disk (${QEMU_DISK_SIZE})"
    rm -f "${disk}" "${test_dir}/OVMF_VARS.fd"
    qemu-img create -f qcow2 "${disk}" "${QEMU_DISK_SIZE}" >/dev/null
  fi

  local free_gb
  free_gb=$(df -BG --output=avail "${OUT_DIR}" | tail -1 | tr -dc '0-9')
  [[ ${free_gb} -ge ${QEMU_DISK_SIZE%[Gg]} ]] ||
    warn "only ${free_gb}G free: the ${QEMU_DISK_SIZE} test disk may not fit"

  local accel=tcg
  [[ -w /dev/kvm ]] && accel=kvm || warn "/dev/kvm not usable - emulating (slow)"

  local -a qemu_args=(
    -machine "q35,accel=${accel}"
    -smp "${QEMU_CPUS}"
    -m "${QEMU_MEMORY}"
    -vga virtio
    -device virtio-net-pci,netdev=n0
    # Deliberately isolated: proves the install really works without internet.
    -netdev user,id=n0,restrict=on
    -drive "file=${disk},format=qcow2,if=virtio"
    -drive "file=${OUTPUT_ISO},format=raw,media=cdrom,readonly=on"
    -boot order=d,menu=off
    -serial "file:${test_dir}/serial.log"
  )
  [[ ${accel} == kvm ]] && qemu_args+=(-cpu host)

  if find_ovmf; then
    local vars="${test_dir}/OVMF_VARS.fd"
    [[ -f ${vars} ]] || cp "${OVMF_VARS_SRC}" "${vars}"
    qemu_args+=(
      -drive "if=pflash,format=raw,unit=0,readonly=on,file=${OVMF_CODE}"
      -drive "if=pflash,format=raw,unit=1,file=${vars}"
    )
    info "UEFI firmware: ${OVMF_CODE}"
  else
    warn "OVMF not found - falling back to legacy BIOS boot"
  fi

  log "Starting QEMU (network restricted to simulate an offline install)"
  info "guest console log: ${test_dir}/serial.log"
  qemu-system-x86_64 "${qemu_args[@]}"

  info "To boot the installed disk afterwards:"
  info "  qemu-system-x86_64 -machine q35,accel=${accel} -m ${QEMU_MEMORY} -drive file=${disk},if=virtio"
}

# --------------------------------------------------------------------------
# Step: clean
# --------------------------------------------------------------------------
cmd_clean() {
  log "Removing ${WORK_DIR} and ${OUT_DIR}"
  rm -rf "${WORK_DIR}" "${OUT_DIR}"
  info "cache/ kept (ISO + debs). Delete it manually to force a full re-download."
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
usage() {
  awk 'NR>1 && /^#/ { sub(/^#[[:space:]]?/, ""); print; next } NR>1 { exit }' \
    "${BASH_SOURCE[0]}"
}

main() {
  local -a args=()
  local arg skip_checksum_flag=no
  for arg in "$@"; do
    case "${arg}" in
      --skip-checksum) skip_checksum_flag=yes ;;
      *) args+=("${arg}") ;;
    esac
  done
  set -- "${args[@]+"${args[@]}"}"

  local cmd="${1:-build}"
  shift || true

  write_default_config
  write_default_packages
  write_default_extensions
  load_config
  # The command-line flag wins over config.env, which load_config just sourced.
  [[ ${skip_checksum_flag} == yes ]] && SKIP_CHECKSUM=yes
  mkdir -p "${CACHE_DIR}" "${WORK_DIR}" "${OUT_DIR}"

  case "${cmd}" in
    deps)      cmd_deps ;;
    download)  cmd_download ;;
    packages)  cmd_packages ;;
    iso)       cmd_iso ;;
    build|all) cmd_build ;;
    usb)       cmd_usb "$@" ;;
    test)      cmd_test ;;
    clean)     cmd_clean ;;
    -h|--help|help) usage ;;
    *) usage; die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
