# Claude Plugins

A collection of plugins for [Claude Code](https://claude.com/claude-code).

## Overview

This repository contains Claude Code plugins that extend the capabilities of
the Claude Code CLI. Plugins add custom commands, agents, skills, and workflows
to your Claude Code sessions.

## Quick Start

```bash
# Run CodeRabbit review and fix issues
/coderabbit

# Scan entire codebase with Codex
/codex-review:code --full

# Get a second opinion on code changes
/codex-review:code

# Auto mode (no prompts, auto-fix valid issues)
/codex-review:code --auto
```

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
/coderabbit                     # Review uncommitted changes
/coderabbit --base origin/main  # Review commits since branch
/coderabbit --auto --base main  # Non-interactive mode
```

> **Note:** When no uncommitted changes exist, use `--base` to specify what to review. `--auto` mode requires `--base` when there are no uncommitted changes.

<details>
<summary><strong>Architecture</strong></summary>

| Agent | Model | Purpose |
|-------|-------|---------|
| `issue-handler` | Opus | Validates AND fixes single issues in one pass |
| `issue-handler-cluster` | Opus | Validates AND fixes clusters of related issues |
| `issue-grouper` | Haiku | Groups similar issues to reduce agent spawns |

</details>

### codex-review

Get second-opinion reviews on Claude Code plans and code changes using OpenAI's Codex CLI.

**Features:**

- Reviews implementation plans before execution
- Reviews uncommitted code changes via git diff
- Reviews commits vs base branch with `--base` flag
- Reviews single commits with `--commit` flag
- Reviews commit ranges with `--range` flag
- Validates feedback against DRY, KISS, YAGNI, SRP, SOLID principles
- Opus-powered validation filters Codex output for actionable insights
- Auto-summon via natural language (see below)

**Usage:**

```bash
/codex-review:code --full           # Scan all git-tracked files
/codex-review:code                  # Review uncommitted changes
/codex-review:code --base main      # Review commits vs base branch
/codex-review:code --commit abc123  # Review a specific commit
/codex-review:code --range a..b     # Review commit range
/codex-review:plan plan.md          # Review a plan file
/codex-review:code --auto           # Auto mode: no prompts, applies fixes
```

**Natural Language:** Say "get a second opinion on my changes" or "ask Codex about this approach" to trigger automatically.

## Installation

### Option 1: Marketplace (Recommended)

Add this repository as a marketplace, then install individual plugins:

```bash
# Add marketplace
/plugin marketplace add https://github.com/lightos/claude-plugins

# Install plugins
/plugin install coderabbit-fix@cc-plugins
/plugin install codex-review@cc-plugins
```

### Option 2: Plugin directory flag

```bash
claude --plugin-dir /path/to/claude-plugins/coderabbit-fix
```

### Option 3: Copy plugin to your project

```bash
mkdir -p /your/project/.claude/plugins
cp -r coderabbit-fix /your/project/.claude/plugins/
```

### Option 4: Symlink for development

```bash
ln -s /path/to/claude-plugins/coderabbit-fix /your/project/.claude/plugins/coderabbit-fix
```

## Requirements

### All Plugins

- [Claude Code](https://claude.com/claude-code) CLI
- **Bash 4.0+** (macOS ships with bash 3.2 - install with `brew install bash`)

### For coderabbit-fix

- [CodeRabbit CLI](https://github.com/coderabbitai/coderabbit): `npm install -g coderabbit`
- `jq`: `apt install jq` (Linux) or `brew install jq` (macOS)
- `timeout`: Part of GNU coreutils. macOS: `brew install coreutils` (provides `gtimeout`)

### For codex-review

- [Codex CLI](https://github.com/openai/codex): `npm install -g @openai/codex` then `codex auth`

<details>
<summary><strong>macOS Users</strong></summary>

macOS requires additional setup:

```bash
# Install modern bash (required for coderabbit-fix)
brew install bash

# Install GNU coreutils (provides gtimeout)
brew install coreutils

# Install jq
brew install jq
```

</details>

## License

MIT License - see [LICENSE](LICENSE) for details.
