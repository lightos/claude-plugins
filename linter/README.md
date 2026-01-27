# Linter Plugin

A Claude Code plugin that automatically detects and runs all available linters on your codebase, fixing issues where possible.

## Features

- **Auto-detection**: Finds linters based on config files and installed CLIs
- **Auto-fix**: Runs linters with `--fix` flags where supported
- **Interactive fixing**: Attempts manual fixes for unfixable errors
- **Conflict handling**: Detects and resolves conflicting formatters
- **Local-first**: Prefers project-local installations over global

## Installation

```bash
# Add as a Claude Code plugin
claude --plugin-dir /path/to/linter
```

## Usage

### Natural Language

Just ask:

- "Run linter"
- "Lint the codebase"
- "Fix lint errors"
- "Check code style"

### Command

```bash
/linter                           # Run all detected linters with auto-fix
/linter --no-fix                  # Report only, don't fix
/linter --only eslint,prettier    # Run specific linters
/linter --skip pylint             # Skip specific linters
/linter --path src/               # Lint specific directory
```

## Supported Linters

| Linter | Auto-fix | Detection |
|--------|----------|-----------|
| ESLint | Yes | `.eslintrc*`, `eslint.config.*`, `package.json` |
| Prettier | Yes | `.prettierrc*`, `prettier.config.*`, `package.json` |
| Biome | Yes | `biome.json`, `biome.jsonc` |
| markdownlint | Yes | `.markdownlint*` |
| ShellCheck | No | `.shellcheckrc`, `*.sh` files |
| Ruff | Yes | `ruff.toml`, `.ruff.toml`, `pyproject.toml` |
| Pylint | No | `.pylintrc`, `pyproject.toml`, `setup.cfg` |
| Black | Yes | `pyproject.toml` |
| mypy | No | `mypy.ini`, `.mypy.ini`, `pyproject.toml` |
| TypeScript | No | `tsconfig.json` |

## Requirements

- `jq` - JSON processor (used by detection scripts)
- Linter CLIs must be installed (globally or locally in project)

### Installing jq

```bash
# macOS
brew install jq

# Ubuntu/Debian
apt install jq

# Fedora
dnf install jq
```

## How It Works

1. **Detection** (`scripts/detect-linters.sh`)
   - Scans for config files
   - Checks for local installs (`npx`, `pnpm exec`, `poetry run`, `python -m`)
   - Falls back to global CLIs
   - Outputs JSON Lines with linter capabilities

2. **Execution** (`scripts/run-linters.sh`)
   - Runs each linter with appropriate arguments
   - Uses `git ls-files` to determine files to lint
   - Captures and normalizes output

3. **Interactive Fixing** (`agents/lint-fixer.md`)
   - For linters without auto-fix (shellcheck, pylint)
   - Analyzes errors and makes targeted code edits
   - Verifies fixes by re-running the linter

## Conflict Resolution

When conflicting formatters are detected, the plugin automatically applies the preferred tool:

- **Biome + ESLint/Prettier**: Automatically uses Biome if configured
- **Ruff + Black**: Automatically uses Ruff if configured

Use `--only` or `--skip` flags to override the default preference.

## File Structure

```text
linter/
├── .claude-plugin/
│   └── plugin.json
├── agents/
│   └── lint-fixer.md        # Interactive fixing agent
├── commands/
│   └── linter.md            # /linter command
├── scripts/
│   ├── detect-linters.sh    # Auto-detection
│   ├── run-linters.sh       # Execution orchestrator
│   └── linter-capabilities.json
├── skills/
│   └── linter/
│       └── SKILL.md         # Natural language triggering
└── README.md
```

## Contributing

To add support for a new linter:

1. Add entry to `scripts/linter-capabilities.json`
2. Test detection with various config file locations
3. Verify fix/check argument handling

## License

MIT
