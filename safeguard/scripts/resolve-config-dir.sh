#!/usr/bin/env bash
# Resolve safeguard config directory
# Outputs the config directory path. Used by both the hook script and commands.
#
# Usage: resolve-config-dir.sh [--write]
#
# Read mode (default): CLAUDE_PROJECT_DIR/.claude (if exists) > PWD/.claude (if exists) > HOME/.claude
# Write mode (--write): CLAUDE_PROJECT_DIR/.claude (if set, created if needed) > PWD/.claude (if exists) > HOME/.claude
#
# Write mode ensures that when CLAUDE_PROJECT_DIR is set, config is always
# written to the project scope rather than falling through to HOME.

WRITE_MODE=false
if [[ "${1:-}" == "--write" ]]; then
    WRITE_MODE=true
fi

if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    if [[ -d "$CLAUDE_PROJECT_DIR/.claude" ]]; then
        echo "$CLAUDE_PROJECT_DIR/.claude/.safeguard"
        exit 0
    elif [[ "$WRITE_MODE" == true ]]; then
        # In write mode, prefer project scope even if .claude/ doesn't exist yet
        echo "$CLAUDE_PROJECT_DIR/.claude/.safeguard"
        exit 0
    fi
fi

if [[ -d "$PWD/.claude" ]]; then
    echo "$PWD/.claude/.safeguard"
else
    echo "$HOME/.claude/.safeguard"
fi
