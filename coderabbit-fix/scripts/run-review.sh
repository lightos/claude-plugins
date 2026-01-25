#!/usr/bin/env bash
# Runs CodeRabbit review and parses issues
# Usage: run-review.sh [--force] [--base <branch>] [-- extra-args...]
#   --force: Delete previous results without prompting
#   --base <branch>: Specify base branch for comparison (e.g., origin/main, HEAD~3)
#   --: Pass remaining args through to coderabbit

set -uo pipefail
# Note: -e disabled to allow capturing exit codes from timeout

# Output Protocol:
#   EXISTS:.coderabbit-results  - Previous results found (exit 0)
#   ISSUES:<count>              - Review complete with N issues (exit 0)
#   MODE:uncommitted            - Reviewing uncommitted changes (info to stderr)
#   MODE:base:<branch> (<N> commits) - Reviewing commits ahead of branch (info to stderr)
#   ERROR: <message>            - Failure (exit 1, details to stderr)
#   ERROR:NO_CHANGES: <message> - No changes found (exit 1, details to stderr)
#   ERROR:NO_BASE: <message>    - No base branch found (exit 1, details to stderr)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR=".coderabbit-results"

# --- Dependency checks ---

# Check for coderabbit CLI
if ! command -v coderabbit >/dev/null 2>&1; then
    echo "ERROR: coderabbit CLI not found" >&2
    echo "Install with: npm install -g coderabbit" >&2
    exit 1
fi

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found" >&2
    echo "Install with: apt install jq (Linux) or brew install jq (macOS)" >&2
    exit 1
fi

# Check we're in a git repository
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: Not in a git repository" >&2
    exit 1
fi

# Find timeout command (GNU coreutils on Linux, gtimeout on macOS via brew)
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
else
    echo "ERROR: timeout command not found" >&2
    echo "Install with: brew install coreutils (macOS) - provides gtimeout" >&2
    exit 1
fi

# --- Git state detection functions ---

# Check for uncommitted changes (staged or unstaged)
has_uncommitted_changes() {
    [[ -n "$(git status --porcelain 2>/dev/null)" ]]
}

# Get upstream tracking branch if set
get_tracking_branch() {
    # shellcheck disable=SC1083
    git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null
}

# Check if a branch/ref exists
branch_exists() {
    git rev-parse --verify "$1" >/dev/null 2>&1
}

# Count commits ahead of a branch (returns non-zero exit code on failure)
commits_ahead_of() {
    local count
    if ! count=$(git rev-list --count "$1..HEAD" 2>/dev/null); then
        echo "Failed to count commits ahead of '$1'" >&2
        return 1
    fi
    echo "$count"
}

# Detect the best base branch (priority: tracking > origin/main > origin/master)
# Validates tracking branch exists locally before returning it
detect_base_branch() {
    local tracking
    tracking=$(get_tracking_branch)
    # Validate tracking branch exists locally before using
    if [[ -n "$tracking" ]] && branch_exists "$tracking"; then
        echo "$tracking"
        return 0
    fi
    if branch_exists "origin/main"; then echo "origin/main"; return 0; fi
    if branch_exists "origin/master"; then echo "origin/master"; return 0; fi
    return 1
}

# --- Argument parsing ---

# Parse arguments - collect unknown args for passthrough to coderabbit
FORCE=false
BASE_BRANCH=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --force) FORCE=true; shift ;;
        --base)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --base requires a branch argument" >&2
                exit 1
            fi
            # Security: Reject option-like values to prevent git option injection
            if [[ "$2" == -* ]]; then
                echo "ERROR: Base branch cannot start with '-' (security restriction)" >&2
                exit 1
            fi
            BASE_BRANCH="$2"; shift 2 ;;
        --) shift; EXTRA_ARGS+=("$@"); break ;;  # Everything after -- is passthrough
        -*) EXTRA_ARGS+=("$1"); shift ;;  # Unknown flags pass through
        *) EXTRA_ARGS+=("$1"); shift ;;   # Unknown positional args pass through
    esac
done

# Check for previous results (unless --force)
if [[ "$FORCE" != "true" ]] && [[ -f "$RESULTS_DIR/issues.json" ]]; then
    echo "EXISTS:$RESULTS_DIR"
    exit 0
fi

# Setup results directory
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR" || {
    echo "ERROR: Failed to create results directory '$RESULTS_DIR'" >&2
    exit 1
}

# --- Review mode selection ---
# Determine what to review: explicit --base, uncommitted changes, or auto-detect base

REVIEW_ARGS=(--plain)

# PRIORITY 1: Explicit --base flag always honored (user intent)
if [[ -n "$BASE_BRANCH" ]]; then
    if ! branch_exists "$BASE_BRANCH"; then
        echo "ERROR: Base branch '$BASE_BRANCH' does not exist" >&2
        exit 1
    fi
    if ! commits=$(commits_ahead_of "$BASE_BRANCH"); then
        echo "ERROR: Failed to compare against '$BASE_BRANCH'" >&2
        exit 1
    fi
    if [[ "$commits" -eq 0 ]]; then
        echo "ERROR:NO_CHANGES: No commits ahead of '$BASE_BRANCH'" >&2
        exit 1
    fi
    # Warn if ignoring uncommitted changes
    if has_uncommitted_changes; then
        echo "WARN: Uncommitted changes ignored due to explicit --base flag" >&2
    fi
    REVIEW_ARGS=(--base "$BASE_BRANCH" --plain)
    echo "MODE:base:$BASE_BRANCH ($commits commits)" >&2

# PRIORITY 2: Uncommitted changes (current behavior)
elif has_uncommitted_changes; then
    echo "MODE:uncommitted" >&2

# PRIORITY 3: Auto-detect base branch
else
    if detected=$(detect_base_branch); then
        if ! commits=$(commits_ahead_of "$detected"); then
            echo "ERROR: Failed to compare against '$detected'" >&2
            exit 1
        fi
        if [[ "$commits" -gt 0 ]]; then
            REVIEW_ARGS=(--base "$detected" --plain)
            echo "MODE:base:$detected ($commits commits)" >&2
        else
            echo "ERROR:NO_CHANGES: No uncommitted changes and no commits ahead of '$detected'" >&2
            exit 1
        fi
    else
        echo "ERROR:NO_BASE: No uncommitted changes and no base branch found" >&2
        echo "Hint: Specify --base <branch> or ensure a remote tracking branch is set" >&2
        exit 1
    fi
fi

# Run CodeRabbit review with timeout (capture exit code explicitly)
$TIMEOUT_CMD 600 coderabbit review "${REVIEW_ARGS[@]}" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} > "$RESULTS_DIR/raw-output.txt" 2>&1
review_exit=$?

if [ $review_exit -eq 124 ]; then
    echo "ERROR: CodeRabbit review timed out after 600 seconds" >&2
    exit 1
elif [ $review_exit -ne 0 ]; then
    echo "ERROR: CodeRabbit review failed (exit $review_exit)" >&2
    tail -20 "$RESULTS_DIR/raw-output.txt" >&2
    exit 1
fi

# Parse issues
if ! bash "$SCRIPT_DIR/parse-issues.sh"; then
    echo "ERROR: Failed to parse issues" >&2
    exit 1
fi

# Output issue count (with validation)
if [[ ! -f "$RESULTS_DIR/issues.json" ]] || [[ ! -r "$RESULTS_DIR/issues.json" ]]; then
    echo "ERROR: $RESULTS_DIR/issues.json does not exist or is not readable" >&2
    exit 1
fi

issue_count=$(jq '.issues | length' "$RESULTS_DIR/issues.json" 2>/dev/null)
jq_exit=$?
if [[ $jq_exit -ne 0 ]] || [[ -z "$issue_count" ]]; then
    echo "ERROR: Failed to parse $RESULTS_DIR/issues.json (jq exit: $jq_exit)" >&2
    exit 1
fi

echo "ISSUES:$issue_count"
