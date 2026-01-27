#!/usr/bin/env bash
set -o pipefail
# Note: not using -u because test cases contain special bash characters

# Test harness for safeguard pattern matching
# Run without Claude to verify patterns work correctly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
BLOCK_SCRIPT="$PLUGIN_DIR/scripts/block-dangerous.sh"
TEST_CASES="$SCRIPT_DIR/test-cases.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Counters
PASS=0
FAIL=0

# Create temporary config dir for testing
TEST_CONFIG_DIR=$(mktemp -d)
export CLAUDE_PROJECT_DIR="$TEST_CONFIG_DIR"

# Config will be set per-test to only enable the category being tested
mkdir -p "$TEST_CONFIG_DIR/.claude/.safeguard"

# Function to enable only a specific category
enable_only_category() {
    local category="$1"
    cat > "$TEST_CONFIG_DIR/.claude/.safeguard/config.json" << EOF
{
  "enabled": {
    "system-destruction": $([ "$category" = "system-destruction" ] && echo "true" || echo "false"),
    "system-control": $([ "$category" = "system-control" ] && echo "true" || echo "false"),
    "git-commits": $([ "$category" = "git-commits" ] && echo "true" || echo "false"),
    "git-pushes": $([ "$category" = "git-pushes" ] && echo "true" || echo "false"),
    "git-destructive": $([ "$category" = "git-destructive" ] && echo "true" || echo "false"),
    "remote-code-exec": $([ "$category" = "remote-code-exec" ] && echo "true" || echo "false"),
    "network-exfil": $([ "$category" = "network-exfil" ] && echo "true" || echo "false"),
    "containers": $([ "$category" = "containers" ] && echo "true" || echo "false")
  }
}
EOF
}

# For "none" category tests, disable everything
disable_all_categories() {
    cat > "$TEST_CONFIG_DIR/.claude/.safeguard/config.json" << 'EOF'
{
  "enabled": {
    "system-destruction": false,
    "system-control": false,
    "git-commits": false,
    "git-pushes": false,
    "git-destructive": false,
    "remote-code-exec": false,
    "network-exfil": false,
    "containers": false
  }
}
EOF
}

# shellcheck disable=SC2317 # Called via trap, not unreachable
cleanup() {
    rm -rf "$TEST_CONFIG_DIR"
}
trap cleanup EXIT

echo "=========================================="
echo "  Safeguard Pattern Matching Tests"
echo "=========================================="
echo ""

# Check dependencies
if ! command -v jq &>/dev/null; then
    echo -e "${RED}ERROR: jq is required. Install with: brew install jq (macOS) or apt install jq (Linux)${NC}"
    exit 1
fi

if [[ ! -f "$BLOCK_SCRIPT" ]]; then
    echo -e "${RED}ERROR: Block script not found at $BLOCK_SCRIPT${NC}"
    exit 1
fi

if [[ ! -f "$TEST_CASES" ]]; then
    echo -e "${RED}ERROR: Test cases file not found at $TEST_CASES${NC}"
    exit 1
fi

# Run tests
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue

    # Parse test case (TAB-delimited)
    IFS=$'\t' read -r cmd expected_category should_block <<< "$line"

    # Skip 'none' category tests - these test that safe commands pass with all categories disabled
    if [[ "$expected_category" == "none" ]]; then
        disable_all_categories

        # Create tool input JSON
        tool_input=$(jq -n --arg cmd "$cmd" '{"tool_input": {"command": $cmd}}')

        # Run the block script
        result=$(echo "$tool_input" | bash "$BLOCK_SCRIPT" 2>/dev/null)

        # Check if blocked
        if echo "$result" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' &>/dev/null; then
            echo -e "${RED}FAIL${NC}: '$cmd' was blocked but should be allowed (safe command)"
            ((FAIL++))
        else
            echo -e "${GREEN}PASS${NC}: '$cmd' correctly allowed"
            ((PASS++))
        fi
        continue
    fi

    # Enable only the category being tested
    enable_only_category "$expected_category"

    # Create tool input JSON
    tool_input=$(jq -n --arg cmd "$cmd" '{"tool_input": {"command": $cmd}}')

    # Run the block script
    result=$(echo "$tool_input" | bash "$BLOCK_SCRIPT" 2>/dev/null)

    # Check if blocked
    is_blocked=0
    if echo "$result" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' &>/dev/null; then
        is_blocked=1
    fi

    # Compare with expected
    if [[ "$is_blocked" -eq "$should_block" ]]; then
        if [[ "$should_block" -eq 1 ]]; then
            echo -e "${GREEN}PASS${NC}: '$cmd' correctly blocked ($expected_category)"
        else
            echo -e "${GREEN}PASS${NC}: '$cmd' correctly allowed"
        fi
        ((PASS++))
    else
        if [[ "$should_block" -eq 1 ]]; then
            echo -e "${RED}FAIL${NC}: '$cmd' should be blocked ($expected_category) but was allowed"
        else
            echo -e "${RED}FAIL${NC}: '$cmd' should be allowed but was blocked"
        fi
        ((FAIL++))
    fi

done < "$TEST_CASES"

echo ""
echo "=========================================="
echo "  Results"
echo "=========================================="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
