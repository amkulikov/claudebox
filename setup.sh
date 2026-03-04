#!/usr/bin/env bash
set -euo pipefail

# ─── Минимальная версия bash (ассоциативные массивы требуют bash 4+) ─────────
if (( BASH_VERSINFO[0] < 4 )); then
    echo "Ошибка: требуется bash 4+ (у вас ${BASH_VERSION}). На macOS: brew install bash" >&2
    exit 1
fi

# ─── Проверка интерактивного терминала ────────────────────────────────────────
if [[ ! -t 0 || ! -t 1 ]]; then
    echo "Ошибка: скрипт требует интерактивный терминал (TTY)" >&2
    exit 1
fi

# ─── Ловушка ошибок для читаемых сообщений при падении ────────────────────────
trap 'echo -e "\033[0;31m✗ Ошибка в строке $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

# ─── Цвета и хелперы ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CONFIGS_DIR="$SCRIPT_DIR/configs"
SECRETS_DIR="$SCRIPT_DIR/secrets"

# Создаём необходимые директории с ограниченными правами
mkdir -p "$CONFIGS_DIR" && chmod 700 "$CONFIGS_DIR"
mkdir -p -m 700 "$SECRETS_DIR"

info()    { echo -e "${CYAN}$1${RESET}" >&2; }
success() { echo -e "${GREEN}✓ $1${RESET}" >&2; }
warn()    { echo -e "${YELLOW}⚠ $1${RESET}" >&2; }
error()   { echo -e "${RED}✗ $1${RESET}" >&2; }
header()  { echo -e "\n${BOLD}$1${RESET}" >&2; }
dim()     { echo -e "${DIM}$1${RESET}" >&2; }

ask() {
    local prompt="$1"
    local default="${2:-}"
    if [[ -n "$default" ]]; then
        echo -ne "  ${prompt} ${DIM}[${default}]${RESET}: " >&2
    else
        echo -ne "  ${prompt}: " >&2
    fi
    read -r answer
    echo "${answer:-$default}"
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    echo -e "  ${prompt}" >&2
    for i in "${!options[@]}"; do
        echo -e "    ${BOLD}$((i+1)).${RESET} ${options[$i]}" >&2
    done
    while true; do
        echo -ne "  ${DIM}Введите номер [1-${#options[@]}]${RESET}: " >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "$choice"
            return
        fi
        error "Неверный выбор, попробуйте ещё раз"
    done
}

# ─── Очистка пути (drag & drop, кавычки, пробелы) ────────────────────────────
clean_path() {
    local p="$1"
    # Убрать кавычки
    p="${p#\'}" ; p="${p%\'}"
    p="${p#\"}" ; p="${p%\"}"
    # Убрать пробелы в конце
    p="${p%"${p##*[![:space:]]}"}"
    # Раскрыть экранированные пробелы (drag & drop на macOS)
    p="${p//\\ / }"
    # Раскрыть ~
    p="${p/#\~/$HOME}"
    echo "$p"
}

# ─── Баннер ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "  ┌──────────────────────────────────────┐"
echo "  │       Настройка Claudebox            │"
echo "  │   Docker + Claude Code + VPN         │"
echo "  └──────────────────────────────────────┘"
echo -e "${RESET}"

# ─── Проверка зависимостей ────────────────────────────────────────────────────
header "[0/6] Проверка зависимостей..."

if ! command -v docker &>/dev/null; then
    error "Docker не найден. Установите: https://docs.docker.com/get-docker/"
    exit 1
fi

# Проверка что Docker-демон запущен
if ! docker info &>/dev/null 2>&1; then
    error "Docker-демон не запущен. Запустите его и перезапустите этот скрипт."
    exit 1
fi

# Определяем команду compose один раз
if docker compose version &>/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif docker-compose version &>/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    error "docker compose не найден"
    exit 1
fi

success "Docker установлен и запущен (${COMPOSE[*]})"

# ─── Шаг 1: VPN ──────────────────────────────────────────────────────────────
header "[1/6] Настройка VPN"
echo ""

vpn_enabled=false
vpn_configured=false

vpn_choice=$(ask_choice "Будете использовать Amnezia VPN для доступа к Claude API?" \
    "Да, у меня есть конфиг AmneziaWG" \
    "Нет, Claude API доступен без VPN")

if [[ "$vpn_choice" == "1" ]]; then
    vpn_enabled=true
    echo ""
    dim "  Вам нужен конфиг-файл AmneziaWG от вашего Amnezia VPN сервера."
    dim "  Выглядит как конфиг WireGuard с доп. полями (Jc, Jmin, Jmax, S1, S2, H1-H4)."
    dim "  В приложении Amnezia: Настройки → Серверы → Поделиться → Конфиг WireGuard."
    echo ""

    while true; do
        vpn_path=$(ask "Путь к конфигу AmneziaWG (или перетащите файл)")
        vpn_path=$(clean_path "$vpn_path")

        if [[ ! -f "$vpn_path" ]]; then
            error "Файл не найден: $vpn_path"
            choice=$(ask_choice "Что делаем?" "Попробовать снова" "Пропустить (настрою позже)")
            if [[ "$choice" == "2" ]]; then
                warn "VPN-конфиг пропущен. Положите его в configs/amnezia.conf перед запуском."
                break
            fi
            continue
        fi

        # Базовая проверка: похож ли на WireGuard-конфиг
        if ! grep -qi '\[Interface\]' "$vpn_path"; then
            error "Не похоже на конфиг WireGuard/AmneziaWG (нет секции [Interface])"
            choice=$(ask_choice "Что делаем?" "Попробовать другой файл" "Использовать как есть" "Пропустить")
            if [[ "$choice" == "1" ]]; then
                continue
            elif [[ "$choice" == "3" ]]; then
                warn "VPN-конфиг пропущен."
                break
            fi
        fi

        cp "$vpn_path" "$CONFIGS_DIR/amnezia.conf"
        chmod 600 "$CONFIGS_DIR/amnezia.conf"
        success "Конфиг скопирован в configs/amnezia.conf"
        vpn_configured=true
        break
    done
else
    # Создаём файл-заглушку, чтобы Docker-маунт не падал
    if [[ ! -f "$CONFIGS_DIR/amnezia.conf" ]]; then
        echo "# VPN отключён — файл-заглушка" > "$CONFIGS_DIR/amnezia.conf"
    fi
    success "Работа без VPN — Claude API должен быть доступен из сети хоста"
fi

# ─── Шаг 2: Аутентификация Claude ────────────────────────────────────────────
header "[2/6] Аутентификация Claude"
echo ""

auth_choice=$(ask_choice "Как хотите авторизоваться в Claude?" \
    "API-ключ (вставить сейчас)" \
    "Через браузер (после запуска контейнера)")

# Собираем значения .env (пишем всё разом в конце, чтобы не было частичной записи)
declare -A env_vars

# Сохраняем режим VPN
if $vpn_enabled; then
    env_vars[VPN_ENABLED]="1"
else
    env_vars[VPN_ENABLED]="0"
fi

if [[ "$auth_choice" == "1" ]]; then
    while true; do
        echo -ne "  Вставьте ANTHROPIC_API_KEY (ввод скрыт): "
        read -rs api_key
        echo ""

        if [[ -z "$api_key" ]]; then
            error "API-ключ не может быть пустым"
            continue
        fi

        if [[ ! "$api_key" =~ ^sk-ant- ]]; then
            warn "Ключ не начинается с 'sk-ant-'. Возможно, он всё равно рабочий."
            choice=$(ask_choice "Продолжить с этим ключом?" "Да" "Ввести заново")
            if [[ "$choice" == "2" ]]; then
                continue
            fi
        fi

        # Сохраняем ключ в файл (безопаснее env-переменной — не виден через docker inspect)
        (umask 077; echo -n "$api_key" > "$SECRETS_DIR/anthropic_api_key")
        # Очищаем ключ из памяти шелла
        api_key=""; unset api_key
        success "API-ключ сохранён в $SECRETS_DIR/anthropic_api_key"
        break
    done
else
    success "Авторизация через браузер — после запуска контейнера"
    dim "  Выполните 'claude' внутри контейнера для входа"
fi

# ─── Шаг 3: Корпоративный bypass (только с VPN) ──────────────────────────────
if $vpn_enabled; then
    header "[3/6] Корпоративные домены"
    echo ""
    dim "  Если вам нужен доступ к корпоративным ресурсам (Git, npm, внутренние API)"
    dim "  из контейнера — укажите их домены."
    dim "  Трафик к ним пойдёт через хост (и ваш корпоративный VPN),"
    dim "  минуя туннель Amnezia VPN."
    dim "  Оставьте пустым, если нужен только Claude API."
    echo ""

    corp_domains=()

    add_corp=$(ask_choice "Нужен доступ к корпоративным доменам из контейнера?" \
        "Да, введу домены" \
        "Нет, пропустить")

    if [[ "$add_corp" == "1" ]]; then
        dim "  Вводите домены по одному. Пустая строка — завершить."
        dim "  Примеры: git.mycorp.com, registry.mycorp.com, *.mycorp.com"
        echo ""
        while true; do
            domain=$(ask "Домен (или пусто для завершения)")
            if [[ -z "$domain" ]]; then
                break
            fi
            # Убираем пробелы
            domain=$(echo "$domain" | tr -d '[:space:]')
            if [[ -z "$domain" ]]; then
                continue
            fi
            corp_domains+=("$domain")
            success "Добавлен: $domain"
        done
    fi

    if [[ ${#corp_domains[@]} -gt 0 ]]; then
        corp_list=$(IFS=,; echo "${corp_domains[*]}")
        env_vars[CORP_BYPASS]="$corp_list"
        success "Корпоративный bypass: ${corp_list}"
        dim "  Эти домены будут маршрутизироваться через хост"
    else
        dim "  Корпоративный bypass не настроен."
    fi
    echo ""
else
    header "[3/6] Корпоративные домены"
    dim "  Пропущено (без VPN — весь трафик идёт через хост)"
    echo ""
fi

# ─── Шаг 4: Директория с проектами ───────────────────────────────────────────
header "[4/6] Директория проектов"
echo ""
dim "  Эта директория будет смонтирована внутри контейнера в /home/claude/projects."
dim "  Claude Code сможет работать с любым проектом внутри неё."
echo ""

default_projects="$HOME/projects"
projects_path=$(ask "Путь к директории с проектами" "$default_projects")
projects_path=$(clean_path "$projects_path")

if [[ ! -d "$projects_path" ]]; then
    choice=$(ask_choice "Директория '$projects_path' не существует. Создать?" "Да" "Выбрать другой путь" "Пропустить")
    if [[ "$choice" == "1" ]]; then
        mkdir -p "$projects_path"
        success "Создана $projects_path"
    elif [[ "$choice" == "2" ]]; then
        projects_path=$(ask "Путь к директории с проектами")
        projects_path=$(clean_path "$projects_path")
        if [[ ! -d "$projects_path" ]]; then
            mkdir -p "$projects_path"
            success "Создана $projects_path"
        fi
    else
        projects_path="$default_projects"
        mkdir -p "$projects_path"
        warn "Используется по умолчанию: $projects_path"
    fi
fi

env_vars[PROJECTS_PATH]="$projects_path"
success "Будет смонтировано: $projects_path → /home/claude/projects"

# ─── Запись .env файла (всё сразу) ───────────────────────────────────────────
{
    for key in $(printf '%s\n' "${!env_vars[@]}" | sort); do
        val="${env_vars[$key]}"
        # Экранируем обратные слеши и кавычки для формата .env
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        echo "${key}=\"${val}\""
    done
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# ─── Шаг 5: Скрытие директорий ───────────────────────────────────────────────
header "[5/6] Скрытие директорий"
echo ""
dim "  Скройте директории от Claude Code внутри ваших проектов."
dim "  Два уровня защиты:"
dim "    Мягкий — .claudeignore: Claude Code не будет искать/читать эти пути"
dim "    Жёсткий — tmpfs overlay: пустая директория поверх реальной (невидима в контейнере)"
echo ""

# Паттерны подозрительных директорий для автодетекта
SUSPECT_PATTERNS=("datafixes" "secrets")

claudeignore_entries=()
overlay_entries=()

# ── 5a. Автодетект подозрительных путей ───────────────────────────────────────
detected_paths=()
for pattern in "${SUSPECT_PATTERNS[@]}"; do
    while IFS= read -r found_path; do
        rel="${found_path#"$projects_path"/}"
        detected_paths+=("$rel")
    done < <(find "$projects_path" -maxdepth 4 -type d -name "$pattern" 2>/dev/null)
done

if [[ ${#detected_paths[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}Найдены потенциально чувствительные пути:${RESET}" >&2
    echo "" >&2

    # Отслеживаем выбранные (по умолчанию все выбраны)
    declare -A selected
    for i in "${!detected_paths[@]}"; do
        selected[$i]=1
    done

    # Показываем список с переключением
    while true; do
        for i in "${!detected_paths[@]}"; do
            if [[ "${selected[$i]}" == "1" ]]; then
                echo -e "    ${GREEN}[x]${RESET} ${BOLD}$((i+1)).${RESET} ${detected_paths[$i]}" >&2
            else
                echo -e "    ${DIM}[ ]${RESET} ${BOLD}$((i+1)).${RESET} ${DIM}${detected_paths[$i]}${RESET}" >&2
            fi
        done
        echo "" >&2
        echo -ne "  ${DIM}Номер для переключения, 'a' — выбрать все, 'n' — снять все, 'done' — готово${RESET}: " >&2
        read -r toggle_input

        if [[ "$toggle_input" == "done" || "$toggle_input" == "" ]]; then
            break
        elif [[ "$toggle_input" == "a" ]]; then
            for i in "${!detected_paths[@]}"; do selected[$i]=1; done
        elif [[ "$toggle_input" == "n" ]]; then
            for i in "${!detected_paths[@]}"; do selected[$i]=0; done
        elif [[ "$toggle_input" =~ ^[0-9]+$ ]] && (( toggle_input >= 1 )); then
            idx=$((toggle_input - 1))
            if (( idx < ${#detected_paths[@]} )); then
                if [[ "${selected[$idx]}" == "1" ]]; then
                    selected[$idx]=0
                else
                    selected[$idx]=1
                fi
            else
                error "Неверный номер"
            fi
        else
            error "Неверный ввод"
        fi
    done

    # Спрашиваем уровень защиты для выбранных путей
    has_selected=false
    for i in "${!detected_paths[@]}"; do
        if [[ "${selected[$i]}" == "1" ]]; then
            has_selected=true
            break
        fi
    done

    if $has_selected; then
        level=$(ask_choice "Уровень защиты для выбранных путей?" \
            "Мягкий (только .claudeignore)" \
            "Жёсткий (tmpfs overlay — физически скрыт)")

        for i in "${!detected_paths[@]}"; do
            if [[ "${selected[$i]}" == "1" ]]; then
                claudeignore_entries+=("${detected_paths[$i]}")
                if [[ "$level" == "2" ]]; then
                    overlay_entries+=("${detected_paths[$i]}")
                fi
                success "Добавлен: ${detected_paths[$i]}"
            fi
        done
    fi
else
    dim "  Подозрительных путей не найдено."
fi

# ── 5b. Ручной поиск ─────────────────────────────────────────────────────────
echo "" >&2
add_more=$(ask_choice "Искать ещё пути для скрытия?" \
    "Да, поиск по имени" \
    "Нет, продолжить")

while [[ "$add_more" == "1" ]]; do
    echo -ne "  Поиск (часть имени): " >&2
    read -r search_term

    if [[ -z "$search_term" ]]; then
        add_more=$(ask_choice "Искать ещё?" "Да" "Нет, продолжить")
        continue
    fi

    # Экранируем glob-символы для безопасности find
    safe_term=$(printf '%s' "$search_term" | sed 's/[][*?\\]/\\&/g')

    # Поиск совпадений
    search_results=()
    while IFS= read -r found_path; do
        rel="${found_path#"$projects_path"/}"
        search_results+=("$rel")
    done < <(find "$projects_path" -maxdepth 5 -iname "*${safe_term}*" 2>/dev/null | head -20)

    if [[ ${#search_results[@]} -eq 0 ]]; then
        warn "Нет совпадений для '$search_term'"
        add_more=$(ask_choice "Искать ещё?" "Да" "Нет, продолжить")
        continue
    fi

    echo "" >&2
    echo -e "  ${CYAN}Найдено ${#search_results[@]} совпадений:${RESET}" >&2
    for i in "${!search_results[@]}"; do
        echo -e "    ${BOLD}$((i+1)).${RESET} ${search_results[$i]}" >&2
    done
    echo "" >&2

    echo -ne "  ${DIM}Номера для скрытия (через запятую) или 'skip'${RESET}: " >&2
    read -r pick_input

    if [[ "$pick_input" != "skip" && -n "$pick_input" ]]; then
        IFS=',' read -ra picks <<< "$pick_input"
        for pick in "${picks[@]}"; do
            pick=$(echo "$pick" | tr -d ' ')
            if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 )); then
                idx=$((pick - 1))
                if (( idx < ${#search_results[@]} )); then
                    entry="${search_results[$idx]}"
                    full_entry="$projects_path/$entry"

                    # tmpfs работает только с директориями
                    if [[ -d "$full_entry" ]]; then
                        level=$(ask_choice "Уровень защиты для '$entry'?" \
                            "Мягкий (только .claudeignore)" \
                            "Жёсткий (tmpfs overlay — физически скрыт)")
                    else
                        dim "    '$entry' — файл, доступен только мягкий уровень"
                        level="1"
                    fi

                    claudeignore_entries+=("$entry")
                    if [[ "$level" == "2" ]]; then
                        overlay_entries+=("$entry")
                    fi
                    success "Добавлен: $entry"
                fi
            fi
        done
    fi

    add_more=$(ask_choice "Искать ещё?" "Да" "Нет, продолжить")
done

# ── 5c. Дедупликация и генерация файлов исключений ───────────────────────────
declare -A seen_ignore seen_overlay
unique_claudeignore=()
unique_overlay=()
for entry in "${claudeignore_entries[@]}"; do
    if [[ -z "${seen_ignore[$entry]+x}" ]]; then
        seen_ignore[$entry]=1
        unique_claudeignore+=("$entry")
    fi
done
for entry in "${overlay_entries[@]}"; do
    if [[ -z "${seen_overlay[$entry]+x}" ]]; then
        seen_overlay[$entry]=1
        unique_overlay+=("$entry")
    fi
done

if [[ ${#unique_claudeignore[@]} -gt 0 ]]; then
    claudeignore_file="$projects_path/.claudeignore"
    # Сохраняем существующие записи
    existing_entries=()
    if [[ -f "$claudeignore_file" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            existing_entries+=("$line")
        done < "$claudeignore_file"
    fi
    {
        echo "# Управляется через claudebox setup.sh"
        echo "# Пути, исключённые из поиска/чтения Claude Code"
        for existing in "${existing_entries[@]}"; do
            if [[ -z "${seen_ignore[$existing]+x}" ]]; then
                echo "$existing"
            fi
        done
        for entry in "${unique_claudeignore[@]}"; do
            echo "$entry"
        done
    } > "$claudeignore_file"
    success "Обновлён $claudeignore_file (${#unique_claudeignore[@]} новых записей)"
fi

if [[ ${#unique_overlay[@]} -gt 0 ]]; then
    override_file="$SCRIPT_DIR/docker-compose.override.yml"
    # Бэкап существующего override перед перезаписью
    if [[ -f "$override_file" ]]; then
        backup="${override_file}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$override_file" "$backup"
        warn "docker-compose.override.yml сохранён в $(basename "$backup")"
    fi
    {
        echo "# Сгенерировано claudebox setup.sh"
        echo "# tmpfs-оверлеи для скрытия чувствительных директорий"
        echo "services:"
        echo "  claudebox:"
        echo "    volumes:"
        for entry in "${unique_overlay[@]}"; do
            echo "      - type: tmpfs"
            echo "        target: /home/claude/projects/${entry}"
        done
    } > "$override_file"
    success "Создан docker-compose.override.yml с ${#unique_overlay[@]} tmpfs-оверлеем(ями)"
fi

if [[ ${#claudeignore_entries[@]} -eq 0 ]]; then
    dim "  Исключения не настроены. Можно добавить позже:"
    dim "    Мягкий: создайте .claudeignore в проекте"
    dim "    Жёсткий: добавьте tmpfs-тома в docker-compose.override.yml"
fi

# ─── Шаг 6: Сборка и запуск ──────────────────────────────────────────────────
header "[6/6] Сборка и запуск"
echo ""

choice=$(ask_choice "Готовы собрать и запустить контейнер?" \
    "Собрать и запустить" \
    "Только собрать (не запускать)" \
    "Пропустить (сделаю вручную)")

if [[ "$choice" == "1" || "$choice" == "2" ]]; then
    echo ""
    info "Сборка Docker-образа (при первом запуске может занять несколько минут)..."
    echo ""

    # Запускаем из SCRIPT_DIR, чтобы compose подхватил docker-compose.override.yml
    if ! (cd "$SCRIPT_DIR" && "${COMPOSE[@]}" build); then
        error "Сборка не удалась. Проверьте вывод выше."
        exit 1
    fi
    success "Образ собран"

    if [[ "$choice" == "1" ]]; then
        echo ""
        info "Запуск контейнера..."

        if ! (cd "$SCRIPT_DIR" && "${COMPOSE[@]}" up -d); then
            error "Не удалось запустить. Проверьте: cd $SCRIPT_DIR && ${COMPOSE[*]} logs"
            exit 1
        fi

        success "Контейнер запущен!"
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        echo -e "  ${GREEN}${BOLD}Войти в контейнер:${RESET}"
        echo -e "  ${CYAN}${COMPOSE[*]} exec claudebox bash${RESET}"
        echo ""
        echo -e "  ${GREEN}${BOLD}Внутри контейнера:${RESET}"
        echo -e "  ${CYAN}claude-safe${RESET}  — запустить Claude Code (с API-ключом)"
        echo -e "  ${CYAN}health-check${RESET}  — проверить VPN и API"
        echo ""
        echo -e "  ${GREEN}${BOLD}Ваши проекты:${RESET} /home/claude/projects"
        echo ""
        echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    fi
else
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${GREEN}${BOLD}Когда будете готовы:${RESET}"
    echo -e "  ${CYAN}cd $(basename "$SCRIPT_DIR") && ${COMPOSE[*]} build${RESET}"
    echo -e "  ${CYAN}${COMPOSE[*]} up -d${RESET}"
    echo -e "  ${CYAN}${COMPOSE[*]} exec claudebox bash${RESET}"
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
fi
