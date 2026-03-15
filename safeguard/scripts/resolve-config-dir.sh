#!/usr/bin/env bash
# Resolve safeguard config directory
# Outputs the config directory path. Used by both the hook script and commands.
#
# Usage: resolve-config-dir.sh [--write | --flags]
#
# Read mode (default): CLAUDE_PROJECT_DIR/.claude (if exists) > PWD/.claude (if exists) > HOME/.claude
# Write mode (--write): CLAUDE_PROJECT_DIR/.claude (if set, created if needed) > PWD/.claude (if exists) > HOME/.claude
# Flags mode (--flags): CLAUDE_PROJECT_DIR/.claude (if set) > HOME/.claude  (skips PWD — see below)
#
# Write mode ensures that when CLAUDE_PROJECT_DIR is set, config is always
# written to the project scope rather than falling through to HOME.
#
# Flags mode resolves the directory for ephemeral allow-flags. It deliberately
# skips the PWD fallback because hook subprocesses and Bash tool calls can have
# different working directories (especially in worktrees). Using only
# CLAUDE_PROJECT_DIR or HOME guarantees the flag writer and reader always agree.

MODE="read"
case "${1:-}" in
    --write) MODE="write" ;;
    --flags) MODE="flags" ;;
esac

# --- Flags mode: deterministic path, no PWD dependency ---
if [[ "$MODE" == "flags" ]]; then
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
        echo "$CLAUDE_PROJECT_DIR/.claude/.safeguard"
    else
        echo "$HOME/.claude/.safeguard"
    fi
    exit 0
fi

# --- Config modes (read / write) ---
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    if [[ -d "$CLAUDE_PROJECT_DIR/.claude" ]]; then
        echo "$CLAUDE_PROJECT_DIR/.claude/.safeguard"
        exit 0
    elif [[ "$MODE" == "write" ]]; then
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
