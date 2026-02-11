---
description: Run full CodeRabbit review, validate, and fix workflow automatically
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Task", "AskUserQuestion"]
argument-hint: "[--auto] [--base <branch>]"
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
- `--base <branch>`: Specify base branch for comparison (e.g., `origin/main`, `HEAD~3`). Takes precedence over uncommitted changes. Auto-detected if not provided.

---

## Phase 1: Review

### Step 1.0: Parse Arguments

Parse arguments to check for `--auto` and `--base` flags:

- If ARGUMENTS contains `--auto`: set `AUTO_MODE=true`, otherwise `AUTO_MODE=false`
- If ARGUMENTS contains `--base <branch>`: set `BASE_BRANCH=<branch>`, otherwise `BASE_BRANCH=""`

### Step 1.1: Run Review Script

Build script arguments based on parsed flags:

```bash
REVIEW_SCRIPT_ARGS=()
if [[ "$AUTO_MODE" == "true" ]]; then
    REVIEW_SCRIPT_ARGS+=("--force")
fi
if [[ -n "$BASE_BRANCH" ]]; then
    REVIEW_SCRIPT_ARGS+=("--base" "$BASE_BRANCH")
fi

"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" "${REVIEW_SCRIPT_ARGS[@]}"
```

**Output interpretation:**

- `EXISTS:<path>` → Previous results found. **This only occurs in interactive mode** (auto mode already passes `--force` in Step 1.1, so the script never returns `EXISTS:`).
  - Use AskUserQuestion:
    - "Delete and re-run" → Run with `--force`
    - "Skip to handling" → Continue to Phase 2/3
    - "Abort" → Stop workflow
- `MODE:uncommitted` → Reviewing uncommitted changes (info)
- `MODE:base:<branch> (<N> commits)` → Reviewing commits ahead of branch (info)
- `ISSUES:<count>` → Fresh review complete, proceed with count
- `ERROR:NO_CHANGES: <message>` → No changes found. **Go to Step 1.1.5** (interactive handling)
- `ERROR:NO_BASE: <message>` → No base branch found. **Go to Step 1.1.5** (interactive handling)
- `ERROR: <message>` → Runtime error occurred. Behavior:
  - **Stop immediately**: Do not proceed to Phase 2/3
  - **Logging**: Write full error (timestamp, message, stack/diagnostics) to stderr
    and append to `error.log` for post-mortem analysis
  - **Preserve partial results**: Serialize current state to `.partial` file alongside
    any `EXISTS:` results so users can resume or inspect
  - **User prompt**: Use AskUserQuestion to surface "Attempt recovery" option only
    for recoverable errors (e.g., timeout, transient network failure)
  - **--force flag**: Follows the same logging/preservation rules

### Step 1.1.5: Handle "No Changes" Scenario (ERROR:NO_CHANGES or ERROR:NO_BASE)

This step handles cases where `run-review.sh` returns `ERROR:NO_CHANGES` or `ERROR:NO_BASE`.

**If `AUTO_MODE=true`**: Report error and exit workflow:

```text
Error: No changes found for review. In --auto mode, cannot prompt for base branch.
Hint: Specify --base <branch> explicitly, e.g., /coderabbit --auto --base origin/main
```

**If `AUTO_MODE=false`**: Trigger interactive prompt:

```yaml
AskUserQuestion:
  question: "No uncommitted changes found. What would you like to review?"
  header: "No Changes"
  options:
    - label: "Review commits since origin/main"
      description: "Compare current HEAD to origin/main"
    - label: "Review commits since origin/master"
      description: "Compare current HEAD to origin/master"
    - label: "Review last N commits"
      description: "Specify how many recent commits to review"
    - label: "Specify custom base"
      description: "Enter a branch name or commit to compare against"
```

**Handle each option:**

**Option: "Review commits since origin/main"**
Re-run: `"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" --base origin/main [--force if needed]`

**Option: "Review commits since origin/master"**
Re-run: `"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" --base origin/master [--force if needed]`

**Option: "Review last N commits"**

1. Use AskUserQuestion:

   ```yaml
   question: "How many recent commits to review?"
   header: "Commits"
   options:
     - label: "1"
       description: "Just the last commit"
     - label: "3"
       description: "Last 3 commits"
     - label: "5"
       description: "Last 5 commits"
     - label: "10"
       description: "Last 10 commits"
   ```

2. If user selects the built-in "Other" option (auto-provided by AskUserQuestion), validate input is a positive integer
3. Re-run: `"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" --base HEAD~N [--force if needed]`

**Option: "Specify custom base"**

1. Prompt user for branch/ref name (can use AskUserQuestion's built-in "Other" for free-form input, or simply ask directly)
2. Validate branch exists: `git rev-parse --verify <input>`
3. If invalid, show error and re-prompt
4. Re-run: `"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" --base <input> [--force if needed]`

**Cancellation:** If user selects the built-in "Other" option on the first prompt and enters "abort" or "cancel", stop workflow with message: "Review cancelled by user"

### Step 1.2: Handle User Decision (if EXISTS, interactive mode only)

**This step only applies in interactive mode.** In auto mode, `--force` is already passed in Step 1.1, so the script never returns `EXISTS:` and this step is skipped entirely.

If the user chose "Delete and re-run", re-run with `--force`:

```bash
REVIEW_SCRIPT_ARGS=("--force")
if [[ -n "$BASE_BRANCH" ]]; then
    REVIEW_SCRIPT_ARGS+=("--base" "$BASE_BRANCH")
fi
"${CLAUDE_PLUGIN_ROOT}/scripts/run-review.sh" "${REVIEW_SCRIPT_ARGS[@]}"
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

1. Write batch prompt to file (do NOT read output into context):

```bash
mkdir -p .coderabbit-results/prompts
# Build complete prompt with BATCH prefix and OUTPUTS suffix
{
  printf 'BATCH: '
  jq -rj '[.issues[] | "#\(.id) \(.file):\(.line) | \(.description) | AIPrompt: \(.aiPrompt // "none")"] | join(" ;; ")' .coderabbit-results/issues.json
  printf ' | OUTPUTS: .coderabbit-results/'
} > .coderabbit-results/prompts/batch-1.txt
```

1. Spawn batch handler with **file path only** (not content):

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-handler-batch
  model: opus
  prompt: "PROMPT_FILE: .coderabbit-results/prompts/batch-1.txt"
```

1. Skip to Step 3.4 (Wait for Handlers)

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
