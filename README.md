# Claude Plugins

A collection of plugins for [Claude Code](https://claude.com/claude-code).

## Plugins

### coderabbit-fix

Automates CodeRabbit code review and intelligent issue fixing using a multi-agent architecture.

**Features:**

- Runs `coderabbit review --plain` and parses issues
- Validates each issue against coding principles (YAGNI, SOLID, DRY, SRP, KISS)
- Checks if code patterns are intentional before suggesting fixes
- Searches codebase for similar issues and batch-fixes them
- Auto-detects and runs project linters/tests after fixes

**Usage:**

```bash
/coderabbit-fix
```

**Architecture:**

| Agent | Model | Purpose |
|-------|-------|---------|
| `issue-validator` | opus (ultrathink) | Validates issues, checks intent, applies coding principles |
| `similar-issues-finder` | haiku | Fast codebase search for related issues |
| `issue-fixer` | haiku | Implements fixes for reported + similar issues |

## Installation

```bash
# Option 1: Use plugin directory flag
claude --plugin-dir /path/to/claude-plugins/coderabbit-fix

# Option 2: Copy to project
cp -r coderabbit-fix/.claude-plugin/* /your/project/.claude-plugin/
cp -r coderabbit-fix/agents /your/project/.claude-plugin/
cp -r coderabbit-fix/commands /your/project/.claude-plugin/
```

## Requirements

- [Claude Code](https://claude.com/claude-code) CLI
- [CodeRabbit CLI](https://github.com/coderabbitai/coderabbit) (for coderabbit-fix plugin)

## License

MIT License - see [LICENSE](LICENSE) for details.
