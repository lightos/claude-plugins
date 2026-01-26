#!/usr/bin/env bash
set -euo pipefail

# Configurable timeout (default 30 minutes)
TIMEOUT_SECS="${CODEX_REVIEW_TIMEOUT_SECONDS:-1800}"

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
    echo "Usage: code-review.sh [--auto] [--full|--base <branch>|--commit <sha>|--range <sha>..<sha>|--pr [number]] [project-path]" >&2
    exit 1
}

# Parse arguments
AUTO=false
FULL_SCAN=false
BASE_BRANCH=""
COMMIT_SHA=""
RANGE_SPEC=""
PR_NUMBER=""
PROJECT_PATH=""
PATH_SET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=true; shift ;;
        --full) FULL_SCAN=true; shift ;;
        --base)
            [[ -z "${2:-}" || "$2" == -* ]] && usage_error "--base requires a branch name"
            BASE_BRANCH="$2"; shift 2 ;;
        --commit)
            [[ -z "${2:-}" || "$2" == -* ]] && usage_error "--commit requires a SHA"
            COMMIT_SHA="$2"; shift 2 ;;
        --range)
            [[ -z "${2:-}" || "$2" == -* ]] && usage_error "--range requires format: sha1..sha2"
            [[ "$2" != *..* ]] && usage_error "--range requires format: sha1..sha2 or sha1...sha2"
            RANGE_SPEC="$2"; shift 2 ;;
        --pr)
            # Allow --pr without number (interactive selection handled by command)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                PR_NUMBER="SELECT"  # Sentinel value for interactive selection
                shift
            elif [[ ! "$2" =~ ^[0-9]+$ ]]; then
                usage_error "--pr requires a numeric PR number or no argument for interactive selection"
            else
                PR_NUMBER="$2"
                shift 2
            fi
            ;;
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

# Check mutual exclusivity of review modes
EXCLUSIVE_COUNT=0
[[ "$FULL_SCAN" == "true" ]] && ((++EXCLUSIVE_COUNT))
[[ -n "$BASE_BRANCH" ]] && ((++EXCLUSIVE_COUNT))
[[ -n "$COMMIT_SHA" ]] && ((++EXCLUSIVE_COUNT))
[[ -n "$RANGE_SPEC" ]] && ((++EXCLUSIVE_COUNT))
[[ -n "$PR_NUMBER" ]] && ((++EXCLUSIVE_COUNT))
[[ $EXCLUSIVE_COUNT -gt 1 ]] && usage_error "Only one of --full, --base, --commit, --range, or --pr can be specified"

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

# Check for gh CLI (only if --pr is used) - after path validation
if [[ -n "$PR_NUMBER" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: gh CLI not found (required for --pr)" >&2
        echo "Install from: https://cli.github.com/" >&2
        exit 1
    fi
    if ! (cd "$PROJECT_PATH" && gh auth status &>/dev/null); then
        echo "ERROR: gh CLI not authenticated. Run: gh auth login" >&2
        exit 1
    fi

    # Handle interactive selection request (error if --auto since it requires non-interactive)
    if [[ "$PR_NUMBER" == "SELECT" ]]; then
        if [[ "$AUTO" == "true" ]]; then
            usage_error "--auto requires a PR number (e.g., --pr 123)"
        fi
        echo "SELECT_PR:"
        exit 0
    fi
fi

# Find timeout command (optional - graceful degradation)
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout $TIMEOUT_SECS"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout $TIMEOUT_SECS"
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

# Helper: Validate commit SHA exists
validate_commit() {
    local sha="$1" resolved
    if ! resolved=$(git -C "$PROJECT_PATH" rev-parse --verify --quiet "$sha^{commit}" 2>/dev/null); then
        echo "ERROR: Commit '$sha' not found or ambiguous" >&2
        return 1
    fi
    echo "$resolved"
}

# Helper: Check if commit is a merge (has >1 parent)
is_merge_commit() {
    [[ $(git -C "$PROJECT_PATH" rev-list --count --parents -n 1 "$1" | awk '{print NF-1}') -gt 1 ]]
}

# Helper: Check if diff is empty (handles set -e safely)
diff_is_empty() {
    git -C "$PROJECT_PATH" diff --quiet "$@" 2>/dev/null
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

# Tier 1: Single commit
elif [[ -n "$COMMIT_SHA" ]]; then
    RESOLVED=$(validate_commit "$COMMIT_SHA") || exit 1
    COMMIT_SHA="$RESOLVED"
    SHORT_SHA=$(git -C "$PROJECT_PATH" rev-parse --short "$COMMIT_SHA")
    REVIEW_MODE="commit"
    echo "MODE:commit:$SHORT_SHA" >&2
    is_merge_commit "$COMMIT_SHA" && echo "WARNING: Merge commit - showing first-parent diff" >&2
    has_uncommitted_changes && echo "WARNING: Uncommitted changes ignored (using --commit)" >&2

# Tier 2: Commit range
elif [[ -n "$RANGE_SPEC" ]]; then
    # Parse range (supports .. and ...)
    if [[ "$RANGE_SPEC" == *...* ]]; then
        RANGE_START="${RANGE_SPEC%%...*}"
        RANGE_END="${RANGE_SPEC##*...}"
        RANGE_TYPE="..."
    else
        RANGE_START="${RANGE_SPEC%%.*}"
        RANGE_END="${RANGE_SPEC##*..}"
        RANGE_TYPE=".."
    fi

    START_RESOLVED=$(validate_commit "$RANGE_START") || exit 1
    END_RESOLVED=$(validate_commit "$RANGE_END") || exit 1

    # Check for empty diff
    if diff_is_empty "${START_RESOLVED}${RANGE_TYPE}${END_RESOLVED}"; then
        echo "ERROR:EMPTY_RANGE: No changes in range $RANGE_SPEC" >&2
        exit 1
    fi

    REVIEW_MODE="range"
    SHORT_START=$(git -C "$PROJECT_PATH" rev-parse --short "$START_RESOLVED")
    SHORT_END=$(git -C "$PROJECT_PATH" rev-parse --short "$END_RESOLVED")
    COMMIT_COUNT=$(git -C "$PROJECT_PATH" rev-list --count "${START_RESOLVED}..${END_RESOLVED}" 2>/dev/null || echo "?")
    echo "MODE:range:${SHORT_START}${RANGE_TYPE}${SHORT_END} ($COMMIT_COUNT commits)" >&2
    has_uncommitted_changes && echo "WARNING: Uncommitted changes ignored (using --range)" >&2

# Tier 3: Pull Request
elif [[ -n "$PR_NUMBER" ]]; then
    # Fetch all PR metadata in a single API call (run gh in repo context)
    PR_DATA=$(cd "$PROJECT_PATH" && gh pr view "$PR_NUMBER" \
        --json title,state,baseRefName,headRefName,isCrossRepository,additions,deletions,changedFiles,body \
        --jq '[.title, .state, .baseRefName, .headRefName, (.isCrossRepository | tostring), (.additions | tostring), (.deletions | tostring), (.changedFiles | tostring)] | @tsv') || {
        echo "ERROR: PR #$PR_NUMBER not found or inaccessible" >&2
        exit 1
    }

    # Parse tab-separated fields (body handled separately due to newlines)
    IFS=$'\t' read -r PR_TITLE PR_STATE PR_BASE PR_HEAD PR_IS_FORK PR_ADDITIONS PR_DELETIONS PR_FILES <<< "$PR_DATA"
    # Get body separately since it can contain tabs/newlines
    PR_BODY=$(cd "$PROJECT_PATH" && gh pr view "$PR_NUMBER" --json body --jq '.body // ""')

    REVIEW_MODE="pr"
    echo "MODE:pr:#$PR_NUMBER ($PR_FILES files, +$PR_ADDITIONS/-$PR_DELETIONS)" >&2

    # Warnings
    [[ "$PR_STATE" != "OPEN" ]] && echo "WARNING: PR is $PR_STATE" >&2
    [[ "$PR_IS_FORK" == "true" ]] && echo "INFO: PR is from a fork" >&2
    has_uncommitted_changes && echo "WARNING: Uncommitted changes ignored (using --pr)" >&2

# Tier 4: Explicit --base
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
elif [[ "$REVIEW_MODE" == "commit" ]]; then
    COMMIT_MSG=$(git -C "$PROJECT_PATH" log -1 --format="%s" "$COMMIT_SHA")
    REVIEW_PROMPT="Review changes from commit at: $PROJECT_PATH

Commit: $COMMIT_SHA
Message: $COMMIT_MSG

Run 'git -C \"$PROJECT_PATH\" show --format=\"\" --patch \"$COMMIT_SHA\"' and analyze against:
DRY, KISS, YAGNI, SRP, SOLID, Security, Performance

For each issue:
- FILE: <path>
- LINE: <number>
- SEVERITY: CRITICAL|HIGH|MEDIUM|LOW
- CATEGORY: <principle>
- ISSUE: <description>
- SUGGESTION: <fix>
"
elif [[ "$REVIEW_MODE" == "range" ]]; then
    DIFF_SPEC="${START_RESOLVED}${RANGE_TYPE}${END_RESOLVED}"
    REVIEW_PROMPT="Review changes in commit range at: $PROJECT_PATH

Range: $RANGE_SPEC ($COMMIT_COUNT commits)
Syntax: ${RANGE_TYPE} $([ "$RANGE_TYPE" == "..." ] && echo "(merge-base to end)" || echo "(tree-to-tree)")

Run 'git -C \"$PROJECT_PATH\" diff \"$DIFF_SPEC\"' and analyze against:
DRY, KISS, YAGNI, SRP, SOLID, Security, Performance

For each issue:
- FILE: <path>
- LINE: <number>
- SEVERITY: CRITICAL|HIGH|MEDIUM|LOW
- CATEGORY: <principle>
- ISSUE: <description>
- SUGGESTION: <fix>
"
elif [[ "$REVIEW_MODE" == "pr" ]]; then
    # Get PR diff and save to temp file for Codex to read
    PR_DIFF_FILE=$(mktemp)
    # Set up trap for guaranteed cleanup on exit/error/interrupt
    trap 'rm -f "$PR_DIFF_FILE"' EXIT

    (cd "$PROJECT_PATH" && gh pr diff "$PR_NUMBER") > "$PR_DIFF_FILE" || {
        echo "ERROR: Failed to get PR diff" >&2
        exit 1
    }

    # PR_BODY already extracted in detection phase

    REVIEW_PROMPT="Review Pull Request #$PR_NUMBER at: $PROJECT_PATH

Title: $PR_TITLE
Base: $PR_BASE <- Head: $PR_HEAD
Changes: $PR_FILES files, +$PR_ADDITIONS/-$PR_DELETIONS

$([ -n "$PR_BODY" ] && echo "Description:
$PR_BODY
")
The PR diff is saved at: $PR_DIFF_FILE
Read it with: cat \"$PR_DIFF_FILE\"

Analyze the changes against:
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

# Status file for polling (supports background execution)
STATUS_FILE="${OUTPUT_FILE}.status"
echo "running" > "$STATUS_FILE"

# Run codex, capture both stdout AND stderr to file
# Temporarily disable errexit to capture exit code reliably
set +e
if [[ -n "$TIMEOUT_CMD" ]]; then
    $TIMEOUT_CMD codex exec "$REVIEW_PROMPT" > "$OUTPUT_FILE" 2>&1
    exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
        echo "timeout" > "$STATUS_FILE"
        if [[ "$REVIEW_MODE" == "full" ]]; then
            echo "ERROR: Full codebase scan timed out after ${TIMEOUT_SECS} seconds. Try --base for incremental review." >&2
        else
            echo "ERROR: Codex timed out after ${TIMEOUT_SECS} seconds" >&2
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
    echo "error:$exit_code" > "$STATUS_FILE"
    echo "ERROR: Codex failed (exit $exit_code). See $OUTPUT_FILE for details." >&2
    exit 1
fi

# Mark as done
echo "done" > "$STATUS_FILE"

# Only output the file path
echo "$OUTPUT_FILE"
