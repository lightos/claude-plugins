#!/usr/bin/env bash
set -euo pipefail

# List recent Claude Code plan files for user selection
# Output: numbered list of plan files with modification date

PLANS_DIR="${HOME}/.claude/plans"

# Check if plans directory exists
if [ ! -d "$PLANS_DIR" ]; then
  echo "ERROR: Plans directory not found at $PLANS_DIR"
  echo "No plans available to review."
  exit 1
fi

# Find .md files, sort by modification time (newest first), limit to 10
# Use null-delimited find with xargs for cross-platform compatibility and safe filename handling
# Note: avoid -r flag (GNU-only) by checking if files exist first
if find "$PLANS_DIR" -maxdepth 1 -name "*.md" -type f -print -quit 2>/dev/null | grep -q .; then
  # Read null-delimited list safely into array
  mapfile -d '' -t plan_arr < <(find "$PLANS_DIR" -maxdepth 1 -name "*.md" -type f -print0 2>/dev/null)
  # Sort by modification time and limit to 10
  plans=$(printf '%s\n' "${plan_arr[@]}" | xargs -d '\n' ls -t 2>/dev/null | head -10)
else
  plans=""
fi

if [ -z "$plans" ]; then
  echo "ERROR: No plan files found in $PLANS_DIR"
  exit 1
fi

echo "Recent plans (newest first):"
echo "---"

i=1
while IFS= read -r plan; do
  # Get modification date (cross-platform: Linux uses stat -c, macOS uses stat -f)
  if [[ "$(uname)" == "Darwin" ]]; then
    mod_date=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$plan" 2>/dev/null)
  else
    mod_date=$(stat -c '%y' "$plan" 2>/dev/null | cut -d'.' -f1)
  fi
  # Get first non-empty line as title (skip frontmatter)
  title=$(grep -m1 '^#' "$plan" 2>/dev/null | sed 's/^#* *//' | head -c 60)
  if [ -z "$title" ]; then
    title=$(basename "$plan" .md)
  fi

  echo "$i. [$mod_date] $title"
  echo "   Path: $plan"

  ((i++))
done <<< "$plans"

echo "---"
echo "Total: $((i-1)) plan(s) found"
