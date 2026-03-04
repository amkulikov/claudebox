#!/usr/bin/env bash
# Wrapper for Claude Code CLI that injects API key only into claude's process.
# This prevents the key from leaking via /proc/1/environ (entrypoint PID).

REAL_CLAUDE="$(which -a claude 2>/dev/null | grep -v "$0" | head -1)"
if [[ -z "$REAL_CLAUDE" ]]; then
    # Fallback: find claude in common npm global paths
    for candidate in /usr/local/bin/claude /usr/bin/claude; do
        if [[ -x "$candidate" && "$candidate" != "$0" ]]; then
            REAL_CLAUDE="$candidate"
            break
        fi
    done
fi

if [[ -z "$REAL_CLAUDE" ]]; then
    echo "Error: claude CLI not found" >&2
    exit 1
fi

# If API key is already in env (e.g. user set it manually), just pass through
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    exec "$REAL_CLAUDE" "$@"
fi

# Read from secret file and inject only into claude's environment
SECRET_FILE="${ANTHROPIC_API_KEY_FILE:-/run/secrets/anthropic_api_key}"
if [[ -f "$SECRET_FILE" && -r "$SECRET_FILE" ]]; then
    exec env ANTHROPIC_API_KEY="$(cat "$SECRET_FILE")" "$REAL_CLAUDE" "$@"
fi

# No key available — claude will prompt for login
exec "$REAL_CLAUDE" "$@"
