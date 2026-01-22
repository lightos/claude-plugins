---
description: Fix validated CodeRabbit issues
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Task"]
---

# CodeRabbit Fix - Fix Validated Issues with Haiku Agents

This command fixes issues that were validated as VALID-FIX. Each fixer agent
writes its results to a file - results are NOT collected into context.

## Step 1: Check Prerequisites

Check that `validated-summary.json` exists:

```bash
cat .coderabbit-results/validated-summary.json 2>/dev/null || echo "NOT_FOUND"
```

If NOT_FOUND: Stop and tell user to run `/coderabbit-validate` first.

## Step 2: Read Validated Issues

Read and parse `.coderabbit-results/validated-summary.json` to get the list of
VALID-FIX issues.

If `total_valid` is 0: Tell the user "No issues to fix - all issues were either
invalid or intentional." and stop.

## Step 3: Spawn Fixer Agents (All in Parallel)

For each VALID-FIX entry, spawn a fixer agent. **Spawn ALL fixers in a SINGLE
message** for parallel execution. Use ultra-minimal prompts - the agent has
full instructions built-in.

Get similar issues from the validator report (replace `{id}` with the actual issue ID from the JSON):

```bash
grep -A 20 "Similar Issues Found" .coderabbit-results/issue-${id}.md | grep "^-" | head -10
```

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-fixer
  model: haiku
  prompt: "#{id} {file}:{line} | AIPrompt: {aiPrompt} | Similar: {similar_list} | Append: .coderabbit-results/issue-${id}.md"
```

Example:

```text
#3 src/utils.ts:42 | AIPrompt: Add explicit type annotation | Similar: src/helpers.ts:10, src/api.ts:20 | Append: .coderabbit-results/issue-3.md
```

**CRITICAL:**

- ALL fixers in ONE message (single turn) - they run in parallel automatically
- Do NOT use `run_in_background: true` - this causes late notification spam
- Do NOT use TaskOutput
- Prompt is ONE LINE - agent has full instructions
- Use `aiPrompt` (not description) - it contains CodeRabbit's exact fix instructions

## Step 4: Wait for Fixers to Complete

Use a single blocking bash command with timeout 600 seconds (600000ms):

```bash
total={valid_count}
timeout 600 bash -c '
  while true; do
    complete=$(grep -l "## Fix Applied" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)
    if [ "$complete" -ge "$total" ]; then
      echo "All $total fixers complete"
      exit 0
    fi
    sleep 15
  done
'
if [ $? -eq 124 ]; then
  echo "Timeout waiting for fixers after 600 seconds"
  exit 1
fi
```

Replace `{valid_count}` with the actual count of VALID-FIX issues being fixed.

## Step 5: Run Linters and Tests

Auto-detect and run the project's linting and testing setup:

1. Check for common config files:
   - `package.json` - look for `lint`, `test`, `check` scripts
   - `Makefile` - look for `lint`, `test` targets
   - `pyproject.toml` / `setup.py` - look for pytest, ruff, black
   - `Cargo.toml` - cargo clippy, cargo test
   - `go.mod` - go vet, go test

2. Run detected linters

3. **Linter Fix Strategy** (configurable):
   - **Max retry count:** Default 3 attempts. Re-run linters up to this limit.
   - **Scope option:** Fix only CodeRabbit-introduced errors (recommended) OR all errors
   - **Pre-existing errors:** Make fixing optional (default: fix only CodeRabbit changes)
   - **Timeout:** 5 minutes total for lint-fix loop to prevent infinite loops

4. If linter errors persist after max retries:
   - Document which errors could not be auto-fixed
   - Continue to test phase

5. Run tests and fix any failures

6. Document unfixable issues in the summary

## Step 6: Create Fix Summary

Read all report files and aggregate fix results into
`.coderabbit-results/fix-summary.json`:

```json
{
  "fixes_applied": [
    {
      "id": 1,
      "file": "src/utils.ts",
      "line": 42,
      "description": "Added type annotation",
      "similar_fixed": 2
    },
    {
      "id": 4,
      "file": "src/api.ts",
      "line": 100,
      "description": "Added error handling",
      "similar_fixed": 0
    }
  ],
  "total_fixes": 2,
  "lint_passed": true,
  "test_passed": true,
  "timestamp": "2024-01-15T10:40:00Z"
}
```

## Step 7: Print Final Summary

```markdown
## CodeRabbit Fix Results

| #   | File            | Issue                  | Action             |
| --- | --------------- | ---------------------- | ------------------ |
| 1   | src/utils.ts:42 | Missing type           | Fixed (+2 similar) |
| 4   | src/api.ts:100  | Missing error handling | Fixed              |

### Summary

- **Issues fixed:** {total_fixes} (including similar issues)
- **Lint:** {passed/warnings/failed}
- **Tests:** {passed/warnings/failed}

### Files Modified

{list of unique files that were modified}

### Notes

- Detailed reports available in `.coderabbit-results/issue-*.md`
- Fix summary in `.coderabbit-results/fix-summary.json`
```
