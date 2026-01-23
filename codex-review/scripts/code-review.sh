#!/usr/bin/env bash
set -euo pipefail

# Check for codex CLI
if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: codex CLI not found" >&2
    echo "Install with: npm install -g @openai/codex" >&2
    echo "Then authenticate: codex auth" >&2
    exit 1
fi

# Parse arguments
AUTO=false
PROJECT_PATH=""
PATH_SET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=true; shift ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: code-review.sh [--auto] [project-path]" >&2
            exit 1
            ;;
        *)
            if [[ "$PATH_SET" == "true" ]]; then
                echo "ERROR: Multiple project paths specified: '$PROJECT_PATH' and '$1'" >&2
                echo "Usage: code-review.sh [--auto] [project-path]" >&2
                exit 1
            fi
            PROJECT_PATH="$1"
            PATH_SET=true
            shift
            ;;
    esac
done

# Default to current directory if no path specified
if [[ -z "$PROJECT_PATH" ]]; then
    PROJECT_PATH="."
fi

# Validate project path exists before resolution
if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "ERROR: Project path does not exist: $PROJECT_PATH" >&2
    exit 1
fi
PROJECT_PATH=$(cd "$PROJECT_PATH" && pwd)

# Validate git repository
git -C "$PROJECT_PATH" rev-parse --is-inside-work-tree &>/dev/null || { echo "ERROR: Not a git repo" >&2; exit 1; }

# Check for changes (handle repos with no commits)
if git -C "$PROJECT_PATH" rev-parse --verify HEAD &>/dev/null; then
    # Has commits - check for uncommitted changes
    git -C "$PROJECT_PATH" diff HEAD --quiet && { echo "ERROR: No changes to review" >&2; exit 1; }
else
    # No commits yet - check for staged changes
    if [[ -z "$(git -C "$PROJECT_PATH" status --porcelain)" ]]; then
        echo "ERROR: No changes to review (empty repo with no staged files)" >&2
        exit 1
    fi
fi

# Setup output
OUTPUT_DIR="$PROJECT_PATH/.codex-review"
mkdir -p "$OUTPUT_DIR"

# Check for existing results (unless --auto)
if [[ "$AUTO" != "true" ]]; then
    # Find latest non-validated code review file
    latest=""
    for f in "$OUTPUT_DIR"/code-review-*.md; do
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
    # --auto mode: delete previous results
    for f in "$OUTPUT_DIR"/code-review-*.md; do
        [[ -f "$f" ]] && rm -f "$f"
    done
fi

OUTPUT_FILE="$OUTPUT_DIR/code-review-$(date +%Y%m%d-%H%M%S).md"

# Run codex, capture both stdout AND stderr to file
# Temporarily disable errexit to capture exit code reliably
set +e
codex exec "Review code changes at: $PROJECT_PATH

Run 'git -C $PROJECT_PATH diff HEAD' and analyze against:
DRY, KISS, YAGNI, SRP, SOLID, Security, Performance

For each issue:
- FILE: <path>
- LINE: <number>
- SEVERITY: CRITICAL|HIGH|MEDIUM|LOW
- CATEGORY: <principle>
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
