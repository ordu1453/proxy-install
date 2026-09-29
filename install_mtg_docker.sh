#!/usr/bin/env bash
#
# MTProxy via Docker (mtg image) — for servers where you prefer
# containerized, isolated services and already use/want Docker.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/mtproxy-variants/install_mtg_docker.sh)
#
# Optional environment overrides:
#   MTG_PORT=443
#   MTG_DOMAIN=www.google.com
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root (sudo)." >&2
  exit 1
fi

PORT="${MTG_PORT:-443}"
DOMAIN="${MTG_DOMAIN:-www.google.com}"
IMAGE="nineseconds/mtg:2"

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Docker not found, installing..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

echo "==> Pulling ${IMAGE}..."
docker pull "$IMAGE"

echo "==> Generating secret (fake-tls, disguised as ${DOMAIN})..."
SECRET=$(docker run --rm "$IMAGE" generate-secret "$DOMAIN")

echo "==> Removing any previous mtg container..."
docker rm -f mtg >/dev/null 2>&1 || true

echo "==> Starting mtg container..."
docker run -d \
  --name mtg \
  --restart unless-stopped \
  -p "${PORT}:${PORT}/tcp" \
  "$IMAGE" simple-run "0.0.0.0:${PORT}" "$SECRET"

echo "==> Opening firewall port ${PORT} (if a firewall is active)..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" || true
  firewall-cmd --reload || true
fi

echo "==> Detecting public IP..."
IP=$(curl -fsSL https://api.ipify.org || curl -fsSL ifconfig.me)

echo
echo "======================================================"
echo " MTProxy (Docker/mtg) is up and running."
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
echo "Container management:"
echo "  docker logs -f mtg"
echo "  docker restart mtg"
echo "  docker rm -f mtg"
