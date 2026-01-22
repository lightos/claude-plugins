# CodeRabbit Fix Plugin

Automates CodeRabbit code review and intelligent issue fixing using a
multi-agent architecture with context-safe design.

## Features

- Runs `coderabbit review --plain` and parses issues into structured JSON
- Intelligent grouping of similar issues (when 20+ issues)
- Validates each issue with a 4-way decision framework
- LSP integration for semantic validation (unused variables, type safety)
- WebSearch verification against official documentation
- Context-safe architecture: agents write to files, not context
- Auto-detects and runs project linters/tests after fixes

## Command

```bash
/coderabbit
```

Runs the complete workflow: Review → Group → Handle → Finalize

## Workflow Phases

### Phase 1: Review

1. Run `coderabbit review --plain`
2. Parse output into `.coderabbit-results/issues.json`

### Phase 2: Grouping (Optional)

**Only runs when 20+ issues are found.**

Groups similar issues by:

- Same issue type + similar description
- Same directory + same issue type
- Same file (multiple issues)
- Similar description keywords

Reduces agent spawns by handling related issues together.

### Phase 3: Handle Issues

Spawns agents in parallel:

- **Clusters**: `issue-handler-cluster` for grouped issues
- **Singletons**: `issue-handler` for individual issues

All agents run in parallel in a single message turn.

### Phase 4: Finalize

1. Run linters (with retry loop, max 3 attempts)
2. Run tests (with retry loop, max 2 attempts)
3. Generate `summary.md` report

## Agents

| Agent                  | Model | Purpose                                       |
| ---------------------- | ----- | --------------------------------------------- |
| `issue-handler`        | Opus  | Validates AND fixes single issues             |
| `issue-handler-cluster`| Opus  | Validates AND fixes clusters of related issues|
| `issue-grouper`        | Haiku | Groups similar issues to reduce agent spawns  |

All agents return only "Done" to prevent context overflow.

## Architecture

```text
.coderabbit-results/
├── raw-output.txt          ← CodeRabbit CLI output
├── issues.json             ← Parsed issues (full data)
├── groups.json             ← Grouping results (if 20+ issues)
├── grouper-input.json      ← Minimal issue data for grouper
├── issue-1.md              ← Handler report for issue 1
├── issue-2.md              ← Handler report for issue 2
├── cluster-dark-mode.md    ← Cluster report (if grouped)
├── cluster-*.md            ← Additional cluster reports
├── lint-status.txt         ← Linter result (passed/failed)
├── test-status.txt         ← Test result (passed/failed)
└── summary.md              ← Final comprehensive report
```

## Decision Framework

Handlers use a 4-way decision framework:

| Decision       | Meaning                                    | Action        |
| -------------- | ------------------------------------------ | ------------- |
| `VALID-FIX`    | Real issue affecting production quality    | Validate + Fix|
| `VALID-SKIP`   | Real issue but fix would violate YAGNI/KISS| Validate only |
| `INVALID`      | CodeRabbit misunderstood the code          | Report only   |
| `INTENTIONAL`  | Code has explicit comment explaining why   | Report only   |

## Context Management

The plugin uses file-based result aggregation to prevent context overflow:

1. **Agents write to files**: Each handler writes its report to a dedicated
   `.md` file and returns only "Done"
2. **No context accumulation**: Results don't fill the main session context
3. **Parallel execution**: All handlers run in a single message turn
4. **Script-based aggregation**: `generate-report.sh` collects results from
   files to produce `summary.md`

This architecture allows handling 100+ issues without context exhaustion.

## Production Quality Standards

Issues are validated against these criteria:

- **UX/UI bugs** - Dark mode, layout, visual glitches
- **Writing/copy** - Typos, grammar, punctuation
- **Accessibility** - Screen reader, keyboard nav, ARIA
- **Performance** - Slow renders, memory leaks
- **Security** - XSS, injection, exposed secrets
- **Type safety** - Missing/incorrect types
- **Error handling** - Unhandled errors

**"Nitpick" is not a valid reason to skip.** If it affects users, it gets fixed.

## Fix Guidelines

Fixes follow YAGNI/KISS principles:

- Use the simplest fix that solves the problem
- Prefer explicit, readable code over clever one-liners
- Match existing codebase style
- Fix consistently across similar issues

## Known Limitations

- **CodeRabbit CLI required**: Must have `coderabbit` command available
- **Review timeout**: 10-minute timeout for CodeRabbit CLI execution
- **Handler timeout**: 10-minute timeout for all handlers to complete
- **Linting scope**: By default only fixes errors in CodeRabbit-modified files

## Requirements

- CodeRabbit CLI installed (`coderabbit` command available)
- Claude Code with Opus model access
- `jq` installed (for JSON parsing in scripts)

## Installation

```bash
claude --plugin-dir /path/to/coderabbit-fix
```
