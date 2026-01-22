---
description: Validate CodeRabbit issues and find similar patterns
allowed-tools: ["Bash", "Read", "Write", "Glob", "Grep", "Task"]
---

# CodeRabbit Validate - Validate Issues with Opus Agents

This command validates issues from `issues.json` using parallel opus agents.
Each issue gets its own validator. Each agent writes results to a file -
results are NOT collected into context.

## Step 1: Check Prerequisites

Check that `issues.json` exists:

```bash
cat .coderabbit-results/issues.json 2>/dev/null || echo "NOT_FOUND"
```

If NOT_FOUND: Stop and tell the user to run `/coderabbit-review` first.

## Step 1.5: Check for Previous Validation Results

```bash
ls .coderabbit-results/validated-summary.json 2>/dev/null
```

### If results exist

Use AskUserQuestion:

- Question: "Previous validation results found. What should I do?"
- Options:
  - "Re-validate all" - Clear and re-run
  - "Continue with existing" - Skip to aggregation
  - "Abort" - Stop to review

**If "Abort"**: "Keeping results. Run `/coderabbit-fix` to apply fixes."
**If "Continue"**: Skip to Step 5.
**If "Re-validate"**:

```bash
rm -f .coderabbit-results/issue-*.md .coderabbit-results/validated-summary.json
```

## Step 2: Read Issues

Read and parse `.coderabbit-results/issues.json` to get the `issues` array.

Note the total count of issues.

## Step 3: Spawn ALL Validators in ONE Message

For each issue, spawn a validator agent. Spawn ALL validators in a SINGLE message.

```yaml
Task tool:
  subagent_type: coderabbit-fix:issue-validator
  model: opus
  prompt: "#{id} {file}:{line} | {description} | AIPrompt: {aiPrompt} | Output: .coderabbit-results/issue-${id}.md"
```

Example (replace `${id}` with the actual issue ID from the JSON):

```text
#3 src/utils.ts:42 | Missing type annotation | AIPrompt: Add explicit type annotation to parameter | Output: .coderabbit-results/issue-3.md
```

**CRITICAL:**

- ALL validators in ONE message (single turn) - they run in parallel automatically
- Do NOT use `run_in_background: true` - this causes late notification spam
- Do NOT use TaskOutput
- Prompt is ONE LINE - agent has full instructions

## Step 4: Wait for Validators to Complete

Use a single blocking bash command with timeout 600000ms:

```bash
total={total_validators}
timeout 600 bash -c '
  while true; do
    complete=$(grep -l "<!-- META:" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)
    if [ "$complete" -ge "$total" ]; then
      echo "All $total validators complete"
      exit 0
    fi
    sleep 15
  done
'
if [ $? -eq 124 ]; then
  echo "Timeout waiting for validators after 600 seconds"
  exit 1
fi
```

Replace `{total_validators}` with the actual count of issues being validated.

The timeout exits with code 124 if validators don't complete within 600 seconds (600000ms).

## Step 5: Aggregate Results (File-Based)

**Do NOT read full issue files.** Use grep/bash to extract counts and IDs:

```bash
valid=$(grep -l "Decision: VALID-FIX" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)
invalid=$(grep -l "Decision: INVALID" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)
intentional=$(grep -l "Decision: INTENTIONAL" .coderabbit-results/issue-*.md 2>/dev/null | wc -l)

# Get valid IDs
valid_ids=$(grep -l "Decision: VALID-FIX" .coderabbit-results/issue-*.md 2>/dev/null | \
  sed 's/.*issue-\([0-9]*\)\.md/\1/')
```

For each valid ID, get data from `issues.json` (not report files):

```bash
jq -r --arg id "$id" '.issues[] | select(.id == ($id | tonumber))' .coderabbit-results/issues.json
```

Create `.coderabbit-results/validated-summary.json`:

```json
{
  "valid_fix": [
    {
      "id": 1,
      "file": "src/utils.ts",
      "line": 42,
      "type": "Type Safety",
      "description": "Missing type annotation",
      "aiPrompt": "Add explicit type annotation to parameter"
    }
  ],
  "invalid": [
    {
      "id": 2,
      "file": "src/api.ts",
      "line": 100,
      "type": "Error Handling",
      "description": "Missing error handling",
      "aiPrompt": "Add try-catch block"
    }
  ],
  "intentional": [
    {
      "id": 3,
      "file": "src/legacy.ts",
      "line": 50,
      "type": "Legacy Code",
      "description": "Intentional pattern for legacy support",
      "aiPrompt": "No fix needed - intentional design"
    }
  ],
  "total_valid": 1,
  "total_invalid": 1,
  "total_intentional": 1,
  "validators_spawned": 3,
  "timestamp": "2024-01-15T10:35:00Z"
}
```

## Step 6: Print Summary

```markdown
## Validation Complete

| Decision    | Count               |
| ----------- | ------------------- |
| VALID-FIX   | {total_valid}       |
| INVALID     | {total_invalid}     |
| INTENTIONAL | {total_intentional} |

**Validators spawned:** {validators_spawned}

Results written to `.coderabbit-results/validated-summary.json`

### Next Steps

Run `/coderabbit-fix` to apply fixes to the {total_valid} validated issues.

Or review individual reports in `.coderabbit-results/issue-*.md`
```
