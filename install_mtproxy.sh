#!/usr/bin/env bash
#
# MTProxy (mtg) installer — one-shot setup for a fresh VPS.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install_mtproxy.sh)
#
# Optional environment overrides:
#   MTG_PORT=443            # port to listen on (default: 443)
#   MTG_DOMAIN=www.google.com   # domain to disguise traffic as (fake-tls)
#   MTG_TAG=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx   # @MTProxybot ad-tag, optional
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root (sudo)." >&2
  exit 1
fi

PORT="${MTG_PORT:-443}"
DOMAIN="${MTG_DOMAIN:-www.google.com}"
TAG="${MTG_TAG:-}"
BIN_PATH="/usr/local/bin/mtg"
SERVICE_PATH="/etc/systemd/system/mtg.service"
ENV_PATH="/etc/mtg.env"

echo "==> Detecting architecture..."
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

echo "==> Fetching latest mtg release info..."
LATEST_JSON=$(curl -fsSL https://api.github.com/repos/9seconds/mtg/releases/latest)
VERSION=$(echo "$LATEST_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z "$VERSION" ]]; then
  echo "Could not determine latest mtg version." >&2
  exit 1
fi
VERSION_NUM="${VERSION#v}"

ASSET_URL="https://github.com/9seconds/mtg/releases/download/${VERSION}/mtg-${VERSION_NUM}-linux-${ARCH}.tar.gz"
echo "==> Downloading mtg ${VERSION} (${ARCH})..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
curl -fsSL "$ASSET_URL" -o "$TMP_DIR/mtg.tar.gz"
tar -xzf "$TMP_DIR/mtg.tar.gz" -C "$TMP_DIR"

FOUND_BIN=$(find "$TMP_DIR" -type f -name mtg | head -n1)
if [[ -z "$FOUND_BIN" ]]; then
  echo "mtg binary not found in archive." >&2
  exit 1
fi
install -m 0755 "$FOUND_BIN" "$BIN_PATH"

echo "==> Generating secret (fake-tls, disguised as ${DOMAIN})..."
SECRET=$("$BIN_PATH" generate-secret --hex "$DOMAIN" 2>/dev/null || "$BIN_PATH" generate-secret "$DOMAIN")

cat > "$ENV_PATH" <<EOF
MTG_PORT=${PORT}
MTG_SECRET=${SECRET}
EOF
chmod 600 "$ENV_PATH"

echo "==> Writing systemd service..."
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=mtg MTProxy
After=network.target

[Service]
EnvironmentFile=${ENV_PATH}
ExecStart=${BIN_PATH} simple-run 0.0.0.0:\${MTG_PORT} \${MTG_SECRET}
Restart=on-failure
RestartSec=2
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

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

echo "==> Enabling and starting mtg..."
systemctl daemon-reload
systemctl enable --now mtg

sleep 1
if ! systemctl is-active --quiet mtg; then
  echo "mtg failed to start. Check: journalctl -u mtg -e" >&2
  exit 1
fi

echo "==> Detecting public IP..."
IP=$(curl -fsSL https://api.ipify.org || curl -fsSL ifconfig.me)

LINK="tg://proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
if [[ -n "$TAG" ]]; then
  LINK="${LINK}"
fi

echo
echo "======================================================"
echo " MTProxy is up and running."
echo " Server:  ${IP}"
echo " Port:    ${PORT}"
echo " Secret:  ${SECRET}"
echo
echo " Connect link:"
echo " ${LINK}"
echo
echo " https:// share link:"
echo " https://t.me/proxy?server=${IP}&port=${PORT}&secret=${SECRET}"
echo "======================================================"
echo
echo "Service management:"
echo "  systemctl status mtg"
echo "  journalctl -u mtg -f"
echo "  systemctl restart mtg"
