#!/bin/bash
# generate-report.sh - Generate CodeRabbit fix summary report
# Parses META lines from issue files AND cluster files, joins with issues.json,
# writes full report and prints compact summary to stdout

set -e

RESULTS_DIR=".coderabbit-results"
ISSUES_JSON="$RESULTS_DIR/issues.json"
SUMMARY_FILE="$RESULTS_DIR/summary.md"
LINT_STATUS="$RESULTS_DIR/lint-status.txt"
TEST_STATUS="$RESULTS_DIR/test-status.txt"

# Check if issues.json exists
if [ ! -f "$ISSUES_JSON" ]; then
    echo "No issues found by CodeRabbit"
    exit 0
fi

# Get total issues count
total=$(jq -r '.total // 0' "$ISSUES_JSON")
if [ "$total" -eq 0 ]; then
    echo "No issues found by CodeRabbit"
    exit 0
fi

# Initialize counters and arrays
fixed_count=0
invalid_count=0
intentional_count=0
failed_count=0
pending_count=0
incomplete_count=0
cluster_count=0

fixed_items=""
invalid_items=""
intentional_items=""
failed_items=""
pending_items=""
incomplete_items=""

# Track processed issue IDs to avoid double-counting from clusters
declare -A processed_issues

# Helper function to append items without leading newlines
append_item() {
    local -n var=$1
    local item=$2
    if [ -z "$var" ]; then
        var="$item"
    else
        var="$var"$'\n'"$item"
    fi
}

# Process cluster files first (they may contain multiple issues)
for cluster_file in "$RESULTS_DIR"/cluster-*.md; do
    [ -f "$cluster_file" ] || continue
    cluster_count=$((cluster_count + 1))

    # Extract all META lines from cluster file (may have multiple)
    while IFS= read -r meta_line; do
        [ -z "$meta_line" ] && continue

        # Extract file and line from META
        # shellcheck disable=SC2001 # sed with capture groups is cleaner for regex extraction
        meta_file=$(echo "$meta_line" | sed 's/.*file=\([^ ]*\).*/\1/')
        # shellcheck disable=SC2001
        meta_line_num=$(echo "$meta_line" | sed 's/.*line=\([^ ]*\).*/\1/')
        location="$meta_file:$meta_line_num"

        # Find matching issue ID from issues.json
        issue_id=$(jq -r --arg f "$meta_file" --arg l "$meta_line_num" \
            '.issues[] | select(.file == $f and .line == ($l | tonumber)) | .id' \
            "$ISSUES_JSON" 2>/dev/null | head -1)

        if [ -n "$issue_id" ]; then
            processed_issues["$issue_id"]=1
        fi

        # Check if this is a decision or status META
        if echo "$meta_line" | grep -q 'status=Fixed'; then
            fix_desc=$(echo "$meta_line" | sed 's/.*description=\([^>]*\) *-->.*/\1/' | sed 's/ *$//')
            fixed_count=$((fixed_count + 1))
            append_item fixed_items "- $location - $fix_desc"
        elif echo "$meta_line" | grep -q 'status=FAILED'; then
            fix_desc=$(echo "$meta_line" | sed 's/.*description=\([^>]*\) *-->.*/\1/' | sed 's/ *$//')
            failed_count=$((failed_count + 1))
            append_item failed_items "- $location - $fix_desc"
        elif echo "$meta_line" | grep -q 'decision=INVALID'; then
            description=$(jq -r --arg f "$meta_file" --arg l "$meta_line_num" \
                '.issues[] | select(.file == $f and .line == ($l | tonumber)) | .description // "Invalid"' \
                "$ISSUES_JSON" 2>/dev/null | head -1)
            invalid_count=$((invalid_count + 1))
            append_item invalid_items "- $location - $description"
        elif echo "$meta_line" | grep -q 'decision=INTENTIONAL'; then
            description=$(jq -r --arg f "$meta_file" --arg l "$meta_line_num" \
                '.issues[] | select(.file == $f and .line == ($l | tonumber)) | .description // "Intentional"' \
                "$ISSUES_JSON" 2>/dev/null | head -1)
            intentional_count=$((intentional_count + 1))
            append_item intentional_items "- $location - $description"
        fi
    done < <(grep -o '<!-- META: [^>]* -->' "$cluster_file" 2>/dev/null || true)
done

# Process individual issue files (skip if already processed via cluster)
for issue_file in "$RESULTS_DIR"/issue-*.md; do
    [ -f "$issue_file" ] || continue

    # Extract issue ID from filename
    issue_id=$(basename "$issue_file" | sed 's/issue-\([0-9]*\)\.md/\1/')

    # Skip if already processed via cluster
    if [ -n "${processed_issues[$issue_id]:-}" ]; then
        continue
    fi

    # Get issue details from issues.json
    issue_data=$(jq -r --arg id "$issue_id" '.issues[] | select(.id == ($id | tonumber))' "$ISSUES_JSON" 2>/dev/null)
    if [ -z "$issue_data" ]; then
        continue
    fi

    file=$(echo "$issue_data" | jq -r '.file // "unknown"')
    line=$(echo "$issue_data" | jq -r '.line // 0')
    description=$(echo "$issue_data" | jq -r '.description // "No description"')
    location="$file:$line"

    # Check for validation META line
    validation_meta=$(grep -o '<!-- META: decision=[^ ]* file=[^ ]* line=[^ ]* -->' "$issue_file" 2>/dev/null | head -1 || true)

    # Check for fix META line
    fix_meta=$(grep -o '<!-- META: status=[^ ]* file=[^ ]* line=[^ ]* description=[^>]* -->' "$issue_file" 2>/dev/null | head -1 || true)

    # Determine status
    if [ -n "$fix_meta" ]; then
        # Has fix result
        # shellcheck disable=SC2001 # sed with capture groups is cleaner for regex extraction
        fix_status=$(echo "$fix_meta" | sed 's/.*status=\([^ ]*\).*/\1/')
        fix_desc=$(echo "$fix_meta" | sed 's/.*description=\([^>]*\) *-->.*/\1/' | sed 's/ *$//')

        if [ "$fix_status" = "Fixed" ]; then
            fixed_count=$((fixed_count + 1))
            append_item fixed_items "- $location - $fix_desc"
        else
            failed_count=$((failed_count + 1))
            append_item failed_items "- $location - $fix_desc"
        fi
    elif [ -n "$validation_meta" ]; then
        # Has validation but no fix
        # shellcheck disable=SC2001 # sed with capture groups is cleaner for regex extraction
        decision=$(echo "$validation_meta" | sed 's/.*decision=\([^ ]*\).*/\1/')

        case "$decision" in
            VALID-FIX)
                # Validated but not fixed yet
                pending_count=$((pending_count + 1))
                append_item pending_items "- $location - $description"
                ;;
            INVALID)
                invalid_count=$((invalid_count + 1))
                append_item invalid_items "- $location - $description"
                ;;
            INTENTIONAL)
                intentional_count=$((intentional_count + 1))
                append_item intentional_items "- $location - $description"
                ;;
        esac
    else
        # Check for legacy Decision: line (fallback)
        if grep -q "Decision: VALID-FIX" "$issue_file" 2>/dev/null; then
            if grep -q "## Fix Applied" "$issue_file" 2>/dev/null; then
                fixed_count=$((fixed_count + 1))
                append_item fixed_items "- $location - $description"
            else
                pending_count=$((pending_count + 1))
                append_item pending_items "- $location - $description"
            fi
        elif grep -q "Decision: INVALID" "$issue_file" 2>/dev/null; then
            invalid_count=$((invalid_count + 1))
            append_item invalid_items "- $location - $description"
        elif grep -q "Decision: INTENTIONAL" "$issue_file" 2>/dev/null; then
            intentional_count=$((intentional_count + 1))
            append_item intentional_items "- $location - $description"
        else
            incomplete_count=$((incomplete_count + 1))
            append_item incomplete_items "- $location - Validation incomplete"
        fi
    fi
done

# Get lint/test status
lint_status="unknown"
test_status="unknown"
[ -f "$LINT_STATUS" ] && lint_status=$(cat "$LINT_STATUS")
[ -f "$TEST_STATUS" ] && test_status=$(cat "$TEST_STATUS")

# Write full report to summary.md
cat > "$SUMMARY_FILE" << EOF
# CodeRabbit - Full Report

**Generated:** $(date -Iseconds)

## Summary

| Category | Count |
|----------|-------|
| Fixed | $fixed_count |
| Invalid | $invalid_count |
| Intentional | $intentional_count |
| Failed | $failed_count |
| Pending | $pending_count |
| Incomplete | $incomplete_count |
| **Total** | **$total** |

**Clusters processed:** $cluster_count
**Lint:** $lint_status
**Tests:** $test_status

---

## Fixed Issues ($fixed_count)
$([ -n "$fixed_items" ] && printf '%b\n' "$fixed_items" || printf 'None\n')

---

## Invalid Issues ($invalid_count)

These issues were false positives from CodeRabbit.
$([ -n "$invalid_items" ] && printf '%b\n' "$invalid_items" || printf 'None\n')

---

## Intentional ($intentional_count)

These patterns are intentional, with code comments explaining why.
$([ -n "$intentional_items" ] && printf '%b\n' "$intentional_items" || printf 'None\n')

---

## Failed to Fix ($failed_count)
$([ -n "$failed_items" ] && printf '%b\n' "$failed_items" || printf 'None\n')

---

## Pending ($pending_count)

Validated as needing fix but not yet applied.
$([ -n "$pending_items" ] && printf '%b\n' "$pending_items" || printf 'None\n')

---

## Validation Incomplete ($incomplete_count)
$([ -n "$incomplete_items" ] && printf '%b\n' "$incomplete_items" || printf 'None\n')

---

## Individual Reports

Detailed reports for each issue are available in:
\`\`\`
$RESULTS_DIR/issue-*.md
$RESULTS_DIR/cluster-*.md
\`\`\`
EOF

# Print compact summary to stdout
echo "## CodeRabbit - Results"
echo ""
echo "Fixed: $fixed_count | Invalid: $invalid_count | Intentional: $intentional_count"
[ "$failed_count" -gt 0 ] && echo "Failed: $failed_count"
[ "$pending_count" -gt 0 ] && echo "Pending: $pending_count"
[ "$incomplete_count" -gt 0 ] && echo "Incomplete: $incomplete_count"
[ "$cluster_count" -gt 0 ] && echo "Clusters: $cluster_count"
echo ""

# Show top 5 fixed items
if [ "$fixed_count" -gt 0 ]; then
    if [ "$fixed_count" -gt 5 ]; then
        echo "### Fixed (showing 5 of $fixed_count)"
    else
        echo "### Fixed ($fixed_count)"
    fi
    printf '%b\n' "$fixed_items" | head -5
    echo ""
fi

# Show all invalid items (usually few)
if [ "$invalid_count" -gt 0 ]; then
    echo "### Invalid ($invalid_count)"
    printf '%b\n' "$invalid_items"
    echo ""
fi

# Show all intentional items (usually few)
if [ "$intentional_count" -gt 0 ]; then
    echo "### Intentional ($intentional_count)"
    printf '%b\n' "$intentional_items"
    echo ""
fi

# Show failed items
if [ "$failed_count" -gt 0 ]; then
    echo "### Failed ($failed_count)"
    printf '%b\n' "$failed_items"
    echo ""
fi

echo "Lint: $lint_status | Tests: $test_status"
echo "Full report: $SUMMARY_FILE"
