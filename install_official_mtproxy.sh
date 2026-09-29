#!/usr/bin/env bash
#
# Official Telegram MTProxy (C implementation, TelegramMessenger/MTProxy).
# Lowest possible runtime footprint (a few MB RAM), but needs to be compiled
# from source, and Telegram rotates its shared proxy-secret/proxy-multi.conf
# files, so this sets up a systemd timer to refresh them daily.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/mtproxy-variants/install_official_mtproxy.sh)
#
# Optional environment overrides:
#   MTPROXY_PORT=443
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root (sudo)." >&2
  exit 1
fi

PORT="${MTPROXY_PORT:-443}"
STATS_PORT=8888
INSTALL_DIR="/opt/MTProxy"

echo "==> Installing build dependencies..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y git curl build-essential libssl-dev zlib1g-dev xxd
elif command -v yum >/dev/null 2>&1; then
  yum groupinstall -y "Development Tools"
  yum install -y git curl openssl-devel zlib-devel vim-common
else
  echo "Unsupported distro: need apt-get or yum." >&2
  exit 1
fi

echo "==> Cloning MTProxy source..."
if [[ -d "$INSTALL_DIR" ]]; then
  git -C "$INSTALL_DIR" pull
else
  git clone https://github.com/TelegramMessenger/MTProxy "$INSTALL_DIR"
fi

echo "==> Building..."
cd "$INSTALL_DIR"
make

BIN="${INSTALL_DIR}/objs/bin/mtproto-proxy"
if [[ ! -x "$BIN" ]]; then
  echo "Build failed: ${BIN} not found." >&2
  exit 1
fi

echo "==> Generating secret..."
SECRET=$(head -c 16 /dev/urandom | xxd -ps)

echo "==> Fetching proxy-secret and proxy-multi.conf from Telegram..."
curl -fsSL https://core.telegram.org/getProxySecret -o "${INSTALL_DIR}/proxy-secret"
curl -fsSL https://core.telegram.org/getProxyConfig -o "${INSTALL_DIR}/proxy-multi.conf"

echo "==> Writing systemd service..."
cat > /etc/systemd/system/mtproxy.service <<EOF
[Unit]
Description=Official Telegram MTProxy
After=network.target

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN} -u nobody -p ${STATS_PORT} -H ${PORT} -S ${SECRET} --aes-pwd proxy-secret proxy-multi.conf -M 1
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

echo "==> Writing config-refresh service + daily timer..."
cat > /etc/systemd/system/mtproxy-update.service <<EOF
[Unit]
Description=Refresh MTProxy proxy-secret/proxy-multi.conf

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/curl -fsSL -o ${INSTALL_DIR}/proxy-secret https://core.telegram.org/getProxySecret
ExecStart=/usr/bin/curl -fsSL -o ${INSTALL_DIR}/proxy-multi.conf https://core.telegram.org/getProxyConfig
ExecStartPost=/bin/systemctl restart mtproxy.service
EOF

cat > /etc/systemd/system/mtproxy-update.timer <<EOF
[Unit]
Description=Daily refresh of MTProxy config

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "==> Opening firewall port ${PORT} (if a firewall is active)..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" || true
  firewall-cmd --reload || true
fi

echo "==> Enabling and starting services..."
systemctl daemon-reload
systemctl enable --now mtproxy
systemctl enable --now mtproxy-update.timer

sleep 1
if ! systemctl is-active --quiet mtproxy; then
  echo "mtproxy failed to start. Check: journalctl -u mtproxy -e" >&2
  exit 1
fi

echo "==> Detecting public IP..."
IP=$(curl -fsSL https://api.ipify.org || curl -fsSL ifconfig.me)

echo
echo "======================================================"
echo " Official MTProxy is up and running."
echo " Server:  ${IP}"
echo " Port:    ${PORT}"
echo " Secret:  ${SECRET}"
echo
echo " Connect link:"
echo " tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
echo
echo " https:// share link:"
echo " https://t.me/proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
echo "======================================================"
echo
echo "Service management:"
echo "  systemctl status mtproxy"
echo "  journalctl -u mtproxy -f"
echo "  systemctl restart mtproxy"
echo
echo "Note: this variant uses a *plain* secret (no fake-TLS). To register an ad"
echo "tag / promoted channel via @MTProxybot, add another -S <secret> or -P <tag>"
echo "flag to ExecStart in /etc/systemd/system/mtproxy.service."
