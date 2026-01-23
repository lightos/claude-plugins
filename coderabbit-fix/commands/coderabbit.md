---
description: Run full CodeRabbit review, validate, and fix workflow automatically
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Task", "AskUserQuestion"]
argument-hint: "[--auto]"
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

## Flags

- `--auto`: Non-interactive mode. Deletes previous results, fixes all lint errors (including pre-existing), no prompts.

---

## Phase 1: Review

### Step 1.0: Parse Arguments

Parse arguments to check for `--auto` flag:

- If ARGUMENTS contains `--auto`: set `AUTO_MODE=true`
- Otherwise: set `AUTO_MODE=false`

### Step 1.1: Run Review Script

```bash
# If AUTO_MODE=true, pass --force to auto-delete previous results
"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" [--force if AUTO_MODE=true]
```

**Output interpretation:**

- `EXISTS:<path>` → Previous results found.
  - **If `AUTO_MODE=true`**: Re-run with `--force` automatically (skip to Step 1.2)
  - **If `AUTO_MODE=false`**: Use AskUserQuestion:
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

**If `AUTO_MODE=true`**: Automatically re-run with `--force`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" --force
```

**If `AUTO_MODE=false`** and user chose "Delete and re-run":

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" --force
```

### Step 1.3: Branch Based on Issue Count

From output `ISSUES:{count}`:

- **count ≤ 5**: Skip to Phase 3, Small Batch Path
- **count > 5**: Continue to Phase 2 (Grouping)

---

## Phase 2: Grouping (>5 issues only)

### Step 2.1: Spawn Issue Grouper

Write grouper input to file (do NOT read it into context):

```bash
jq '[.issues[] | {id, file, line, type, description}]' .coderabbit-results/issues.json > .coderabbit-results/grouper-input.json
```

Spawn grouper with **file path** (not content):

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-grouper
  model: haiku
  prompt: "INPUT_FILE: .coderabbit-results/grouper-input.json | OUTPUT: .coderabbit-results/groups.json"
```

Wait for grouper to complete (check for groups.json file).

### Step 2.2: Read Grouping Results

Extract only stats (not full content) to minimize context:

```bash
jq '.stats' .coderabbit-results/groups.json
```

Use the stats to determine handler spawning:

- `group_count`: Number of cluster handlers to spawn
- `singleton_issues`: Number of singleton batch files to expect

Print: "Grouped into {group_count} clusters + {singleton_count} singletons"

**Note:** The full `groups` and `singletons` arrays are read by `build-handler-prompts.sh`, not by the main agent.

---

## Phase 3: Handle Issues (Unified Validate + Fix)

### Small Batch Path (≤5 issues)

**Use this path when skipping Phase 2 due to small issue count.**

> **Why inline mode here:** For ≤5 issues, the aiPrompt data adds ~10 lines per issue (~50 lines max), which has minimal context cost. Using prompt files for such small batches adds complexity without meaningful benefit.

1. Build a single batch prompt with ALL issues from `issues.json`
2. Spawn one `issue-handler-batch` agent
3. Skip directly to Step 3.4 (Wait for Handlers)

**Build the batch prompt:**

```bash
# Extract all issues into batch format (separator must be " ;; " with spaces)
jq -r '.issues[] | "#\(.id) \(.file):\(.line) | \(.description) | AIPrompt: \(.aiPrompt // "none")"' .coderabbit-results/issues.json | paste -sd ' ;; ' -
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

### Step 3.1: Build Handler Prompts

Run the prompt builder script to generate prompt files from `groups.json` and `issues.json`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/build-handler-prompts.sh"
```

**Output interpretation:**

- `PROMPTS_READY: N files` → Prompt files generated, proceed to spawn handlers
- `ERROR: jq is required...` → Install jq and retry

This creates files in `.coderabbit-results/prompts/`:

- `cluster-{group_id}.txt` - One file per cluster
- `batch-{n}.txt` - Singletons in batches of max 5

### Step 3.2: Spawn Cluster Handlers

List cluster prompt files:

```bash
ls .coderabbit-results/prompts/cluster-*.txt 2>/dev/null || echo "No cluster prompts"
```

For each `cluster-{id}.txt` file, spawn a handler with the **file path** (not content):

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-handler-cluster
  model: opus
  prompt: "PROMPT_FILE: .coderabbit-results/prompts/cluster-{id}.txt"
```

**Important:** Do NOT read the file content here. Handlers read their own prompt files to avoid loading aiPrompt data into the main context.

### Step 3.3: Spawn Singleton Batch Handlers

List batch prompt files:

```bash
ls .coderabbit-results/prompts/batch-*.txt 2>/dev/null || echo "No batch prompts"
```

For each `batch-{n}.txt` file, spawn a handler with the **file path** (not content):

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-handler-batch
  model: opus
  prompt: "PROMPT_FILE: .coderabbit-results/prompts/batch-{n}.txt"
```

**Important:** Do NOT read the file content here. Handlers read their own prompt files.

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

```text
# PSEUDO-CODE: This block describes agent behavior, not executable bash

# Detect pre-existing errors (errors outside CodeRabbit-modified files)
IF LINT_SCOPE = "coderabbit-changes" AND has_preexisting_linter_errors:
  IF AUTO_MODE = true:
    # Auto mode: aggressively fix all errors without prompting
    LINT_SCOPE := "all-errors"
    retry_count := 0  # Reset retries for new scope
  ELSE:
    # Interactive mode: ask user
    user_choice := AskUserQuestion(
      "Pre-existing linter errors detected. What should I do?",
      [
        "Fix CodeRabbit changes only",
        "Fix all errors (including pre-existing)",
        "Skip linting"
      ]
    )

    MATCH user_choice:
      "Fix CodeRabbit changes only":
        # Keep LINT_SCOPE=coderabbit-changes and continue
        PASS
      "Fix all errors (including pre-existing)":
        # Set LINT_SCOPE=all-errors and retry linting
        LINT_SCOPE := "all-errors"
        retry_count := 0  # Reset retries for new scope
      "Skip linting":
        # Skip to test phase
        lint_status := "skipped"
        BREAK
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
