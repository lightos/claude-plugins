---
name: linter
description: Use this skill when the user asks to "run linter", "lint the codebase", "check code style", "fix lint errors", "fix linting issues", "run eslint", "run prettier", "run code formatters", "format code", "check for warnings", or wants to run code quality tools across the project. This skill detects available linters automatically and runs them with auto-fix enabled.
---

# Linting the Codebase

Run all detected linters on the codebase with auto-fix enabled.

## Quick Start

Invoke the `/linter` command to run all linters:

```bash
/linter
```

## What This Does

1. **Detects linters** - Scans for configuration files (`.eslintrc`, `.prettierrc`, `pyproject.toml`, etc.) and checks for installed linter CLIs
2. **Runs with auto-fix** - Executes each linter with `--fix` flags where supported
3. **Handles unfixable errors** - For linters without auto-fix (shellcheck, pylint) or remaining errors, attempts interactive manual fixes
4. **Reports summary** - Shows what was fixed and any remaining issues

## Supported Linters

| Linter | Auto-fix | File Types |
|--------|----------|------------|
| ESLint | Yes | js, jsx, ts, tsx |
| Prettier | Yes | js, ts, json, css, md |
| Biome | Yes | js, jsx, ts, tsx, json |
| markdownlint | Yes | md |
| ShellCheck | No | sh, bash |
| Ruff | Yes | py |
| Pylint | No | py |
| Black | Yes | py |
| mypy | No | py |
| TypeScript (tsc) | No | ts, tsx |

## Command Options

```bash
/linter [--path <dir>] [--only <linters>] [--skip <linters>] [--no-fix]
```

- `--path <dir>` - Lint specific directory only
- `--only eslint,prettier` - Run only these linters
- `--skip pylint,mypy` - Skip these linters
- `--no-fix` - Report issues without fixing

## Conflict Handling

When conflicting formatters are detected (e.g., both Prettier and Biome), the plugin automatically applies the preferred tool without prompting:

- Biome over ESLint+Prettier (if Biome is configured)
- Ruff over Black (if Ruff is configured)

If you want to override the default preference, use the `--only` or `--skip` flags to explicitly select which linters to run.

## After Running

Files are modified but NOT committed. Review changes with:

```bash
git diff
git status
```
