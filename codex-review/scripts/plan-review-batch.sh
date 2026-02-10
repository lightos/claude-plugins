#!/usr/bin/env bash
set -euo pipefail

# Batch plan review: runs codex exec in parallel for multiple plan files.
# Outputs a manifest JSON with status per entry.
#
# Usage: plan-review-batch.sh [--auto] <path1> <path2> ...
#
# Environment:
#   CODEX_BATCH_MAX_PARALLEL  - max concurrent codex processes (default: 3)
#   CODEX_REVIEW_TIMEOUT_SECONDS - per-plan timeout in seconds (default: 1800)

MAX_PARALLEL="${CODEX_BATCH_MAX_PARALLEL:-3}"
TIMEOUT_SECS="${CODEX_REVIEW_TIMEOUT_SECONDS:-1800}"

# Validate TIMEOUT_SECS is a positive integer
if ! [[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECS" -eq 0 ]]; then
    echo "ERROR: CODEX_REVIEW_TIMEOUT_SECONDS must be a positive integer, got: $TIMEOUT_SECS" >&2
    exit 1
fi

# Validate MAX_PARALLEL is a positive integer
if ! [[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || [[ "$MAX_PARALLEL" -eq 0 ]]; then
    echo "ERROR: CODEX_BATCH_MAX_PARALLEL must be a positive integer, got: $MAX_PARALLEL" >&2
    exit 1
fi

# Portable realpath function (macOS doesn't have realpath by default)
portable_realpath() {
    local path="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$path"
    elif command -v greadlink >/dev/null 2>&1; then
        greadlink -f "$path"
    else
        local dir file
        dir=$(dirname "$path")
        file=$(basename "$path")
        (cd "$dir" 2>/dev/null && echo "$(pwd -P)/$file") || echo "$path"
    fi
}

# 4-char hash of a path for filename collision safety
path_hash4() {
    printf '%s' "$1" | md5sum 2>/dev/null | cut -c1-4 \
        || printf '%s' "$1" | md5 -q 2>/dev/null | cut -c1-4 \
        || printf '%04x' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)" | tail -c 4
}

# Check for codex CLI
if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: codex CLI not found" >&2
    echo "Install with: npm install -g @openai/codex" >&2
    echo "Then authenticate: codex auth" >&2
    exit 1
fi

# Find timeout command (use array form for safe execution)
TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout "$TIMEOUT_SECS")
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(gtimeout "$TIMEOUT_SECS")
else
    echo "WARN: timeout command not found - reviews may hang on complex prompts" >&2
fi

# Parse arguments
AUTO=false
PLAN_PATHS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=true; shift ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: plan-review-batch.sh [--auto] <path1> <path2> ..." >&2
            exit 1
            ;;
        *)
            PLAN_PATHS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#PLAN_PATHS[@]} -eq 0 ]]; then
    echo "ERROR: No plan files specified" >&2
    echo "Usage: plan-review-batch.sh [--auto] <path1> <path2> ..." >&2
    exit 1
fi

# Validate all plan files exist
for p in "${PLAN_PATHS[@]}"; do
    if [[ ! -f "$p" ]]; then
        echo "ERROR: Plan file not found: $p" >&2
        exit 1
    fi
done

# Setup output directory
OUTPUT_DIR=".codex-review"
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
MANIFEST_FILE="$OUTPUT_DIR/batch-manifest-${TIMESTAMP}.json"

# Build the review prompt template (same as plan-review.sh)
build_review_prompt() {
    local plan_path="$1"
    cat <<PROMPT
Review implementation plan at: $plan_path

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
PROMPT
}

# Auto mode: delete previous results for these plans
if [[ "$AUTO" == "true" ]]; then
    for p in "${PLAN_PATHS[@]}"; do
        basename_noext=$(basename "$p" .md)
        for f in "$OUTPUT_DIR"/plan-review-"${basename_noext}"-*.md; do
            if [[ -f "$f" ]]; then
                echo "Removing previous result: $f" >&2
                rm -f "$f"
            fi
        done
    done
fi

# Track background jobs: associative arrays keyed by PID
declare -A PID_TO_NAME
declare -A PID_TO_PLAN_PATH
declare -A PID_TO_OUTPUT

# Track results: indexed arrays parallel to PLAN_PATHS
declare -a RESULT_STATUS
declare -a RESULT_OUTPUT
declare -a RESULT_ERROR

for i in "${!PLAN_PATHS[@]}"; do
    RESULT_STATUS[i]=""
    RESULT_OUTPUT[i]=""
    RESULT_ERROR[i]=""
done

# Launch codex exec for a single plan (runs in background)
launch_one() {
    local idx="$1"
    local plan_path
    plan_path=$(portable_realpath "${PLAN_PATHS[$idx]}")
    local basename_noext
    basename_noext=$(basename "$plan_path" .md)
    local hash4
    hash4=$(path_hash4 "$plan_path")
    local output_file="$OUTPUT_DIR/plan-review-${basename_noext}-${hash4}-${TIMESTAMP}.md"

    local prompt
    prompt=$(build_review_prompt "$plan_path")

    # Run codex in background, propagate exit code via wrapper
    local exit_file="$output_file.exit"
    (
        set +e
        if [[ ${#TIMEOUT_CMD[@]} -gt 0 ]]; then
            "${TIMEOUT_CMD[@]}" codex exec "$prompt" > "$output_file" 2>&1
            printf '%d' $? > "$exit_file"
        else
            codex exec "$prompt" > "$output_file" 2>&1
            printf '%d' $? > "$exit_file"
        fi
    ) &
    local pid=$!
    PID_TO_NAME[$pid]="$basename_noext"
    PID_TO_PLAN_PATH[$pid]="$plan_path"
    PID_TO_OUTPUT[$pid]="$output_file"

    # Store index mapping
    eval "PID_IDX_$pid=$idx"
}

# Process completed job
handle_completion() {
    local pid="$1"
    local name="${PID_TO_NAME[$pid]}"
    local plan_path="${PID_TO_PLAN_PATH[$pid]}"
    local output="${PID_TO_OUTPUT[$pid]}"
    local idx
    eval "idx=\$PID_IDX_$pid"

    # Read actual codex exit code from sidecar file
    local exit_file="$output.exit"
    local exit_code=1  # default to failure if file missing
    if [[ -f "$exit_file" ]]; then
        exit_code=$(cat "$exit_file")
        rm -f "$exit_file"
    fi

    if [[ "$exit_code" -eq 0 ]]; then
        RESULT_STATUS[idx]="success"
        RESULT_OUTPUT[idx]="$output"
        echo "OK:${name}:${output}"
    else
        RESULT_STATUS[idx]="failed"
        RESULT_ERROR[idx]="exit code $exit_code"
        # Keep partial output for debugging
        RESULT_OUTPUT[idx]="$output"
        echo "FAIL:${name}:exit code $exit_code"
    fi
}

# Job queue: launch up to MAX_PARALLEL at a time, use wait -n to process completions
active_pids=()
next_idx=0
total=${#PLAN_PATHS[@]}

echo "Starting batch review of $total plan(s) (max $MAX_PARALLEL parallel)..." >&2

while [[ $next_idx -lt $total || ${#active_pids[@]} -gt 0 ]]; do
    # Fill up to MAX_PARALLEL slots
    while [[ ${#active_pids[@]} -lt $MAX_PARALLEL && $next_idx -lt $total ]]; do
        launch_one "$next_idx"
        active_pids+=($!)
        echo "  Launched: $(basename "${PLAN_PATHS[$next_idx]}")" >&2
        next_idx=$((next_idx + 1))
    done

    # Wait for any one job to complete
    if [[ ${#active_pids[@]} -gt 0 ]]; then
        # wait -n returns the exit code of the completed job (bash 4.3+)
        # The completed job's exit code is actually the last line of our wrapper
        set +e
        wait -n "${active_pids[@]}" 2>/dev/null
        _wait_exit=$?  # captured for errexit; actual status read per-PID below
        set -e

        # Find which PID finished
        new_active=()
        for pid in "${active_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                new_active+=("$pid")
            else
                # Wait for subshell to finish; actual codex exit code
                # is read from .exit sidecar file by handle_completion
                wait "$pid" 2>/dev/null || true
                handle_completion "$pid"
            fi
        done
        active_pids=("${new_active[@]}")
    fi
done

# Build manifest JSON safely (handles special chars in paths)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

manifest_entries=()
for i in "${!PLAN_PATHS[@]}"; do
    plan_path=$(portable_realpath "${PLAN_PATHS[$i]}")
    basename_noext=$(basename "$plan_path" .md)
    hash4=$(path_hash4 "$plan_path")
    status="${RESULT_STATUS[$i]}"
    output="${RESULT_OUTPUT[$i]}"
    error="${RESULT_ERROR[$i]}"

    if [[ "$status" == "success" ]]; then
        entry=$(printf '{"name":"%s","hash":"%s","plan_path":"%s","codex_output":"%s","status":"success"}' \
            "$(json_escape "$basename_noext")" "$(json_escape "$hash4")" "$(json_escape "$plan_path")" "$(json_escape "$output")")
    else
        entry=$(printf '{"name":"%s","hash":"%s","plan_path":"%s","codex_output":"%s","status":"failed","error":"%s"}' \
            "$(json_escape "$basename_noext")" "$(json_escape "$hash4")" "$(json_escape "$plan_path")" "$(json_escape "$output")" "$(json_escape "$error")")
    fi
    manifest_entries+=("$entry")
done

# Write manifest
{
    echo '{"plans":['
    for i in "${!manifest_entries[@]}"; do
        if [[ $i -gt 0 ]]; then
            echo ","
        fi
        printf '  %s' "${manifest_entries[$i]}"
    done
    echo
    echo ']}'
} > "$MANIFEST_FILE"

echo "MANIFEST:$MANIFEST_FILE"

# Determine exit code: 0 = all success, 2 = partial, 1 = all failed
success_count=0
fail_count=0
for s in "${RESULT_STATUS[@]}"; do
    if [[ "$s" == "success" ]]; then
        success_count=$((success_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
done

echo "Batch complete: $success_count succeeded, $fail_count failed" >&2

if [[ $fail_count -eq 0 ]]; then
    exit 0
elif [[ $success_count -eq 0 ]]; then
    exit 1
else
    exit 2
fi
