#!/usr/bin/env bash
set -euo pipefail

# Portable realpath function (macOS doesn't have realpath by default)
portable_realpath() {
    local path="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$path"
    elif command -v greadlink >/dev/null 2>&1; then
        greadlink -f "$path"
    else
        # Fallback using cd and pwd
        local dir file
        dir=$(dirname "$path")
        file=$(basename "$path")
        # Return original path if cd fails (directory doesn't exist)
        (cd "$dir" 2>/dev/null && echo "$(pwd -P)/$file") || echo "$path"
    fi
}

# Check for codex CLI
if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: codex CLI not found" >&2
    echo "Install with: npm install -g @openai/codex" >&2
    echo "Then authenticate: codex auth" >&2
    exit 1
fi

# Parse arguments
AUTO=false
PLAN_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=true; shift ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: plan-review.sh [--auto] <plan-file-path>" >&2
            exit 1
            ;;
        *)
            if [[ -n "$PLAN_PATH" ]]; then
                echo "ERROR: Multiple plan files specified: '$PLAN_PATH' and '$1'" >&2
                echo "Usage: plan-review.sh [--auto] <plan-file-path>" >&2
                exit 1
            fi
            PLAN_PATH="$1"
            shift
            ;;
    esac
done

if [[ -z "$PLAN_PATH" ]]; then
    echo "Usage: plan-review.sh [--auto] <plan-file-path>" >&2
    exit 1
fi

if [[ ! -f "$PLAN_PATH" ]]; then
    echo "ERROR: Plan file not found: $PLAN_PATH" >&2
    exit 1
fi

PLAN_PATH=$(portable_realpath "$PLAN_PATH")
PLAN_BASENAME=$(basename "$PLAN_PATH" .md)

# Setup output (in current directory)
OUTPUT_DIR=".codex-review"
mkdir -p "$OUTPUT_DIR"

# Check for existing results for THIS plan (unless --auto)
if [[ "$AUTO" != "true" ]]; then
    # Find latest non-validated plan review file for this plan
    latest=""
    for f in "$OUTPUT_DIR"/plan-review-"${PLAN_BASENAME}"-*.md; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *validated* ]] && continue
        if [[ -z "$latest" || "$f" -nt "$latest" ]]; then
            latest="$f"
        fi
    done
    if [[ -n "$latest" ]]; then
        echo "EXISTS:$latest"
        exit 0
    fi
else
    # --auto mode: delete previous results for this plan
    deleted_count=0
    for f in "$OUTPUT_DIR"/plan-review-"${PLAN_BASENAME}"-*.md; do
        if [[ -f "$f" ]]; then
            echo "Removing previous result: $f" >&2
            rm -f "$f"
            ((deleted_count++)) || true
        fi
    done
    if [[ $deleted_count -eq 0 ]]; then
        echo "No previous results found for ${PLAN_BASENAME}" >&2
    else
        echo "Removed $deleted_count previous result(s)" >&2
    fi
fi

OUTPUT_FILE="$OUTPUT_DIR/plan-review-${PLAN_BASENAME}-$(date +%Y%m%d-%H%M%S).md"

# Run codex, capture both stdout AND stderr to file
# Temporarily disable errexit to capture exit code reliably
set +e
codex exec "Review implementation plan at: $PLAN_PATH

Read the plan file and analyze for:
- Completeness: Are all requirements addressed?
- Correctness: Will the approach work?
- Risk: What could go wrong?
- Missing steps: What's not covered?
- Over-engineering: Is anything unnecessary?

For each issue:
- SECTION: <plan section>
- SEVERITY: CRITICAL|HIGH|MEDIUM|LOW
- ISSUE: <description>
- SUGGESTION: <fix>
" > "$OUTPUT_FILE" 2>&1
exit_code=$?
set -e

# Check for errors
if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: Codex failed (exit $exit_code). See $OUTPUT_FILE for details." >&2
    exit 1
fi

# Only output the file path
echo "$OUTPUT_FILE"
