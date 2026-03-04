#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; errors=$((errors + 1)); }
warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }

echo ""
echo -e "${BOLD}  Claudebox Health Check${RESET}"
echo -e "  ━━━━━━━━━━━━━━━━━━━━━"
echo ""

errors=0

# 1. VPN interface — detect any awg*/wg* interface
echo -e "${CYAN}  VPN${RESET}"
vpn_iface=""
for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(awg|wg)'); do
    vpn_iface="$iface"
    break
done

if [[ -n "$vpn_iface" ]]; then
    ok "VPN interface ($vpn_iface) is up"
    vpn_ip=$(ip -4 addr show "$vpn_iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [[ -n "$vpn_ip" ]]; then
        ok "VPN IP: $vpn_ip"
    fi
else
    fail "No VPN interface found"
fi

# Show peer status (awg/wg show requires root — may not be available)
if command -v awg &>/dev/null; then
    handshake=$(awg show 2>/dev/null | grep "latest handshake" | head -1 || true)
elif command -v wg &>/dev/null; then
    handshake=$(wg show 2>/dev/null | grep "latest handshake" | head -1 || true)
else
    handshake=""
fi
if [[ -n "${handshake:-}" ]]; then
    ok "Peer handshake:$(echo "$handshake" | sed 's/.*latest handshake://')"
fi

echo ""

# 2. DNS
echo -e "${CYAN}  DNS${RESET}"
resolved_ip=$(dig +short api.anthropic.com 2>/dev/null | head -1)
if [[ -n "$resolved_ip" ]]; then
    ok "api.anthropic.com resolves to ${resolved_ip}"
else
    fail "Cannot resolve api.anthropic.com"
fi

echo ""

# 3. API connectivity
echo -e "${CYAN}  Claude API${RESET}"
if curl -sf --max-time 5 "https://api.anthropic.com" >/dev/null 2>&1; then
    ok "HTTPS connection to api.anthropic.com"
else
    fail "Cannot reach api.anthropic.com over HTTPS"
fi

echo ""

# 4. Claude Code
echo -e "${CYAN}  Claude Code${RESET}"
if command -v claude &>/dev/null; then
    claude_version=$(claude --version 2>/dev/null || echo "unknown")
    ok "Claude Code installed (${claude_version})"
else
    fail "Claude Code CLI not found"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    ok "ANTHROPIC_API_KEY is set"
elif [[ -f "$HOME/.claude/credentials.json" ]]; then
    ok "Claude credentials found"
else
    warn "No API key or credentials configured"
    warn "Run 'claude' to authenticate"
fi

echo ""

# 5. Projects
echo -e "${CYAN}  Projects${RESET}"
if [[ -d /home/claude/projects ]]; then
    count=$(find /home/claude/projects -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
    ok "Projects directory mounted ($count items)"
else
    warn "Projects directory not found"
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━"
if [[ $errors -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All checks passed!${RESET}"
else
    echo -e "  ${RED}${BOLD}$errors check(s) failed${RESET}"
fi
echo ""

exit "$errors"
