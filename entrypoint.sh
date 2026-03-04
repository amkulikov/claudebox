#!/usr/bin/env bash
set -euo pipefail

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

# ─── VPN Setup ──────────────────────────────────────────────────────────────
start_vpn() {
    if [[ ! -f "$AWG_CONF" ]]; then
        warn "No VPN config found at $AWG_CONF"
        warn "Container will run without VPN. Claude API may not be accessible."
        warn "Mount your config: -v /path/to/amnezia.conf:/etc/amnezia/awg0.conf:ro"
        return 1
    fi

    info "Starting AmneziaWG VPN..."

    # Need root for VPN
    if ! sudo awg-quick up awg0 2>/dev/null; then
        # Fallback: try standard wg-quick if awg-quick not available
        if command -v wg-quick &>/dev/null; then
            warn "awg-quick failed, trying wg-quick..."
            if ! sudo wg-quick up awg0 2>/dev/null; then
                error "VPN failed to start. Check your config."
                return 1
            fi
        else
            error "VPN failed to start. Check your config."
            return 1
        fi
    fi

    # Wait for interface
    local retries=5
    for ((i=1; i<=retries; i++)); do
        if ip link show awg0 &>/dev/null 2>&1 || ip link show wg0 &>/dev/null 2>&1; then
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

    # Allow only VPN traffic + DNS + local network
    sudo iptables -F OUTPUT 2>/dev/null || true
    sudo iptables -A OUTPUT -o lo -j ACCEPT
    sudo iptables -A OUTPUT -o awg0 -j ACCEPT
    sudo iptables -A OUTPUT -o wg0 -j ACCEPT
    sudo iptables -A OUTPUT -d "$endpoint" -j ACCEPT
    sudo iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
    sudo iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
    sudo iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
    sudo iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    sudo iptables -A OUTPUT -j DROP

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
    check_api
fi

echo ""
echo -e "  ${DIM}Commands:${RESET}"
echo -e "  ${CYAN}claude${RESET}        — Start Claude Code"
echo -e "  ${CYAN}health-check${RESET}  — Check VPN & API status"
echo ""

# Hand off to CMD
exec "$@"
