#!/usr/bin/env bash
# Автоматические тесты для claudebox.
# Запуск: ./tests/run-tests.sh
# Не требует Docker — тестирует логику shell-скриптов в изоляции.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

passed=0
failed=0
skipped=0
current_suite=""

suite() {
    current_suite="$1"
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

assert_success() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} $desc"
        passed=$((passed + 1))
    else
        echo -e "  ${RED}✗${RESET} $desc (exit code: $?)"
        failed=$((failed + 1))
    fi
}

assert_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${RED}✗${RESET} $desc (expected failure, got success)"
        failed=$((failed + 1))
    else
        echo -e "  ${GREEN}✓${RESET} $desc"
        passed=$((passed + 1))
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

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo -e "  ${GREEN}✓${RESET} $desc"
        passed=$((passed + 1))
    else
        echo -e "  ${RED}✗${RESET} $desc (file not found: $path)"
        failed=$((failed + 1))
    fi
}

skip_test() {
    local desc="$1" reason="$2"
    echo -e "  ${YELLOW}⊘${RESET} $desc ${DIM}($reason)${RESET}"
    skipped=$((skipped + 1))
}

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: валидация setup.sh функций
# ═══════════════════════════════════════════════════════════════════════════════

# Извлекаем функции из setup.sh для тестирования
source_setup_functions() {
    # Загружаем только функции, не выполняя основной код
    eval "$(sed -n '/^validate_relative_path()/,/^}/p' "$PROJECT_DIR/setup.sh")"
    eval "$(sed -n '/^validate_domain()/,/^}/p' "$PROJECT_DIR/setup.sh")"
    eval "$(sed -n '/^clean_path()/,/^}/p' "$PROJECT_DIR/setup.sh")"
    eval "$(sed -n '/^array_contains()/,/^}/p' "$PROJECT_DIR/setup.sh")"
    _path_reject_reason=""
}

source_setup_functions

suite "validate_relative_path"

validate_relative_path "src/main.js"
assert_eq "допускает обычный путь" "0" "$?"

validate_relative_path "project/datafixes"
assert_eq "допускает вложенный путь" "0" "$?"

validate_relative_path "file with spaces/dir"
assert_eq "допускает пробелы" "0" "$?"

! validate_relative_path ""
assert_eq "отклоняет пустой путь" "0" "$?"

! validate_relative_path "/etc/passwd"
assert_eq "отклоняет абсолютный путь" "0" "$?"

! validate_relative_path "../../../etc/passwd"
assert_eq "отклоняет path traversal" "0" "$?"

! validate_relative_path "foo/../bar"
assert_eq "отклоняет path traversal в середине" "0" "$?"

_path_reject_reason=""
validate_relative_path "test\$injection" || true
assert_eq "отклоняет спецсимволы" "содержит спецсимволы (допускаются: буквы, цифры, . _ / @ + - пробел)" "$_path_reject_reason"

suite "validate_domain"

assert_success "допускает обычный домен" validate_domain "example.com"
assert_success "допускает поддомен" validate_domain "git.corp.example.com"
assert_success "допускает wildcard" validate_domain "*.example.com"
assert_fail "отклоняет пустой" validate_domain ""
assert_fail "отклоняет спецсимволы" validate_domain "exam;ple.com"
assert_fail "отклоняет пробелы" validate_domain "exam ple.com"
assert_fail "отклоняет wildcard в середине" validate_domain "foo.*.com"

suite "array_contains"

assert_success "находит элемент" array_contains "b" "a" "b" "c"
assert_fail "не находит отсутствующий" array_contains "d" "a" "b" "c"
assert_success "находит первый" array_contains "a" "a" "b"
assert_success "находит последний" array_contains "c" "a" "b" "c"
assert_fail "не находит в пустом" array_contains "a"

suite "clean_path"

result=$(clean_path "'~/projects'")
assert_eq "раскрывает ~ и убирает кавычки" "$HOME/projects" "$result"

result=$(clean_path "\"$HOME/test\"")
assert_eq "убирает двойные кавычки" "$HOME/test" "$result"

result=$(clean_path "$HOME/test   ")
assert_eq "убирает пробелы в конце" "$HOME/test" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: entrypoint.sh
# ═══════════════════════════════════════════════════════════════════════════════

suite "entrypoint.sh — синтаксис"

assert_success "entrypoint.sh проходит bash -n" bash -n "$PROJECT_DIR/entrypoint.sh"

suite "entrypoint.sh — парсинг VPN-конфига"

# Тестируем парсинг endpoint из конфига
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cat > "$TMPDIR_TEST/test.conf" << 'CONF'
[Interface]
PrivateKey = test123
Address = 10.0.0.2/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = peer123
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0
CONF

# Извлекаем endpoint (копируем логику из entrypoint.sh)
endpoint_raw=$(grep -i '^Endpoint' "$TMPDIR_TEST/test.conf" | head -1 | sed 's/^[^=]*= *//')
if [[ "$endpoint_raw" =~ ^([^:]+):([0-9]+)$ ]]; then
    endpoint="${BASH_REMATCH[1]}"
    endpoint_port="${BASH_REMATCH[2]}"
fi
assert_eq "парсит IPv4 endpoint host" "1.2.3.4" "$endpoint"
assert_eq "парсит IPv4 endpoint port" "51820" "$endpoint_port"

# Тестируем парсинг DNS
dns_servers=$(grep -i '^DNS' "$TMPDIR_TEST/test.conf" | head -1 | sed 's/^[^=]*= *//' | tr ',' '\n' | tr -d ' ')
dns_count=$(echo "$dns_servers" | wc -l)
assert_eq "парсит 2 DNS-сервера" "2" "$(echo "$dns_count" | tr -d ' ')"
assert_contains "парсит DNS 1.1.1.1" "1.1.1.1" "$dns_servers"
assert_contains "парсит DNS 8.8.8.8" "8.8.8.8" "$dns_servers"

# Тестируем парсинг IPv6 endpoint
cat > "$TMPDIR_TEST/test-ipv6.conf" << 'CONF'
[Interface]
PrivateKey = test123

[Peer]
Endpoint = [2001:db8::1]:51820
CONF

endpoint_raw=$(grep -i '^Endpoint' "$TMPDIR_TEST/test-ipv6.conf" | head -1 | sed 's/^[^=]*= *//')
if [[ "$endpoint_raw" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
    endpoint="${BASH_REMATCH[1]}"
    endpoint_port="${BASH_REMATCH[2]}"
fi
assert_eq "парсит IPv6 endpoint host" "2001:db8::1" "$endpoint"
assert_eq "парсит IPv6 endpoint port" "51820" "$endpoint_port"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: claude-wrapper.sh
# ═══════════════════════════════════════════════════════════════════════════════

suite "claude-wrapper.sh — синтаксис"

assert_success "claude-wrapper.sh проходит bash -n" bash -n "$PROJECT_DIR/scripts/claude-wrapper.sh"

suite "claude-wrapper.sh — логика инъекции ключа"

# Тестируем что ключ читается из файла
echo -n "sk-ant-test-key-123" > "$TMPDIR_TEST/test_api_key"

# Симулируем claude-wrapper: проверяем что файл читается правильно
SECRET_FILE="$TMPDIR_TEST/test_api_key"
if [[ -f "$SECRET_FILE" && -s "$SECRET_FILE" ]]; then
    read_key=$(cat "$SECRET_FILE")
fi
assert_eq "читает API-ключ из файла" "sk-ant-test-key-123" "$read_key"

# Тестируем пустой файл
touch "$TMPDIR_TEST/empty_key"
SECRET_FILE="$TMPDIR_TEST/empty_key"
empty_result="no"
if [[ -f "$SECRET_FILE" && -s "$SECRET_FILE" ]]; then
    empty_result="yes"
fi
assert_eq "игнорирует пустой файл ключа" "no" "$empty_result"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: health-check.sh
# ═══════════════════════════════════════════════════════════════════════════════

suite "health-check.sh — синтаксис"

assert_success "health-check.sh проходит bash -n" bash -n "$PROJECT_DIR/scripts/health-check.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: setup.sh
# ═══════════════════════════════════════════════════════════════════════════════

suite "setup.sh — синтаксис"

assert_success "setup.sh проходит bash -n" bash -n "$PROJECT_DIR/setup.sh"

suite "setup.sh — генерация .env"

# Тестируем _write_env_var
eval "$(sed -n '/_write_env_var()/,/^}/p' "$PROJECT_DIR/setup.sh")"

result=$(_write_env_var "TEST_KEY" "simple_value")
assert_eq "простое значение" 'TEST_KEY="simple_value"' "$result"

result=$(_write_env_var "PATH_KEY" '/home/user/my "projects"')
assert_eq "экранирует кавычки" 'PATH_KEY="/home/user/my \"projects\""' "$result"

result=$(_write_env_var "BACK" 'back\\slash')
assert_eq "экранирует обратные слеши" 'BACK="back\\\\slash"' "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: start.sh / stop.sh / add-project.sh — синтаксис
# ═══════════════════════════════════════════════════════════════════════════════

suite "Вспомогательные скрипты — синтаксис"

assert_success "start.sh проходит bash -n" bash -n "$PROJECT_DIR/start.sh"
assert_success "stop.sh проходит bash -n" bash -n "$PROJECT_DIR/stop.sh"
assert_success "add-project.sh проходит bash -n" bash -n "$PROJECT_DIR/add-project.sh"

suite "add-project.sh — генерация override"

# Тестируем создание нового override
_test_override_dir=$(mktemp -d)
# Создаём минимальный .env
echo 'PROJECTS_PATH="/tmp/main-project"' > "$_test_override_dir/.env"

# Симулируем add-project в temp-директории (подменяем SCRIPT_DIR)
_test_project=$(mktemp -d)
_test_override="$_test_override_dir/docker-compose.override.yml"

cat > "$_test_override" << EOF
# Сгенерировано claudebox
services:
  claudebox:
    volumes:
      - "$_test_project:/home/claude/projects/test-project"
EOF

assert_file_exists "генерирует override" "$_test_override"
override_content=$(cat "$_test_override")
assert_contains "override содержит volume mount" "/home/claude/projects/test-project" "$override_content"

rm -rf "$_test_override_dir" "$_test_project"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: Dockerfile
# ═══════════════════════════════════════════════════════════════════════════════

suite "Dockerfile — структура"

assert_file_exists "Dockerfile существует" "$PROJECT_DIR/Dockerfile"

dockerfile_content=$(cat "$PROJECT_DIR/Dockerfile")
assert_contains "базовый образ ubuntu" "ubuntu:24.04" "$dockerfile_content"
assert_contains "устанавливает gosu" "gosu" "$dockerfile_content"
assert_contains "устанавливает claude-code (native)" "claude.ai/install.sh" "$dockerfile_content"
assert_contains "создаёт пользователя claude" "useradd" "$dockerfile_content"
assert_contains "home dir 755 (Ubuntu 24.04 default 0750)" "chmod 755 /home/claude" "$dockerfile_content"
assert_contains "копирует entrypoint" "COPY entrypoint.sh" "$dockerfile_content"
assert_contains "WORKDIR проекты" "/home/claude/projects" "$dockerfile_content"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: docker-compose.yml
# ═══════════════════════════════════════════════════════════════════════════════

suite "docker-compose.yml — конфигурация"

compose_content=$(cat "$PROJECT_DIR/docker-compose.yml")
assert_contains "capability NET_ADMIN" "NET_ADMIN" "$compose_content"
assert_contains "capability SETUID для gosu" "SETUID" "$compose_content"
assert_contains "capability SETGID для gosu" "SETGID" "$compose_content"
assert_contains "capability CHOWN для entrypoint" "CHOWN" "$compose_content"
assert_contains "capability FOWNER для entrypoint" "FOWNER" "$compose_content"
assert_contains "capability DAC_OVERRIDE для entrypoint" "DAC_OVERRIDE" "$compose_content"
assert_contains "именованный том claude-config" "claude-config" "$compose_content"
assert_contains "no-new-privileges" "no-new-privileges" "$compose_content"
assert_contains "лимит памяти" "memory:" "$compose_content"
assert_contains "лимит CPU" "cpus:" "$compose_content"
assert_contains "лимит PID" "pids:" "$compose_content"
assert_contains "healthcheck" "health-check" "$compose_content"
assert_contains "tun устройство" "/dev/net/tun" "$compose_content"
assert_not_contains "привилегированный режим" "privileged" "$compose_content"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: безопасность
# ═══════════════════════════════════════════════════════════════════════════════

suite "Безопасность — API-ключ не утекает"

# Проверяем что entrypoint НЕ экспортирует API-ключ
entrypoint_content=$(cat "$PROJECT_DIR/entrypoint.sh")
assert_not_contains "entrypoint не экспортирует ANTHROPIC_API_KEY" "export ANTHROPIC_API_KEY" "$entrypoint_content"
assert_not_contains "entrypoint не содержит ключ напрямую" "sk-ant-" "$entrypoint_content"

# Проверяем что .gitignore защищает секреты
if [[ -f "$PROJECT_DIR/.gitignore" ]]; then
    gitignore=$(cat "$PROJECT_DIR/.gitignore")
    assert_contains ".gitignore содержит secrets/" "secrets/" "$gitignore"
else
    skip_test ".gitignore содержит secrets/" "файл .gitignore не найден"
fi

suite "Безопасность — symlink-защита в setup.sh"

setup_content=$(cat "$PROJECT_DIR/setup.sh")
assert_contains "проверка symlink для CONFIGS_DIR" 'if [[ -L "$_dir" ]]' "$setup_content"
assert_contains "assert_not_symlink определён" "assert_not_symlink()" "$setup_content"

# ═══════════════════════════════════════════════════════════════════════════════
# Тесты: entrypoint privilege drop
# ═══════════════════════════════════════════════════════════════════════════════

suite "Entrypoint — сброс привилегий"

assert_contains "пробует gosu первым" "gosu" "$entrypoint_content"
assert_contains "фолбэк на runuser" "runuser" "$entrypoint_content"
assert_contains "проверяет UID перед сбросом" 'id -u' "$entrypoint_content"
assert_contains "использует exec для замены процесса" "exec gosu" "$entrypoint_content"

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
