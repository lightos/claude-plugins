#!/usr/bin/env bash
set -euo pipefail

# Generates a compact markdown summary table from a batch manifest.
# Reads .meta.json sidecars (written by issue-handler-batch agent) for counts.
#
# Usage: plan-review-summary.sh <manifest-path>

if [[ $# -lt 1 ]]; then
    echo "ERROR: No manifest path specified" >&2
    echo "Usage: plan-review-summary.sh <manifest-path>" >&2
    exit 1
fi

MANIFEST_PATH="$1"

if [[ ! -f "$MANIFEST_PATH" ]]; then
    echo "ERROR: Manifest not found: $MANIFEST_PATH" >&2
    exit 1
fi

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found" >&2
    echo "Install with: sudo apt install jq (Linux) or brew install jq (macOS)" >&2
    exit 1
fi

# Read manifest
plan_count=$(jq '.plans | length' "$MANIFEST_PATH")

if [[ "$plan_count" -eq 0 ]]; then
    echo "No plans found in manifest."
    exit 0
fi

# Count successes and failures
success_count=$(jq '[.plans[] | select(.status == "success")] | length' "$MANIFEST_PATH")
fail_count=$(jq '[.plans[] | select(.status == "failed")] | length' "$MANIFEST_PATH")

echo "## Codex Batch Plan Review Summary"
echo ""
echo "**Plans reviewed:** $success_count of $plan_count"
if [[ "$fail_count" -gt 0 ]]; then
    echo "**Failed:** $fail_count"
fi
echo ""
echo "| Plan | Valid | Dismissed | Flagged | Report |"
echo "|------|------:|----------:|--------:|--------|"

# Escape pipe characters in table cell values
escape_cell() {
    echo "${1//|/\\|}"
}

# Process each plan entry
jq -c '.plans[]' "$MANIFEST_PATH" | while IFS= read -r entry; do
    name=$(echo "$entry" | jq -r '.name')
    hash=$(echo "$entry" | jq -r '.hash // empty')
    status=$(echo "$entry" | jq -r '.status')
    codex_output=$(echo "$entry" | jq -r '.codex_output')

    if [[ "$status" == "failed" ]]; then
        error=$(echo "$entry" | jq -r '.error // "unknown error"')
        echo "| $(escape_cell "$name") | - | - | - | FAILED: $(escape_cell "$error") |"
        continue
    fi

    # Look for validated report: same directory, pattern plan-review-validated-*
    output_dir=$(dirname "$codex_output")
    # The agent writes validated reports with pattern: validated-<name>-<hash>-*.md
    validated_report=""
    glob_pattern="plan-review-validated-${name}-${hash:+${hash}-}*.md"
    for f in "$output_dir"/$glob_pattern; do
        if [[ -f "$f" ]]; then
            if [[ -z "$validated_report" || "$f" -nt "$validated_report" ]]; then
                validated_report="$f"
            fi
        fi
    done

    # Try to read .meta.json sidecar
    meta_file=""
    if [[ -n "$validated_report" ]]; then
        meta_file="${validated_report%.md}.meta.json"
    fi

    valid="-"
    dismissed="-"
    flagged="-"
    report_path="${validated_report:-pending}"

    if [[ -n "$meta_file" && -f "$meta_file" ]]; then
        valid=$(jq -r '.valid // 0' "$meta_file" 2>/dev/null || echo "-")
        dismissed=$(jq -r '.dismissed // 0' "$meta_file" 2>/dev/null || echo "-")
        flagged=$(jq -r '.flagged // 0' "$meta_file" 2>/dev/null || echo "-")
    fi

    echo "| $(escape_cell "$name") | $(escape_cell "$valid") | $(escape_cell "$dismissed") | $(escape_cell "$flagged") | $(escape_cell "$report_path") |"
done

echo ""
echo "---"
echo "Full manifest: $MANIFEST_PATH"
