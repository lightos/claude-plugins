---
description: Run CodeRabbit review and intelligently fix reported issues
allowed-tools: ["Bash", "Read", "Grep", "Glob", "Task", "TodoWrite"]
---

# CodeRabbit Fix Flow

Run CodeRabbit review on code changes and intelligently fix reported issues using a multi-agent validation and fixing pipeline.

## Execution Flow

### Step 1: Run CodeRabbit Review

Execute the CodeRabbit CLI in the background:

```
coderabbit review --plain
```

Capture the full output. If the command fails, report the error and stop.

### Step 2: Parse Issues

Parse the CodeRabbit output to extract individual issues. Each issue should include:
- File path and line number (if provided)
- Issue category (type safety, performance, security, style, etc.)
- Issue description
- Suggested fix (if provided)

Create a todo list with all identified issues.

### Step 3: Process Issues in Parallel

For each issue, spawn an `issue-validator` agent using the Task tool with:
- `subagent_type`: `coderabbit-fix:issue-validator`
- `model`: `opus` (uses extended thinking/ultrathink)

The validator agent will:
1. Analyze if the issue is valid and necessary to fix
2. Apply coding principles: YAGNI, SOLID, DRY, SRP, KISS
3. Search for similar issues in the codebase (spawns `similar-issues-finder`)
4. If valid, spawn `issue-fixer` to implement the fix

**Spawn all validator agents in parallel** for maximum efficiency.

### Step 4: Auto-Detect and Run Linters/Tests

After all fixes are complete, auto-detect the project's linting and testing setup:

1. Check for common config files:
   - `package.json` → look for `lint`, `test`, `check` scripts
   - `Makefile` → look for `lint`, `test` targets
   - `pyproject.toml` / `setup.py` → look for pytest, ruff, black
   - `Cargo.toml` → cargo clippy, cargo test
   - `go.mod` → go vet, go test

2. Run detected linters and tests in the background using Bash with `run_in_background: true`

3. Report any failures from linting or tests that may need attention

### Step 5: Summary

Provide a summary including:
- Total issues found by CodeRabbit
- Issues validated as necessary to fix
- Issues skipped (with reasons)
- Similar issues found and fixed
- Linter/test results

## Important Guidelines

- **Be skeptical of AI suggestions**: CodeRabbit is an AI tool and may flag issues that aren't actually problems. The validator agent must critically evaluate each issue.
- **Follow existing patterns**: Fixes should match the codebase's existing style and patterns.
- **Minimize changes**: Apply YAGNI and KISS - don't over-engineer fixes.
- **Batch similar issues**: When similar issues are found, fix them together for consistency.
- **Verify with documentation**: When unsure about best practices, check official documentation (try context7 MCP if available, otherwise use web search).
