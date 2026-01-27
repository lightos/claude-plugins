# Claude Plugins

A collection of plugins for [Claude Code](https://claude.com/claude-code) that extend the CLI with code review, linting, and automated fixing capabilities.

## Quick Start

```bash
# Run all linters with auto-fix
/linter

# Run CodeRabbit review and fix issues
/coderabbit

# Get a second opinion on code changes
/codex-review:code
```

## Plugins

| Plugin | Purpose | Install |
|--------|---------|---------|
| linter | Auto-detect and run linters | `/plugin install linter@cc-plugins` |
| coderabbit-fix | CodeRabbit review + auto-fix | `/plugin install coderabbit-fix@cc-plugins` |
| codex-review | Second-opinion code reviews | `/plugin install codex-review@cc-plugins` |

### linter

Auto-detect and run all available linters on your codebase with intelligent fixing. Supports ESLint, Prettier, Biome, markdownlint, ShellCheck, Ruff, Pylint, Black, mypy, and TypeScript.

[Full documentation →](linter/README.md)

### coderabbit-fix

Run CodeRabbit code review and automatically validate and fix issues using a multi-agent architecture. Features intelligent issue grouping, LSP validation, and context-safe design.

[Full documentation →](coderabbit-fix/README.md)

### codex-review

Get second-opinion reviews on code changes using OpenAI's Codex CLI. Reviews uncommitted changes, branch comparisons, specific commits, or GitHub PRs with Opus-powered validation.

[Full documentation →](codex-review/README.md)

## Installation

### Option 1: Marketplace (Recommended)

```bash
# Add marketplace
/plugin marketplace add https://github.com/lightos/claude-plugins

# Install plugins
/plugin install linter@cc-plugins
/plugin install coderabbit-fix@cc-plugins
/plugin install codex-review@cc-plugins
```

### Option 2: Plugin directory flag

```bash
claude --plugin-dir /path/to/claude-plugins/linter
```

### Option 3: Copy to project

```bash
mkdir -p /your/project/.claude/plugins
cp -r linter /your/project/.claude/plugins/
```

### Option 4: Symlink for development

```bash
ln -s /path/to/claude-plugins/linter /your/project/.claude/plugins/linter
```

## Requirements

- [Claude Code](https://claude.com/claude-code) CLI
- Bash 4.0+ (macOS ships with 3.2 - install with `brew install bash`)
- Plugin-specific requirements in each plugin's README

## License

MIT License - see [LICENSE](LICENSE) for details.
