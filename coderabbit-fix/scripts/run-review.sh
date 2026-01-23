#!/usr/bin/env bash
# Runs CodeRabbit review and parses issues
# Usage: run-review.sh [--force]
#   --force: Delete previous results without prompting

set -uo pipefail
# Note: -e disabled to allow capturing exit codes from timeout

# Output Protocol:
#   EXISTS:.coderabbit-results  - Previous results found (exit 0)
#   ISSUES:<count>              - Review complete with N issues (exit 0)
#   ERROR: <message>            - Failure (exit 1, details to stderr)

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

# Parse arguments
FORCE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force) FORCE=true; shift ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
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

# Run CodeRabbit review with timeout (capture exit code explicitly)
$TIMEOUT_CMD 600 coderabbit review --plain > "$RESULTS_DIR/raw-output.txt" 2>&1
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
