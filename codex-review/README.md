# Codex Review Plugin

Get second-opinion reviews on Claude Code plans and code changes using
OpenAI's Codex CLI.

## Features

- **Plan Review**: Review Claude Code implementation plans before execution
- **Code Review**: Review uncommitted code changes via git diff
- **Second Opinion**: Consult Codex for independent perspective on technical decisions
- **Autofix**: Automatically fix valid issues with `--auto` flag
- **Principle Validation**: Validates feedback against DRY, KISS, YAGNI, SRP
- **Context-Safe**: Writes results to files, displays summaries to terminal
- **AI-Validated Feedback**: Claude filters Codex output for actionable insights
- **Auto-Summon**: Skill triggers when discussing code review or second opinions

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
# Review current directory
/codex-review:code

# Review specific project
/codex-review:code /path/to/project

# Auto mode (no prompts, deletes previous, applies fixes)
/codex-review:code --auto
```

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

### Skill Auto-Summon

The plugin includes skills that auto-trigger:

**Review skill** - when you mention:

- "second opinion on my code"
- "review my uncommitted changes"
- "validate my plan"

**Second-opinion skill** - when you mention:

- "ask Codex"
- "get a second opinion"
- "what would Codex say"

## Flags

| Flag     | Effect                                                     |
| -------- | ---------------------------------------------------------- |
| `--auto` | Non-interactive mode: deletes previous results, no prompts |

For code reviews, `--auto` also enables autofix (applies fixes for valid issues).

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

## Validation Principles

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

## Decision Categories

| Category     | Meaning                             | Action                     |
| ------------ | ----------------------------------- | -------------------------- |
| VALID-FIX    | Legitimate, can be auto-fixed       | Fix (if --auto) or suggest |
| VALID-SKIP   | Legitimate, needs manual review     | Flag for user              |
| INVALID      | Not applicable, Codex misunderstood | Dismiss                    |
| INTENTIONAL  | Intentional design choice           | Dismiss                    |

## Requirements

- **Codex CLI**: Install with `npm install -g @openai/codex`
- **Authentication**: Run `codex auth` to authenticate
- **Git**: For code reviews, must be in a git repository

## Installation

```bash
claude --plugin-dir /path/to/codex-review
```

Or add to your Claude Code plugin configuration.

## Architecture

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

## Troubleshooting

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

## License

MIT
