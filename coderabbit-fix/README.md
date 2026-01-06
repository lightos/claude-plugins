# CodeRabbit Fix Plugin

Automates CodeRabbit code review and intelligent issue fixing using a multi-agent architecture.

## Features

- Runs `coderabbit review --plain` and parses issues
- Validates each issue against coding principles (YAGNI, SOLID, DRY, SRP, KISS)
- Searches codebase for similar issues and batch-fixes them
- Auto-detects and runs project linters/tests after fixes

## Usage

```bash
/coderabbit-fix
```

## Architecture

```text
/coderabbit-fix (command)
    │
    ├── Run coderabbit review --plain (background)
    │
    ├── For each issue (parallel):
    │   │
    │   └── issue-validator (opus ultrathink)
    │       ├── Validate against coding principles
    │       ├── Spawn similar-issues-finder (haiku)
    │       └── If valid → spawn issue-fixer (haiku)
    │
    └── Auto-detect & run linters/tests (background)
```

## Agents

| Agent | Model | Purpose |
|-------|-------|---------|
| `issue-validator` | opus (ultrathink) | Validates issues against best practices |
| `similar-issues-finder` | haiku | Searches codebase for related issues |
| `issue-fixer` | haiku | Implements fixes for reported + similar issues |

## Requirements

- CodeRabbit CLI installed (`coderabbit` command available)
- Claude Code with opus and haiku model access

## Installation

```bash
claude --plugin-dir /path/to/coderabbit-fix
```
