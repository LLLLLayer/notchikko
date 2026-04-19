#!/bin/bash
# notchikko-hook-version: 4
# Notchikko Hook — thin wrapper that forwards stdin to notchikko-hook.py.
# Usage: notchikko-hook.sh [source]
#   source: "claude-code" | "codex" | "gemini-cli" | "trae-cli"
#
# Logic is in the sibling notchikko-hook.py file (split out to avoid the
# inline-Python-in-bash fragility — unescaped quotes in Python strings used
# to brick the whole hook). Both files are installed together by the app.

SOCKET_PATH="/tmp/notchikko.sock"

# App not running → exit silently (fail-open)
[ -S "$SOCKET_PATH" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_IMPL="$SCRIPT_DIR/notchikko-hook.py"

# Python implementation missing → exit silently (don't block the CLI)
[ -f "$PY_IMPL" ] || exit 0

exec /usr/bin/python3 "$PY_IMPL" "$@"
