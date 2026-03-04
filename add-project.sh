#!/usr/bin/env bash
# Добавление проекта в claudebox без повторного запуска setup.sh.
# Использование:
#   ./add-project.sh /path/to/project
#   ./add-project.sh /path/to/project custom-name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

if [[ $# -lt 1 || "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Использование: ./add-project.sh <путь> [имя-в-контейнере]"
    echo ""
    echo "Примеры:"
    echo "  ./add-project.sh ~/work/backend"
    echo "  ./add-project.sh ~/work/backend api-service"
    echo ""
    echo "Проект будет доступен как /home/claude/projects/<имя>"
    echo "После добавления перезапустите контейнер: ./start.sh --rebuild"
    exit 0
fi

project_path="$1"

# Раскрываем ~
project_path="${project_path/#\~/$HOME}"
# Убираем trailing slash
project_path="${project_path%/}"

# Нормализуем путь
if [[ -e "$project_path" ]]; then
    project_path="$(cd "$project_path" && pwd)"
fi

if [[ ! -d "$project_path" ]]; then
    echo -e "${RED}✗ Директория не найдена: $project_path${RESET}" >&2
    exit 1
fi

mount_name="${2:-$(basename "$project_path")}"

# Читаем текущий override (если есть)
override_file="$SCRIPT_DIR/docker-compose.override.yml"

# Проверяем дубликаты
if [[ -f "$override_file" ]]; then
    if grep -qF "$project_path:" "$override_file" 2>/dev/null; then
        echo -e "${YELLOW}⚠ Проект уже добавлен: $project_path${RESET}" >&2
        exit 0
    fi
fi

# Проверяем PROJECTS_PATH (основной mount)
if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    source .env 2>/dev/null || true
    if [[ "${PROJECTS_PATH:-}" == "$project_path" ]]; then
        echo -e "${YELLOW}⚠ Это основной проект (уже в PROJECTS_PATH)${RESET}" >&2
        exit 0
    fi
fi

# Добавляем в override
if [[ -f "$override_file" ]]; then
    # Добавляем volume в существующий файл
    # Проверяем есть ли секция volumes
    if grep -q "volumes:" "$override_file"; then
        # Добавляем перед последней строкой с volume или в конец секции
        escaped_src="${project_path//\\/\\\\}"
        escaped_src="${escaped_src//\"/\\\"}"
        new_line="      - \"${escaped_src}:/home/claude/projects/${mount_name}\""

        # Вставляем после последней строки volumes: или существующего volume
        # Ищем последнюю строку с "- " под volumes
        awk -v new="$new_line" '
            /^      - / { last_vol = NR; line[NR] = $0; next }
            { line[NR] = $0 }
            END {
                for (i = 1; i <= NR; i++) {
                    print line[i]
                    if (i == last_vol) print new
                }
                if (last_vol == 0) {
                    # Нет volumes записей — добавляем в конец
                    print new
                }
            }
        ' "$override_file" > "${override_file}.tmp"
        mv -f "${override_file}.tmp" "$override_file"
    else
        # Нет секции volumes — добавляем
        cat >> "$override_file" << EOF
    volumes:
      - "${project_path}:/home/claude/projects/${mount_name}"
EOF
    fi
else
    # Создаём новый override
    cat > "$override_file" << EOF
# Сгенерировано claudebox add-project.sh
services:
  claudebox:
    volumes:
      - "${project_path}:/home/claude/projects/${mount_name}"
EOF
fi

echo -e "${GREEN}✓ Проект добавлен: ${project_path} → /home/claude/projects/${mount_name}${RESET}"
echo -e "${DIM}  Перезапустите контейнер: ./stop.sh && ./start.sh${RESET}"
