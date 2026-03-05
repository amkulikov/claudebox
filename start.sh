#!/usr/bin/env bash
# Быстрый запуск контейнера (без повторного прохождения setup).
# Использование:
#   ./start.sh              — запуск и вход
#   ./start.sh --detach     — запуск в фоне
#   ./start.sh --rebuild    — пересборка образа и запуск
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Определяем compose
if docker compose version &>/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif docker-compose version &>/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    echo -e "${RED}✗ docker compose не найден${RESET}" >&2
    exit 1
fi

# Проверяем что setup был выполнен
if [[ ! -f .env ]]; then
    echo -e "${RED}✗ Файл .env не найден. Сначала выполните: ./setup.sh${RESET}" >&2
    exit 1
fi

detach=false
rebuild=false
for arg in "$@"; do
    case "$arg" in
        --detach|-d) detach=true ;;
        --rebuild|-r) rebuild=true ;;
        --help|-h)
            echo "Использование: ./start.sh [--detach] [--rebuild]"
            echo "  --detach, -d   Запуск в фоне (без входа в контейнер)"
            echo "  --rebuild, -r  Пересборка образа перед запуском"
            exit 0
            ;;
    esac
done

# Проверяем текущее состояние контейнера
container_state=$(docker inspect -f '{{.State.Status}}' claudebox 2>/dev/null || echo "not_found")

case "$container_state" in
    running)
        echo -e "${GREEN}✓ Контейнер уже запущен${RESET}"
        if ! $detach; then
            echo -e "${CYAN}Вход в контейнер...${RESET}"
            exec "${COMPOSE[@]}" exec claudebox bash
        fi
        exit 0
        ;;
    exited|created)
        if $rebuild; then
            echo -e "${CYAN}Пересборка образа...${RESET}"
            "${COMPOSE[@]}" build
        fi
        echo -e "${CYAN}Запуск остановленного контейнера...${RESET}"
        "${COMPOSE[@]}" start
        ;;
    *)
        if $rebuild; then
            echo -e "${CYAN}Пересборка образа...${RESET}"
            "${COMPOSE[@]}" build
        fi
        echo -e "${CYAN}Создание и запуск контейнера...${RESET}"
        "${COMPOSE[@]}" up -d
        ;;
esac

echo -e "${GREEN}✓ Контейнер запущен${RESET}"

if ! $detach; then
    echo -e "${CYAN}Вход в контейнер...${RESET}"
    exec "${COMPOSE[@]}" exec claudebox bash
fi
