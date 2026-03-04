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
echo -e "${BOLD}  Диагностика Claudebox${RESET}"
echo -e "  ━━━━━━━━━━━━━━━━━━━━━━"
echo ""

errors=0

# 1. VPN
echo -e "${CYAN}  VPN${RESET}"
if [[ "${VPN_ENABLED:-1}" == "0" ]]; then
    ok "VPN отключён — используется сеть хоста"
else
    vpn_iface=""
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(awg|wg)'); do
        vpn_iface="$iface"
        break
    done

    if [[ -n "$vpn_iface" ]]; then
        ok "VPN-интерфейс ($vpn_iface) поднят"
        vpn_ip=$(ip -4 addr show "$vpn_iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        if [[ -n "$vpn_ip" ]]; then
            ok "VPN IP: $vpn_ip"
        fi
    else
        fail "VPN-интерфейс не найден"
    fi

    # Статус пира (awg/wg show требует root — может быть недоступен)
    if command -v awg &>/dev/null; then
        handshake=$(awg show 2>/dev/null | grep "latest handshake" | head -1 || true)
    elif command -v wg &>/dev/null; then
        handshake=$(wg show 2>/dev/null | grep "latest handshake" | head -1 || true)
    else
        handshake=""
    fi
    if [[ -n "${handshake:-}" ]]; then
        ok "Рукопожатие с пиром:$(echo "$handshake" | sed 's/.*latest handshake://')"
    fi
fi

echo ""

# 2. DNS
echo -e "${CYAN}  DNS${RESET}"
resolved_ip=$(dig +short api.anthropic.com 2>/dev/null | head -1)
if [[ -n "$resolved_ip" ]]; then
    ok "api.anthropic.com → ${resolved_ip}"
else
    fail "Не удаётся резолвить api.anthropic.com"
fi

echo ""

# 3. Подключение к API
echo -e "${CYAN}  Claude API${RESET}"
if curl -sf --max-time 5 "https://api.anthropic.com" >/dev/null 2>&1; then
    ok "HTTPS-подключение к api.anthropic.com"
else
    fail "Нет доступа к api.anthropic.com по HTTPS"
fi

echo ""

# 4. Claude Code
echo -e "${CYAN}  Claude Code${RESET}"
if command -v claude &>/dev/null; then
    claude_version=$(claude --version 2>/dev/null || echo "неизвестно")
    ok "Claude Code установлен (${claude_version})"
else
    fail "Claude Code CLI не найден"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    ok "ANTHROPIC_API_KEY задан"
elif [[ -f "$HOME/.claude/credentials.json" ]]; then
    ok "Учётные данные Claude найдены"
else
    warn "Нет API-ключа или учётных данных"
    warn "Запустите 'claude' для авторизации"
fi

echo ""

# 5. Корпоративный bypass
if [[ -n "${CORP_BYPASS:-}" ]]; then
    echo -e "${CYAN}  Корпоративный bypass${RESET}"
    IFS=',' read -ra corp_domains <<< "$CORP_BYPASS"
    for domain in "${corp_domains[@]}"; do
        domain=$(echo "$domain" | tr -d '[:space:]')
        [[ -z "$domain" ]] && continue
        # Пробуем резолвить (пропускаем wildcard-префикс)
        check_domain="${domain#\*.}"
        if dig +short "$check_domain" &>/dev/null && [[ -n "$(dig +short "$check_domain" 2>/dev/null)" ]]; then
            ok "$domain резолвится"
        else
            warn "$domain — не удаётся резолвить (DNS хоста может быть недоступен)"
        fi
    done
    echo ""
fi

# 6. Проекты
echo -e "${CYAN}  Проекты${RESET}"
if [[ -d /home/claude/projects ]]; then
    count=$(find /home/claude/projects -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
    ok "Директория проектов примонтирована ($count элементов)"
else
    warn "Директория проектов не найдена"
fi

echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━"
if [[ $errors -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Все проверки пройдены!${RESET}"
else
    echo -e "  ${RED}${BOLD}Не пройдено проверок: $errors${RESET}"
fi
echo ""

exit "$errors"
