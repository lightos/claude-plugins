#!/usr/bin/env bash
set -uo pipefail

# run-linters.sh - Execute detected linters with appropriate arguments
# Reads JSON Lines from detect-linters.sh output (stdin only for security)
#
# Usage: run-linters.sh [--fix] [--path <dir>] [--output <file>]
#
# Options:
#   --fix       Run linters in fix mode (where supported)
#   --path      Target directory for linting (default: current directory)
#   --output    Write results to file (JSON Lines format)

# Parse arguments
FIX_MODE=false
TARGET_PATH="."
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --path)
            [[ $# -ge 2 ]] || { echo '{"error":"--path requires an argument"}' >&2; exit 1; }
            TARGET_PATH="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { echo '{"error":"--output requires an argument"}' >&2; exit 1; }
            OUTPUT_FILE="$2"
            shift 2
            ;;
        *)
            echo "{\"error\":\"Unknown option: $1\"}" >&2
            exit 1
            ;;
    esac
done

# Check dependencies
if ! command -v jq &>/dev/null; then
    echo '{"error":"jq is required but not installed"}' >&2
    exit 1
fi

cd "$TARGET_PATH" || { echo "{\"error\":\"failed to change directory\",\"path\":\"$TARGET_PATH\"}" >&2; exit 1; }

# Get list of tracked files (NUL-delimited for safety)
get_files_for_linter() {
    local file_types="$1"
    local accepts_dirs="$2"
    local glob_pattern="$3"

    if [[ -n "$glob_pattern" ]]; then
        # Use glob pattern if specified
        if git rev-parse --git-dir &>/dev/null; then
            # Handle brace expansion (e.g., *.{sh,bash}) which git ls-files doesn't support
            if [[ "$glob_pattern" == *"{"*"}"* ]]; then
                # Extract the brace contents and expand manually
                # e.g., **/*.{sh,bash} -> **/*.sh **/*.bash
                local prefix="${glob_pattern%%\{*}"
                local suffix="${glob_pattern#*\}}"
                local braces="${glob_pattern#*\{}"
                braces="${braces%%\}*}"
                # Split on comma and call git ls-files for each pattern
                IFS=',' read -ra extensions <<< "$braces"
                for ext in "${extensions[@]}"; do
                    git ls-files -z "${prefix}${ext}${suffix}" 2>/dev/null
                done
            else
                git ls-files -z "$glob_pattern" 2>/dev/null
            fi
        else
            # Fallback find with pruning for heavy directories
            find . \( -name node_modules -o -name .git -o -name __pycache__ -o -name venv -o -name .venv -o -name dist -o -name build \) -prune -o \
                -name "$(basename "$glob_pattern")" -type f -print0 2>/dev/null
        fi
    elif [[ "$accepts_dirs" == "true" ]]; then
        printf '%s\0' "."
    else
        # Build extension list and get files
        local extensions_str=""
        for ext in $(echo "$file_types" | jq -r '.[]'); do
            extensions_str="${extensions_str}*.${ext} "
        done
        if git rev-parse --git-dir &>/dev/null; then
            # shellcheck disable=SC2086
            git ls-files -z $extensions_str 2>/dev/null
        else
            # Fallback find with pruning
            for ext in $(echo "$file_types" | jq -r '.[]'); do
                find . \( -name node_modules -o -name .git -o -name __pycache__ -o -name venv -o -name .venv \) -prune -o \
                    -name "*.${ext}" -type f -print0 2>/dev/null
            done
        fi
    fi
}

# Count issues from linter output (prefers JSON parsing when available)
count_issues() {
    local output="$1"
    local json_flag="$2"
    local linter="$3"

    # If JSON output flag is available, try to parse structured output
    if [[ -n "$json_flag" ]] && echo "$output" | jq -e . &>/dev/null; then
        # Linter-specific JSON parsing
        case "$linter" in
            eslint)
                # ESLint JSON: array of {filePath, messages: [...]}
                echo "$output" | jq '[.[].messages | length] | add // 0' 2>/dev/null && return
                ;;
            biome)
                # Biome JSON: {diagnostics: [...]}
                echo "$output" | jq '.diagnostics | length // 0' 2>/dev/null && return
                ;;
            shellcheck)
                # ShellCheck JSON: array of {file, line, ...}
                echo "$output" | jq 'length // 0' 2>/dev/null && return
                ;;
            ruff|pylint)
                # Ruff/Pylint JSON: array of issue objects
                echo "$output" | jq 'length // 0' 2>/dev/null && return
                ;;
            *)
                # Generic: try to count array length or object count
                local count
                count=$(echo "$output" | jq 'if type == "array" then length elif type == "object" and has("errors") then (.errors | length) else 0 end' 2>/dev/null)
                if [[ -n "$count" ]] && [[ "$count" =~ ^[0-9]+$ ]]; then
                    echo "$count"
                    return
                fi
                ;;
        esac
    fi

    # Fallback: count lines matching error/warning patterns (one match per line)
    local count
    count=$(echo "$output" | grep -cE '(error|warning|Error|Warning|E[0-9]{3,4}|W[0-9]{3,4})' || true)
    echo "${count:-0}"
}

# Output helper
output_result() {
    local result="$1"
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$result" >> "$OUTPUT_FILE"
    fi
    echo "$result"
}

# Initialize output file
if [[ -n "$OUTPUT_FILE" ]]; then
    : > "$OUTPUT_FILE"
fi

TOTAL_ISSUES=0
FIXED_COUNT=0
UNFIXABLE_COUNT=0

# Create temp file for NUL-delimited file lists (command substitution strips NULs)
FILES_TMP=$(mktemp)
trap 'rm -f "$FILES_TMP"' EXIT INT TERM HUP

while IFS= read -r line; do
    # Skip non-linter lines (conflicts, summaries have explicit .type field).
    # Linter entries from detect-linters.sh have no .type field, so they default to "linter"
    # and pass through. Only skip if .type exists AND is not "linter".
    line_type=$(echo "$line" | jq -r '.type // "linter"')
    [[ "$line_type" != "linter" ]] && [[ -n "$(echo "$line" | jq -r '.type // empty')" ]] && continue

    # Extract linter info
    linter_id=$(echo "$line" | jq -r '.id // empty')
    [[ -z "$linter_id" ]] && continue

    linter_name=$(echo "$line" | jq -r '.name // .id')
    exec_cmd=$(echo "$line" | jq -r '.exec_cmd')
    json_output_flag=$(echo "$line" | jq -r '.json_output // empty')
    supports_fix=$(echo "$line" | jq -r '.supports_fix')
    fix_args=$(echo "$line" | jq -r '.fix_args // [] | join(" ")')
    check_args=$(echo "$line" | jq -r '.check_args // [] | join(" ")')
    file_types=$(echo "$line" | jq -c '.file_types // []')
    accepts_dirs=$(echo "$line" | jq -r '.accepts_directories // false')
    glob_pattern=$(echo "$line" | jq -r '.glob_pattern // empty')

    output_result "{\"type\":\"start\",\"linter\":\"$linter_id\",\"name\":\"$linter_name\"}"

    # Build command
    cmd="$exec_cmd"

    # Add fix or check args
    if [[ "$FIX_MODE" == "true" ]] && [[ "$supports_fix" == "true" ]]; then
        cmd="$cmd $fix_args"
    else
        [[ -n "$check_args" ]] && cmd="$cmd $check_args"
    fi

    # Get files/directory to lint (NUL-delimited, written to temp file to preserve NULs)
    get_files_for_linter "$file_types" "$accepts_dirs" "$glob_pattern" > "$FILES_TMP"

    if [[ ! -s "$FILES_TMP" ]]; then
        output_result "{\"type\":\"skip\",\"linter\":\"$linter_id\",\"reason\":\"no_files_found\"}"
        continue
    fi

    # Run the linter
    start_time=$(date +%s)

    # Reset exit codes before each linter
    exit_code=0
    remaining_exit=0

    # Capture output - run command with files
    if [[ "$accepts_dirs" == "true" ]]; then
        # shellcheck disable=SC2086
        linter_output=$($cmd . 2>&1) || exit_code=$?
    else
        # Pass files as arguments using NUL-safe xargs with -- to prevent option injection
        # shellcheck disable=SC2086
        linter_output=$(xargs -0 $cmd -- < "$FILES_TMP" 2>&1) || exit_code=$?
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Parse results
    # Note: Different linters have different output formats
    # We do basic parsing here; detailed parsing happens in the command/agent

    if [[ $exit_code -eq 0 ]]; then
        output_result "{\"type\":\"success\",\"linter\":\"$linter_id\",\"duration\":$duration,\"issues\":0}"
    else
        # Count issues using JSON parsing when available, fallback to regex heuristic
        issue_count=$(count_issues "$linter_output" "$json_output_flag" "$linter_id")
        [[ -z "$issue_count" ]] && issue_count=0

        # Track total issues in all modes
        TOTAL_ISSUES=$((TOTAL_ISSUES + issue_count))

        if [[ "$FIX_MODE" == "true" ]] && [[ "$supports_fix" == "true" ]]; then
            # Re-run in check mode to see remaining issues
            check_cmd="$exec_cmd"
            [[ -n "$check_args" ]] && check_cmd="$check_cmd $check_args"

            remaining_exit=0
            if [[ "$accepts_dirs" == "true" ]]; then
                # shellcheck disable=SC2086
                remaining_output=$($check_cmd . 2>&1) || remaining_exit=$?
            else
                # shellcheck disable=SC2086
                remaining_output=$(xargs -0 $check_cmd -- < "$FILES_TMP" 2>&1) || remaining_exit=$?
            fi

            if [[ $remaining_exit -eq 0 ]]; then
                output_result "{\"type\":\"fixed\",\"linter\":\"$linter_id\",\"duration\":$duration,\"fixed_count\":$issue_count}"
                FIXED_COUNT=$((FIXED_COUNT + issue_count))
            else
                remaining_count=$(count_issues "$remaining_output" "$json_output_flag" "$linter_id")
                [[ -z "$remaining_count" ]] && remaining_count=0
                fixed=$((issue_count - remaining_count))
                [[ $fixed -lt 0 ]] && fixed=0

                output_result "{\"type\":\"partial\",\"linter\":\"$linter_id\",\"duration\":$duration,\"fixed\":$fixed,\"remaining\":$remaining_count,\"output\":$(echo "$remaining_output" | head -100 | jq -Rs .)}"
                FIXED_COUNT=$((FIXED_COUNT + fixed))
                UNFIXABLE_COUNT=$((UNFIXABLE_COUNT + remaining_count))
            fi
        else
            # Report only mode or linter doesn't support fix
            output_result "{\"type\":\"issues\",\"linter\":\"$linter_id\",\"duration\":$duration,\"count\":$issue_count,\"supports_fix\":$supports_fix,\"output\":$(echo "$linter_output" | head -100 | jq -Rs .)}"

            if [[ "$supports_fix" == "false" ]]; then
                UNFIXABLE_COUNT=$((UNFIXABLE_COUNT + issue_count))
            fi
        fi
    fi
done

# Final summary
output_result "{\"type\":\"complete\",\"total_issues\":$TOTAL_ISSUES,\"fixed\":$FIXED_COUNT,\"unfixable\":$UNFIXABLE_COUNT}"
