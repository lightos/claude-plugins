# Codex Review Plugin

Get second-opinion reviews on Claude Code plans and code changes using
OpenAI's Codex CLI.

## Features

- **Full Codebase Scan**: Review all git-tracked files with `--full` flag
- **Plan Review**: Review Claude Code implementation plans before execution
- **Code Review**: Review uncommitted code changes via git diff
- **Pull Request Review**: Review GitHub PRs by number with `--pr` flag (supports forks, interactive selection)
- **Branch Comparison**: Review commits between branches with `--base` flag
- **Single Commit Review**: Review changes from a specific commit with `--commit` flag
- **Commit Range Review**: Review changes across commit ranges with `--range` flag
- **Auto-Detection**: Automatically detects base branch (tracking > remote HEAD > origin/main)
- **Second Opinion**: Consult Codex for independent perspective on technical decisions
- **Autofix**: Automatically fix valid issues with `--auto` flag
- **Principle Validation**: Validates feedback against DRY, KISS, YAGNI, SRP
- **Context-Safe**: Writes results to files, displays summaries to terminal
- **AI-Validated Feedback**: Claude filters Codex output for actionable insights
- **Auto-Summon**: Skill triggers when discussing code review or second opinions

## Quick Start

```bash
# Scan entire codebase
/codex-review:code --full

# Review uncommitted changes
/codex-review:code

# Review commits on current branch vs main
/codex-review:code --base main

# Review a specific commit
/codex-review:code --commit abc1234

# Review changes between commits (PR-style)
/codex-review:code --range main...HEAD

# Review a GitHub Pull Request
/codex-review:code --pr 123

# Interactive PR selection (lists recent PRs)
/codex-review:code --pr

# Or just say in conversation:
# "get a second opinion on my changes"
# "ask Codex about this approach"
```

## Usage

### Plan Review

```bash
# With explicit path
/codex-review:plan ~/.claude/plans/my-plan.md

# Interactive selection (lists recent plans)
/codex-review:plan

# Auto mode (no prompts, deletes previous results)
/codex-review:plan --auto my-plan.md
```

### Code Review

```bash
# Scan entire codebase (all git-tracked files)
/codex-review:code --full

# Review uncommitted changes in current directory
/codex-review:code

# Review commits vs base branch
/codex-review:code --base main

# Review specific project
/codex-review:code /path/to/project

# Auto mode (no prompts, deletes previous, applies fixes)
/codex-review:code --auto

# Combine flags
/codex-review:code --auto --base develop /path/to/project
```

**Detection Priority:**

1. Explicit `--full` (highest priority - scans all files)
2. Explicit `--commit <sha>`
3. Explicit `--range <sha>..<sha>`
4. Explicit `--pr <number>`
5. Explicit `--base <branch>`
6. Uncommitted changes (staged + unstaged + untracked)
7. Auto-detect base branch (tracking > remote HEAD > origin/main > origin/master)

### Second Opinion (Consultation)

Claude can consult Codex for independent perspectives on technical decisions:

**Proactive triggers** (Claude uses automatically when uncertain):

- Architectural decisions with multiple valid approaches
- Unfamiliar technology or patterns
- High-stakes changes (security, performance, breaking changes)
- Explicit uncertainty ("I think", "probably")

**User triggers** (say these to invoke):

- "Ask Codex about X"
- "Get a second opinion on this"
- "What would Codex say about Y"
- "Check with Codex"

**How it works:**

1. Claude extracts the problem and constraints (without its own solution)
2. Codex provides independent: approach, concerns, alternatives, checklist
3. Claude silently synthesizes the feedback
4. Only surfaces to user if there's a major conflict or insight

**Example:**

```text
User: "I'm implementing rate limiting - ask Codex what approach to use"

Claude: [Invokes consultant agent]

Here's Codex's perspective on rate limiting:

**Recommended Approach:** Token bucket algorithm with Redis backend...
**Concerns:** Consider distributed clock skew, burst handling...
**Alternatives:** Sliding window, fixed window with...
**Checklist:** Verify Redis failover handling, test burst scenarios...

Based on this and your Express.js setup, I recommend...
```

### Natural Language Invocation

Skills trigger automatically through conversation - no commands needed:

**Review skill** - say things like:

- "second opinion on my code"
- "review my uncommitted changes"
- "validate my plan"

**Second-opinion skill** - say things like:

- "ask Codex about X"
- "get a second opinion"
- "what would Codex say"
- "check with Codex"
- "consult Codex about this"

**Note:** You can also use `/codex-review:code` or `/codex-review:plan` for direct invocation.

## Flags

| Flag                | Effect                                                                     |
| ------------------- | -------------------------------------------------------------------------- |
| `--auto`            | Non-interactive mode: deletes previous results, no prompts                 |
| `--full`            | Scan all git-tracked files (may timeout on large repos)                    |
| `--base <branch>`   | Compare current HEAD against specified branch                              |
| `--commit <sha>`    | Review changes from a specific commit                                      |
| `--range <s>..<e>`  | Review commit range (`..` tree-diff, `...` PR-style)                       |
| `--pr [number]`     | Review a GitHub PR by number, or select interactively (requires `gh` CLI)  |

For code reviews, `--auto` also enables autofix (applies fixes for valid issues).

When `--base` is specified with uncommitted changes present, a warning is shown but the branch comparison proceeds (uncommitted changes are ignored).

## Configuration

### Environment Variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `CODEX_REVIEW_TIMEOUT_SECONDS` | `1800` | Timeout for Codex CLI in seconds (default 30 minutes) |

Example:

```bash
# Set a 1-hour timeout for large codebase scans
export CODEX_REVIEW_TIMEOUT_SECONDS=3600
/codex-review:code --full
```

### Execution Strategy

- **Standard reviews**: Run directly (fits within 10-minute limit)
- **Full codebase scans (--full)**: Run in background; user checks back for results
- **Scripts write minimal output**: Only the result file path is printed
- **Status files**: `.status` files track running/done/timeout/error for debugging

| Status | Meaning |
| ------ | ------- |
| `running` | Review in progress |
| `done` | Review completed successfully |
| `timeout` | Codex timed out |
| `error:N` | Codex failed with exit code N |

To check status manually (for debugging only):

```bash
cat .codex-review/code-review-*.status | tail -1
```

## Workflow

```text
+-------------------+
| User invokes      |
| command           |
+---------+---------+
          |
          v
+-------------------+
| Check for         |
| existing results  |
+---------+---------+
          |
    +-----+-----+
    |           |
    v           v
[EXISTS]    [NEW]
    |           |
    v           v
+--------+  +-------------------+
| Prompt |  | Codex CLI         |
| user   |  | analyzes          |
+--------+  | plan/code         |
    |       +---------+---------+
    +-------+         |
            |         v
            |   +-------------------+
            +-->| issue-handler     |
                | agent validates   |
                | (and fixes if     |
                |  --auto)          |
                +---------+---------+
                          |
                          v
                +-------------------+
                | Present summary   |
                | to user           |
                +-------------------+
```

## Output

Results are saved to `.codex-review/` directory:

```text
.codex-review/
├── plan-review-myplan-20260122-143000.md           # Raw Codex output
├── plan-review-validated-20260122-143000.md        # Validated report
├── code-review-20260122-150000.md                  # Raw Codex output
└── code-review-validated-20260122-150000.md        # Validated report
```

<details>
<summary><strong>Validation Principles</strong></summary>

The issue-handler agent evaluates Codex feedback against:

| Principle       | What It Checks                 |
| --------------- | ------------------------------ |
| **DRY**         | Code/logic duplication         |
| **KISS**        | Unnecessary complexity         |
| **YAGNI**       | Over-engineering               |
| **SRP**         | Single responsibility issues   |
| **SOLID**       | Design principle adherence     |
| **Security**    | Vulnerabilities (always valid) |
| **Performance** | Realistic concerns             |

</details>

<details>
<summary><strong>Decision Categories</strong></summary>

| Category     | Meaning                             | Action                     |
| ------------ | ----------------------------------- | -------------------------- |
| VALID-FIX    | Legitimate, can be auto-fixed       | Fix (if --auto) or suggest |
| VALID-SKIP   | Legitimate, needs manual review     | Flag for user              |
| INVALID      | Not applicable, Codex misunderstood | Dismiss                    |
| INTENTIONAL  | Intentional design choice           | Dismiss                    |

</details>

## Requirements

- **Codex CLI**: Install with `npm install -g @openai/codex`
- **Authentication**: Run `codex auth` to authenticate
- **Git**: For code reviews, must be in a git repository
- **For PR reviews**: [GitHub CLI](https://cli.github.com/) authenticated with `gh auth login`

## Installation

```bash
claude --plugin-dir /path/to/codex-review
```

Or add to your Claude Code plugin configuration.

<details>
<summary><strong>Architecture</strong></summary>

### Plugin Components

- `commands/plan.md` - Orchestrates plan review workflow
- `commands/code.md` - Orchestrates code review workflow
- `agents/issue-handler.md` - Validates Codex output and applies fixes (Opus)
- `agents/consultant.md` - Queries Codex for independent perspectives (Haiku)
- `skills/review.md` - Auto-summon skill for review requests
- `skills/second-opinion.md` - Auto-summon skill for technical consultations
- `scripts/code-review.sh` - Runs Codex code review with project path
- `scripts/plan-review.sh` - Runs Codex plan review
- `scripts/list-plans.sh` - Lists recent Claude Code plan files
- `scripts/list-prs.sh` - Lists recent GitHub PRs for interactive selection

### Agents

| Agent         | Model | Tools                                                         |
| ------------- | ----- | ------------------------------------------------------------- |
| issue-handler | Opus  | Read, Write, Edit, Grep, Glob, Bash, WebSearch, WebFetch, LSP |
| consultant    | Haiku | Bash, Read, Write                                             |

**issue-handler** uses:

- **Edit**: Apply automatic fixes for VALID-FIX issues
- **LSP**: Code intelligence for deep context understanding
- **WebSearch/WebFetch**: Research latest best practices from official docs

**consultant** uses:

- **Bash**: Execute `codex exec` queries
- **Write**: Save Codex responses to `.codex-review/`
- **Read**: Verify output files

</details>

## Why Use This?

1. **Second Opinion**: Get a different AI's perspective on your work
2. **Principle Enforcement**: Ensures feedback aligns with best practices
3. **Noise Filtering**: Claude validates Codex feedback, reducing false positives
4. **Pre-Execution Check**: Review plans before investing time in implementation
5. **Autofix**: Valid issues can be fixed automatically with `--auto`

## Limitations

- Requires Codex CLI to be installed and authenticated
- Plan reviews require knowledge of Claude Code's plan storage location (see below)
- Code reviews only work in git repositories
- Codex has its own token limits for large diffs

<details>
<summary><strong>Troubleshooting</strong></summary>

### "codex: command not found"

Install Codex CLI: `npm install -g @openai/codex`

### "Not authenticated"

Run `codex auth` to authenticate with your OpenAI account.

### Finding plan files

Claude Code stores plans in `~/.claude/plans/`. To find recent plans:

```bash
ls -lt ~/.claude/plans/ | head -10
```

Or use `/codex-review:plan` without arguments for interactive selection.

### Large diff exceeds Codex limits

Break your changes into smaller commits or review specific files:

```bash
git diff -- src/specific-file.ts | codex review -
```

</details>

## License

MIT
