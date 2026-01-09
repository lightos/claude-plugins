---
description: Run CodeRabbit review and intelligently fix reported issues
allowed-tools: ["Bash", "Read", "Grep", "Glob", "Task", "TodoWrite"]
---

# CodeRabbit Fix Flow

Run CodeRabbit review on code changes and intelligently fix reported issues using a multi-agent validation and fixing pipeline.

## Execution Flow

### Step 1: Run CodeRabbit Review

Execute the CodeRabbit CLI in the background:

```bash
coderabbit review --plain
```

Capture the full output. If the command fails, report the error and stop.

### Step 2: Parse Issues and Setup Results Directory

Parse the CodeRabbit output to extract individual issues. Each issue should include:

- File path and line number (if provided)
- Issue category (type safety, performance, security, style, etc.)
- Issue description
- Suggested fix (if provided)

Create a todo list with all identified issues.

**Setup results directory** to store detailed validation reports (keeps parent context lean):

1. Check if `.coderabbit-results/` exists from a previous run
2. If it exists, use AskUserQuestion to ask:
   - "Previous results found in .coderabbit-results/. Clear them?"
   - Options: "Yes, clear old results" / "No, abort so I can review them first"
3. If user approves (or directory doesn't exist):

```bash
rm -rf .coderabbit-results && mkdir -p .coderabbit-results
```

### Step 3: Process Issues in Parallel

For each issue (numbered starting at 1), spawn an `issue-validator` agent using the Task tool with:

- `subagent_type`: `coderabbit-fix:issue-validator`
- `model`: `opus` (uses extended thinking/ultrathink)
- `run_in_background`: `true` (reduces UI noise, output written to file)
- `prompt`: Include the issue details AND the results file path:

  ```text
  Validate this issue and write your full report to: .coderabbit-results/issue-{N}.md

  Issue #{N}: [issue description]
  File: [file path]
  Line: [line number]
  Suggestion: [CodeRabbit's suggestion]
  ```

The validator agent will:

1. Analyze if the issue is valid and necessary to fix
2. Apply coding principles: YAGNI, SOLID, DRY, SRP, KISS
3. Search for similar issues in the codebase (spawns `similar-issues-finder`)
4. If valid, spawn `issue-fixer` to implement the fix
5. Write full report to the results file
6. Return only a single-line status (to keep parent context lean)

**Spawn all validator agents in parallel** for maximum efficiency.

### Step 4: Wait for Completion and Aggregate Results

Since validators run in background, wait for them to complete:

1. Use `TaskOutput` tool with `block: true` to wait for each background agent
2. Collect the single-line status returned by each validator
3. Once all complete, use Glob to find all `issue-*.md` files in `.coderabbit-results/`
4. Read each file to get the full validation details if needed
5. Compile statistics: issues fixed, skipped, invalid, intentional

The results directory persists for user reference. Users can review individual issue reports there.

### Step 5: Auto-Detect and Run Linters/Tests

After all fixes are complete, auto-detect the project's linting and testing setup:

1. Check for common config files:
   - `package.json` → look for `lint`, `test`, `check` scripts
   - `Makefile` → look for `lint`, `test` targets
   - `pyproject.toml` / `setup.py` → look for pytest, ruff, black
   - `Cargo.toml` → cargo clippy, cargo test
   - `go.mod` → go vet, go test

2. Run detected linters and tests in the background using Bash with `run_in_background: true`

3. Report any failures from linting or tests that may need attention

### Step 6: Summary

Provide a summary including:

- Total issues found by CodeRabbit
- Issues validated as necessary to fix
- Issues skipped (with reasons)
- Similar issues found and fixed
- Linter/test results
- Location of detailed reports: `.coderabbit-results/`

## Important Guidelines

- **Be skeptical of AI suggestions**: CodeRabbit is an AI tool and may flag issues that aren't actually problems. The validator agent must critically evaluate each issue.
- **Follow existing patterns**: Fixes should match the codebase's existing style and patterns.
- **Minimize changes**: Apply YAGNI and KISS - don't over-engineer fixes.
- **Batch similar issues**: When similar issues are found, fix them together for consistency.
- **Verify with documentation**: When unsure about best practices, check official documentation (try context7 MCP if available, otherwise use web search).
