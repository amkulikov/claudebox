#!/usr/bin/env bash
# Интеграционные тесты: сборка образа и проверка контейнера.
# Запуск: ./tests/run-docker-tests.sh
# Требует Docker. Автоматически чистит за собой.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

IMAGE_NAME="claudebox-test"
CONTAINER_NAME="claudebox-test-$$"

passed=0
failed=0
skipped=0

suite() {
    echo ""
    echo -e "${BOLD}━━━ $1 ━━━${RESET}"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GREEN}✓${RESET} $desc"
        passed=$((passed + 1))
    else
        echo -e "  ${RED}✗${RESET} $desc"
        echo -e "    ${DIM}expected: ${expected}${RESET}"
        echo -e "    ${DIM}actual:   ${actual}${RESET}"
        failed=$((failed + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "  ${GREEN}✓${RESET} $desc"
        passed=$((passed + 1))
    else
        echo -e "  ${RED}✗${RESET} $desc"
        echo -e "    ${DIM}expected to contain: ${needle}${RESET}"
        echo -e "    ${DIM}actual: ${haystack}${RESET}"
        failed=$((failed + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "  ${GREEN}✓${RESET} $desc"
        passed=$((passed + 1))
    else
        echo -e "  ${RED}✗${RESET} $desc"
        echo -e "    ${DIM}should not contain: ${needle}${RESET}"
        failed=$((failed + 1))
    fi
}

skip_test() {
    local desc="$1" reason="$2"
    echo -e "  ${YELLOW}⊘${RESET} $desc ${DIM}($reason)${RESET}"
    skipped=$((skipped + 1))
}

# Выполнить команду в контейнере
docker_run() {
    docker run --rm \
        --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID \
        --cap-drop ALL \
        "$IMAGE_NAME" "$@"
}

# Выполнить команду в контейнере от root (без entrypoint)
docker_run_root() {
    docker run --rm --user root --entrypoint "" \
        "$IMAGE_NAME" "$@"
}

# Выполнить команду в контейнере от claude (без entrypoint)
docker_run_claude() {
    docker run --rm --user claude --entrypoint "" \
        "$IMAGE_NAME" "$@"
}

# ─── Cleanup ──────────────────────────────────────────────────────────────────
cleanup() {
    echo ""
    echo -e "${DIM}Очистка...${RESET}"
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker rmi "$IMAGE_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Проверка Docker ─────────────────────────────────────────────────────────
if ! docker info &>/dev/null; then
    echo -e "${RED}✗ Docker недоступен${RESET}" >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Сборка образа
# ═══════════════════════════════════════════════════════════════════════════════

suite "Сборка образа"

echo -e "  ${DIM}Сборка $IMAGE_NAME (может занять несколько минут при первом запуске)...${RESET}"
build_output=$(docker build -t "$IMAGE_NAME" "$PROJECT_DIR" 2>&1) && build_ok=true || build_ok=false

if $build_ok; then
    echo -e "  ${GREEN}✓${RESET} Образ собран"
    passed=$((passed + 1))
else
    echo -e "  ${RED}✗${RESET} Сборка не удалась"
    echo "$build_output" | tail -20
    failed=$((failed + 1))
    echo ""
    echo -e "${RED}Сборка упала — дальнейшие тесты невозможны${RESET}"
    exit 1
fi

# Проверяем размер образа
image_size=$(docker image inspect "$IMAGE_NAME" --format='{{.Size}}' 2>/dev/null || echo "0")
image_size_mb=$((image_size / 1024 / 1024))
if (( image_size_mb < 2000 )); then
    echo -e "  ${GREEN}✓${RESET} Размер образа: ${image_size_mb}MB (< 2GB)"
    passed=$((passed + 1))
else
    echo -e "  ${YELLOW}⚠${RESET} Образ слишком большой: ${image_size_mb}MB"
    failed=$((failed + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: установленные инструменты
# ═══════════════════════════════════════════════════════════════════════════════

suite "Установленные инструменты"

# Node.js
node_version=$(docker_run_root node --version 2>/dev/null || echo "NOT_FOUND")
assert_contains "Node.js установлен" "v" "$node_version"

# Claude CLI
claude_path=$(docker_run_root which claude 2>/dev/null || echo "NOT_FOUND")
assert_contains "Claude CLI установлен" "/claude" "$claude_path"

# gosu
gosu_path=$(docker_run_root which gosu 2>/dev/null || echo "NOT_FOUND")
assert_contains "gosu установлен" "/gosu" "$gosu_path"

# WireGuard tools (awg-quick или wg-quick)
wg_ok=false
if docker_run_root which awg-quick &>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} awg-quick установлен"
    passed=$((passed + 1))
    wg_ok=true
elif docker_run_root which wg-quick &>/dev/null; then
    echo -e "  ${GREEN}✓${RESET} wg-quick установлен (fallback)"
    passed=$((passed + 1))
    wg_ok=true
fi
if ! $wg_ok; then
    echo -e "  ${RED}✗${RESET} Ни awg-quick, ни wg-quick не найдены"
    failed=$((failed + 1))
fi

# curl, jq, git, dig
for tool in curl jq git dig; do
    tool_path=$(docker_run_root which "$tool" 2>/dev/null || echo "NOT_FOUND")
    if [[ "$tool_path" != "NOT_FOUND" ]]; then
        echo -e "  ${GREEN}✓${RESET} $tool установлен"
        passed=$((passed + 1))
    else
        echo -e "  ${RED}✗${RESET} $tool не найден"
        failed=$((failed + 1))
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: пользователь и права
# ═══════════════════════════════════════════════════════════════════════════════

suite "Пользователь и права"

# Пользователь claude существует
claude_uid=$(docker_run_root id -u claude 2>/dev/null || echo "NOT_FOUND")
if [[ "$claude_uid" != "NOT_FOUND" && "$claude_uid" =~ ^[0-9]+$ ]]; then
    echo -e "  ${GREEN}✓${RESET} Пользователь claude существует (UID: $claude_uid)"
    passed=$((passed + 1))
else
    echo -e "  ${RED}✗${RESET} Пользователь claude не найден"
    failed=$((failed + 1))
fi

# Домашняя директория
claude_home=$(docker_run_root bash -c 'echo ~claude' 2>/dev/null || echo "NOT_FOUND")
assert_eq "Домашняя директория claude" "/home/claude" "$claude_home"

# Права на /home/claude/projects
projects_owner=$(docker_run_root stat -c '%U' /home/claude/projects 2>/dev/null || echo "NOT_FOUND")
assert_eq "projects/ принадлежит claude" "claude" "$projects_owner"

# Права на /home/claude/.claude
claude_dir_owner=$(docker_run_root stat -c '%U' /home/claude/.claude 2>/dev/null || echo "NOT_FOUND")
assert_eq ".claude/ принадлежит claude" "claude" "$claude_dir_owner"

# /etc/amnezia закрыт
amnezia_perms=$(docker_run_root stat -c '%a' /etc/amnezia 2>/dev/null || echo "NOT_FOUND")
assert_eq "/etc/amnezia имеет права 700" "700" "$amnezia_perms"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: сброс привилегий (gosu)
# ═══════════════════════════════════════════════════════════════════════════════

suite "Сброс привилегий"

# gosu может переключиться на claude
gosu_user=$(docker_run_root bash -c 'gosu claude id -un' 2>/dev/null || echo "FAIL")
assert_eq "gosu переключает на claude" "claude" "$gosu_user"

# gosu устанавливает правильные группы
gosu_groups=$(docker_run_root bash -c 'gosu claude id -Gn' 2>/dev/null || echo "FAIL")
assert_contains "gosu устанавливает группу claude" "claude" "$gosu_groups"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: скрипты в контейнере
# ═══════════════════════════════════════════════════════════════════════════════

suite "Скрипты в контейнере"

# entrypoint.sh на месте и исполняемый
ep_perms=$(docker_run_root stat -c '%a' /entrypoint.sh 2>/dev/null || echo "NOT_FOUND")
assert_eq "entrypoint.sh исполняемый" "755" "$ep_perms"

# health-check на месте
hc_path=$(docker_run_root which health-check 2>/dev/null || echo "NOT_FOUND")
assert_contains "health-check в PATH" "health-check" "$hc_path"

# claude-safe на месте
cs_path=$(docker_run_root which claude-safe 2>/dev/null || echo "NOT_FOUND")
assert_contains "claude-safe в PATH" "claude-safe" "$cs_path"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: API-ключ не утекает
# ═══════════════════════════════════════════════════════════════════════════════

suite "Безопасность API-ключа"

# Запускаем контейнер с тестовым ключом
test_key="sk-ant-test-DO-NOT-USE-123"

# Проверяем что ключ НЕ виден в env PID 1 через /proc
# Используем entrypoint с VPN_ENABLED=0 чтобы не падало на VPN
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Создаём temp-файл с ключом
_tmp_key=$(mktemp)
echo -n "$test_key" > "$_tmp_key"

docker run -d \
    --name "$CONTAINER_NAME" \
    --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID \
    --cap-drop ALL \
    -e VPN_ENABLED=0 \
    -e ANTHROPIC_API_KEY_FILE=/run/secrets/test_key \
    -v "$_tmp_key:/run/secrets/test_key:ro" \
    "$IMAGE_NAME" \
    sleep 60 >/dev/null 2>&1

# Ждём старта
sleep 3

# Проверяем /proc/1/environ (entrypoint PID)
pid1_env=$(docker exec "$CONTAINER_NAME" cat /proc/1/environ 2>/dev/null | tr '\0' '\n' || echo "")
assert_not_contains "API-ключ не в /proc/1/environ" "$test_key" "$pid1_env"

# Проверяем что claude-safe может прочитать ключ
safe_key=$(docker exec "$CONTAINER_NAME" bash -c 'cat /run/secrets/test_key' 2>/dev/null || echo "FAIL")
assert_eq "Файл ключа доступен" "$test_key" "$safe_key"

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
rm -f "$_tmp_key"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: entrypoint без VPN
# ═══════════════════════════════════════════════════════════════════════════════

suite "Entrypoint (VPN_ENABLED=0)"

# Запускаем с VPN_ENABLED=0
ep_output=$(docker run --rm \
    --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID \
    --cap-drop ALL \
    -e VPN_ENABLED=0 \
    "$IMAGE_NAME" \
    whoami 2>&1 || true)

assert_contains "Выводит баннер Claudebox" "Claudebox" "$ep_output"
assert_contains "Сообщает что VPN отключён" "VPN" "$ep_output"
assert_contains "Сбрасывает привилегии до claude" "claude" "$ep_output"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: WORKDIR
# ═══════════════════════════════════════════════════════════════════════════════

suite "Рабочая директория"

workdir=$(docker_run_root pwd 2>/dev/null || echo "NOT_FOUND")
assert_eq "WORKDIR = /home/claude/projects" "/home/claude/projects" "$workdir"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: монтирование проектов
# ═══════════════════════════════════════════════════════════════════════════════

suite "Монтирование проектов"

# Создаём тестовый проект
_test_proj=$(mktemp -d)
echo "test-file-content" > "$_test_proj/test.txt"

# Монтируем и проверяем
mounted_content=$(docker run --rm --entrypoint "" \
    -v "$_test_proj:/home/claude/projects/test-proj" \
    "$IMAGE_NAME" \
    cat /home/claude/projects/test-proj/test.txt 2>/dev/null || echo "FAIL")
assert_eq "Проект доступен в контейнере" "test-file-content" "$mounted_content"

# Проверяем мульти-проект (два маунта)
_test_proj2=$(mktemp -d)
echo "second-project" > "$_test_proj2/readme.txt"

multi_output=$(docker run --rm --entrypoint "" \
    -v "$_test_proj:/home/claude/projects/proj-a" \
    -v "$_test_proj2:/home/claude/projects/proj-b" \
    "$IMAGE_NAME" \
    bash -c 'cat /home/claude/projects/proj-a/test.txt && cat /home/claude/projects/proj-b/readme.txt' 2>/dev/null || echo "FAIL")
assert_contains "Первый проект доступен" "test-file-content" "$multi_output"
assert_contains "Второй проект доступен" "second-project" "$multi_output"

rm -rf "$_test_proj" "$_test_proj2"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: лимиты ресурсов (smoke test)
# ═══════════════════════════════════════════════════════════════════════════════

suite "Изоляция контейнера"

# Проверяем что claude не может читать /etc/shadow
shadow_read=$(docker_run_claude cat /etc/shadow 2>&1 || true)
assert_contains "claude не может читать /etc/shadow" "Permission denied" "$shadow_read"

# Проверяем что claude не может писать в /etc
etc_write=$(docker_run_claude touch /etc/test-file 2>&1 || true)
assert_contains "claude не может писать в /etc" "denied\|Read-only\|Permission" "$etc_write"

# ═══════════════════════════════════════════════════════════════════════════════
# Итоги
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${GREEN}✓ Passed: ${passed}${RESET}"
if [[ $failed -gt 0 ]]; then
    echo -e "  ${RED}✗ Failed: ${failed}${RESET}"
fi
if [[ $skipped -gt 0 ]]; then
    echo -e "  ${YELLOW}⊘ Skipped: ${skipped}${RESET}"
fi
echo -e "  Total: $((passed + failed + skipped))"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

exit $((failed > 0 ? 1 : 0))
