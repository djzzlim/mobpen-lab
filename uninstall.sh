#!/usr/bin/env bash
# =============================================================================
#  mobpen-lab - Uninstaller
#
#  Removes everything the installer (install.sh) placed on the system:
#    - /opt/mobpen-lab            (lab folder + generated docs)
#    - /opt/mobile-sec-venv       (Python venv + /usr/local/bin symlinks)
#    - /opt/android-studio, /opt/jadx, /opt/dex-tools
#    - desktop entries, mobsf.service, checkra1n apt repo, npm igf
#
#  Usage:
#    sudo ./uninstall.sh            (interactive - asks before system-wide changes)
#    sudo ./uninstall.sh --purge    (remove everything, no prompts)
# =============================================================================

set -uo pipefail

C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YLW=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_RST=$'\033[0m'
log()  { printf '%b[*]%b %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%b[+]%b %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%b[!]%b %s\n' "$C_YLW" "$C_RST" "$*"; }
die()  { printf '%b[x]%b %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
section() { printf '\n%b=== %s ===%b\n' "$C_BLU" "$*" "$C_RST"; }

PURGE=0
for a in "$@"; do case "$a" in --purge|-y|--yes) PURGE=1;; *) ;; esac; done

if [[ "$EUID" -ne 0 ]]; then
  log "Re-running with sudo..."
  exec sudo -H bash "$0" "$@"
fi

LAB_ROOT="/opt/mobpen-lab"
VENV="/opt/mobile-sec-venv"
SUDO_USER_OR_ROOT="${SUDO_USER:-root}"
# Safe repo dir: empty when run via `curl | sudo bash` (BASH_SOURCE[0] unset).
# Note: dirname "" == ".", so we must test emptiness first, never default to cwd.
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
else
  REPO_DIR=""
fi

confirm() { # $1 = question ; returns 0 for yes
  [[ "$PURGE" == "1" ]] && return 0
  local ans
  read -r -p "$(printf '%b[?]%b %s [y/N] ' "$C_YLW" "$C_RST" "$1")" ans
  [[ "$ans" =~ ^[yY] ]]
}

# Symlinks/scripts created by install.sh into /usr/local/bin
BIN_LINKS=(frida frida-ps frida-trace frida-join frida-inject objection pidcat apkleaks androguard qark drozer reflutter kill_flutter rms studio jadx jadx-gui palera1n igf mobpen ipsw ktool ktool_bless cutter fastboot zipalign)
D2J_LINKS=(/usr/local/bin/d2j-*.sh)

remove_usr_local_bin() {
  local removed=0
  for l in "${BIN_LINKS[@]}"; do
    if [[ -L "/usr/local/bin/$l" || -f "/usr/local/bin/$l" ]]; then rm -f "/usr/local/bin/$l"; removed=1; ok "removed /usr/local/bin/$l"; fi
  done
  for l in $D2J_LINKS; do
    if [[ -L "$l" ]]; then rm -f "$l"; ok "removed symlink $l"; fi
  done
  [[ "$removed" == "1" ]] || ok "no /usr/local/bin entries found"
}

section "Lab folder + docs"
for d in "$LAB_ROOT" /opt/mobile-sec-lab /opt/mobile-sec-tools; do
  [[ -e "$d" ]] && { rm -rf "$d"; ok "removed $d"; }
done

section "Python venv"
if [[ -d "$VENV" ]]; then
  rm -rf "$VENV"; ok "removed $VENV"
else
  ok "no venv found ($VENV)"
fi
remove_usr_local_bin

section "Standalone binaries under /opt"
for d in /opt/android-studio /opt/jadx /opt/dex-tools; do
   [[ -e "$d" ]] && { rm -rf "$d"; ok "removed $d"; }
 done
 
 section "Desktop entries"
for f in /usr/share/applications/android-studio.desktop; do
   [[ -e "$f" ]] && { rm -f "$f"; ok "removed $f"; }
 done

section "MobSF service"
if [[ -f /etc/systemd/system/mobsf.service ]]; then
  systemctl disable --now mobsf >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/mobsf.service
  systemctl daemon-reload
  ok "removed mobsf.service"
else
  ok "no mobsf.service found"
fi
if command -v docker >/dev/null 2>&1; then
  docker rm -f mobsf >/dev/null 2>&1 && ok "removed mobsf container" || true
fi

section "checkra1n (deprecated) leftovers"
rm -f /etc/apt/sources.list.d/checkra1n.list
rm -f /usr/share/keyrings/checkra1n.gpg
rm -f /usr/local/bin/checkra1n
rm -rf /opt/mobpen-lab/ios/checkra1n
ok "removed checkra1n apt repo + keyring + binary"

section "System-wide changes (asked only if you answer yes)"

if command -v igf >/dev/null 2>&1 || npm list -g igf >/dev/null 2>&1; then
  if confirm "Remove npm package 'igf' (Grapefruit)?"; then
    npm uninstall -g igf >/dev/null 2>&1 && ok "removed igf" || warn "could not uninstall igf"
  fi
fi

if [[ -f /etc/apt/sources.list.d/nodesource.list || -d /usr/share/keyrings/nodesource.gpg ]]; then
  if confirm "Remove the NodeSource apt repo (Node.js stays installed)?"; then
    rm -f /etc/apt/sources.list.d/nodesource.list
    rm -f /usr/share/keyrings/nodesource.gpg
    apt-get update -y >/dev/null 2>&1 || true
    ok "removed NodeSource repo"
  fi
fi

APT_PACKAGES=(apksigner apktool scrcpy sqlitebrowser radare2 zaproxy ghidra android-tools-adb pidcat dex2jar zipalign fastboot virtualbox-guest-utils virtualbox-guest-x11 virtualbox-guest-dkms open-vm-tools-desktop)
installed_apt=()
for p in "${APT_PACKAGES[@]}"; do dpkg -s "$p" >/dev/null 2>&1 && installed_apt+=("$p"); done
if [[ ${#installed_apt[@]} -gt 0 ]]; then
  if confirm "Remove the installed apt packages? (${installed_apt[*]})"; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y "${installed_apt[@]}" >/dev/null 2>&1 && ok "removed apt packages" || warn "apt remove had issues"
  fi
fi

if confirm "Remove Docker (docker packages + mobsf image)?"; then
  if command -v docker >/dev/null 2>&1; then
    docker image rm opensecurity/mobile-security-framework-mobsf:latest >/dev/null 2>&1 || true
    docker volume rm mobsf_data >/dev/null 2>&1 || true
  fi
  systemctl disable --now docker >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get remove -y 'docker*' containerd runc >/dev/null 2>&1 \
    && ok "removed docker" || warn "docker removal may need manual cleanup"
  rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker*.list
  rm -f /etc/apt/keyrings/docker.gpg /usr/share/keyrings/docker.gpg
fi

if grep -q docker /etc/group 2>/dev/null && [[ "$PURGE" == "1" || -n "$SUDO_USER" ]]; then
  if confirm "Remove user '$SUDO_USER_OR_ROOT' from the docker group?"; then
    gpasswd -d "$SUDO_USER_OR_ROOT" docker >/dev/null 2>&1 && ok "removed from docker group" || true
  fi
fi

section "Done"
cat <<EOF
${C_GRN}mobpen-lab has been uninstalled.${C_RST}

Remaining (removed only with 'yes' above): any apt packages, Docker, NodeSource repo.
If you chose not to remove Docker, the MobSF image/container may still exist.
Burp Suite was left in place (launcher + /opt/burpsuite jar kept).
You can leave the repo folder in place or delete it:
  rm -rf ${REPO_DIR:-/opt/mobpen-lab/mobpen-lab}
EOF