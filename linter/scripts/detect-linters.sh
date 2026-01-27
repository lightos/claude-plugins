#!/usr/bin/env bash
set -uo pipefail

# detect-linters.sh - Auto-detect available linters in the codebase
# Outputs JSON Lines with detected linters and their capabilities
#
# Usage: detect-linters.sh [--path <dir>] [--only <linter,...>] [--skip <linter,...>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPABILITIES_FILE="${SCRIPT_DIR}/linter-capabilities.json"

# Parse arguments
TARGET_PATH="."
ONLY_LINTERS=""
SKIP_LINTERS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --path)
            [[ $# -ge 2 ]] || { echo '{"error":"--path requires an argument"}' >&2; exit 1; }
            TARGET_PATH="$2"
            shift 2
            ;;
        --only)
            [[ $# -ge 2 ]] || { echo '{"error":"--only requires an argument"}' >&2; exit 1; }
            ONLY_LINTERS="$2"
            shift 2
            ;;
        --skip)
            [[ $# -ge 2 ]] || { echo '{"error":"--skip requires an argument"}' >&2; exit 1; }
            SKIP_LINTERS="$2"
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
    echo '{"error":"jq is required but not installed. Install with: brew install jq (macOS) or apt install jq (Linux)"}' >&2
    exit 1
fi

if [[ ! -f "$CAPABILITIES_FILE" ]]; then
    echo '{"error":"linter-capabilities.json not found"}' >&2
    exit 1
fi

cd "$TARGET_PATH" || { echo "{\"error\":\"failed to change directory\",\"path\":\"$TARGET_PATH\"}" >&2; exit 1; }

# Helper: Check if linter should be skipped
should_skip() {
    local linter="$1"
    if [[ -n "$ONLY_LINTERS" ]]; then
        if [[ ! ",$ONLY_LINTERS," == *",$linter,"* ]]; then
            return 0  # Skip if not in only list
        fi
    fi
    if [[ -n "$SKIP_LINTERS" ]]; then
        if [[ ",$SKIP_LINTERS," == *",$linter,"* ]]; then
            return 0  # Skip if in skip list
        fi
    fi
    return 1
}

# Helper: Find local executable
find_local_exec() {
    local linter="$1"
    local local_execs
    local_execs=$(jq -r --arg l "$linter" '.linters[$l].local_exec[]? // empty' "$CAPABILITIES_FILE")

    while IFS= read -r exec_cmd; do
        [[ -z "$exec_cmd" ]] && continue
        local first_word="${exec_cmd%% *}"

        # Check for package manager executors
        case "$first_word" in
            npx|pnpm|yarn|bunx)
                if command -v "$first_word" &>/dev/null; then
                    # Check if package is installed locally
                    if [[ -d "node_modules" ]]; then
                        echo "$exec_cmd"
                        return 0
                    fi
                fi
                ;;
            python)
                if command -v python &>/dev/null || command -v python3 &>/dev/null; then
                    local py_cmd
                    py_cmd=$(command -v python3 || command -v python)
                    # Check if module is available
                    local module="${exec_cmd#python -m }"
                    if "$py_cmd" -c "import ${module%%[[:space:]]*}" 2>/dev/null; then
                        echo "${exec_cmd/python/$py_cmd}"
                        return 0
                    fi
                fi
                ;;
            poetry)
                if command -v poetry &>/dev/null && [[ -f "pyproject.toml" ]]; then
                    if poetry run which "${linter}" &>/dev/null 2>&1; then
                        echo "$exec_cmd"
                        return 0
                    fi
                fi
                ;;
            uv)
                if command -v uv &>/dev/null; then
                    # Verify the linter tool is available via uv
                    if uv run --quiet "$linter" --version &>/dev/null 2>&1; then
                        echo "$exec_cmd"
                        return 0
                    fi
                fi
                ;;
        esac
    done <<< "$local_execs"

    # Fallback to global
    if command -v "$linter" &>/dev/null; then
        echo "$linter"
        return 0
    fi

    return 1
}

# Helper: Check for config files
find_config() {
    local linter="$1"
    local configs
    configs=$(jq -r --arg l "$linter" '.linters[$l].configs[]? // empty' "$CAPABILITIES_FILE")

    while IFS= read -r config; do
        [[ -z "$config" ]] && continue
        if [[ -f "$config" ]]; then
            echo "$config"
            return 0
        fi
    done <<< "$configs"

    # Check package.json for embedded config
    if [[ -f "package.json" ]]; then
        local pkg_key
        pkg_key=$(jq -r --arg l "$linter" '.linters[$l].package_json_key // empty' "$CAPABILITIES_FILE")
        if [[ -n "$pkg_key" ]]; then
            if jq -e --arg k "$pkg_key" '.[$k] // .[$k+"Config"]' package.json &>/dev/null; then
                echo "package.json"
                return 0
            fi
        fi
    fi

    # Check pyproject.toml for Python tools
    if [[ -f "pyproject.toml" ]]; then
        local pyproject_section
        pyproject_section=$(jq -r --arg l "$linter" '.linters[$l].pyproject_section // empty' "$CAPABILITIES_FILE")
        if [[ -n "$pyproject_section" ]]; then
            if grep -Fq "[${pyproject_section}]" pyproject.toml 2>/dev/null; then
                echo "pyproject.toml"
                return 0
            fi
        fi
        # Also check for tool.linter sections
        if grep -Fq "[tool.${linter}]" pyproject.toml 2>/dev/null; then
            echo "pyproject.toml"
            return 0
        fi
    fi

    return 1
}

# Main detection loop
DETECTED_LINTERS=()

for linter in $(jq -r '.linters | keys[]' "$CAPABILITIES_FILE"); do
    should_skip "$linter" && continue

    config_path=""
    exec_cmd=""
    source_type="none"

    # Check for config first (preferred)
    if config_path=$(find_config "$linter"); then
        source_type="config"
    fi

    # Check for executable
    if exec_cmd=$(find_local_exec "$linter"); then
        if [[ "$source_type" == "none" ]]; then
            source_type="fallback"
        fi
    else
        # No executable found, skip this linter
        continue
    fi

    # Get capabilities from JSON
    linter_info=$(jq -c --arg l "$linter" --arg src "$source_type" --arg cfg "$config_path" --arg exec "$exec_cmd" '
        .linters[$l] + {
            "id": $l,
            "source": $src,
            "config_path": $cfg,
            "exec_cmd": $exec
        }
    ' "$CAPABILITIES_FILE")

    DETECTED_LINTERS+=("$linter")
    echo "$linter_info"
done

# Check for conflicts
if [[ ${#DETECTED_LINTERS[@]} -gt 1 ]]; then
    conflicts=$(jq -c --argjson detected "$(printf '%s\n' "${DETECTED_LINTERS[@]}" | jq -R . | jq -s .)" '
        .conflict_groups[] |
        select(
            (.linters | map(. as $l | $detected | index($l) != null) | add) >= 2
        ) |
        {
            "type": "conflict_warning",
            "group": .name,
            "linters": [.linters[] | select(. as $l | $detected | index($l) != null)],
            "resolution": .resolution
        }
    ' "$CAPABILITIES_FILE" 2>/dev/null)

    if [[ -n "$conflicts" ]]; then
        echo "$conflicts"
    fi
fi

# Summary
if [[ ${#DETECTED_LINTERS[@]} -eq 0 ]]; then
    linters_json=""
else
    linters_json=$(printf '"%s",' "${DETECTED_LINTERS[@]}")
    linters_json="${linters_json%,}"  # Remove trailing comma
fi
echo "{\"type\":\"summary\",\"detected_count\":${#DETECTED_LINTERS[@]},\"linters\":[$linters_json]}"
