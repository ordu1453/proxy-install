#!/usr/bin/env bash
#
# Universal uninstaller for the MTProxy variants in this repo.
# Detects whichever variant(s) are installed and removes them:
#
#   - install_mtproxy.sh            -> mtg (systemd + binary)
#   - install_mtg_docker.sh         -> mtg (Docker container)
#   - install_official_mtproxy.sh   -> TelegramMessenger/MTProxy
#   - install_python_mtprotoproxy.sh -> mtprotoproxy (Python)
#
# For each one found it stops/disables the service, deletes its unit
# files, binaries/sources/config, and closes the firewall port that was
# opened for it. Safe to run even if nothing (or only some variants)
# are installed.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/ordu1453/proxy-install/main/uninstall_mtproxy.sh)
#
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root (sudo)." >&2
  exit 1
fi

FOUND=0

close_port() {
  local port="$1"
  [[ -z "$port" ]] && return
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

# 1. mtg — install_mtproxy.sh (binary + systemd)
if systemctl list-unit-files 2>/dev/null | grep -q '^mtg\.service'; then
  echo "==> Removing mtg (binary/systemd) ..."
  PORT=$(grep -oE 'MTG_PORT=[0-9]+' /etc/mtg.env 2>/dev/null | cut -d= -f2)
  systemctl stop mtg >/dev/null 2>&1 || true
  systemctl disable mtg >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/mtg.service
  rm -f /etc/mtg.env
  rm -f /usr/local/bin/mtg
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true
  close_port "$PORT"
  FOUND=1
fi

# 2. mtg — install_mtg_docker.sh (Docker container)
if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx mtg; then
  echo "==> Removing mtg (Docker) ..."
  PORT=$(docker port mtg 2>/dev/null | head -n1 | sed -E 's#.*:([0-9]+)/tcp#\1#')
  docker rm -f mtg >/dev/null 2>&1 || true
  close_port "$PORT"
  FOUND=1
fi

# 3. install_official_mtproxy.sh (TelegramMessenger/MTProxy)
if systemctl list-unit-files 2>/dev/null | grep -q '^mtproxy\.service'; then
  echo "==> Removing official MTProxy ..."
  PORT=$(systemctl cat mtproxy.service 2>/dev/null | grep -oE -- '-H [0-9]+' | awk '{print $2}')
  systemctl stop mtproxy mtproxy-update.timer mtproxy-update.service >/dev/null 2>&1 || true
  systemctl disable mtproxy mtproxy-update.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/mtproxy.service
  rm -f /etc/systemd/system/mtproxy-update.service
  rm -f /etc/systemd/system/mtproxy-update.timer
  rm -rf /opt/MTProxy
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true
  close_port "$PORT"
  FOUND=1
fi

# 4. install_python_mtprotoproxy.sh (mtprotoproxy)
if systemctl list-unit-files 2>/dev/null | grep -q '^mtprotoproxy\.service'; then
  echo "==> Removing mtprotoproxy (Python) ..."
  PORT=$(grep -oE '^PORT = [0-9]+' /opt/mtprotoproxy/config.py 2>/dev/null | awk '{print $3}')
  systemctl stop mtprotoproxy >/dev/null 2>&1 || true
  systemctl disable mtprotoproxy >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/mtprotoproxy.service
  rm -rf /opt/mtprotoproxy
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true
  close_port "$PORT"
  FOUND=1
fi

if [[ "$FOUND" -eq 0 ]]; then
  echo "No known MTProxy installation (mtg, mtg-docker, official MTProxy, mtprotoproxy) found on this server."
  exit 0
fi

echo
echo "======================================================"
echo " Done. All detected MTProxy services/files were removed."
echo "======================================================"
