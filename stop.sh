#!/usr/bin/env bash
# Остановка контейнера (данные сохраняются).
# Использование:
#   ./stop.sh          — остановка (можно запустить снова через ./start.sh)
#   ./stop.sh --rm     — остановка и удаление контейнера (тома сохраняются)
#   ./stop.sh --purge  — полное удаление (контейнер + тома)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

if docker compose version &>/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif docker-compose version &>/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    echo -e "${RED}✗ docker compose не найден${RESET}" >&2
    exit 1
fi

case "${1:-}" in
    --rm)
        echo "Остановка и удаление контейнера (тома сохранены)..."
        "${COMPOSE[@]}" down
        echo -e "${GREEN}✓ Контейнер удалён. Данные Claude сохранены.${RESET}"
        ;;
    --purge)
        echo -e "${YELLOW}⚠ Будут удалены: контейнер + том claude-config (учётные данные Claude)${RESET}"
        echo -ne "Продолжить? [y/N]: "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            "${COMPOSE[@]}" down -v
            echo -e "${GREEN}✓ Полностью очищено${RESET}"
        else
            echo "Отменено"
        fi
        ;;
    --help|-h)
        echo "Использование: ./stop.sh [--rm] [--purge]"
        echo "  (без флагов)  Остановка (быстрый перезапуск через ./start.sh)"
        echo "  --rm          Остановка + удаление контейнера (тома сохранены)"
        echo "  --purge       Полное удаление (контейнер + тома с учётными данными)"
        ;;
    *)
        "${COMPOSE[@]}" stop
        echo -e "${GREEN}✓ Контейнер остановлен. Запуск: ./start.sh${RESET}"
        ;;
esac
