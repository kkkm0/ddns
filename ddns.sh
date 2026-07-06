#!/usr/bin/env bash

set -e

########################################
# Cloudflare DDNS Installer
# Author: qi
########################################

# ---------- 参数检查 ----------
if [ $# -ne 2 ]; then
    echo "Usage:"
    echo "bash ddns.sh <Cloudflare_API_Token> <Domain>"
    echo ""
    echo "Example:"
    echo "bash ddns.sh cf_xxxxxxxxx awshk.2012021.xyz"
    exit 1
fi

CF_API_TOKEN="$1"
DOMAIN="$2"

INSTALL_DIR="/opt/cloudflare-ddns"

echo "=========================================="
echo " Cloudflare DDNS Installer"
echo "=========================================="

# ---------- 检查 Docker ----------
if ! command -v docker >/dev/null 2>&1; then
    echo "[INFO] Docker not found, installing..."

    curl -fsSL https://get.docker.com | sh

    systemctl enable docker
    systemctl start docker
else
    echo "[INFO] Docker already installed."
fi

# ---------- 创建目录 ----------
mkdir -p "${INSTALL_DIR}"

# ---------- 写入 .env ----------
cat > "${INSTALL_DIR}/.env" <<EOF
CLOUDFLARE_API_TOKEN=${CF_API_TOKEN}
DOMAINS=${DOMAIN}
EOF

# ---------- docker-compose.yml ----------
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  cloudflare-ddns:
    image: favonia/cloudflare-ddns:1
    container_name: cloudflare-ddns
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env
EOF

# ---------- 启动 ----------
cd "${INSTALL_DIR}"

docker compose pull
docker compose up -d

echo ""
echo "=========================================="
echo " Cloudflare DDNS Installed Successfully!"
echo "=========================================="
echo ""
echo "Domain : ${DOMAIN}"
echo "Path   : ${INSTALL_DIR}"
echo ""
echo "Useful commands:"
echo "docker compose logs -f"
echo "docker compose restart"
echo "docker compose down"
echo ""
