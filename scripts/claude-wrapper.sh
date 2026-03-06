#!/usr/bin/env bash
# Обёртка для Claude Code CLI: инжектит API-ключ только в процесс Claude.
# Это предотвращает утечку ключа через /proc/1/environ (PID entrypoint).

# ─── Защита от запуска под root ──────────────────────────────────────────────
# Claude Code запрещает --dangerously-skip-permissions под root.
# Если мы root — переключаемся на claude автоматически.
if [[ "$(id -u)" == "0" ]]; then
    CLAUDE_USER="${CLAUDE_USER:-claude}"
    if command -v gosu &>/dev/null; then
        exec gosu "$CLAUDE_USER" "$0" "$@"
    elif command -v runuser &>/dev/null; then
        exec runuser -u "$CLAUDE_USER" -- "$0" "$@"
    else
        exec su -s /bin/bash "$CLAUDE_USER" -c "\"$0\" \"\$@\"" -- "$@"
    fi
fi

REAL_CLAUDE="$(which -a claude 2>/dev/null | grep -Fv "$0" | head -1)"
if [[ -z "$REAL_CLAUDE" ]]; then
    # Фолбэк: ищем claude в стандартных путях (native installer + npm legacy)
    for candidate in /usr/local/bin/claude /home/claude/.local/bin/claude /usr/bin/claude; do
        if [[ -x "$candidate" && "$candidate" != "$0" ]]; then
            REAL_CLAUDE="$candidate"
            break
        fi
    done
fi

if [[ -z "$REAL_CLAUDE" ]]; then
    echo "Ошибка: claude CLI не найден" >&2
    exit 1
fi

# Если API-ключ уже в env (юзер задал вручную), просто передаём дальше
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    exec "$REAL_CLAUDE" "$@"
fi

# Читаем из файла секрета и инжектим только в окружение Claude
SECRET_FILE="${ANTHROPIC_API_KEY_FILE:-/run/secrets/anthropic_api_key}"
if [[ -f "$SECRET_FILE" && -s "$SECRET_FILE" ]]; then
    exec env ANTHROPIC_API_KEY="$(cat "$SECRET_FILE")" "$REAL_CLAUDE" "$@"
fi

# Ключ не найден — claude предложит залогиниться
exec "$REAL_CLAUDE" "$@"
