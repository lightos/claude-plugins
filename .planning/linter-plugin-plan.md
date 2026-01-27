# Linter Plugin Plan

## Purpose

A Claude Code plugin that runs all available linters on the codebase and fixes warnings/errors.

## Requirements

- Triggers via `/linter` command or natural language ("run linter")
- Auto-detects linters from config files (eslintrc, prettierrc, etc.) + fallback list of common linters
- Runs linters on ALL files (not just changed)
- Auto-fixes where possible
- Interactive fix mode for unfixable errors (Claude attempts manual fixes)
- No auto-commit (leaves fixes for user review)

## Proposed Components

### 1. Skill (`skills/linter/SKILL.md`)

Natural language triggering with description for phrases like "run linter", "lint the codebase", "fix lint errors".

**Trigger phrases:**

- "run linter"
- "lint the codebase"
- "fix lint errors"
- "check code style"

### 2. Command (`commands/linter.md`)

Direct `/linter` invocation, accepts optional arguments.

**Arguments:**

- `--path <dir>` - Limit to specific directory (default: entire codebase)
- `--only <linter>` - Run only specific linter(s)
- `--skip <linter>` - Skip specific linter(s)
- `--no-fix` - Report only, don't auto-fix

### 3. Agent (`agents/lint-fixer.md`)

Triggered when unfixable lint errors remain - reads error context, attempts manual code fixes, works interactively.

**Capabilities:**

- Reads lint error output with file/line context
- Understands common lint rules and their intent
- Makes targeted code edits to fix violations
- Explains changes made

### 4. Script (`scripts/detect-linters.sh`)

Auto-detection of available linters.

**Detection logic:**

1. Scan for config files:
   - `.eslintrc*`, `eslint.config.*` → eslint
   - `.prettierrc*`, `prettier.config.*` → prettier
   - `pyproject.toml` (with ruff/pylint/black sections) → ruff, pylint, black
   - `.markdownlint*` → markdownlint
   - `.shellcheckrc` or `*.sh` files → shellcheck
   - `biome.json` → biome
   - `deno.json` → deno lint

2. Fallback: Check if CLI exists in PATH:
   - eslint, prettier, markdownlint, shellcheck, pylint, ruff, black, biome, deno

**Output format:**

```text
LINTER:eslint:config:/path/to/.eslintrc.json
LINTER:prettier:fallback:
LINTER:shellcheck:fallback:
```

## Workflow

1. User triggers via skill or command
2. `detect-linters.sh` identifies available linters
3. Each linter runs with --fix flags on all files
4. Collect remaining unfixable errors
5. If unfixable errors remain, spawn `lint-fixer` agent per error batch
6. Agent attempts manual code edits interactively
7. Summary report shown
8. Files left uncommitted for user review

## File Structure

```text
linter/
├── .claude-plugin/
│   └── plugin.json
├── commands/
│   └── linter.md
├── skills/
│   └── linter/
│       └── SKILL.md
├── agents/
│   └── lint-fixer.md
├── scripts/
│   └── detect-linters.sh
└── README.md
```

## Location

`/home/manchine/dev/claude-plugins/linter/`

## Edge Cases to Handle

1. No linters detected - warn user and suggest installing common linters
2. Linter not installed but config exists - warn and skip
3. Conflicting linters (eslint vs biome) - run both, let user resolve conflicts
4. Very large codebases - may need to batch or parallelize
5. Linter crashes mid-run - capture error, continue with other linters
6. Permission errors on files - skip and report

## Success Criteria

- [ ] `/linter` command works
- [ ] "run linter" natural language triggers skill
- [ ] Auto-detects eslint, prettier, markdownlint, shellcheck at minimum
- [ ] Runs --fix mode on all detected linters
- [ ] Spawns agent for manual fixes when needed
- [ ] Clean summary output showing what was fixed
