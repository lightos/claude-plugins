---
description: Run full CodeRabbit review, validate, and fix workflow automatically
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Task", "AskUserQuestion"]
---

# CodeRabbit Auto - Context-Optimized Full Workflow

This command runs the complete CodeRabbit workflow (review → validate → fix)
with minimal context usage.

## Prerequisites

### Environment Variables

#### CLAUDE_PLUGIN_ROOT

This environment variable must point to the root directory of the Claude plugin.
It is used by the scripts to locate helper utilities and parse issue data.

- **Auto-set:** `CLAUDE_PLUGIN_ROOT` is automatically set by Claude Code when
  running commands within a plugin context. You do not need to export it manually.
- **When unset:** If the variable is not set (e.g., running scripts outside
  Claude Code), the command will fail with an error indicating that scripts
  cannot be found. Ensure you are running this command through Claude Code or
  manually export `CLAUDE_PLUGIN_ROOT` to the absolute path of your plugin directory.

Example (if needed manually):

```bash
export CLAUDE_PLUGIN_ROOT=/path/to/your/plugin
```

---

## Context Optimization Strategy

**Why individual commands work but auto overflows:** Individual commands spawn
all agents in ONE turn. Auto mode spans multiple turns, accumulating context.

**Solution:**

1. **Ultra-minimal prompts** - Agent has full instructions built-in
2. **File-based aggregation** - Use grep/bash, don't read issue files
3. **Minimal output** - No verbose status messages

---

## Phase 1: Review

### Step 1.1: Check for Previous Results

```bash
ls .coderabbit-results/issues.json 2>/dev/null
```

If file exists, use AskUserQuestion:

- Question: "Previous CodeRabbit results found. What should I do?"
- Options:
  - "Delete and re-run" - Clear results and run fresh scan
  - "Skip to validation" - Use existing issues.json
  - "Abort" - Stop to review existing results

### Step 1.2: Setup Results Directory

```bash
rm -rf .coderabbit-results && mkdir -p .coderabbit-results
```

### Step 1.3: Run CodeRabbit Review (Background)

Run the review in a **single background Bash** using `run_in_background: true`:

```bash
# Use Bash with run_in_background: true
coderabbit review --plain > .coderabbit-results/raw-output.txt 2>&1
```

### Step 1.4: Wait for Review Completion

Run a **single blocking Bash** that polls internally until complete:

```bash
timeout 600 bash -c '
  while true; do
    if grep -q "Review completed" .coderabbit-results/raw-output.txt 2>/dev/null; then
      echo "Review: COMPLETE"
      exit 0
    fi
    # Check for CLI errors (at line start, not in review content)
    if grep -qE "^(Error|ERROR|Fatal|FATAL):" .coderabbit-results/raw-output.txt 2>/dev/null; then
      echo "Review: FAILED"
      grep -E "^(Error|ERROR|Fatal|FATAL):" .coderabbit-results/raw-output.txt | head -5
      exit 1
    fi
    sleep 30
  done
'
if [ $? -eq 124 ]; then
  echo "Timeout waiting for review after 600 seconds"
  exit 1
fi
```

Use timeout of 600 seconds (600000ms / 10 min). If FAILED, report error and stop.

### Step 1.5: Parse Issues into JSON

Run the parser script:

```bash
if [ -z "${CLAUDE_PLUGIN_ROOT}" ]; then
  echo "ERROR: CLAUDE_PLUGIN_ROOT environment variable not set" >&2
  exit 1
fi

bash "${CLAUDE_PLUGIN_ROOT}/scripts/parse-issues.sh"
```

This extracts issues from raw-output.txt and writes issues.json instantly.

Print: "Found {total} issues. Spawning validators..."

---

## Phase 2: Validate

### Step 2.1: Spawn ALL Validators in ONE Message

Read `issues.json` and spawn ALL validators in a SINGLE message.
The agent has full instructions built-in.

**JSON Structure Reference:**

```json
{
  "issues": [
    { "id": 1, "file": "src/foo.ts", "line": 42, "description": "...", "aiPrompt": "..." },
    { "id": 2, "file": "src/bar.ts", "line": 18, "description": "...", "aiPrompt": "..." }
  ],
  "total": 50
}
```

**For each issue - Extract these fields:**

- `id` → from `.id`
- Location → `{.file}:{.line}`
- Description → from `.description`
- AI Prompt → from `.aiPrompt`

Build this prompt format (replace `{id}`, `{file}`, `{line}`, etc. with actual values from the JSON):

```text
#{id} {file}:{line} | {description} | AIPrompt: {aiPrompt} | Output: .coderabbit-results/issue-${id}.md
```

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-validator
  model: opus
  prompt: "<constructed prompt string>"
```

**CRITICAL:**

- ALL validators in ONE message (single turn) - they run in parallel automatically
- Do NOT use `run_in_background: true` - this causes late notification spam
- Do NOT use TaskOutput
- Prompt is ONE LINE - agent has full instructions
- Include `aiPrompt` field - it contains CodeRabbit's exact fix instructions

### Step 2.2: Wait for Validators to Complete

Run a **single blocking Bash** that polls internally until all validators finish:

```bash
total={total_validators}
timeout 600 bash -c '
  while true; do
    count=$(grep -l "<!-- META: decision=" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)
    if [ "$count" -ge "$total" ]; then
      echo "Validators: $count/$total complete"
      exit 0
    fi
    sleep 30
  done
'
if [ $? -eq 124 ]; then
  echo "Timeout waiting for validators after 600 seconds"
  exit 1
fi
```

Use timeout of 600 seconds (600000ms / 10 min).

### Step 2.3: Aggregate Validation Results (File-Based)

**Do NOT read issue files into context.** Use bash/grep:

```bash
# Count decisions from issue files
valid=$(grep -l "Decision: VALID-FIX" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)
invalid=$(grep -l "Decision: INVALID" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)
intentional=$(grep -l "Decision: INTENTIONAL" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)

# Get list of valid issue IDs
valid_issues=$(grep -l "Decision: VALID-FIX" .coderabbit-results/issue-*.md 2>/dev/null | \
  sed 's/.*issue-\([0-9]*\)\.md/\1/' | tr '\n' ' ')

echo "VALID-FIX: $valid"
echo "INVALID: $invalid"
echo "INTENTIONAL: $intentional"
echo "Valid issues: $valid_issues"
```

Write `validated-summary.json` using the counts and IDs extracted above.

**CRITICAL:** For each valid issue, include the `aiPrompt` field by extracting it from `issues.json`:

```bash
# Get aiPrompt for issue ID from issues.json
aiPrompt=$(jq -r --arg id "$issue_id" '.issues[] | select(.id == ($id | tonumber)) | .aiPrompt // empty' .coderabbit-results/issues.json)
if [ $? -ne 0 ]; then
  echo "Error: Failed to parse aiPrompt for issue $issue_id from issues.json" >&2
  exit 1
fi
```

The validated-summary.json schema for valid_fix entries must include aiPrompt:

```json
{
  "valid_fix": [
    {
      "id": 1,
      "file": "src/utils.ts",
      "line": 42,
      "description": "Missing type annotation",
      "aiPrompt": "Add explicit type annotation to parameter",
      "similar_issues": [],
      "reasoning": "Issue affects type safety"
    }
  ]
}
```

Print: "Validation complete. {valid} to fix, {invalid} invalid, {intentional} intentional."

---

## Phase 3: Fix (Single Turn)

### Step 3.1: Check for Valid Issues

If no VALID-FIX issues: Print "No issues to fix" and skip to Phase 4.

### Step 3.2: Spawn ALL Fixers in ONE Message

For each VALID-FIX issue, spawn a fixer agent.
Spawn ALL fixers in a SINGLE message.

**For each VALID issue:**

```bash
# Get similar issues from validator report (replace ${id} with the actual issue ID)
grep -A 20 "Similar Issues Found" .coderabbit-results/issue-${id}.md | \
  grep "^-" | head -10
```

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-fixer
  model: haiku
  prompt: "#{id} {file}:{line} | AIPrompt: {aiPrompt} | Similar: {similar_list} | Append: .coderabbit-results/issue-${id}.md"
```

**CRITICAL:**

- ALL fixers in ONE message (single turn) - they run in parallel automatically
- Do NOT use `run_in_background: true` - this causes late notification spam
- Do NOT use TaskOutput
- Prompt is ONE LINE - agent has full instructions
- Use `aiPrompt` (not description) - it contains CodeRabbit's exact fix instructions

### Step 3.3: Wait for Fixers to Complete

Run a **single blocking Bash** that polls internally until all fixers finish:

```bash
total={valid_count}
timeout 600 bash -c '
  while true; do
    count=$(grep -l "## Fix Applied" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)
    if [ "$count" -ge "$total" ]; then
      echo "Fixers: $count/$total complete"
      exit 0
    fi
    sleep 30
  done
'
if [ $? -eq 124 ]; then
  echo "Timeout waiting for fixers after 600 seconds"
  exit 1
fi
```

Use timeout of 600 seconds (600000ms / 10 min).

---

## Phase 4: Finalize

### Step 4.1: Run Linters and Tests

Auto-detect and run the project's linting and testing setup.

**Linter Fix Strategy** (configurable scope with best-effort retries):

Configure linting scope (default: only CodeRabbit-introduced errors):

```bash
LINT_SCOPE="${LINT_SCOPE:-coderabbit-changes}"
# Scopes: "coderabbit-changes" (default) or "all-errors"
```

**Best-Effort Loop with Retry Guardrails (max 3 attempts):**

```bash
max_retries=3
retry_count=0
lint_status="failed"
timeout_seconds=300

start_time=$(date +%s)

while [ $retry_count -lt $max_retries ]; do
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))

  # Check timeout (5 minutes max)
  if [ $elapsed -gt $timeout_seconds ]; then
    echo "Linting timeout exceeded ($timeout_seconds seconds)"
    break
  fi

  echo "Linting (attempt $((retry_count + 1))/$max_retries)..."

  # Run linters for configured scope
  if run_linters_for_scope "$LINT_SCOPE"; then
    lint_status="passed"
    break
  fi

  # Attempt auto-fix
  if ! auto_fix_linters_for_scope "$LINT_SCOPE"; then
    echo "Auto-fix failed, stopping retries"
    break
  fi

  ((retry_count++))
done
```

**User Opt-In for Pre-Existing Errors:**

After first lint pass, if pre-existing errors are detected outside modified files:

```bash
# Detect pre-existing errors (errors outside CodeRabbit-modified files)
if [ "$LINT_SCOPE" = "coderabbit-changes" ] && has_preexisting_linter_errors; then
  # Use AskUserQuestion tool
  user_choice = AskUserQuestion(
    "Pre-existing linter errors detected. What should I do?",
    [
      "Fix CodeRabbit changes only",
      "Fix all errors (including pre-existing)",
      "Skip linting"
    ]
  )

  case "$user_choice" in
    "Fix CodeRabbit changes only")
      # Keep LINT_SCOPE=coderabbit-changes and continue
      ;;
    "Fix all errors (including pre-existing)")
      # Set LINT_SCOPE=all-errors and retry linting
      LINT_SCOPE="all-errors"
      retry_count=0  # Reset retries for new scope
      ;;
    "Skip linting")
      # Skip to test phase
      lint_status="skipped"
      break
      ;;
  esac
fi
```

Document retry count, timeout status, and final scope in the report.

**Test Phase (max 2 retries):**

```bash
max_test_retries=2
test_retry_count=0
test_status="failed"

while [ $test_retry_count -lt $max_test_retries ]; do
  echo "Testing (attempt $((test_retry_count + 1))/$max_test_retries)..."

  if run_tests; then
    test_status="passed"
    break
  fi

  ((test_retry_count++))
done
```

Document any unfixable linter or test issues in the report, noting the final scope, retry counts, and timeout status.

**Save status to files for report generation:**

```bash
# After lint completes (passed/warnings/failed)
echo "passed" > .coderabbit-results/lint-status.txt

# After tests complete (passed/warnings/failed)
echo "passed" > .coderabbit-results/test-status.txt
```

### Step 4.2: Generate Final Report

Run the report generation script to create detailed summary and print compact output:

```bash
if [ -z "${CLAUDE_PLUGIN_ROOT}" ]; then
  echo "ERROR: CLAUDE_PLUGIN_ROOT environment variable not set" >&2
  exit 1
fi

bash "${CLAUDE_PLUGIN_ROOT}/scripts/generate-report.sh"
```

This script:

1. Reads META lines from all issue files
2. Joins with `issues.json` for descriptions
3. Writes full report to `.coderabbit-results/summary.md`
4. Prints compact summary to stdout

The compact summary shows:

- Counts: Fixed | Invalid | Intentional
- Top 5 fixed items (with full list in summary.md)
- All invalid/intentional items (usually few)
- Any failures or incomplete validations
- Lint/test status
- Path to full report

---

## Summary of Context Optimizations

| Before                     | After                               |
| -------------------------- | ----------------------------------- |
| 25-line Task prompts       | 1-line prompts (agent has instrs)   |
| Read files to aggregate    | Use grep/bash for counts            |
| Verbose status messages    | Minimal output (4 print points)     |
| Manual /compact between    | No compaction needed                |
| Polling every 10s (16+ UI) | Single blocking bash (1 UI call)    |
| Grouping step (~37k tokens)| No grouping needed                  |
