---
description: Run CodeRabbit review and parse issues for validation
allowed-tools: ["Bash", "Read", "Write", "Glob", "Task"]
---

# CodeRabbit Review - Parse Issues

This command runs CodeRabbit and parses the output into a structured JSON file.
No agents are needed - this is a simple CLI + parsing operation.

## Step 1: Check for Previous Results

Check if previous results exist:

```bash
ls .coderabbit-results/issues.json 2>/dev/null
```

### If results exist

Use AskUserQuestion:

- Question: "Previous CodeRabbit results found. What should I do?"
- Options:
  - "Delete and re-run" - Clear results and run fresh scan
  - "Abort" - Stop so you can review existing results first

**If user chooses "Abort"**: Stop execution. Tell them:
"Keeping existing results. Run `/coderabbit-validate` to validate them."

**If user chooses "Delete and re-run"**: Continue to Step 2.

### If no results exist

Continue to Step 2.

## Step 2: Setup Results Directory

```bash
rm -rf .coderabbit-results && mkdir -p .coderabbit-results
```

## Step 3: Run CodeRabbit Review

```bash
coderabbit review --plain 2>&1 | tee .coderabbit-results/raw-output.txt
exit_code=${PIPESTATUS[0]}
```

### Check for Errors

```bash
if [ $exit_code -ne 0 ]; then
  echo "CLI_ERROR: Exit code $exit_code"
fi

if grep -qE "^(Error|ERROR|Fatal|FATAL|error:|failed:)" .coderabbit-results/raw-output.txt; then
  echo "OUTPUT_ERROR"
  grep -E "^(Error|ERROR|Fatal|FATAL)" .coderabbit-results/raw-output.txt | head -5
fi
```

### If errors detected

Use AskUserQuestion:

- Question: "CodeRabbit review encountered errors. What should I do?"
- Options:
  - "Show full output" - Display raw-output.txt
  - "Retry" - Run again
  - "Abort" - Stop execution

### Common Errors

| Error                  | Cause             | Resolution                       |
| ---------------------- | ----------------- | -------------------------------- |
| `command not found`    | CLI not installed | `npm install -g @coderabbit/cli` |
| `Authentication failed`| Invalid API key   | `coderabbit auth`                |
| `Rate limit exceeded`  | Too many requests | Wait and retry                   |

## Step 4: Parse Issues into JSON

Run the parser script:

```bash
if [ -z "${CLAUDE_PLUGIN_ROOT}" ]; then
  echo "ERROR: CLAUDE_PLUGIN_ROOT environment variable not set" >&2
  exit 1
fi

bash "${CLAUDE_PLUGIN_ROOT}/scripts/parse-issues.sh"
```

This extracts issues from raw-output.txt and writes issues.json instantly.

## Step 5: Print Summary

Print:

```markdown
## CodeRabbit Review Complete

**Found {total} issues** in the codebase.

Issues written to `.coderabbit-results/issues.json`

### Next Steps

Run `/coderabbit-validate` to validate these issues and find similar patterns.

Or run `/coderabbit-auto` for fully automated validation and fixing.
```
