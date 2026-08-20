#!/usr/bin/env bash
# =============================================================================
#  Mobile Security & Reverse Engineering Lab Installer
#  Target: Kali Linux / Debian-based (x86_64 or arm64)
#
#  Installs: iOS jailbreak/instrumentation tools, Android RE & analysis tools,
#  web/proxy pentesting tools, general RE utilities, Docker + MobSF as a
#  systemd service.
#
#  Usage:
#    sudo ./install.sh [--all|--ios|--android|--web|--utils|--docker-only]
#                                        [--no-docker] [--no-venv] [--help]
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Colors / helpers
# -----------------------------------------------------------------------------
C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YLW=$'\033[1;33m'; C_BLU=$'\033[1;34m'
C_RST=$'\033[0m'

log()  { printf '%b[*]%b %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%b[+]%b %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%b[!]%b %s\n' "$C_YLW" "$C_RST" "$*"; }
die()  { printf '%b[x]%b %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

section() { printf '\n%b======================================================%b\n' "$C_BLU" "$C_RST"; log "$*"; printf '%b======================================================%b\n' "$C_BLU" "$C_RST"; }

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
DO_IOS=0 DO_ANDROID=0 DO_WEB=0 DO_UTILS=0 DO_DOCKER=0 DO_VENV=1
MODE=""
VENV="/opt/mobile-sec-venv"

# Organized lab folder structure
LAB_ROOT="/opt/mobpen-lab"       # top-level lab folder (everything below is categorized)
LAB_IOS="$LAB_ROOT/ios"             # iOS jailbreak / instrumentation / RE sources
LAB_ANDROID="$LAB_ROOT/android"     # Android reverse-engineering sources & gadgets
LAB_WEB="$LAB_ROOT/web"             # web / network pentesting sources
LAB_FLUTTER="$LAB_ROOT/flutter"     # Flutter reverse-engineering tools
LAB_BIN="$LAB_ROOT/bin"             # convenience launchers / helper scripts
LAB_DOCS="$LAB_ROOT/docs"           # generated documentation
LAB_TMP="$LAB_ROOT/.tmp"            # scratch space during installs

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [options]

  --all           Install everything (default)
  --ios           iOS jailbreak & instrumentation tools only
  --android       Android RE & analysis tools only
  --web           Web/network pentesting tools only
  --utils         General utilities only
  --docker-only   Only install Docker + MobSF service
  --no-docker     Skip Docker + MobSF setup
  --no-venv       Skip the shared Python venv (pip tools)
  --docs-only     Only regenerate the lab documentation
  -h, --help      Show this help
EOF
}

[[ $# -eq 0 ]] && MODE="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)        MODE="all" ;;
    --ios)        DO_IOS=1 ;;
    --android)    DO_ANDROID=1 ;;
    --web)        DO_WEB=1 ;;
    --utils)      DO_UTILS=1 ;;
    --docker-only) DO_DOCKER=1 ;;
    --no-docker)  DO_DOCKER=-1 ;;
    --no-venv)    DO_VENV=0 ;;
    --docs-only)  DO_DOCS=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

if [[ "${DO_DOCS:-0}" == "1" ]]; then
  MODE="docs-only"
fi

if [[ "$MODE" == "all" ]]; then
  DO_IOS=1 DO_ANDROID=1 DO_WEB=1 DO_UTILS=1
  [[ "$DO_DOCKER" -eq 0 ]] && DO_DOCKER=1
elif [[ "$DO_DOCKER" -eq 0 && "$MODE" != "docker-only" ]]; then
  DO_DOCKER=1
fi

# -----------------------------------------------------------------------------
# Root / sudo re-exec
# -----------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
  printf '%bRe-running with sudo...%b\n' "$C_YLW" "$C_RST"
  exec sudo -H bash "$0" "$@"
fi
[[ -n "${SUDO_USER:-}" ]] && USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)" || USER_HOME="$HOME"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) PA_ARCH="x86_64"; FRIDA_ARCH="x86_64" ;;
  aarch64|arm64) PA_ARCH="arm64"; FRIDA_ARCH="arm64" ;;
  *) PA_ARCH="$ARCH"; FRIDA_ARCH="$ARCH" ;;
esac

command -v curl >/dev/null 2>&1 || apt-get update -y && apt-get install -y curl ca-certificates

# Never prompt for git credentials during clones (e.g. dead/renamed repos)
export GIT_TERMINAL_PROMPT=0

# -----------------------------------------------------------------------------
# Low-level helpers
# -----------------------------------------------------------------------------
fetch() { curl -fL --retry 3 --retry-delay 2 "$1" -o "$2" || return 1; }

apt_install() {
  if DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1; then
    return 0
  fi
  warn "batch apt install failed for: $* - retrying per-package"
  local fail=0
  for pkg in "$@"; do
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
      :
    else
      warn "apt install failed: $pkg"
      fail=1
    fi
  done
  return "$fail"
}

# Pick the first installed/available package from a candidate list
apt_pick() {
  local pkg
  for pkg in "$@"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      printf '%s' "$pkg"
      return 0
    fi
  done
  return 1
}

# Resolve latest GitHub release asset URL. $1=owner/repo  $2=asset regex
# Uses python3 for JSON parsing so it never depends on jq being installed.
gh_latest_asset() {
  local repo="$1" pattern="$2"
  python3 - "$repo" "$pattern" <<'PYEOF'
import json, re, sys, urllib.request
repo, pattern = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases/latest",
    headers={"User-Agent": "mobpen-lab", "Accept": "application/vnd.github+json"})
try:
    data = json.load(urllib.request.urlopen(req, timeout=30))
except Exception:
    sys.exit(0)
rx = re.compile(pattern)
for a in data.get("assets", []):
    if rx.search(a.get("name", "")):
        print(a["browser_download_url"])
        break
PYEOF
}

link_bin() {
  local name="$1"
  if [[ -x "${VENV}/bin/$name" ]]; then
    ln -sf "${VENV}/bin/$name" "/usr/local/bin/$name"
    ok "linked $name -> ${VENV}/bin/$name"
  else
    warn "$name was not created in the venv (check pip output above)"
  fi
}

# Repair a broken zsh install. Fresh boxes sometimes lose the zsh modules
# (failed to load module 'zsh/complist' / comparguments: command not found)
# when a source-built zsh shadows the distro one or the modules dir is missing.
repair_zsh() {
  local probe='zmodload zsh/complist && autoload -Uz comparguments'
  if command -v zsh >/dev/null 2>&1; then
    if zsh -fc "$probe" >/dev/null 2>&1; then
      ok "zsh modules OK"
      return 0
    fi
    warn "zsh modules broken (complist/comparguments) - reinstalling zsh"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall zsh zsh-common >/dev/null 2>&1 \
      || apt_install zsh zsh-common
    # A source-built zsh under /usr/local shadows the distro /usr/bin/zsh
    if [[ -x /usr/local/bin/zsh && "$(command -v zsh)" != /usr/bin/zsh ]]; then
      warn "non-system zsh at $(command -v zsh) - removing /usr/local/bin/zsh"
      rm -f /usr/local/bin/zsh
    fi
    if zsh -fc "$probe" >/dev/null 2>&1; then
      ok "zsh modules repaired"
    else
      warn "zsh modules still broken after reinstall - run manually: apt-get install --reinstall zsh zsh-common"
    fi
  else
    apt_install zsh zsh-common
    ok "zsh installed"
  fi
}

# Create the organized lab layout + migrate any old flat-layout installs
mkdir -p "$LAB_ROOT" "$LAB_IOS" "$LAB_ANDROID" "$LAB_WEB" "$LAB_FLUTTER" "$LAB_BIN" "$LAB_DOCS" "$LAB_TMP"

migrate_lab_layout() {
  # Rename the lab root if an older run created it under the previous name
  if [[ -d /opt/mobile-sec-lab && ! -d "$LAB_ROOT" ]]; then
    log "Renaming /opt/mobile-sec-lab -> $LAB_ROOT"
    mv /opt/mobile-sec-lab "$LAB_ROOT"
  fi
  local old
  old="/opt/mobile-sec-tools"
  [[ -d "$old" ]] || return 0
  log "Migrating old $old layout into categorized folders"
  for t in frida-ios-dump bfinject ssl-kill-switch2 needle class-dump; do
    [[ -d "$old/$t" && ! -d "$LAB_IOS/$t" ]] && mv "$old/$t" "$LAB_IOS/$t"
  done
  for t in pidcat frida-gadget; do
    [[ -d "$old/$t" && ! -d "$LAB_ANDROID/$t" ]] && mv "$old/$t" "$LAB_ANDROID/$t"
  done
  [[ -d "$old/rms" && ! -d "$LAB_WEB/rms" ]] && mv "$old/rms" "$LAB_WEB/rms"
  [[ -d "$old/kill_flutter" && ! -d "$LAB_FLUTTER/kill_flutter" ]] && mv "$old/kill_flutter" "$LAB_FLUTTER/kill_flutter"
  # re-link any stale symlinks that pointed into the old layout
  for l in pidcat kill_flutter; do
    if [[ -L "/usr/local/bin/$l" && ! -e "/usr/local/bin/$l" ]]; then
      rm -f "/usr/local/bin/$l"
    fi
  done
}
migrate_lab_layout

# =============================================================================
# 0. System update + VM guest tools
# =============================================================================
if [[ "$MODE" == "all" || "$DO_IOS" == "1" || "$DO_ANDROID" == "1" || "$DO_WEB" == "1" || "$DO_UTILS" == "1" ]]; then
  section "Updating system and installing VM guest tools"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y || warn "apt upgrade had issues - continuing anyway"

  repair_zsh

  # Detect the hypervisor (systemd-detect-virt, falling back to DMI info)
  VM_KIND="none"; virt=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  if [[ -z "$virt" && -r /sys/class/dmi/id/sys_vendor ]]; then
    sv="$(tr '[:upper:]' '[:lower:]' < /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    case "$sv" in
      *virtualbox*) virt="oracle" ;;
      *vmware*)     virt="vmware" ;;
    esac
  fi
  case "$virt" in
    oracle|virtualbox) VM_KIND="virtualbox" ;;
    vmware)           VM_KIND="vmware" ;;
    kvm|qemu|hyperv|microsoft|xen|zvm|bochs|none|"") VM_KIND="none" ;;
    *)                VM_KIND="none" ;;
  esac

  if [[ "$VM_KIND" == "virtualbox" ]]; then
    log "Detected VirtualBox - installing guest additions"
    apt_install virtualbox-guest-utils virtualbox-guest-x11
    vhk="linux-headers-$(uname -r)"
    if apt-cache show "$vhk" >/dev/null 2>&1; then
      apt_install "$vhk" virtualbox-guest-dkms build-essential
    else
      warn "no matching $vhk package - skipping virtualbox-guest-dkms (guest utils may need a reboot to load)"
    fi
    ok "VirtualBox guest tools installed"
  elif [[ "$VM_KIND" == "vmware" ]]; then
    log "Detected VMware - installing open-vm-tools"
    apt_install open-vm-tools-desktop
    ok "VMware guest tools installed"
  else
    warn "No VirtualBox/VMware hypervisor detected (${virt:-none}) - skipping guest tools"
  fi
fi

# =============================================================================
# 1. Base system packages
# =============================================================================
if [[ "$MODE" == "all" || "$DO_IOS" == "1" || "$DO_ANDROID" == "1" || "$DO_WEB" == "1" || "$DO_UTILS" == "1" ]]; then
  section "Installing base system packages"
  apt-get update -y || true
  apt_install \
    git curl wget unzip zip xz-utils jq gnupg ca-certificates \
    build-essential python3 python3-pip python3-venv \
    squashfs-tools \
    ruby-full \
    usbutils usbmuxd libimobiledevice-utils libusb-1.0-0-dev \
    android-tools-adb scrcpy sqlitebrowser apktool radare2 zaproxy ghidra \
    openssh-client net-tools python3-tk tmux adb

  # 7z for AppImage extraction (package is '7zip' on Kali, 'p7zip-full' on Debian)
  z7="$(apt_pick 7zip p7zip-full || true)"
  [[ -n "$z7" ]] && apt_install "$z7"

  # JDK for jadx / Android Studio tooling (17 is gone from Kali; try 21/25 first)
  local_jdk="$(apt_pick openjdk-21-jdk-headless openjdk-25-jdk-headless openjdk-17-jdk-headless default-jdk-headless)"
  if [[ -n "$local_jdk" ]]; then
    apt_install "$local_jdk"
  else
    warn "no JDK package found - jadx/Android tooling may lack a JVM"
  fi

  if [[ "$DO_VENV" == "1" ]]; then
    section "Creating shared Python venv: $VENV"
    python3 -m venv "$VENV"
    "${VENV}/bin/pip" install --upgrade pip wheel setuptools || true
  fi

  # Install the 'mobpen' management CLI.
  # From a repo checkout we symlink directly. When run via `curl | sudo bash`
  # there is no checkout, so clone the repo to a persistent location first.
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd 2>/dev/null || true)"
  if [[ -z "$repo_dir" || ! -f "$repo_dir/mobpen" ]]; then
    repo_dir="$LAB_ROOT/mobpen-lab"
    if [[ ! -d "$repo_dir" ]]; then
      log "Cloning mobpen-lab repo to $repo_dir (for the 'mobpen' CLI)"
      rm -rf "$repo_dir"
      git clone -q --depth 1 https://github.com/djzzlim/mobpen-lab.git "$repo_dir" \
        || repo_dir=""
    fi
  fi
  if [[ -n "$repo_dir" && -f "$repo_dir/mobpen" ]]; then
    ln -sf "$repo_dir/mobpen" /usr/local/bin/mobpen
    ok "installed 'mobpen' CLI -> /usr/local/bin/mobpen (from $repo_dir)"
  else
    warn "could not install 'mobpen' CLI - clone https://github.com/djzzlim/mobpen-lab and symlink its 'mobpen' into /usr/local/bin"
  fi
fi

# =============================================================================
# 2. iOS Security & Jailbreak Tools
# =============================================================================
install_ios() {
  section "iOS tools"

# --- checkra1n (deprecated) ---
  # checkra1n is unmaintained (last release 0.12.4, 2021) and its binary needs
  # legacy libs (libncurses5, libgdk-pixbuf2.0-0, libirecovery-1.0.so.3) that
  # modern distros no longer ship, so it cannot run here. Remove any stale
  # install and point the user at palera1n, which this script installs.
  log "checkra1n (removing - deprecated, superseded by palera1n)"
  rm -f /usr/local/bin/checkra1n
  rm -rf /opt/mobpen-lab/ios/checkra1n
  rm -f /etc/apt/sources.list.d/checkra1n.list
  rm -f /usr/share/keyrings/checkra1n.gpg
  DEBIAN_FRONTEND=noninteractive apt-get purge -y checkra1n >/dev/null 2>&1 || true
  warn "checkra1n is deprecated (last release 2021) and requires legacy libs that Kali no longer ships."
  warn "Use 'palera1n' (installed by this script) for iOS 15-17 checkm8/A8+ devices."

  # --- palera1n (GitHub latest release) ---
  log "palera1n"
  if command -v palera1n >/dev/null 2>&1; then
    ok "palera1n already installed"
  else
    local p_url
    p_url="$(gh_latest_asset palera1n/palera1n "palera1n-linux-${PA_ARCH}\$" || true)"
    if [[ -n "$p_url" ]]; then
      curl -fL "$p_url" -o /usr/local/bin/palera1n && chmod +x /usr/local/bin/palera1n
      ok "palera1n -> /usr/local/bin/palera1n"
    else
      warn "could not resolve palera1n release asset; grab it from https://github.com/palera1n/palera1n/releases"
    fi
  fi

  # --- Frida ---
  log "Frida (frida-tools)"
  if [[ "$DO_VENV" == "1" ]]; then
    "${VENV}/bin/pip" install -q frida-tools || warn "frida-tools install failed"
    link_bin frida
    link_bin frida-ps
    link_bin frida-trace
    link_bin frida-join
    # frida-inject is no longer shipped by the frida-tools pip package;
    # grab the standalone binary from the matching frida release instead.
    if [[ ! -x "${VENV}/bin/frida-inject" && ! -x /usr/local/bin/frida-inject ]]; then
      local inj_url
      inj_url="$(gh_latest_asset frida/frida "frida-inject-.*-linux-${FRIDA_ARCH}\.xz\$" || true)"
      if [[ -n "$inj_url" ]]; then
        fetch "$inj_url" "$LAB_TMP/frida-inject.xz" && {
          xz -dkf "$LAB_TMP/frida-inject.xz"
          if [[ -f "$LAB_TMP/frida-inject" ]]; then
            mv "$LAB_TMP/frida-inject" /usr/local/bin/frida-inject
            chmod +x /usr/local/bin/frida-inject
            ok "frida-inject -> /usr/local/bin/frida-inject"
          else
            warn "frida-inject extraction failed"
          fi
        } || warn "frida-inject download failed - grab it from https://github.com/frida/frida/releases"
      else
        warn "could not resolve frida-inject release"
      fi
    fi
  else
    pip3 install --break-system-packages frida-tools || warn "frida-tools install failed"
  fi

  # --- Grapefruit (npm: igf) ---
  log "Grapefruit (igf) - requires Node.js 22.18+"
  if command -v igf >/dev/null 2>&1; then
    ok "igf (Grapefruit) already installed"
  else
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1)" -lt 22 ]]; then
      log "Installing Node.js 22 via NodeSource"
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash - || warn "NodeSource setup failed"
      apt_install nodejs
    fi
    if command -v node >/dev/null 2>&1; then
      npm install -g igf || warn "npm install -g igf failed"
      # npm 11+ blocks postinstall scripts (frida / better-sqlite3 native builds)
      # unless approved; approve pending scripts and rebuild so igf's binary exists.
      npm approve-scripts --allow-scripts-pending >/dev/null 2>&1 || true
      npm rebuild -g igf >/dev/null 2>&1 || true
      if ! command -v igf >/dev/null 2>&1; then
        local igf_bin
        igf_bin="$(npm prefix -g 2>/dev/null)/bin/igf"
        [[ -x "$igf_bin" ]] && ln -sf "$igf_bin" /usr/local/bin/igf
      fi
      command -v igf >/dev/null 2>&1 && ok "igf (Grapefruit) installed" || warn "igf binary not found on PATH - run: npm approve-scripts --allow-scripts-pending && npm rebuild -g igf"
    else
      warn "Node.js unavailable - install manually then: npm install -g igf"
    fi
  fi

  # --- Radare2 ---
  log "Radare2"
  command -v r2 >/dev/null 2>&1 && ok "r2 already installed" || { apt_install radare2; command -v r2 >/dev/null 2>&1 && ok "r2 installed"; }

  # --- frida-ios-dump ---
  log "frida-ios-dump"
  if [[ -d "$LAB_IOS/frida-ios-dump" ]]; then
    ok "frida-ios-dump already cloned"
  else
    git clone --depth 1 https://github.com/AloneMonkey/frida-ios-dump "$LAB_IOS/frida-ios-dump" 2>/dev/null \
      && ok "frida-ios-dump -> $LAB_IOS/frida-ios-dump" \
      || warn "frida-ios-dump clone failed"
  fi

  # --- bfinject ---
  log "bfinject"
  if [[ -d "$LAB_IOS/bfinject" ]]; then
    ok "bfinject already cloned"
  else
    git clone --depth 1 https://github.com/BishopFox/bfinject "$LAB_IOS/bfinject" 2>/dev/null \
      && ok "bfinject -> $LAB_IOS/bfinject" || warn "bfinject clone failed"
  fi

  # --- SSL Kill Switch 2 ---
  log "SSL Kill Switch 2"
  if [[ -d "$LAB_IOS/ssl-kill-switch2" ]]; then
    ok "ssl-kill-switch2 already cloned"
  else
    git clone --depth 1 https://github.com/nabla-c0d3/ssl-kill-switch2 "$LAB_IOS/ssl-kill-switch2" 2>/dev/null \
      && ok "ssl-kill-switch2 -> $LAB_IOS/ssl-kill-switch2" || warn "ssl-kill-switch2 clone failed"
  fi

  # --- Needle (archived; objection is the modern successor) ---
  log "Needle (iOS security testing framework)"
  if [[ -d "$LAB_IOS/needle" ]]; then
    ok "needle already cloned"
  else
    git clone --depth 1 https://github.com/WithSecureLabs/needle "$LAB_IOS/needle" 2>/dev/null \
      && ok "needle -> $LAB_IOS/needle (note: archived, use objection on modern iOS)" \
      || warn "needle clone failed"
  fi

  # --- ipsw (Mach-O / dyld analysis + class-dump; native Linux) ---
  # Replaces macOS-only tools: ipsw class-dump (ObjC+Swift headers),
  # ipsw macho (load commands, entitlements, symbols) ~ jtool2/otool.
  log "ipsw (Mach-O analysis + class-dump, Linux-native)"
  if command -v ipsw >/dev/null 2>&1; then
    ok "ipsw already installed"
  else
    local ipsw_url
    ipsw_url="$(gh_latest_asset blacktop/ipsw "ipsw_[0-9].*_linux_${PA_ARCH}\.tar\.gz\$" || true)"
    if [[ -n "$ipsw_url" ]]; then
      fetch "$ipsw_url" "$LAB_TMP/ipsw.tar.gz" && {
        mkdir -p "$LAB_TMP/ipsw-x"
        tar xzf "$LAB_TMP/ipsw.tar.gz" -C "$LAB_TMP/ipsw-x" 2>/dev/null
        local ipsw_bin
        ipsw_bin="$(find "$LAB_TMP/ipsw-x" -maxdepth 1 -type f -name ipsw -print -quit)"
        if [[ -n "$ipsw_bin" ]]; then
          mv "$ipsw_bin" /usr/local/bin/ipsw
          chmod +x /usr/local/bin/ipsw
          ok "ipsw -> /usr/local/bin/ipsw (class-dump/jtool2 replacement)"
        else
          warn "ipsw binary not found inside archive"
        fi
        rm -rf "$LAB_TMP/ipsw-x"
      } || warn "ipsw download failed - manual: https://github.com/blacktop/ipsw/releases"
    else
      warn "could not resolve ipsw release; manual: https://github.com/blacktop/ipsw/releases"
    fi
  fi

  # --- ktool / k2l (pure-Python Mach-O/ObjC toolkit; class-dump style) ---
  log "ktool (k2l)"
  if command -v ktool >/dev/null 2>&1; then
    ok "ktool already installed"
  elif [[ "$DO_VENV" == "1" ]]; then
    "${VENV}/bin/pip" install -q k2l 'setuptools<81' || warn "k2l install failed"
    link_bin ktool
    [[ -x "${VENV}/bin/ktool_bless" ]] && link_bin ktool_bless
  else
    pip3 install --break-system-packages k2l 'setuptools<81' || warn "k2l install failed"
  fi

  # --- class-dump source kept for reference / building on a Mac ---
  log "class-dump (source kept for reference)"
  if [[ -d "$LAB_IOS/class-dump" ]]; then
    ok "class-dump source already present (native analysis via ipsw/ktool above)"
  else
    git clone --depth 1 https://github.com/nygard/class-dump "$LAB_IOS/class-dump" 2>/dev/null \
      && ok "class-dump source -> $LAB_IOS/class-dump (needs macOS/GNUstep+libobjc2 to build)" \
      || warn "class-dump clone failed"
  fi

  ok "iOS section complete"
}

# =============================================================================
# 3. Android Security & Reverse Engineering
# =============================================================================
install_android() {
  section "Android tools"

  # --- Android Studio (latest stable, resolved dynamically) ---
  log "Android Studio (latest stable)"
  if [[ -d /opt/android-studio ]]; then
    ok "Android Studio already at /opt/android-studio"
  elif [[ "$ARCH" != "x86_64" ]]; then
    warn "Android Studio Linux build is x86_64-only; skipping on $ARCH"
  else
    local as_url
    as_url="$(curl -fsSL --max-time 20 https://developer.android.com/studio \
              | grep -oE 'https://[^"]*android-studio[^"]*linux\.tar\.gz' | head -n1 || true)"
    if [[ -z "$as_url" ]]; then
      warn "could not resolve latest Android Studio link; falling back to Koala 2024.1.1"
      as_url="https://redirector.gvt1.com/edgedl/android/studio/ide-zips/2024.1.1.13/android-studio-2024.1.1.13-linux.tar.gz"
    fi
    log "Downloading $as_url"
    if fetch "$as_url" /tmp/android-studio.tar.gz; then
      tar -xzf /tmp/android-studio.tar.gz -C /opt
      ln -sf /opt/android-studio/bin/studio.sh /usr/local/bin/studio
      cat > /usr/share/applications/android-studio.desktop <<'EOF'
[Desktop Entry]
Name=Android Studio
Comment=Android IDE (latest stable)
Exec=/opt/android-studio/bin/studio.sh
Icon=/opt/android-studio/bin/studio.png
Terminal=false
Type=Application
Categories=Development;IDE;
EOF
      ok "Android Studio installed (launch with 'studio')"
    else
      warn "Android Studio download failed - manual: https://developer.android.com/studio"
    fi
  fi

  # --- jadx ---
  log "jadx / jadx-gui"
  if command -v jadx >/dev/null 2>&1; then
    ok "jadx already installed"
  else
    local j_url
    j_url="$(gh_latest_asset skylot/jadx 'jadx-[0-9][^/]*\.zip$' || true)"
    if [[ -n "$j_url" ]]; then
      fetch "$j_url" /tmp/jadx.zip && {
        rm -rf /opt/jadx && mkdir -p /opt/jadx && unzip -oq /tmp/jadx.zip -d /opt/jadx
        local jadir
        jadir="$(find /opt/jadx -maxdepth 2 -type d -name bin -print -quit)"
        if [[ -n "$jadir" ]]; then
          ln -sf "$jadir/jadx" /usr/local/bin/jadx
          ln -sf "$jadir/jadx-gui" /usr/local/bin/jadx-gui
          ok "jadx installed"
        else
          warn "jadx bin dir not found after extraction"
        fi
      } || warn "jadx download/install failed"
    else
      warn "could not resolve jadx release; manual: https://github.com/skylot/jadx/releases"
    fi
  fi

  # --- dex2jar / dex-tools ---
  log "dex-tools (dex2jar)"
  # Reinstall when the binary is missing OR /opt/dex-tools exists but contains
  # no d2j-*.sh (e.g. a broken dir left over from a failed first run).
  if ! command -v d2j-dex2jar.sh >/dev/null 2>&1 \
     && { [[ ! -d /opt/dex-tools ]] || ! find /opt/dex-tools -name 'd2j-*.sh' -type f 2>/dev/null | grep -q .; }; then
    local d_url dd
    d_url="$(gh_latest_asset pxb1988/dex2jar 'dex-tools-.*\.zip$' || true)"
    if [[ -n "$d_url" ]]; then
      fetch "$d_url" /tmp/dex-tools.zip && {
        rm -rf /tmp/dex-tools-x && mkdir -p /tmp/dex-tools-x
        unzip -oq /tmp/dex-tools.zip -d /tmp/dex-tools-x || { warn "dex-tools unzip failed"; false; }
        dd="$(find /tmp/dex-tools-x -mindepth 1 -maxdepth 1 -type d -name 'dex-tools-*' -print -quit)"
        if [[ -n "$dd" && -d "$dd" ]]; then
          rm -rf /opt/dex-tools
          mv "$dd" /opt/dex-tools
          ok "dex-tools installed at /opt/dex-tools"
        else
          warn "dex-tools dir not found inside archive"; false
        fi
      } || warn "dex2jar download/install failed"
    else
      warn "could not resolve dex2jar release; manual: https://github.com/pxb1988/dex2jar/releases"
    fi
  else
    ok "dex-tools already installed"
  fi
  # Ensure d2j-* shims are on PATH. Layout varies (flat or nested under
  # /opt/dex-tools); clear stale links first, then link whatever exists.
  rm -f /usr/local/bin/d2j-*.sh 2>/dev/null
  local n_d2j=0
  while IFS= read -r d2j; do
    [[ -e "$d2j" ]] && { ln -sf "$d2j" "/usr/local/bin/$(basename "$d2j")"; n_d2j=$((n_d2j+1)); }
  done < <(find /opt/dex-tools -name 'd2j-*.sh' -type f 2>/dev/null)
  if [[ "$n_d2j" -gt 0 ]] && command -v d2j-dex2jar.sh >/dev/null 2>&1; then
    ok "d2j-* shims on PATH ($n_d2j linked)"
  else
    warn "no d2j-*.sh found under /opt/dex-tools (manual: symlink them into /usr/local/bin)"
  fi

  # --- apksigner (APK signing/verification) ---
  log "apksigner"
  command -v apksigner >/dev/null 2>&1 && ok "apksigner already installed" || { apt_install apksigner; command -v apksigner >/dev/null 2>&1 && ok "apksigner installed" || warn "apksigner not available (try 'apt install apksigner')"; }

  # --- adb + fastboot (device tooling; package names differ across distros) ---
  log "adb / fastboot"
  local ab_pkg fb_pkg
  ab_pkg="$(apt_pick adb android-tools-adb || true)"
  fb_pkg="$(apt_pick fastboot android-tools-fastboot || true)"
  for pkg in "$ab_pkg" "$fb_pkg"; do
    [[ -n "$pkg" ]] && apt_install "$pkg"
  done
  command -v adb >/dev/null 2>&1 && ok "adb installed" || warn "adb not on PATH"
  command -v fastboot >/dev/null 2>&1 && ok "fastboot installed" || warn "fastboot not on PATH"

  # --- zipalign (APK zip alignment for release signing) ---
  log "zipalign"
  command -v zipalign >/dev/null 2>&1 && ok "zipalign already installed" || { apt_install zipalign; command -v zipalign >/dev/null 2>&1 && ok "zipalign installed" || warn "zipalign unavailable"; }

  # --- keytool / jarsigner (JDK signing tooling, shipped with the JDK) ---
  log "keytool / jarsigner"
  if command -v keytool >/dev/null 2>&1 && command -v jarsigner >/dev/null 2>&1; then
    ok "keytool + jarsigner present (JDK)"
  else
    local jdk_extra
    jdk_extra="$(apt_pick openjdk-21-jdk-headless openjdk-25-jdk-headless openjdk-17-jdk-headless default-jdk-headless || true)"
    [[ -n "$jdk_extra" ]] && apt_install "$jdk_extra"
    command -v keytool >/dev/null 2>&1 && command -v jarsigner >/dev/null 2>&1 \
      && ok "keytool + jarsigner present after JDK install" \
      || warn "keytool/jarsigner not found - install a JDK (e.g. openjdk-21-jdk-headless)"
  fi

  # --- objection ---
  log "objection"
  if command -v objection >/dev/null 2>&1; then
    ok "objection already installed"
  elif [[ "$DO_VENV" == "1" ]]; then
    "${VENV}/bin/pip" install -q objection || warn "objection install failed"
    link_bin objection
  else
    pip3 install --break-system-packages objection || warn "objection install failed"
  fi

  # --- Flutter reverse-engineering tools ---
  log "reFlutter (Flutter SSL pinning bypass / engine patching)"
  if command -v reflutter >/dev/null 2>&1; then
    ok "reflutter already installed"
  elif [[ "$DO_VENV" == "1" ]]; then
    "${VENV}/bin/pip" install -q reflutter || warn "reflutter install failed"
    link_bin reflutter
  else
    pip3 install --break-system-packages reflutter || warn "reflutter install failed"
  fi

  log "kill_flutter (dynamic Flutter SSL pinning bypass, works on any Flutter version)"
  if [[ -x "$LAB_FLUTTER/kill_flutter/kill_flutter.py" ]]; then
    ok "kill_flutter already installed"
  else
    git clone --depth 1 https://github.com/f3rb123/kill_flutter "$LAB_FLUTTER/kill_flutter" 2>/dev/null \
      && { chmod +x "$LAB_FLUTTER/kill_flutter/kill_flutter.py"; ln -sf "$LAB_FLUTTER/kill_flutter/kill_flutter.py" /usr/local/bin/kill_flutter; ok "kill_flutter installed"; } \
      || warn "kill_flutter clone failed (requires frida-tools + aapt, both installed above)"
  fi

  # --- pidcat ---
  log "pidcat"
  if command -v pidcat >/dev/null 2>&1; then
    ok "pidcat already installed"
  else
    if [[ -d "$LAB_ANDROID/pidcat" ]]; then
      ok "pidcat already cloned"
    else
      git clone --depth 1 https://github.com/JakeWharton/pidcat "$LAB_ANDROID/pidcat" 2>/dev/null || warn "pidcat clone failed"
    fi
    [[ -f "$LAB_ANDROID/pidcat/pidcat.py" ]] && { chmod +x "$LAB_ANDROID/pidcat/pidcat.py"; ln -sf "$LAB_ANDROID/pidcat/pidcat.py" /usr/local/bin/pidcat; ok "pidcat installed"; }
  fi

  # --- scrcpy ---
  log "scrcpy"
  command -v scrcpy >/dev/null 2>&1 && ok "scrcpy already installed" || { apt_install scrcpy; }

  # --- Frida Gadget (match installed frida version) ---
  log "Frida Gadget (.so for repackaging APKs)"
  if [[ -f "$LAB_ANDROID/frida-gadget/frida-gadget.so" ]]; then
    ok "frida-gadget already present"
  else
    local g_url
    g_url="$(gh_latest_asset frida/frida "frida-gadget-.*-linux-${FRIDA_ARCH}\.so\.xz" || true)"
    if [[ -n "$g_url" ]]; then
      mkdir -p "$LAB_ANDROID/frida-gadget"
      fetch "$g_url" /tmp/frida-gadget.so.xz && {
        xz -dkf /tmp/frida-gadget.so.xz
        mv /tmp/frida-gadget.so "$LAB_ANDROID/frida-gadget/frida-gadget.so"
        ok "frida-gadget -> $LAB_ANDROID/frida-gadget/frida-gadget.so"
      } || warn "frida-gadget download failed"
    else
      warn "could not resolve frida-gadget; manual: https://github.com/frida/frida/releases"
    fi
  fi

  # --- APKLeaks ---
  log "APKLeaks"
  if command -v apkleaks >/dev/null 2>&1; then
    ok "apkleaks already installed"
  elif [[ "$DO_VENV" == "1" ]]; then
    "${VENV}/bin/pip" install -q apkleaks || warn "apkleaks install failed"
    link_bin apkleaks
  else
    pip3 install --break-system-packages apkleaks || warn "apkleaks install failed"
  fi

  # --- Androguard ---
  log "Androguard"
  if command -v androguard >/dev/null 2>&1 || python3 -c 'import androguard' 2>/dev/null; then
    ok "androguard already installed"
  elif [[ "$DO_VENV" == "1" ]]; then
    "${VENV}/bin/pip" install -q androguard || warn "androguard install failed"
    link_bin androguard
  else
    pip3 install --break-system-packages androguard || warn "androguard install failed"
  fi

  # --- QARK ---
  log "QARK"
  if command -v qark >/dev/null 2>&1; then
    ok "qark already installed"
  elif [[ "$DO_VENV" == "1" ]]; then
    "${VENV}/bin/pip" install -q qark || warn "qark install failed (it is unmaintained; install manually if needed)"
    link_bin qark
  else
    pip3 install --break-system-packages qark || warn "qark install failed"
  fi

  # --- Drozer ---
  log "Drozer"
  if command -v drozer >/dev/null 2>&1; then
    ok "drozer already installed"
  elif [[ "$DO_VENV" == "1" ]]; then
    "${VENV}/bin/pip" install -q drozer || warn "drozer pip install failed - install manually: https://github.com/WithSecureLabs/drozer"
    link_bin drozer
  else
    pip3 install --break-system-packages drozer || warn "drozer install failed"
  fi

  ok "Android section complete"
}

# =============================================================================
# 4. Web & Network Pentesting
# =============================================================================
install_web() {
  section "Web & network tools"

  # --- Burp Suite Community (JAR-based, non-interactive) ---
  log "Burp Suite Community Edition"
  if [[ -f /opt/burpsuite/burpsuite_community.jar ]]; then
    ok "Burp Suite jar already downloaded"
  else
    mkdir -p /opt/burpsuite
    if fetch "https://portswigger.net/burp/releases/download?product=community&type=jar" /opt/burpsuite/burpsuite_community.jar; then
      ok "Burp Suite jar downloaded"
    else
      warn "Burp Suite download failed - manual: https://portswigger.net/burp/communitydownload"
    fi
  fi
  cat > /usr/local/bin/burpsuite <<'EOF'
#!/usr/bin/env bash
exec java -jar /opt/burpsuite/burpsuite_community.jar "$@"
EOF
  chmod +x /usr/local/bin/burpsuite
  cat > /usr/share/applications/burpsuite.desktop <<'EOF'
[Desktop Entry]
Name=Burp Suite Community
Comment=Intercepting web proxy
Exec=burpsuite
Icon=java
Terminal=false
Type=Application
Categories=Development;Security;
EOF
  ok "burpsuite launcher installed"

  # --- Runtime Mobile Security (RMS) ---
  log "Runtime Mobile Security (RMS)"
  if command -v rms >/dev/null 2>&1 || [[ -d "$LAB_WEB/rms" ]]; then
    ok "rms already present"
  elif git ls-remote --heads https://github.com/m0bilesecurity/RMS-Runtime-Mobile-Security >/dev/null 2>&1; then
    git clone --depth 1 https://github.com/m0bilesecurity/RMS-Runtime-Mobile-Security "$LAB_WEB/rms" 2>/dev/null \
      && ok "rms -> $LAB_WEB/rms" || warn "rms clone failed"
  else
    warn "RMS repo unreachable - install manually: git clone https://github.com/m0bilesecurity/RMS-Runtime-Mobile-Security"
  fi
  if [[ -d "$LAB_WEB/rms" && -f "$LAB_WEB/rms/requirements.txt" ]]; then
    if [[ "$DO_VENV" == "1" ]]; then
      "${VENV}/bin/pip" install -q -r "$LAB_WEB/rms/requirements.txt" 2>/dev/null \
        && { ln -sf "${VENV}/bin/rms" /usr/local/bin/rms 2>/dev/null; ok "rms dependencies installed"; } \
        || warn "rms requirements failed to install - see README at $LAB_WEB/rms"
    fi
  fi

  # --- OWASP ZAP ---
  log "OWASP ZAP"
  command -v zaproxy >/dev/null 2>&1 && ok "zaproxy already installed" || { apt_install zaproxy; }

  ok "Web section complete"
}

# =============================================================================
# 5. Utilities & Frameworks
# =============================================================================
install_utils() {
  section "Utilities"

  # --- Ghidra ---
  log "Ghidra"
  if command -v ghidraRun >/dev/null 2>&1 || [[ -d /opt/ghidra ]] || ls -d /usr/share/ghidra >/dev/null 2>&1; then
    ok "ghidra already installed"
  else
    apt_install ghidra
    command -v ghidraRun >/dev/null 2>&1 || ls -d /usr/share/ghidra >/dev/null 2>&1 && ok "ghidra installed" || warn "ghidra install failed"
  fi

  # --- Termius ---
  log "Termius"
  if command -v termius-app >/dev/null 2>&1 || dpkg -s termius-app >/dev/null 2>&1; then
    ok "termius already installed"
  else
    if fetch "https://www.termius.com/download/linux/Termius.deb" /tmp/Termius.deb; then
      DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/Termius.deb >/dev/null 2>&1 \
        || apt-get -f install -y >/dev/null 2>&1 \
        || warn "termius dpkg install failed - try: dpkg -i /tmp/Termius.deb"
      command -v termius-app >/dev/null 2>&1 && ok "termius installed"
    else
      warn "termius download failed"
    fi
  fi

  # --- DB Browser for SQLite ---
  log "DB Browser for SQLite"
  command -v sqlitebrowser >/dev/null 2>&1 && ok "sqlitebrowser already installed" || apt_install sqlitebrowser

  # --- Apktool ---
  log "Apktool"
  command -v apktool >/dev/null 2>&1 && ok "apktool already installed" || apt_install apktool

  # --- Cutter (radare2/rizin GUI) via AppImage, extracted to avoid FUSE ---
  log "Cutter (radare2/rizin GUI)"
  if command -v cutter >/dev/null 2>&1 || [[ -x "$LAB_BIN/cutter/AppRun" ]]; then
    ok "cutter already installed"
  else
    local cut_url cut_ext cut_dir cut_ok fuse_pkg
    cut_url="$(gh_latest_asset rizinorg/cutter 'Cutter-v[0-9].*Linux.*x86_64\.AppImage$' || true)"
    if [[ -n "$cut_url" ]]; then
      fetch "$cut_url" "$LAB_TMP/cutter.AppImage" && {
        chmod +x "$LAB_TMP/cutter.AppImage"
        # Best-effort libfuse2 (needed only by --appimage-extract). Kali usually
        # has neither libfuse2 nor libfuse2t64 - that is fine, 7z handles the
        # type-1 AppImage without it.
        fuse_pkg="$(apt_pick libfuse2t64 libfuse2 || true)"
        [[ -n "$fuse_pkg" ]] && { apt_install "$fuse_pkg" || warn "no libfuse2 available - using 7z extraction"; }
        cut_ext="$LAB_TMP/cutter-ext"
        rm -rf "$cut_ext" && mkdir -p "$cut_ext"
        cut_ok=0; cut_dir=""
        # 7z first: dependency-free and handles type-1 AppImages.
        if command -v 7z >/dev/null 2>&1; then
          ( cd "$cut_ext" && 7z x -y "$LAB_TMP/cutter.AppImage" >/dev/null 2>&1 ) \
            && [[ -f "$cut_ext/AppRun" ]] && { cut_dir="$cut_ext"; cut_ok=1; }
        fi
        # Official --appimage-extract (works when libfuse2 is present)
        if [[ "$cut_ok" == "0" ]] \
           && ( cd "$cut_ext" && "$LAB_TMP/cutter.AppImage" --appimage-extract >/dev/null 2>&1 ) \
           && [[ -d "$cut_ext/squashfs-root" ]]; then
          cut_dir="$cut_ext/squashfs-root"; cut_ok=1
        fi
        # Last resort: unsquashfs (type-2 AppImages)
        if [[ "$cut_ok" == "0" ]] && command -v unsquashfs >/dev/null 2>&1; then
          unsquashfs -q -d "$cut_ext/squashfs-root" "$LAB_TMP/cutter.AppImage" >/dev/null 2>&1 \
            && [[ -f "$cut_ext/squashfs-root/AppRun" ]] && { cut_dir="$cut_ext/squashfs-root"; cut_ok=1; }
        fi
        if [[ "$cut_ok" == "1" && -x "$cut_dir/AppRun" ]]; then
          rm -rf "$LAB_BIN/cutter"
          mv "$cut_dir" "$LAB_BIN/cutter"
          ln -sf "$LAB_BIN/cutter/AppRun" /usr/local/bin/cutter
          ok "cutter -> /usr/local/bin/cutter"
        else
          warn "cutter extraction failed - manual: https://github.com/rizinorg/cutter/releases (extract the AppImage, symlink AppRun)"
        fi
        rm -rf "$cut_ext" "$LAB_TMP/cutter.AppImage"
      } || warn "cutter download failed - manual: https://github.com/rizinorg/cutter/releases"
    else
      warn "could not resolve cutter release; manual: https://github.com/rizinorg/cutter/releases"
    fi
  fi

  ok "Utilities section complete"
}

# =============================================================================
# 6. Docker + MobSF service
# =============================================================================
install_docker() {
  section "Docker"

  if command -v docker >/dev/null 2>&1; then
    ok "docker already installed"
  elif [[ "$(. /etc/os-release; echo "$ID")" == "kali" ]]; then
    # get.docker.com generates a debian repo for kali-rolling which does not
    # exist upstream; Kali ships docker.io in its own repos - use that.
    log "Kali detected - installing docker.io from Kali repos"
    apt_install docker.io docker-compose
    command -v docker >/dev/null 2>&1 || { apt-get install -y docker.io; }
  else
    log "Installing Docker via get.docker.com"
    fetch https://get.docker.com /tmp/get-docker.sh && sh /tmp/get-docker.sh \
      || { warn "get.docker.com failed, falling back to apt docker.io"; apt_install docker.io docker-compose; }
  fi

  systemctl enable --now docker 2>/dev/null || warn "could not enable docker service"
  command -v docker >/dev/null 2>&1 && ok "docker $(docker --version | awk '{print $3}' | tr -d ',')" || die "docker install failed"

  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER"
    ok "added $SUDO_USER to the docker group (log out/in for it to apply)"
  fi

  section "MobSF (Dockerized) as a systemd service"

  log "Pulling MobSF image (this is ~1GB, may take a while)"
  docker pull opensecurity/mobile-security-framework-mobsf:latest || warn "MobSF image pull failed"

  log "Writing systemd unit /etc/systemd/system/mobsf.service"
  cat > /etc/systemd/system/mobsf.service <<'EOF'
[Unit]
Description=MobSF - Mobile Security Framework (Docker)
Documentation=https://mobsf.github.io/docs
Wants=docker.service
After=docker.service network-online.target
Requires=docker.service

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f mobsf
ExecStartPre=/usr/bin/docker pull opensecurity/mobile-security-framework-mobsf:latest
ExecStart=/usr/bin/docker run --name mobsf --rm \
    -p 8000:8000 \
    -p 1337:1337 \
    --add-host=host.docker.internal:host-gateway \
    -v mobsf_data:/root/.MobSF \
    opensecurity/mobile-security-framework-mobsf:latest
ExecStop=/usr/bin/docker stop -t 15 mobsf

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable mobsf.service
  systemctl restart mobsf.service
  sleep 3
  if systemctl is-active --quiet mobsf; then
    ok "MobSF service is running"
  else
    warn "MobSF service not active yet - check: systemctl status mobsf / journalctl -u mobsf -f"
  fi
}

# =============================================================================
# 7. Documentation (regenerates README files in each lab folder)
# =============================================================================
write_docs() {
  section "Documenting lab layout"

  # --- shared header used by every README ---
  local header
  header="# Mobile Security Lab"
  cat > "$LAB_ROOT/README.md" <<EOF
# Mobile Security & Reverse-Engineering Lab

Everything installed by \`install.sh\` lives under this folder,
grouped by category. Command-line tools are symlinked into \`/usr/local/bin\`.

## Layout

\`\`\`
$LAB_ROOT
├── README.md                <- you are here
├── ios/                     <- iOS jailbreak / instrumentation / RE sources
├── android/                 <- Android reverse-engineering sources & gadgets
├── web/                     <- web / network pentesting sources
├── flutter/                 <- Flutter reverse-engineering tools
├── bin/                     <- convenience launchers / helper scripts
└── docs/                    <- generated documentation (TOOLS.md, ...)
\`\`\`

## Categories

| Folder      | Contents |
|-------------|----------|
| \`ios/\`       | palera1n, Frida, Grapefruit (igf), frida-ios-dump, bfinject, SSL-Kill-Switch-2, needle, ipsw, ktool, class-dump (source), Radare2 |
| \`android/\`   | Android Studio, jadx, dex-tools, apksigner, keytool/jarsigner, zipalign, adb/fastboot, objection, pidcat, scrcpy, frida-gadget, APKLeaks, Androguard, QARK, Drozer |
| \`flutter/\`   | reFlutter, kill_flutter |
| \`web/\`       | Burp Suite Community, RMS, OWASP ZAP |
| \`utils/\`     | Ghidra, Cutter (radare2/rizin GUI), Termius, DB Browser for SQLite, Apktool, Radare2 |

## Related locations

- Python venv (all pip-based tools): \`/opt/mobile-sec-venv\`
- MobSF service: \`systemctl status mobsf\` -> http://127.0.0.1:8000 (\`mobsf\`/\`mobsf\`)
- Full command reference: \`docs/TOOLS.md\`

See each category README for details.
EOF

  cat > "$LAB_IOS/README.md" <<'EOF'
# ios/ - iOS Security & Jailbreak Tools

| Tool | Type | Notes |
|------|------|-------|
| palera1n | binary | `palera1n` - jailbreak iOS 15-18 on checkm8 devices. `palera1n --help` (replaces deprecated checkra1n) |
| frida | pip (venv) | `frida`, `frida-ps`, `frida-trace` - dynamic instrumentation. Needs frida-server on device |
| Grapefruit | npm (igf) | `igf` - web UI (port 31337) over Frida. Requires Node 22.18+ and frida-server |
| frida-ios-dump | source | `./dump.py <app>` - dump decrypted IPA from jailbroken device. Edit `dump.py` first |
| bfinject | source | inject dylibs into running iOS processes (iOS < 11) |
| ssl-kill-switch2 | source | disable SSL validation / pinning in iOS apps (build & install on device via theos/Sileo) |
| needle | source | iOS assessment framework - ARCHIVED, use objection |
| ipsw | binary | `ipsw class-dump <bin> --headers -o dir` (ObjC+Swift headers), `ipsw macho -l/-e <bin>` - Linux-native class-dump/jtool2 replacement |
| ktool | pip (venv) | `ktool dump --headers --out dir <bin>`, `ktool info/lists/objc` - pure-Python Mach-O/ObjC toolkit |
| class-dump | source | original ObjC header dumper - needs macOS or GNUstep+libobjc2 to build; on Linux use ipsw/ktool |
| radare2 | apt binary | \`r2\` - binary analysis / disassembly |

### Typical workflow
1. Jailbreak with `palera1n`
2. Run frida-server on device, install `frida-tools` on host
3. `objection -g <app> explore` for runtime manipulation / SSL-pinning bypass
4. `frida-ios-dump/dump.py <bundle-id>` to grab a decrypted IPA for static analysis
EOF

  cat > "$LAB_ANDROID/README.md" <<'EOF'
# android/ - Android Reverse-Engineering Tools

| Tool | Type | Notes |
|------|------|-------|
| Android Studio | binary | `studio` - IDE; includes SDK, emulator (dynamic analysis) |
| jadx / jadx-gui | binary | decompile APK -> Java source. `jadx app.apk` / `jadx-gui` |
| dex-tools | binary | `d2j-dex2jar.sh`, `d2j-dex2smali.sh`, ... - convert/decompile .dex |
| apksigner | apt binary | `apksigner verify --print-certs app.apk` / sign APKs (also in Android SDK build-tools) |
| keytool / jarsigner | JDK | `keytool -genkeypair -alias key -keystore ks.jks` then `jarsigner -keystore ks.jks app.apk key` |
| zipalign | apt binary | `zipalign -v 4 app.apk aligned.apk` - align APK resources for release |
| adb / fastboot | apt binary | `adb devices`, `adb logcat`; `fastboot flash ...` - device tooling |
| objection | pip (venv) | `objection -g <app> explore` - runtime exploration, SSL-pinning bypass |
| pidcat | source | `pidcat` - colored logcat by package |
| scrcpy | apt binary | `scrcpy` - display/control Android over USB |
| frida-gadget | binary | `frida-gadget.so` - inject Frida into an APK (non-rooted) |
| APKLeaks | pip (venv) | `apkleaks -f app.apk` - find hardcoded secrets/endpoints |
| androguard | pip (venv) | Python lib + CLI - programmatic APK/DEX analysis |
| QARK | pip (venv) | `qark --apk app.apk` - static vuln scanner (legacy) |
| Drozer | pip (venv) | `drozer console connect` - IPC/attack surface testing (legacy) |
| apktool | apt binary | decode/rebuild APK, edit smali: `apktool d app.apk` |

### Typical workflow
1. Recon: `apkleaks -f app.apk`
2. Static: `jadx app.apk` (Java) + `apktool d` (smali/resources) + `d2j-dex2jar.sh`
3. Dynamic: install on emulator/rooted device, `objection` or Frida to bypass pinning
EOF

  cat > "$LAB_FLUTTER/README.md" <<'EOF'
# flutter/ - Flutter Reverse-Engineering Tools

Flutter apps bundle their own network stack (BoringSSL inside `libflutter.so`),
so standard SSL-pinning bypasses do not work. These tools target that layer.

| Tool | Type | Notes |
|------|------|-------|
| reflutter | pip (venv) | `reflutter app.apk|app.ipa` - patches Flutter engine to disable cert validation & log calls. Resign result (uber-apk-signer) |
| kill_flutter | source | `kill_flutter app.apk|app.ipa -i <burp-ip> -p 8080` - dynamic bypass, works on ANY Flutter version (no hash database). Generates `flutter_bypass.js` + iptables/Frida commands |

### Workflow
- Quick dynamic test: `kill_flutter app.apk -i 192.168.1.10 -p 8080`, then run generated Frida script
- Full patch/repack: `reflutter app.apk`, align + sign, install
EOF

  cat > "$LAB_WEB/README.md" <<'EOF'
# web/ - Web & Network Pentesting Tools

| Tool | Type | Notes |
|------|------|-------|
| Burp Suite Community | jar launcher | `burpsuite` - intercepting proxy (port 8080). Import CA on device |
| RMS | source + venv | `rms` - web GUI for runtime manipulation (Frida-based) |
| OWASP ZAP | apt binary | `zaproxy` - open-source web scanner / proxy alternative |

### Device traffic setup
1. Start proxy (Burp/ZAP), note IP:port
2. Point device at it (Wi-Fi proxy or `adb shell settings put global http_proxy <ip:port>`)
3. Install proxy CA cert on the device
4. Bypass app pinning with objection / kill_flutter / reflutter as needed
EOF

  cat > "$LAB_DOCS/TOOLS.md" <<EOF
# Installed Tools - Command Reference

Generated: $(date -u '+%Y-%m-%d %H:%M UTC')

## iOS
- \`palera1n --help\`                 palera1n jailbreak (iOS 15-18, checkm8)
- \`frida\`, \`frida-ps -U\`, \`frida-trace -U\`   Frida instrumentation
- \`igf\`                            Grapefruit web UI -> http://127.0.0.1:31337
- \`r2\`                             radare2
- \`frida-ios-dump/dump.py <app>\`   decrypted IPA dump
- \`objection -g <app> explore\`      runtime exploration (also iOS)

## Android
- \`studio\`                         Android Studio
- \`jadx\` / \`jadx-gui\`             DEX decompiler
- \`d2j-dex2jar.sh app.apk\`         dex -> jar
- \`apksigner verify --print-certs app.apk\`   check signing cert
- \`keytool -genkeypair ...\`, \`jarsigner -keystore ks.jks app.apk key\`   sign an APK
- \`zipalign -v 4 app.apk out.apk\`  align APK for release
- \`adb devices\` / \`adb logcat\`    device tooling; \`fastboot flash ...\`
- \`objection\`, \`pidcat\`, \`scrcpy\`
- \`apkleaks -f app.apk\`, \`androguard\`, \`qark\`, \`drozer\`
- \`apktool d app.apk\`              decode apk

## Flutter
- \`reflutter app.apk\`              patch engine / bypass SSL pinning
- \`kill_flutter app.apk -i <ip> -p 8080\`

## Web / Network
- \`burpsuite\`, \`zaproxy\`, \`rms\`

## Services
- MobSF: http://127.0.0.1:8000  (mobsf/mobsf) - \`systemctl {start|stop|restart} mobsf\`
- Docker daemon: \`systemctl status docker\`

## Python venv
- Location: \`/opt/mobile-sec-venv\`
- Console scripts symlinked into \`/usr/local/bin\`
- Upgrade a tool: \`/opt/mobile-sec-venv/bin/pip install -U <pkg>\`
EOF

  ok "Documentation written: $LAB_ROOT/README.md (+ category READMEs, docs/TOOLS.md)"
}

# =============================================================================
# Run
# =============================================================================
if [[ "$MODE" == "docs-only" ]]; then
  write_docs
  exit 0
fi
if [[ "$MODE" == "docker-only" ]]; then
  install_docker
else
  [[ "$DO_IOS" == "1" ]] && install_ios
  [[ "$DO_ANDROID" == "1" ]] && install_android
  [[ "$DO_WEB" == "1" ]] && install_web
  [[ "$DO_UTILS" == "1" ]] && install_utils
  [[ "$DO_DOCKER" == "1" ]] && install_docker
fi

# Always refresh the documentation (works for partial installs too)
write_docs

# =============================================================================
# Summary
# =============================================================================
section "Done"

cat <<EOF
${C_GRN}Installed tools:${C_RST}
  iOS  : palera1n, Grapefruit (igf), Frida, Radare2, frida-ios-dump,
         bfinject, SSL-Kill-Switch-2, needle, ipsw (class-dump/macho), ktool,
         class-dump (source, for macOS builds)
  Android: Android Studio (studio), jadx / jadx-gui, dex-tools (d2j-*), apksigner,
         keytool / jarsigner, zipalign, adb / fastboot, objection, pidcat, scrcpy,
         frida-gadget ($LAB_ANDROID/frida-gadget), APKLeaks, Androguard, QARK, Drozer
  Flutter: reflutter (SSL pinning bypass / engine patch), kill_flutter (dynamic bypass)
  Web  : Burp Suite Community (burpsuite), RMS, OWASP ZAP (zaproxy)
  Utils: Ghidra (ghidraRun), Cutter (cutter), Radare2 (r2), Termius (termius-app),
         DB Browser (sqlitebrowser), Apktool

${C_GRN}Services:${C_RST}
  MobSF : http://127.0.0.1:8000   (login: mobsf / mobsf)
          manage with: systemctl {status|stop|start|restart} mobsf

${C_GRN}Python tools live in:${C_RST} $VENV  (symlinked into /usr/local/bin)

${C_GRN}Lab layout & docs:${C_RST} everything is organized under $LAB_ROOT
  - $LAB_ROOT/README.md        (index)
  - $LAB_ROOT/{ios,android,web,flutter}/README.md
  - $LAB_ROOT/docs/TOOLS.md    (full command reference)

${C_GRN}Quick references:${C_RST}
  Frida CodeShare scripts : https://codeshare.frida.re
  palera1n usage          : palera1n --help
  objection               : objection -g <app> explore
  reflutter               : reflutter <app.apk|app.ipa>   (sign result with uber-apk-signer)
  kill_flutter            : kill_flutter <app.apk|app.ipa> -i <burp-ip> -p 8080

${C_YLW}Notes:${C_RST}
  - Burp: run 'burpsuite', choose Community Edition. A GUI session is required.
  - class-dump/jtool2 are macOS-only; the Linux-native equivalents installed here
    are 'ipsw class-dump' / 'ipsw macho' and 'ktool' (pip k2l).
  - Drozer/QARK are legacy; install their server/agent side on the target device as needed.
  - If you are in the docker group, log out and back in for permission to apply.
EOF
