#!/usr/bin/env bash
set -euo pipefail

# Check for codex CLI
if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: codex CLI not found" >&2
    echo "Install with: npm install -g @openai/codex" >&2
    echo "Then authenticate: codex auth" >&2
    exit 1
fi

# Usage error helper
usage_error() {
    echo "ERROR: $1" >&2
    echo "Usage: code-review.sh [--auto] [--full] [--base <branch>] [project-path]" >&2
    exit 1
}

# Parse arguments
AUTO=false
FULL_SCAN=false
BASE_BRANCH=""
PROJECT_PATH=""
PATH_SET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=true; shift ;;
        --full) FULL_SCAN=true; shift ;;
        --base)
            [[ -z "${2:-}" || "$2" == -* ]] && usage_error "--base requires a branch name"
            BASE_BRANCH="$2"; shift 2 ;;
        -*)
            usage_error "Unknown option: $1"
            ;;
        *)
            if [[ "$PATH_SET" == "true" ]]; then
                usage_error "Multiple project paths specified: '$PROJECT_PATH' and '$1'"
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

# Find timeout command (optional - graceful degradation)
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout 600"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout 600"
else
    echo "WARN: timeout command not found - review may hang on complex prompts" >&2
fi

# Helper: Check for uncommitted changes (includes untracked files)
has_uncommitted_changes() {
    [[ -n "$(git -C "$PROJECT_PATH" status --porcelain 2>/dev/null)" ]]
}

# Helper: Check if HEAD exists (false for new repos with no commits)
has_head() {
    git -C "$PROJECT_PATH" rev-parse --verify HEAD &>/dev/null
}

# Helper: Detect base branch using multiple strategies
detect_base_branch() {
    local tracking remote_head
    # 1. Try tracking branch
    if tracking=$(git -C "$PROJECT_PATH" rev-parse --abbrev-ref '@{u}' 2>/dev/null); then
        if git -C "$PROJECT_PATH" rev-parse --verify "$tracking" &>/dev/null; then
            echo "$tracking"; return 0
        fi
    fi
    # 2. Try remote default branch
    if remote_head=$(git -C "$PROJECT_PATH" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null); then
        remote_head="${remote_head#refs/remotes/}"
        if git -C "$PROJECT_PATH" rev-parse --verify "$remote_head" &>/dev/null; then
            echo "$remote_head"; return 0
        fi
    fi
    # 3. Fallback to common defaults
    for branch in origin/main origin/master main master; do
        if git -C "$PROJECT_PATH" rev-parse --verify "$branch" &>/dev/null; then
            echo "$branch"; return 0
        fi
    done
    return 1
}

# Helper: Count commits ahead of base branch
count_commits_ahead() {
    local count
    if count=$(git -C "$PROJECT_PATH" rev-list --count "$1..HEAD" 2>/dev/null); then
        echo "$count"
    else
        echo "ERROR: Failed to count commits from $1" >&2
        return 1
    fi
}

# Determine review mode with 4-tier priority
REVIEW_MODE=""

# Tier 0: Full codebase scan (highest priority)
if [[ "$FULL_SCAN" == "true" ]]; then
    REVIEW_MODE="full"
    FILE_COUNT=$(git -C "$PROJECT_PATH" ls-files --cached | wc -l | tr -d ' ')
    echo "MODE:full ($FILE_COUNT files)" >&2
    if has_uncommitted_changes; then
        echo "WARNING: Uncommitted changes will be included in scan" >&2
    fi

# Tier 1: Explicit --base
elif [[ -n "$BASE_BRANCH" ]]; then
    git -C "$PROJECT_PATH" rev-parse --verify "$BASE_BRANCH" &>/dev/null || \
        { echo "ERROR: Branch '$BASE_BRANCH' not found" >&2; exit 1; }
    COMMIT_COUNT=$(count_commits_ahead "$BASE_BRANCH") || exit 1
    [[ "$COMMIT_COUNT" -eq 0 ]] && { echo "ERROR:NO_CHANGES: No commits ahead of $BASE_BRANCH" >&2; exit 1; }
    REVIEW_MODE="base"
    echo "MODE:base:$BASE_BRANCH ($COMMIT_COUNT commits)" >&2
    # Warn if uncommitted changes exist but continue
    if has_uncommitted_changes; then
        echo "WARNING: Uncommitted changes exist but will be ignored (using --base)" >&2
    fi

# Tier 2: Uncommitted changes
elif has_uncommitted_changes; then
    REVIEW_MODE="uncommitted"
    if has_head; then
        echo "MODE:uncommitted" >&2
    else
        echo "MODE:uncommitted (new repo, no commits)" >&2
    fi

# Tier 3: Auto-detect base branch
else
    if detected=$(detect_base_branch); then
        COMMIT_COUNT=$(count_commits_ahead "$detected") || exit 1
        if [[ "$COMMIT_COUNT" -gt 0 ]]; then
            BASE_BRANCH="$detected"
            REVIEW_MODE="base"
            echo "MODE:base:$detected ($COMMIT_COUNT commits, auto-detected)" >&2
        fi
    fi
fi

# Final check with distinct errors
if [[ -z "$REVIEW_MODE" ]]; then
    if ! detect_base_branch >/dev/null 2>&1; then
        echo "ERROR:NO_BASE: Could not detect base branch. Use --base <branch> to specify." >&2
    else
        echo "ERROR:NO_CHANGES: No uncommitted changes and no commits ahead of base branch" >&2
    fi
    exit 1
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

# Build prompt based on review mode
if [[ "$REVIEW_MODE" == "full" ]]; then
    REVIEW_PROMPT="Review entire codebase at: $PROJECT_PATH

List all git-tracked files with: git -C \"$PROJECT_PATH\" ls-files
Then read and analyze each file for:
DRY, KISS, YAGNI, SRP, SOLID, Security, Performance

Prioritize: Security > Performance > Code Quality
Focus on: logic, architecture, design patterns (ignore formatting)

For each issue:
- FILE: <path>
- LINE: <number>
- SEVERITY: CRITICAL|HIGH|MEDIUM|LOW
- CATEGORY: <principle>
- ISSUE: <description>
- SUGGESTION: <fix>
"
elif [[ "$REVIEW_MODE" == "uncommitted" ]]; then
    if has_head; then
        DIFF_CMD="git -C \"$PROJECT_PATH\" diff HEAD"
        REVIEW_PROMPT="Review code changes at: $PROJECT_PATH

Run '$DIFF_CMD' and analyze against:
DRY, KISS, YAGNI, SRP, SOLID, Security, Performance

For each issue:
- FILE: <path>
- LINE: <number>
- SEVERITY: CRITICAL|HIGH|MEDIUM|LOW
- CATEGORY: <principle>
- ISSUE: <description>
- SUGGESTION: <fix>
"
    else
        # Unborn HEAD: use git diff --cached for staged + list untracked files
        STAGED_CMD="git -C \"$PROJECT_PATH\" diff --cached"
        UNTRACKED_CMD="git -C \"$PROJECT_PATH\" ls-files --others --exclude-standard"
        REVIEW_PROMPT="Review code changes in new repository at: $PROJECT_PATH

This is a new repository with no commits yet.

1. For staged changes, run: $STAGED_CMD
2. For untracked files, run: $UNTRACKED_CMD
   Then read each untracked file to review its contents.

Analyze all files against:
DRY, KISS, YAGNI, SRP, SOLID, Security, Performance

For each issue:
- FILE: <path>
- LINE: <number>
- SEVERITY: CRITICAL|HIGH|MEDIUM|LOW
- CATEGORY: <principle>
- ISSUE: <description>
- SUGGESTION: <fix>
"
    fi
else
    DIFF_CMD="git -C \"$PROJECT_PATH\" diff \"$BASE_BRANCH\"...HEAD"
    REVIEW_PROMPT="Review code changes at: $PROJECT_PATH

Run '$DIFF_CMD' and analyze against:
DRY, KISS, YAGNI, SRP, SOLID, Security, Performance

For each issue:
- FILE: <path>
- LINE: <number>
- SEVERITY: CRITICAL|HIGH|MEDIUM|LOW
- CATEGORY: <principle>
- ISSUE: <description>
- SUGGESTION: <fix>
"
fi

# Run codex, capture both stdout AND stderr to file
# Temporarily disable errexit to capture exit code reliably
set +e
if [[ -n "$TIMEOUT_CMD" ]]; then
    $TIMEOUT_CMD codex exec "$REVIEW_PROMPT" > "$OUTPUT_FILE" 2>&1
    exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
        if [[ "$REVIEW_MODE" == "full" ]]; then
            echo "ERROR: Full codebase scan timed out. Try --base for incremental review." >&2
        else
            echo "ERROR: Codex timed out after 600 seconds" >&2
        fi
        exit 1
    fi
else
    codex exec "$REVIEW_PROMPT" > "$OUTPUT_FILE" 2>&1
    exit_code=$?
fi
set -e

# Check for errors
if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: Codex failed (exit $exit_code). See $OUTPUT_FILE for details." >&2
    exit 1
fi

# Only output the file path
echo "$OUTPUT_FILE"
