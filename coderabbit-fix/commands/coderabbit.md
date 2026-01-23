---
description: Run full CodeRabbit review, validate, and fix workflow automatically
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Task", "AskUserQuestion"]
---

# CodeRabbit - Optimized Full Workflow

This command runs the complete CodeRabbit workflow (review → group → handle)
with minimal context usage and optimized token consumption.

## Key Optimizations

1. **Issue Grouping**: Groups similar issues to reduce agent spawns
2. **Unified Handlers**: Single agent validates AND fixes (no redundant file reads)
3. **Cluster Handling**: Related issues handled together in one pass

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

---

## Phase 1: Review

### Step 1.1: Run Review Script

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh"
```

**Output interpretation:**

- `EXISTS:<path>` → Previous results found. Use AskUserQuestion:
  - "Delete and re-run" → Run with `--force`
  - "Skip to handling" → Continue to Phase 2/3
  - "Abort" → Stop workflow
- `ISSUES:<count>` → Fresh review complete, proceed with count
- `ERROR: <message>` → Runtime error occurred. Behavior:
  - **Stop immediately**: Do not proceed to Phase 2/3
  - **Logging**: Write full error (timestamp, message, stack/diagnostics) to stderr
    and append to `error.log` for post-mortem analysis
  - **Preserve partial results**: Serialize current state to `.partial` file alongside
    any `EXISTS:` results so users can resume or inspect
  - **User prompt**: Use AskUserQuestion to surface "Attempt recovery" option only
    for recoverable errors (e.g., timeout, transient network failure)
  - **--force flag**: Follows the same logging/preservation rules

### Step 1.2: Handle User Decision (if EXISTS)

If user chose "Delete and re-run":

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" --force
```

### Step 1.3: Branch Based on Issue Count

From output `ISSUES:{count}`:

- **count ≤ 5**: Skip to Phase 3, Small Batch Path
- **count > 5**: Continue to Phase 2 (Grouping)

---

## Phase 2: Grouping (>5 issues only)

### Step 2.1: Prepare Grouper Input

Extract minimal issue data (NO aiPrompt to save tokens):

```bash
jq '[.issues[] | {id, file, line, type, description}]' \
  .coderabbit-results/issues.json > .coderabbit-results/grouper-input.json
```

### Step 2.2: Spawn Issue Grouper

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-grouper
  model: haiku
  prompt: "GROUP_ISSUES: <contents of grouper-input.json> | OUTPUT: .coderabbit-results/groups.json"
```

Wait for grouper to complete (check for groups.json file).

### Step 2.3: Read Grouping Results

```bash
cat .coderabbit-results/groups.json
```

Extract:

- `groups` array (clusters of related issues)
- `singletons` array (individual issues)
- `stats` for logging

Print: "Grouped into {group_count} clusters + {singleton_count} singletons"

---

## Phase 3: Handle Issues (Unified Validate + Fix)

### Small Batch Path (≤5 issues)

**Use this path when skipping Phase 2 due to small issue count.**

1. Build a single batch prompt with ALL issues from `issues.json`
2. Spawn one `issue-handler-batch` agent
3. Skip directly to Step 3.4 (Wait for Handlers)

**Build the batch prompt:**

```bash
# Extract all issues into batch format (separator must be " ;; " with spaces)
jq -r '.issues[] | "#\(.id) \(.file):\(.line) | \(.description) | AIPrompt: \(.aiPrompt // "none")"' .coderabbit-results/issues.json | sed ':a;N;$!ba;s/\n/ ;; /g'
```

**Spawn single batch handler:**

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-handler-batch
  model: opus
  prompt: "BATCH: <constructed batch prompt> | OUTPUTS: .coderabbit-results/"
```

After spawning, skip to Step 3.4 to wait for completion.

---

### Normal Flow (>5 issues)

The following steps apply when Phase 2 (Grouping) was executed.

### Step 3.1: Determine Processing Mode

From `groups.json`:

- Process clusters using `issue-handler-cluster`
- Process singletons in batches using `issue-handler-batch` (max 5 per batch)

### Step 3.2: Spawn Cluster Handlers (if any)

For each group in `groups.json`, spawn a cluster handler.

**Build cluster prompt format:**

```text
CLUSTER: {group_id} | PATTERN: {pattern} | ISSUES: #{id1} {file1}:{line1} | AIPrompt: {aiPrompt1} ;; #{id2} {file2}:{line2} | AIPrompt: {aiPrompt2} ;; ... | OUTPUT: .coderabbit-results/cluster-{group_id}.md
```

Get aiPrompt for each issue from issues.json:

```bash
jq -r --arg id "$issue_id" '.issues[] | select(.id == ($id | tonumber)) | .aiPrompt // empty' .coderabbit-results/issues.json
```

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-handler-cluster
  model: opus
  prompt: "<constructed cluster prompt>"
```

**Spawn ALL cluster handlers in ONE message.**

### Step 3.3: Spawn Singleton Batch Handlers

Batch singletons into groups of max 5 to reduce agent overhead.

**Batching logic:**

1. Collect all singleton issue IDs from `singletons` array in `groups.json`
2. Chunk into batches of max 5 issues each
3. For each batch, spawn one `issue-handler-batch` agent

**Example:** 13 singletons → 3 batch handlers (5 + 5 + 3)

**Build batch prompt format:**

```text
BATCH: #{id1} {file1}:{line1} | {desc1} | AIPrompt: {ai1} ;; #{id2} {file2}:{line2} | {desc2} | AIPrompt: {ai2} ;; ... | OUTPUTS: .coderabbit-results/
```

Get aiPrompt for each issue from issues.json:

```bash
jq -r --arg id "$issue_id" '.issues[] | select(.id == ($id | tonumber)) | .aiPrompt // empty' .coderabbit-results/issues.json
```

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-handler-batch
  model: opus
  prompt: "<constructed batch prompt with up to 5 issues>"
```

**Spawn ALL handlers (clusters + singleton batches) in ONE message.**

**CRITICAL:**

- ALL handlers (clusters + singleton batches) in ONE message - they run in parallel
- Do NOT use `run_in_background: true` - this causes late notification spam
- Do NOT use TaskOutput
- Batch handlers write individual `issue-{id}.md` files for each issue

### Step 3.4: Wait for Handlers to Complete

Run a **single blocking Bash** that polls until all handlers finish:

```bash
# Count expected outputs (singletons = individual issues, not batches)
#
# For Small Batch Path (≤5 issues):
#   cluster_count=0
#   singleton_count=$(jq '.issues | length' .coderabbit-results/issues.json)
#
# For Normal Flow (>5 issues):
#   cluster_count={number_of_clusters from groups.json}
#   singleton_count={number_of_singletons from groups.json}
#
cluster_count={number_of_clusters}
singleton_count={number_of_singletons}

timeout 600 bash -c '
  while true; do
    # Count cluster reports
    cluster_done=$(ls .coderabbit-results/cluster-*.md 2>/dev/null | wc -l)
    # Count singleton reports (batch handlers write individual issue-{id}.md files)
    singleton_done=$(grep -l "<!-- META: decision=" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)

    total_done=$((cluster_done + singleton_done))
    expected=$((cluster_count + singleton_count))

    if [ "$total_done" -ge "$expected" ]; then
      echo "Handlers: $total_done/$expected complete"
      exit 0
    fi
    sleep 30
  done
'
if [ $? -eq 124 ]; then
  echo "Timeout waiting for handlers after 600 seconds"
  exit 1
fi
```

---

## Phase 4: Finalize

### Step 4.1: Run Linters and Tests

Auto-detect and run the project's linting and testing setup.

**CRITICAL: Warnings are NOT acceptable.** All linters must pass without warnings.
Treat warnings as errors and fix them. The only exception is warnings that are
explicitly documented as intentional (e.g., via inline comments like
`// eslint-disable-next-line` with an explanation, or project-level exclusions
in config files with documented rationale).

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
# After lint completes (passed/failed)
# Remember: warnings count as failures unless explicitly documented as intentional
echo "passed" > .coderabbit-results/lint-status.txt

# After tests complete (passed/failed)
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

1. Reads META lines from all issue files AND cluster files
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

## Summary of Optimizations

| Before                     | After                               |
| -------------------------- | ----------------------------------- |
| 85 validator + 41 fixer    | ~50 unified handlers (with grouping)|
| Separate validate → fix    | Single pass validate+fix            |
| Fixer re-reads all files   | Handler already has context         |
| ~2.63M Opus tokens         | ~1.4-1.6M Opus tokens (40-45% less) |
| ~15-20 min wall clock      | ~10-14 min (25-30% faster)          |
