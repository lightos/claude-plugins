#!/usr/bin/env bash
set -euo pipefail

RESULTS_DIR=".coderabbit-results"
PROMPTS_DIR="$RESULTS_DIR/prompts"

# Preflight check for jq
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# Clean stale prompt files and create directory
mkdir -p "$PROMPTS_DIR"
rm -f "$PROMPTS_DIR"/*.txt

# Build cluster prompts (use tostring for consistent ID comparison)
if [ -f "$RESULTS_DIR/groups.json" ]; then
  while read -r group_id; do
    # Validate group_id is kebab-case (lowercase letters, numbers, and hyphens only)
    if ! [[ "$group_id" =~ ^[a-z0-9-]+$ ]]; then
      echo "WARNING: Skipping invalid group_id '$group_id' (not kebab-case)" >&2
      continue
    fi

    pattern=$(jq -r --arg id "$group_id" '.groups[] | select(.id|tostring == $id) | .pattern' "$RESULTS_DIR/groups.json")
    mapfile -t issue_ids < <(jq -r --arg id "$group_id" '.groups[] | select(.id|tostring == $id) | .issues[]' "$RESULTS_DIR/groups.json")

    issues_str=""
    for issue_id in "${issue_ids[@]}"; do
      data=$(jq -r --arg id "$issue_id" '.issues[] | select(.id|tostring == $id) | "#\(.id) \(.file):\(.line) | AIPrompt: \(.aiPrompt // "none")"' "$RESULTS_DIR/issues.json")
      [ -n "$issues_str" ] && issues_str="$issues_str ;; "
      issues_str="$issues_str$data"
    done

    echo "CLUSTER: $group_id | PATTERN: $pattern | ISSUES: $issues_str | OUTPUT: $RESULTS_DIR/cluster-$group_id.md" > "$PROMPTS_DIR/cluster-$group_id.txt"
  done < <(jq -r '.groups[] | .id | tostring' "$RESULTS_DIR/groups.json")
else
  echo "WARNING: groups.json not found, skipping cluster generation" >&2
fi

# Build singleton batch prompts (max 5 per batch)
if [ -f "$RESULTS_DIR/groups.json" ] && jq -e '.singletons | length > 0' "$RESULTS_DIR/groups.json" &>/dev/null; then
  mapfile -t singletons < <(jq -r '.singletons[]' "$RESULTS_DIR/groups.json")
  batch_num=1
  batch_issues=""
  count=0

  for issue_id in "${singletons[@]}"; do
    data=$(jq -r --arg id "$issue_id" '.issues[] | select(.id|tostring == $id) | "#\(.id) \(.file):\(.line) | \(.description) | AIPrompt: \(.aiPrompt // "none")"' "$RESULTS_DIR/issues.json")
    [ -n "$batch_issues" ] && batch_issues="$batch_issues ;; "
    batch_issues="$batch_issues$data"
    ((count+=1))

    if [ $count -ge 5 ]; then
      echo "BATCH: $batch_issues | OUTPUTS: $RESULTS_DIR/" > "$PROMPTS_DIR/batch-$batch_num.txt"
      ((batch_num+=1))
      batch_issues=""
      count=0
    fi
  done

  # Write remaining singletons
  [ -n "$batch_issues" ] && echo "BATCH: $batch_issues | OUTPUTS: $RESULTS_DIR/" > "$PROMPTS_DIR/batch-$batch_num.txt"
fi

# Count files safely (handles zero files)
file_count=$(find "$PROMPTS_DIR" -name "*.txt" -type f 2>/dev/null | wc -l)
echo "PROMPTS_READY: $file_count files"
