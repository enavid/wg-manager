#!/bin/bash
# =============================================================================
# wg-manager installer
# https://github.com/enavid/wg-manager
# =============================================================================

set -eo pipefail

REPO="https://raw.githubusercontent.com/enavid/wg-manager/main"
INSTALL_PATH="/usr/local/bin/wg-manager"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} Please run as root: sudo bash <(curl -Ls ...)"
    exit 1
fi

echo ""
echo -e "${BOLD}${CYAN}wg-manager installer${NC}"
echo -e "https://github.com/enavid/wg-manager"
echo ""

# Check dependencies
for cmd in curl wg wg-quick; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} Missing: ${cmd}"
        echo "Install WireGuard: apt install wireguard wireguard-tools"
        exit 1
    fi
done

echo -e "${GREEN}[INFO]${NC}  Downloading wg-manager..."
curl -fsSL "${REPO}/wg-manager.sh" -o "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

echo -e "${GREEN}[INFO]${NC}  Installed to: ${INSTALL_PATH}"
echo ""
echo -e "${BOLD}Done. Get started:${NC}"
echo ""
echo "  sudo wg-manager init"
echo "  sudo wg-manager help"
echo ""
