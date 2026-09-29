#!/usr/bin/env bash
#
# mtprotoproxy (alexbers/mtprotoproxy) — pure Python 3, single script.
# The most portable option: no C compiler needed, works on tiny/OpenVZ VPS,
# containers, or anywhere Python 3 is available. Slightly heavier on CPU
# than mtg/official MTProxy under load, but uvloop (installed if possible)
# closes most of that gap.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/mtproxy-variants/install_python_mtprotoproxy.sh)
#
# Optional environment overrides:
#   MTP_PORT=443
#   MTP_DOMAIN=www.google.com   # domain for TLS-mode disguise
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root (sudo)." >&2
  exit 1
fi

PORT="${MTP_PORT:-443}"
DOMAIN="${MTP_DOMAIN:-www.google.com}"
INSTALL_DIR="/opt/mtprotoproxy"

echo "==> Installing Python and git..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y python3 python3-pip git
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 python3-pip git
else
  echo "Unsupported distro: need apt-get or yum." >&2
  exit 1
fi

echo "==> Cloning mtprotoproxy..."
if [[ -d "$INSTALL_DIR" ]]; then
  git -C "$INSTALL_DIR" pull
else
  git clone https://github.com/alexbers/mtprotoproxy.git "$INSTALL_DIR"
fi

echo "==> Trying to install uvloop for better performance (optional)..."
pip3 install --quiet uvloop || echo "uvloop unavailable, continuing without it."

echo "==> Generating secret..."
SECRET=$(python3 -c "import secrets; print(secrets.token_hex(16))")

echo "==> Writing config.py..."
cat > "${INSTALL_DIR}/config.py" <<EOF
PORT = ${PORT}

USERS = {
    "tg": "${SECRET}",
}

MODES = {
    "classic": False,
    "secure": False,
    "tls": True
}

TLS_DOMAIN = "${DOMAIN}"
EOF

echo "==> Writing systemd service..."
PYTHON_BIN=$(command -v python3)
cat > /etc/systemd/system/mtprotoproxy.service <<EOF
[Unit]
Description=mtprotoproxy (Python MTProxy)
After=network.target

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PYTHON_BIN} ${INSTALL_DIR}/mtprotoproxy.py
Restart=on-failure
RestartSec=2
User=nobody

[Install]
WantedBy=multi-user.target
EOF

echo "==> Opening firewall port ${PORT} (if a firewall is active)..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" || true
  firewall-cmd --reload || true
fi

echo "==> Enabling and starting mtprotoproxy..."
systemctl daemon-reload
systemctl enable --now mtprotoproxy

sleep 2
if ! systemctl is-active --quiet mtprotoproxy; then
  echo "mtprotoproxy failed to start. Check: journalctl -u mtprotoproxy -e" >&2
  exit 1
fi

echo "==> Detecting public IP..."
IP=$(curl -fsSL https://api.ipify.org || curl -fsSL ifconfig.me)

# mtprotoproxy.py computes the TLS-mode secret itself as
# "ee" + secret + hex(TLS_DOMAIN) and prints the ready-made tg:// link on
# startup — pull it straight from the journal instead of rebuilding it here.
LINK=$(journalctl -u mtprotoproxy --no-pager -o cat | grep -m1 'tg://proxy' | sed -E 's/^tg: //' || true)
if [[ -z "$LINK" ]]; then
  # give it a bit more time and try once more
  sleep 3
  LINK=$(journalctl -u mtprotoproxy --no-pager -o cat | grep -m1 'tg://proxy' || true)
fi

echo
echo "======================================================"
echo " mtprotoproxy (Python) is up and running."
echo " Server:  ${IP}"
echo " Port:    ${PORT}"
echo
if [[ -n "$LINK" ]]; then
  echo " Connect link (from service log):"
  echo " ${LINK}"
else
  echo " Could not auto-read the link from the log, fetch it manually with:"
  echo "   journalctl -u mtprotoproxy --no-pager | grep 'tg://proxy'"
fi
echo "======================================================"
echo
echo "Service management:"
echo "  systemctl status mtprotoproxy"
echo "  journalctl -u mtprotoproxy -f"
echo "  systemctl restart mtprotoproxy"
