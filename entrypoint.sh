#!/usr/bin/env bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[claudebox]${RESET} $1"; }
success() { echo -e "${GREEN}[claudebox] ✓${RESET} $1"; }
warn()    { echo -e "${YELLOW}[claudebox] ⚠${RESET} $1"; }
error()   { echo -e "${RED}[claudebox] ✗${RESET} $1"; }

AWG_CONF="/etc/amnezia/awg0.conf"

# ─── Load API key from secret file if available ─────────────────────────────
if [[ -z "${ANTHROPIC_API_KEY:-}" && -f "${ANTHROPIC_API_KEY_FILE:-/run/secrets/anthropic_api_key}" ]]; then
    ANTHROPIC_API_KEY=$(cat "${ANTHROPIC_API_KEY_FILE}")
    export ANTHROPIC_API_KEY
fi

# ─── VPN Setup ──────────────────────────────────────────────────────────────
start_vpn() {
    if [[ ! -f "$AWG_CONF" ]]; then
        warn "No VPN config found at $AWG_CONF"
        warn "Container will run without VPN. Claude API may not be accessible."
        warn "Mount your config: -v /path/to/amnezia.conf:/etc/amnezia/awg0.conf:ro"
        return 1
    fi

    info "Starting AmneziaWG VPN..."

    # Use full path so awg-quick/wg-quick finds the config
    # (default search paths are /etc/amneziawg/ and /etc/wireguard/, not /etc/amnezia/)
    if command -v awg-quick &>/dev/null; then
        if ! sudo awg-quick up "$AWG_CONF"; then
            error "awg-quick failed to start VPN. See errors above."
            return 1
        fi
    elif command -v wg-quick &>/dev/null; then
        warn "awg-quick not found, trying wg-quick (no obfuscation)..."
        if ! sudo wg-quick up "$AWG_CONF"; then
            error "wg-quick failed to start VPN. See errors above."
            return 1
        fi
    else
        error "Neither awg-quick nor wg-quick found."
        return 1
    fi

    # Wait for interface (name derived from config filename: awg0.conf → awg0)
    local iface_name
    iface_name=$(basename "$AWG_CONF" .conf)
    local retries=5
    for ((i=1; i<=retries; i++)); do
        if ip link show "$iface_name" &>/dev/null 2>&1; then
            success "VPN interface is up"
            return 0
        fi
        sleep 1
    done

    error "VPN interface did not come up"
    return 1
}

# ─── Kill Switch ─────────────────────────────────────────────────────────────
setup_killswitch() {
    if [[ "${KILLSWITCH:-1}" == "0" ]]; then
        info "Kill switch disabled"
        return
    fi

    info "Setting up kill switch..."

    # Get VPN server endpoint to allow initial connection
    local endpoint
    endpoint=$(grep -i '^Endpoint' "$AWG_CONF" | head -1 | awk -F'=' '{print $2}' | tr -d ' ' | cut -d: -f1)

    if [[ -z "$endpoint" ]]; then
        warn "Could not determine VPN endpoint, skipping kill switch"
        return
    fi

    # Parse DNS servers from VPN config to restrict DNS traffic
    local dns_servers
    dns_servers=$(grep -i '^DNS' "$AWG_CONF" | head -1 | awk -F'=' '{print $2}' | tr ',' '\n' | tr -d ' ')

    # Set default policy to DROP first (no traffic leak window)
    sudo iptables -P OUTPUT DROP 2>/dev/null || true
    sudo iptables -F OUTPUT 2>/dev/null || true

    # Block all IPv6 to prevent leaks
    sudo ip6tables -P OUTPUT DROP 2>/dev/null || true
    sudo ip6tables -F OUTPUT 2>/dev/null || true
    sudo ip6tables -A OUTPUT -o lo -j ACCEPT
    sudo ip6tables -A OUTPUT -j DROP

    # IPv4: allow only VPN traffic
    local iface_name
    iface_name=$(basename "$AWG_CONF" .conf)
    sudo iptables -A OUTPUT -o lo -j ACCEPT
    sudo iptables -A OUTPUT -o "$iface_name" -j ACCEPT
    sudo iptables -A OUTPUT -d "$endpoint" -j ACCEPT

    # Allow DNS only to servers from VPN config
    if [[ -n "$dns_servers" ]]; then
        for dns in $dns_servers; do
            sudo iptables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
            sudo iptables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
        done
    fi

    # Allow Docker network (for communication with host)
    local docker_network
    docker_network=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [[ -n "$docker_network" ]]; then
        # Allow only the Docker gateway subnet (/16)
        local docker_subnet
        docker_subnet=$(echo "$docker_network" | awk -F. '{print $1"."$2".0.0/16"}')
        sudo iptables -A OUTPUT -d "$docker_subnet" -j ACCEPT
    fi

    success "Kill switch active — traffic only through VPN"
}

# ─── Check API ───────────────────────────────────────────────────────────────
check_api() {
    info "Checking Claude API access..."
    local retries=3
    for ((i=1; i<=retries; i++)); do
        if curl -sf --max-time 5 "https://api.anthropic.com" >/dev/null 2>&1; then
            success "Claude API is reachable"
            return 0
        fi
        sleep 2
    done
    warn "Claude API is not reachable. VPN may not be connected properly."
    warn "Run 'health-check' for diagnostics."
    return 1
}

# ─── Main ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  ┌─────────────────────────────────┐${RESET}"
echo -e "${BOLD}  │         Claudebox                │${RESET}"
echo -e "${BOLD}  └─────────────────────────────────┘${RESET}"
echo ""

vpn_ok=false
if start_vpn; then
    vpn_ok=true
    setup_killswitch
fi

if $vpn_ok; then
    check_api || true
fi

echo ""
echo -e "  ${DIM}Commands:${RESET}"
echo -e "  ${CYAN}claude${RESET}        — Start Claude Code"
echo -e "  ${CYAN}health-check${RESET}  — Check VPN & API status"
echo ""

# Hand off to CMD
exec "$@"
