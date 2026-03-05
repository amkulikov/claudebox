#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[claudebox]${RESET} $1" >&2; }
success() { echo -e "${GREEN}[claudebox] ✓${RESET} $1" >&2; }
warn()    { echo -e "${YELLOW}[claudebox] ⚠${RESET} $1" >&2; }
error()   { echo -e "${RED}[claudebox] ✗${RESET} $1" >&2; }

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
        if ip link show "$iface_name" &>/dev/null; then
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

    # Получаем адрес и порт VPN-сервера для разрешения начального подключения
    local endpoint_raw endpoint endpoint_port
    endpoint_raw=$(grep -i '^Endpoint' "$AWG_CONF" | head -1 | sed 's/^[^=]*= *//')

    if [[ -z "$endpoint_raw" ]]; then
        warn "Не удалось определить адрес VPN-сервера, пропускаем kill switch"
        return 1
    fi

    # Парсим хост и порт (поддержка IPv6: [2001:db8::1]:51820)
    if [[ "$endpoint_raw" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
        # IPv6: [addr]:port
        endpoint="${BASH_REMATCH[1]}"
        endpoint_port="${BASH_REMATCH[2]}"
    elif [[ "$endpoint_raw" =~ ^([^:]+):([0-9]+)$ ]]; then
        # IPv4 или hostname: addr:port
        endpoint="${BASH_REMATCH[1]}"
        endpoint_port="${BASH_REMATCH[2]}"
    else
        endpoint="$endpoint_raw"
        endpoint_port=""
    fi

    # Парсим DNS-серверы из VPN-конфига для ограничения DNS-трафика
    local dns_servers
    dns_servers=$(grep -i '^DNS' "$AWG_CONF" | head -1 | sed 's/^[^=]*= *//' | tr ',' '\n' | tr -d ' ')

    # Сначала ставим политику DROP (без окна утечки трафика)
    iptables -P OUTPUT DROP 2>/dev/null || true
    iptables -F OUTPUT 2>/dev/null || true

    # Блокируем весь IPv6 для предотвращения утечек
    ip6tables -P OUTPUT DROP 2>/dev/null || true
    ip6tables -F OUTPUT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT
    # Явное правило DROP не нужно — политика уже DROP

    # IPv4: разрешаем только VPN-трафик
    local iface_name
    iface_name=$(basename "$AWG_CONF" .conf)
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -o "$iface_name" -j ACCEPT
    # Разрешаем только UDP на порт WireGuard к VPN-серверу (не весь трафик)
    if [[ -n "$endpoint_port" ]]; then
        iptables -A OUTPUT -d "$endpoint" -p udp --dport "$endpoint_port" -j ACCEPT
    else
        iptables -A OUTPUT -d "$endpoint" -p udp -j ACCEPT
    fi

    # Разрешаем DNS только к серверам из VPN-конфига
    if [[ -n "$dns_servers" ]]; then
        for dns in $dns_servers; do
            iptables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
            iptables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
        done
    fi

    # Разрешаем Docker-сеть (для связи с хостом)
    # Берём реальную подсеть из таблицы маршрутизации вместо хардкода /16
    local docker_subnet
    docker_subnet=$(ip -4 route show 2>/dev/null | grep -v "default" | grep -v "$iface_name" | awk '{print $1}' | grep '/' | head -1)
    if [[ -n "$docker_subnet" ]]; then
        iptables -A OUTPUT -d "$docker_subnet" -j ACCEPT
    else
        # Фолбэк: разрешаем gateway напрямую
        local docker_gw
        docker_gw=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
        if [[ -n "$docker_gw" ]]; then
            iptables -A OUTPUT -d "$docker_gw" -j ACCEPT
        fi
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

    # Разрешаем DNS к Docker gateway ДО резолвинга корп-доменов,
    # чтобы dig мог использовать DNS хоста (корп. DNS может отличаться от VPN DNS)
    iptables -A OUTPUT -d "$gateway" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -d "$gateway" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true

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
}

# ─── Проверка API ─────────────────────────────────────────────────────────────
check_api() {
    info "Проверка доступа к Claude API..."
    local retries=3
    for ((i=1; i<=retries; i++)); do
        if curl -s -o /dev/null --max-time 5 "https://api.anthropic.com" 2>/dev/null; then
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
        setup_killswitch || warn "Kill switch не настроен — см. ошибки выше"
        setup_corp_bypass || warn "Корпоративный bypass не настроен — см. ошибки выше"
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

# ─── Фиксим права на рабочие директории ──────────────────────────────────────
# При монтировании volume /home/claude/projects может сменить владельца на
# хостовой UID. Claude CLI делает lstat на CWD — без прав получим EACCES.
if [[ "$(id -u)" == "0" ]]; then
    # Определяем UID/GID владельца первого смонтированного проекта
    host_uid=$(stat -c '%u' /home/claude/projects 2>/dev/null || echo "")
    host_gid=$(stat -c '%g' /home/claude/projects 2>/dev/null || echo "")
    claude_uid=$(id -u "$CLAUDE_USER" 2>/dev/null || echo "")

    # Если /home/claude/projects принадлежит чужому UID (bind mount) —
    # подгоняем UID claude под хост, чтобы файлы были read/write
    if [[ -n "$host_uid" && -n "$claude_uid" && "$host_uid" != "0" && "$host_uid" != "$claude_uid" ]]; then
        info "UID хоста ($host_uid) ≠ claude ($claude_uid) — подгоняем..."
        usermod -u "$host_uid" "$CLAUDE_USER" 2>/dev/null || true
        groupmod -g "${host_gid:-$host_uid}" "$CLAUDE_USER" 2>/dev/null || true
        # Фиксим владельца домашней директории после смены UID
        chown -R "$CLAUDE_USER:$CLAUDE_USER" /home/claude/.claude 2>/dev/null || true
    fi

    # В любом случае гарантируем доступ к рабочей директории и конфигам
    chown "$CLAUDE_USER:$CLAUDE_USER" /home/claude/projects 2>/dev/null || true
    chmod 755 /home/claude/projects 2>/dev/null || true
    chown -R "$CLAUDE_USER:$CLAUDE_USER" /home/claude/.claude 2>/dev/null || true
fi

# ─── Сброс привилегий и передача управления CMD ──────────────────────────────
# Запускаем CMD от имени непривилегированного юзера.
# Порядок: gosu (exec без лишнего процесса) → runuser (PAM, всегда есть) → прямой exec.
if [[ "$(id -u)" == "0" ]]; then
    if command -v gosu &>/dev/null && gosu "$CLAUDE_USER" true 2>/dev/null; then
        exec gosu "$CLAUDE_USER" "$@"
    elif command -v runuser &>/dev/null; then
        exec runuser -u "$CLAUDE_USER" -- "$@"
    else
        warn "Не удалось сбросить привилегии — запуск от root"
        exec "$@"
    fi
else
    exec "$@"
fi
