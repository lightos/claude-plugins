# CodeRabbit Fix Plugin

Automates CodeRabbit code review and intelligent issue fixing using a
multi-command, multi-agent architecture designed to prevent context overflow.

## Features

- Runs `coderabbit review --plain` and parses issues into structured JSON
- Validates each issue against production quality standards using Opus agents
- Searches codebase for similar issues and batch-fixes them using Haiku agents
- Auto-detects and runs project linters/tests after fixes
- **Context-safe architecture**: Results go to files, not context

## Commands

| Command                | Purpose                                     |
| ---------------------- | ------------------------------------------- |
| `/coderabbit-review`   | Run CodeRabbit and parse issues to JSON     |
| `/coderabbit-validate` | Validate issues with Opus agents            |
| `/coderabbit-fix`      | Fix validated issues with Haiku agents      |
| `/coderabbit-auto`     | Run all 3 phases with file-based result aggregation |

### Granular Control (Recommended for Large Codebases)

Run each command in a **fresh session** to avoid context accumulation:

```bash
# Session 1: Review
/coderabbit-review
# Creates: .coderabbit-results/issues.json

# Session 2: Validate
/coderabbit-validate
# Creates: .coderabbit-results/issue-*.md, validated-summary.json

# Session 3: Fix
/coderabbit-fix
# Applies fixes, creates: fix-summary.json
```

### Full Automation

For smaller codebases or when you want automation with batching:

```bash
/coderabbit-auto
```

Auto mode spawns all validators in a single message turn for maximum parallelism.
Claude Code manages internal concurrency.

## Workflow

```text
Review → Parse → Validate Each Issue → Fix Valid Issues → Lint/Test
  ↓        ↓           ↓                    ↓
 CLI   issues.json   issue-N.md          Fix appended
```

## Architecture

```text
.coderabbit-results/
├── raw-output.txt          ← CodeRabbit CLI output
├── issues.json             ← Parsed issues (full data)
├── issue-1.md              ← Validator report for issue 1
├── issue-2.md              ← Validator report for issue 2
├── ...
├── validated-summary.json  ← Aggregated validation results
└── fix-summary.json        ← Final fix results
```

### Why Multi-Command?

Single-command approach causes **context overflow** with many issues:

- 60+ parallel validator agents all return results to main context
- Context fills up, can't even compact
- Session becomes unusable

Multi-command solution:

- **File-based results**: Agents write to files, not returned to context
- **Fresh sessions**: Each command runs in its own session
- **Batched execution**: Auto mode processes 15 issues at a time
- **No grouping overhead**: Each issue validated independently

## Agents

| Agent             | Model | Purpose                                         |
| ----------------- | ----- | ----------------------------------------------- |
| `issue-validator` | Opus  | Validates issues, finds similar patterns        |
| `issue-fixer`     | Haiku | Applies fixes consistently, appends to file     |

Both agents return only "Done" to avoid filling context with results.

## Production Quality Standards

Issues are validated against these criteria (none are "just nitpicks"):

- **UX/UI bugs** - Dark mode, layout, visual glitches
- **Writing/copy** - Typos, grammar, punctuation
- **Accessibility** - Screen reader, keyboard nav, ARIA
- **Performance** - Slow renders, memory leaks
- **Security** - XSS, injection, exposed secrets
- **Type safety** - Missing/incorrect types
- **Error handling** - Unhandled errors

## Fix Guidelines

Fixes follow YAGNI/KISS principles:

- Use the simplest fix that solves the problem
- Prefer explicit, readable code over clever one-liners
- Match existing codebase style
- Fix consistently across similar issues

## Known Limitations

- **Very large codebases (100+ issues):** Auto mode spawns all validators at once.
  For very large reviews, use granular commands in separate sessions:
  1. `/coderabbit-review` (Session 1)
  2. `/coderabbit-validate` (Session 2)
  3. `/coderabbit-fix` (Session 3)

## Requirements

- CodeRabbit CLI installed (`coderabbit` command available)
- Claude Code with Opus model access
- `jq` installed (for JSON parsing in scripts)

## Installation

```bash
claude --plugin-dir /path/to/coderabbit-fix
```
