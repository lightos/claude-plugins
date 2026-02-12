---
name: linter
description: Run all available linters on the codebase with auto-fix
argument-hint: "[--path <dir>] [--only <linters>] [--skip <linters>] [--no-fix]"
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - Task
---

# Linter Command

Run all detected linters on the codebase, auto-fixing issues where possible and interactively fixing remaining issues.

## Execution Steps

### 1. Parse Arguments

Extract flags from ARGUMENTS:

- `--path <dir>`: Limit linting to specific directory (default: current directory)
- `--only <linters>`: Comma-separated list of linters to run (e.g., `--only eslint,prettier`)
- `--skip <linters>`: Comma-separated list of linters to skip (e.g., `--skip pylint`)
- `--no-fix`: Report issues only, don't auto-fix or interactively fix

### 2. Detect Available Linters

Run the detection script:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/detect-linters.sh" [--path <dir>] [--only <linters>] [--skip <linters>]
```

This outputs JSON Lines with each detected linter's capabilities.

**Review the output for:**

- Conflict warnings (e.g., both prettier and biome detected)
- Number of linters detected

If conflicts are detected, inform the user and ask which to use, or proceed with the resolution strategy from the conflict warning.

### 3. Run Linters

Execute linters using the runner script:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/detect-linters.sh" [flags] | "${CLAUDE_PLUGIN_ROOT}/scripts/run-linters.sh" --fix [--path <dir>]
```

If `--no-fix` was specified, omit `--fix` from run-linters.sh.

**Parse the JSON Lines output:**

- `type: start` - Linter beginning
- `type: success` - Linter passed with no issues
- `type: fixed` - All issues were auto-fixed
- `type: partial` - Some issues fixed, some remain
- `type: issues` - Issues found (check-only mode or linter doesn't support fix)
- `type: complete` - Final summary

### 4. Handle Unfixable Issues

If the summary shows `unfixable > 0` AND `--no-fix` was NOT specified:

1. Collect all unfixable issues from the output
2. Group issues by file
3. If total unfixable issues > 50, ask user for confirmation before proceeding
4. For each file with issues (up to 10 at a time):
   - Read the file
   - Analyze the lint errors
   - Attempt targeted fixes using the Edit tool
   - Re-run the specific linter on that file to verify
5. Continue until all issues are resolved or no progress is being made

**Interactive fixing guidelines:**

- Focus on one file at a time
- Make minimal, targeted edits
- Preserve code intent and functionality
- Never add disable comments, ignore directives, or config exclusions to suppress warnings. Always fix the actual code. If an error cannot be resolved, report it to the user.
- If an error cannot be fixed without changing behavior, ask the user
- Track which errors have been addressed to avoid loops

### 5. Generate Summary

After all linting is complete, provide a summary:

```markdown
## Linting Summary

**Linters run:** eslint, prettier, shellcheck
**Files checked:** 142

### Results
- Auto-fixed: 23 issues
- Manually fixed: 5 issues
- Remaining: 0 issues

### Changes Made
- src/utils/helper.ts: Fixed 3 ESLint errors (unused imports)
- scripts/deploy.sh: Fixed 2 ShellCheck warnings (SC2086)
...

Files have been modified but NOT committed. Review changes with `git diff`.
```

## Error Handling

- **No linters detected**: Suggest installing common linters based on detected file types
- **Linter not installed**: Skip and warn (don't fail entire run)
- **Linter crashes**: Capture error, continue with other linters
- **No files to lint**: Skip linter, note in summary
- **Interactive fix fails**: Report the error and move to next issue

## Examples

Run all linters with auto-fix:

```bash
/linter
```

Run only ESLint and Prettier:

```bash
/linter --only eslint,prettier
```

Skip Python linters:

```bash
/linter --skip pylint,ruff,black
```

Check a specific directory:

```bash
/linter --path src/components
```

Report only (no fixes):

```bash
/linter --no-fix
```
