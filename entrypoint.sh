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

# ─── Обработка API-ключа ─────────────────────────────────────────────────────
# ВАЖНО: мы НЕ экспортируем API-ключ здесь. Он бы утёк через /proc/1/environ
# всем процессам. Вместо этого claude-safe инжектит его только в процесс Claude.
# См.: scripts/claude-wrapper.sh

# ─── Настройка VPN ────────────────────────────────────────────────────────────
start_vpn() {
    if [[ ! -f "$AWG_CONF" ]]; then
        warn "VPN-конфиг не найден: $AWG_CONF"
        warn "Контейнер запустится без VPN. Claude API может быть недоступен."
        warn "Примонтируйте конфиг: -v /path/to/amnezia.conf:/etc/amnezia/awg0.conf:ro"
        return 1
    fi

    info "Запуск AmneziaWG VPN..."

    # Entrypoint запущен от root — sudo не нужен
    if command -v awg-quick &>/dev/null; then
        if ! awg-quick up "$AWG_CONF"; then
            error "awg-quick не смог поднять VPN. См. ошибки выше."
            return 1
        fi
    elif command -v wg-quick &>/dev/null; then
        warn "awg-quick не найден, пробуем wg-quick (без обфускации)..."
        if ! wg-quick up "$AWG_CONF"; then
            error "wg-quick не смог поднять VPN. См. ошибки выше."
            return 1
        fi
    else
        error "Не найден ни awg-quick, ни wg-quick."
        return 1
    fi

    # Ждём появления интерфейса (имя берётся из файла конфига: awg0.conf → awg0)
    local iface_name
    iface_name=$(basename "$AWG_CONF" .conf)
    local retries=5
    for ((i=1; i<=retries; i++)); do
        if ip link show "$iface_name" &>/dev/null 2>&1; then
            success "VPN-интерфейс поднят"
            return 0
        fi
        sleep 1
    done

    error "VPN-интерфейс не появился"
    return 1
}

# ─── Kill Switch ──────────────────────────────────────────────────────────────
setup_killswitch() {
    if [[ "${KILLSWITCH:-1}" == "0" ]]; then
        info "Kill switch отключён"
        return
    fi

    info "Настройка kill switch..."

    # Получаем адрес VPN-сервера для разрешения начального подключения
    local endpoint
    endpoint=$(grep -i '^Endpoint' "$AWG_CONF" | head -1 | awk -F'=' '{print $2}' | tr -d ' ' | cut -d: -f1)

    if [[ -z "$endpoint" ]]; then
        warn "Не удалось определить адрес VPN-сервера, пропускаем kill switch"
        return
    fi

    # Парсим DNS-серверы из VPN-конфига для ограничения DNS-трафика
    local dns_servers
    dns_servers=$(grep -i '^DNS' "$AWG_CONF" | head -1 | awk -F'=' '{print $2}' | tr ',' '\n' | tr -d ' ')

    # Сначала ставим политику DROP (без окна утечки трафика)
    iptables -P OUTPUT DROP 2>/dev/null || true
    iptables -F OUTPUT 2>/dev/null || true

    # Блокируем весь IPv6 для предотвращения утечек
    ip6tables -P OUTPUT DROP 2>/dev/null || true
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -j DROP

    # IPv4: разрешаем только VPN-трафик
    local iface_name
    iface_name=$(basename "$AWG_CONF" .conf)
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -o "$iface_name" -j ACCEPT
    iptables -A OUTPUT -d "$endpoint" -j ACCEPT

    # Разрешаем DNS только к серверам из VPN-конфига
    if [[ -n "$dns_servers" ]]; then
        for dns in $dns_servers; do
            iptables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
            iptables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
        done
    fi

    # Разрешаем Docker-сеть (для связи с хостом)
    local docker_network
    docker_network=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [[ -n "$docker_network" ]]; then
        # Разрешаем только подсеть Docker gateway (/16)
        local docker_subnet
        docker_subnet=$(echo "$docker_network" | awk -F. '{print $1"."$2".0.0/16"}')
        iptables -A OUTPUT -d "$docker_subnet" -j ACCEPT
    fi

    success "Kill switch активен — трафик только через VPN"
}

# ─── Корпоративный bypass ────────────────────────────────────────────────────
setup_corp_bypass() {
    local corp_bypass="${CORP_BYPASS:-}"
    if [[ -z "$corp_bypass" ]]; then
        return
    fi

    info "Настройка корпоративного bypass..."

    # Получаем Docker gateway (корп. трафик идёт через хост, не через VPN)
    local gateway
    gateway=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [[ -z "$gateway" ]]; then
        warn "Не удалось определить Docker gateway, пропускаем корп. bypass"
        return
    fi

    # Получаем имя Docker bridge интерфейса
    local bridge_iface
    bridge_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)

    IFS=',' read -ra domains <<< "$corp_bypass"
    for domain in "${domains[@]}"; do
        domain=$(echo "$domain" | tr -d '[:space:]')
        [[ -z "$domain" ]] && continue

        # Резолвим домен в IP (может вернуть несколько)
        local ips
        ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)

        if [[ -z "$ips" ]]; then
            # Пробуем wildcard: если *.mycorp.com, резолвим mycorp.com
            local base_domain="${domain#\*.}"
            if [[ "$base_domain" != "$domain" ]]; then
                ips=$(dig +short "$base_domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
            fi
        fi

        if [[ -z "$ips" ]]; then
            warn "Не удалось резолвить $domain — попробуем при первом обращении"
            continue
        fi

        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            # Маршрут через Docker gateway (хост), не через VPN
            ip route add "$ip/32" via "$gateway" 2>/dev/null || true
            # Разрешаем в kill-switch
            if [[ -n "$bridge_iface" ]]; then
                iptables -A OUTPUT -d "$ip" -o "$bridge_iface" -j ACCEPT 2>/dev/null || true
            else
                iptables -A OUTPUT -d "$ip" -j ACCEPT 2>/dev/null || true
            fi
        done <<< "$ips"

        success "Bypass: $domain"
    done

    # Разрешаем DNS к Docker gateway (хост может резолвить корп. домены через корп. VPN)
    iptables -A OUTPUT -d "$gateway" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -d "$gateway" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
}

# ─── Проверка API ─────────────────────────────────────────────────────────────
check_api() {
    info "Проверка доступа к Claude API..."
    local retries=3
    for ((i=1; i<=retries; i++)); do
        if curl -sf --max-time 5 "https://api.anthropic.com" >/dev/null 2>&1; then
            success "Claude API доступен"
            return 0
        fi
        sleep 2
    done
    warn "Claude API недоступен. Возможно, VPN не подключён."
    warn "Запустите 'health-check' для диагностики."
    return 1
}

# ─── Основной блок ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  ┌─────────────────────────────────┐${RESET}"
echo -e "${BOLD}  │         Claudebox                │${RESET}"
echo -e "${BOLD}  └─────────────────────────────────┘${RESET}"
echo ""

if [[ "${VPN_ENABLED:-1}" == "0" ]]; then
    info "VPN отключён — используем сеть хоста напрямую"
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
echo -e "  ${DIM}Команды:${RESET}"
echo -e "  ${CYAN}claude-safe${RESET}   — Запуск Claude Code (API-ключ инжектится безопасно)"
echo -e "  ${CYAN}claude${RESET}        — Запуск Claude Code (если авторизованы через браузер)"
echo -e "  ${CYAN}health-check${RESET}  — Проверка статуса VPN и API"
echo ""

# ─── Сброс привилегий и передача управления CMD ──────────────────────────────
# Запускаем шелл пользователя от имени непривилегированного юзера.
# gosu предпочтительнее su, т.к. делает exec напрямую (без лишнего процесса).
exec gosu "$CLAUDE_USER" "$@"
