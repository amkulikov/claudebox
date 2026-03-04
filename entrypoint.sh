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
CLAUDE_USER="claude"

# ─── API key handling ────────────────────────────────────────────────────────
# NOTE: We do NOT export the API key here. It would leak via /proc/1/environ
# to all processes. Instead, claude-safe wrapper injects it per-process only.
# See: scripts/claude-wrapper.sh

# ─── VPN Setup ──────────────────────────────────────────────────────────────
start_vpn() {
    if [[ ! -f "$AWG_CONF" ]]; then
        warn "No VPN config found at $AWG_CONF"
        warn "Container will run without VPN. Claude API may not be accessible."
        warn "Mount your config: -v /path/to/amnezia.conf:/etc/amnezia/awg0.conf:ro"
        return 1
    fi

    info "Starting AmneziaWG VPN..."

    # Entrypoint runs as root — no sudo needed
    if command -v awg-quick &>/dev/null; then
        if ! awg-quick up "$AWG_CONF"; then
            error "awg-quick failed to start VPN. See errors above."
            return 1
        fi
    elif command -v wg-quick &>/dev/null; then
        warn "awg-quick not found, trying wg-quick (no obfuscation)..."
        if ! wg-quick up "$AWG_CONF"; then
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
    iptables -P OUTPUT DROP 2>/dev/null || true
    iptables -F OUTPUT 2>/dev/null || true

    # Block all IPv6 to prevent leaks
    ip6tables -P OUTPUT DROP 2>/dev/null || true
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -j DROP

    # IPv4: allow only VPN traffic
    local iface_name
    iface_name=$(basename "$AWG_CONF" .conf)
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -o "$iface_name" -j ACCEPT
    iptables -A OUTPUT -d "$endpoint" -j ACCEPT

    # Allow DNS only to servers from VPN config
    if [[ -n "$dns_servers" ]]; then
        for dns in $dns_servers; do
            iptables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
            iptables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
        done
    fi

    # Allow Docker network (for communication with host)
    local docker_network
    docker_network=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [[ -n "$docker_network" ]]; then
        # Allow only the Docker gateway subnet (/16)
        local docker_subnet
        docker_subnet=$(echo "$docker_network" | awk -F. '{print $1"."$2".0.0/16"}')
        iptables -A OUTPUT -d "$docker_subnet" -j ACCEPT
    fi

    success "Kill switch active — traffic only through VPN"
}

# ─── Corporate bypass ────────────────────────────────────────────────────────
setup_corp_bypass() {
    local corp_bypass="${CORP_BYPASS:-}"
    if [[ -z "$corp_bypass" ]]; then
        return
    fi

    info "Setting up corporate domain bypass..."

    # Get Docker gateway (traffic to corp goes through host, not VPN)
    local gateway
    gateway=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [[ -z "$gateway" ]]; then
        warn "Cannot determine Docker gateway, skipping corp bypass"
        return
    fi

    # Get the Docker bridge interface name
    local bridge_iface
    bridge_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)

    IFS=',' read -ra domains <<< "$corp_bypass"
    for domain in "${domains[@]}"; do
        domain=$(echo "$domain" | tr -d '[:space:]')
        [[ -z "$domain" ]] && continue

        # Resolve domain to IPs (may return multiple)
        local ips
        ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)

        if [[ -z "$ips" ]]; then
            # Try wildcard: if *.mycorp.com, resolve mycorp.com
            local base_domain="${domain#\*.}"
            if [[ "$base_domain" != "$domain" ]]; then
                ips=$(dig +short "$base_domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
            fi
        fi

        if [[ -z "$ips" ]]; then
            warn "Cannot resolve $domain — will retry at first access"
            continue
        fi

        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            # Route through Docker gateway (host), not through VPN
            ip route add "$ip/32" via "$gateway" 2>/dev/null || true
            # Allow in kill-switch
            if [[ -n "$bridge_iface" ]]; then
                iptables -A OUTPUT -d "$ip" -o "$bridge_iface" -j ACCEPT 2>/dev/null || true
            else
                iptables -A OUTPUT -d "$ip" -j ACCEPT 2>/dev/null || true
            fi
        done <<< "$ips"

        success "Bypass: $domain"
    done

    # Also allow DNS to Docker gateway (host can resolve corp domains via corp VPN)
    iptables -A OUTPUT -d "$gateway" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -d "$gateway" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
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

if [[ "${VPN_ENABLED:-1}" == "0" ]]; then
    info "VPN disabled — using host network directly"
    check_api || true
else
    vpn_ok=false
    if start_vpn; then
        vpn_ok=true
        setup_killswitch
        setup_corp_bypass
    fi

    if $vpn_ok; then
        check_api || true
    fi
fi

echo ""
echo -e "  ${DIM}Commands:${RESET}"
echo -e "  ${CYAN}claude-safe${RESET}   — Start Claude Code (API key injected securely)"
echo -e "  ${CYAN}claude${RESET}        — Start Claude Code (if authenticated via browser)"
echo -e "  ${CYAN}health-check${RESET}  — Check VPN & API status"
echo ""

# ─── Drop privileges and hand off to CMD ─────────────────────────────────────
# Run the user's shell as non-root. This is the last thing we do.
# gosu is preferred over su because it execs directly (no extra process).
exec gosu "$CLAUDE_USER" "$@"
