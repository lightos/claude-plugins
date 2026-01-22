# Claude Plugins

A collection of plugins for [Claude Code](https://claude.com/claude-code).

## Plugins

### coderabbit-fix

Automates CodeRabbit code review and intelligent issue fixing using a multi-agent architecture with context-safe design.

**Features:**

- Runs `coderabbit review --plain` and parses issues to structured JSON
- Intelligent grouping of similar issues (20+ issues) to reduce redundant validation
- Validates issues with 4-way decision framework: VALID-FIX, VALID-SKIP, INVALID, INTENTIONAL
- LSP integration for semantic validation (unused variables, type safety)
- WebSearch verification against official documentation
- Context-safe architecture: agents write to files, preventing context overflow
- Auto-detects and runs project linters/tests after fixes

**Usage:**

```bash
/coderabbit
```

**Architecture:**

| Agent | Model | Purpose |
|-------|-------|---------|
| `issue-handler` | Opus | Validates AND fixes single issues in one pass |
| `issue-handler-cluster` | Opus | Validates AND fixes clusters of related issues |
| `issue-grouper` | Haiku | Groups similar issues to reduce agent spawns |

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
