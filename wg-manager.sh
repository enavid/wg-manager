#!/bin/bash
# =============================================================================
# wg-manager — WireGuard Peer Manager
# https://github.com/enavid/wg-manager
# =============================================================================

set -euo pipefail

# --- Paths ---
DATA_DIR="/etc/wg-manager"
CONFIG_FILE="${DATA_DIR}/wg-manager.conf"
CLIENTS_DIR="${DATA_DIR}/clients"
WG_CONF=""

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# Utility
# =============================================================================

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${BOLD}${BLUE}==> $*${NC}"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This command must be run as root."
        exit 1
    fi
}

require_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "No configuration found at ${CONFIG_FILE}."
        log_error "Run 'wg-manager init' to initialize the server first."
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    WG_CONF="/etc/wireguard/${WG_INTERFACE}.conf"
}

check_dependencies() {
    local missing=()
    for cmd in wg wg-quick ip iptables; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install WireGuard: apt install wireguard wireguard-tools"
        exit 1
    fi
}

# =============================================================================
# IP Management
# =============================================================================

get_subnet_base() {
    echo "$VPN_SUBNET" | grep -oP '^\d+\.\d+\.\d+'
}

next_available_ip() {
    local base
    base=$(get_subnet_base)
    local used_ips=("${SERVER_VPN_IP}")

    if [[ -f "$WG_CONF" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                used_ips+=("${BASH_REMATCH[1]}")
            fi
        done < "$WG_CONF"
    fi

    for i in $(seq 2 254); do
        local candidate="${base}.${i}"
        local found=false
        for used in "${used_ips[@]}"; do
            [[ "$used" == "$candidate" ]] && found=true && break
        done
        $found || { echo "$candidate"; return; }
    done

    log_error "No available IPs in subnet ${VPN_SUBNET}."
    exit 1
}

# =============================================================================
# init
# =============================================================================

cmd_init() {
    log_section "Initializing WireGuard Server"
    check_dependencies

    if [[ -f "$CONFIG_FILE" ]]; then
        log_warn "Server is already initialized (${CONFIG_FILE})."
        read -rp "Re-initialize and overwrite settings? [y/N]: " confirm
        [[ "${confirm,,}" == "y" ]] || { log_info "Aborted."; exit 0; }
    fi

    local default_iface
    default_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

    echo ""
    echo -e "${CYAN}Server Configuration${NC}"
    echo "--------------------"
    read -rp "Server public IP                    : " input_server_ip
    read -rp "WireGuard listen port        [51820] : " input_port;         input_port="${input_port:-51820}"
    read -rp "VPN subnet           [10.10.10.0/24] : " input_subnet;       input_subnet="${input_subnet:-10.10.10.0/24}"
    read -rp "Server VPN IP           [10.10.10.1] : " input_server_vpn;   input_server_vpn="${input_server_vpn:-10.10.10.1}"
    read -rp "Public network interface  [${default_iface}] : " input_iface; input_iface="${input_iface:-$default_iface}"
    read -rp "WireGuard interface name        [wg0] : " input_wg_iface;    input_wg_iface="${input_wg_iface:-wg0}"
    read -rp "Client DNS server           [8.8.8.8] : " input_dns;         input_dns="${input_dns:-8.8.8.8}"

    log_section "Generating Server Keys"
    local server_priv server_pub
    server_priv=$(wg genkey)
    server_pub=$(echo "$server_priv" | wg pubkey)

    mkdir -p "$DATA_DIR" "$CLIENTS_DIR"
    chmod 700 "$DATA_DIR"

    cat > "$CONFIG_FILE" <<EOF
# wg-manager configuration — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
SERVER_IP="${input_server_ip}"
SERVER_PORT="${input_port}"
VPN_SUBNET="${input_subnet}"
SERVER_VPN_IP="${input_server_vpn}"
NET_INTERFACE="${input_iface}"
WG_INTERFACE="${input_wg_iface}"
DNS="${input_dns}"
SERVER_PRIVATE_KEY="${server_priv}"
SERVER_PUBLIC_KEY="${server_pub}"
EOF
    chmod 600 "$CONFIG_FILE"

    WG_CONF="/etc/wireguard/${input_wg_iface}.conf"

    if [[ -f "$WG_CONF" ]]; then
        log_warn "WireGuard config already exists (${WG_CONF}) — skipping overwrite."
    else
        cat > "$WG_CONF" <<EOF
[Interface]
Address = ${input_server_vpn}/24
ListenPort = ${input_port}
PrivateKey = ${server_priv}
PostUp   = iptables -A FORWARD -i ${input_wg_iface} -j ACCEPT; iptables -A FORWARD -o ${input_wg_iface} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${input_iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${input_wg_iface} -j ACCEPT; iptables -D FORWARD -o ${input_wg_iface} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${input_iface} -j MASQUERADE
EOF
        chmod 600 "$WG_CONF"
        log_info "Server config written: ${WG_CONF}"
    fi

    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || {
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p &>/dev/null
        log_info "IP forwarding enabled."
    }

    systemctl enable "wg-quick@${input_wg_iface}" &>/dev/null
    if systemctl is-active --quiet "wg-quick@${input_wg_iface}"; then
        log_info "WireGuard is already running."
    else
        systemctl start "wg-quick@${input_wg_iface}"
        log_info "WireGuard started."
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Server initialized successfully.${NC}"
    echo -e "  Public Key : ${CYAN}${server_pub}${NC}"
    echo -e "  Endpoint   : ${CYAN}${input_server_ip}:${input_port}${NC}"
    echo ""
    echo "Run 'wg-manager add <name>' to add your first peer."
}

# =============================================================================
# add
# =============================================================================

cmd_add() {
    require_root
    require_config

    local client_name="${1:-}"
    if [[ -z "$client_name" ]]; then
        read -rp "Peer name (e.g. server-us-01): " client_name
    fi

    client_name="${client_name//[^a-zA-Z0-9_-]/}"
    [[ -z "$client_name" ]] && { log_error "Invalid peer name."; exit 1; }

    local client_conf="${CLIENTS_DIR}/${client_name}.conf"
    [[ -f "$client_conf" ]] && { log_error "Peer '${client_name}' already exists."; exit 1; }

    log_section "Adding Peer: ${client_name}"

    local client_priv client_pub
    client_priv=$(wg genkey)
    client_pub=$(echo "$client_priv" | wg pubkey)

    local client_ip created_at
    client_ip=$(next_available_ip)
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat >> "$WG_CONF" <<EOF

# Peer: ${client_name} | Added: ${created_at}
[Peer]
PublicKey = ${client_pub}
AllowedIPs = ${client_ip}/32
PersistentKeepalive = 25
EOF

    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        wg set "${WG_INTERFACE}" peer "${client_pub}" allowed-ips "${client_ip}/32" persistent-keepalive 25
        log_info "Peer added to running WireGuard instance."
    else
        log_warn "WireGuard is not running. Config updated but not applied live."
    fi

    cat > "$client_conf" <<EOF
# Peer: ${client_name} | Server: ${SERVER_IP}:${SERVER_PORT} | Created: ${created_at}

[Interface]
PrivateKey = ${client_priv}
Address = ${client_ip}/32
ListenPort = ${SERVER_PORT}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = ${VPN_SUBNET}
Endpoint = ${SERVER_IP}:${SERVER_PORT}
PersistentKeepalive = 25
EOF
    chmod 600 "$client_conf"

    echo ""
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo -e "${GREEN}${BOLD}  Peer '${client_name}' created — paste this on the client server${NC}"
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo ""
    echo -e "${CYAN}Save to: /etc/wireguard/${WG_INTERFACE}.conf${NC}"
    echo ""
    cat "$client_conf"
    echo ""
    echo -e "${YELLOW}Commands to run on the CLIENT server:${NC}"
    echo "  sudo apt install wireguard wireguard-tools"
    echo "  sudo nano /etc/wireguard/${WG_INTERFACE}.conf   # paste config above"
    echo "  sudo systemctl enable --now wg-quick@${WG_INTERFACE}"
    echo "  sudo wg show"
    echo ""
}

# =============================================================================
# remove
# =============================================================================

cmd_remove() {
    require_root
    require_config

    local client_name="${1:-}"
    [[ -z "$client_name" ]] && { log_error "Usage: wg-manager remove <name>"; exit 1; }

    local client_conf="${CLIENTS_DIR}/${client_name}.conf"
    [[ ! -f "$client_conf" ]] && { log_error "Peer '${client_name}' not found."; exit 1; }

    local client_pub
    client_pub=$(grep -oP '(?<=PublicKey = ).+' "$client_conf" | head -1 || true)

    log_section "Removing Peer: ${client_name}"

    python3 - "$WG_CONF" "$client_name" <<'PYEOF'
import sys, re
path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
pattern = rf'\n# Peer: {re.escape(name)} \|[^\n]*\n\[Peer\]\n(?:[^\[]*\n)*'
result = re.sub(pattern, '\n', content)
with open(path, 'w') as f:
    f.write(result)
print("Server config updated.")
PYEOF

    if [[ -n "$client_pub" ]] && systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        wg set "${WG_INTERFACE}" peer "${client_pub}" remove 2>/dev/null && \
            log_info "Peer removed from running WireGuard instance."
    fi

    mkdir -p "${CLIENTS_DIR}/removed"
    mv "$client_conf" "${CLIENTS_DIR}/removed/${client_name}.conf"
    log_info "Peer '${client_name}' removed. Config archived to: ${CLIENTS_DIR}/removed/"
}

# =============================================================================
# list
# =============================================================================

cmd_list() {
    require_config

    log_section "Registered Peers"

    local found=false
    for conf in "${CLIENTS_DIR}"/*.conf 2>/dev/null; do
        [[ -f "$conf" ]] && { found=true; break; }
    done

    if ! $found; then
        log_warn "No peers found. Run 'wg-manager add <name>' to create one."
        return
    fi

    printf "\n${BOLD}%-20s %-18s %s${NC}\n" "NAME" "VPN IP" "CREATED"
    printf "%-20s %-18s %s\n" "----" "------" "-------"

    for conf in "${CLIENTS_DIR}"/*.conf; do
        [[ -f "$conf" ]] || continue
        local name vpn_ip created
        name=$(basename "$conf" .conf)
        vpn_ip=$(grep -oP '(?<=Address = )[^\s/]+' "$conf" 2>/dev/null || echo "—")
        created=$(grep -oP '(?<=Created: ).+' "$conf" 2>/dev/null || echo "—")
        printf "%-20s %-18s %s\n" "$name" "$vpn_ip" "$created"
    done

    echo ""
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
        echo -e "${CYAN}Live WireGuard status:${NC}"
        wg show "${WG_INTERFACE}" 2>/dev/null || true
    else
        log_warn "WireGuard interface '${WG_INTERFACE}' is not running."
    fi
}

# =============================================================================
# show
# =============================================================================

cmd_show() {
    require_config

    local client_name="${1:-}"
    [[ -z "$client_name" ]] && { log_error "Usage: wg-manager show <name>"; exit 1; }

    local client_conf="${CLIENTS_DIR}/${client_name}.conf"
    [[ ! -f "$client_conf" ]] && { log_error "Peer '${client_name}' not found."; exit 1; }

    echo ""
    echo -e "${BOLD}${CYAN}Config for peer '${client_name}':${NC}"
    echo "------------------------------------------------------------"
    cat "$client_conf"
    echo "------------------------------------------------------------"
}

# =============================================================================
# status
# =============================================================================

cmd_status() {
    require_config

    log_section "Server Status"
    printf "  %-20s %s\n" "Server IP:"       "${SERVER_IP}"
    printf "  %-20s %s\n" "Endpoint:"        "${SERVER_IP}:${SERVER_PORT}"
    printf "  %-20s %s\n" "VPN Subnet:"      "${VPN_SUBNET}"
    printf "  %-20s %s\n" "Server VPN IP:"   "${SERVER_VPN_IP}"
    printf "  %-20s %s\n" "WG Interface:"    "${WG_INTERFACE}"
    printf "  %-20s %s\n" "Net Interface:"   "${NET_INTERFACE}"
    printf "  %-20s %s\n" "Public Key:"      "${SERVER_PUBLIC_KEY}"

    echo ""
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
        echo -e "  Status               : ${GREEN}Running${NC}"
        wg show "${WG_INTERFACE}" 2>/dev/null || true
    else
        echo -e "  Status               : ${RED}Stopped${NC}"
        echo "  Run: systemctl start wg-quick@${WG_INTERFACE}"
    fi
}

# =============================================================================
# help
# =============================================================================

cmd_help() {
    cat <<EOF

${BOLD}wg-manager${NC} - WireGuard peer manager

${BOLD}USAGE${NC}
    wg-manager <command> [arguments]

${BOLD}COMMANDS${NC}
    init                Initialize the WireGuard server
    add   <name>        Add a new peer
    remove <name>       Remove a peer
    list                List all peers and live WireGuard status
    show  <name>        Print the client config for a peer
    status              Show server info and WireGuard status
    help                Show this help message

${BOLD}EXAMPLES${NC}
    sudo wg-manager init
    sudo wg-manager add server-de-01
    sudo wg-manager list
    sudo wg-manager show server-de-01
    sudo wg-manager remove server-de-01

${BOLD}FILES${NC}
    /etc/wg-manager/wg-manager.conf     Server settings
    /etc/wg-manager/clients/            Saved peer configs

${BOLD}PROJECT${NC}
    https://github.com/enavid/wg-manager

EOF
}

# =============================================================================
# Entry Point
# =============================================================================

case "${1:-help}" in
    init)    require_root; check_dependencies; cmd_init ;;
    add)     cmd_add "${2:-}" ;;
    remove)  cmd_remove "${2:-}" ;;
    list)    cmd_list ;;
    show)    cmd_show "${2:-}" ;;
    status)  cmd_status ;;
    help|--help|-h) cmd_help ;;
    *)
        log_error "Unknown command: '${1}'"
        echo "Run 'wg-manager help' for usage."
        exit 1
        ;;
esac
