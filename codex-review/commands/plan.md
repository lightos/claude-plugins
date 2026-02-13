---
description: Get a second-opinion review of a Claude Code implementation plan
argument-hint: "[--auto] [--fix] <plan-file-path>"
allowed-tools: ["Bash", "Read", "Task", "AskUserQuestion"]
---

# Codex Plan Review

Review a Claude Code implementation plan using OpenAI Codex as a second opinion.

## Prerequisites

- `codex` CLI must be installed and authenticated
- Plan file must exist

## Flags

- `--auto`: Non-interactive mode. Deletes previous results, no prompts. Does NOT imply `--fix`.
- `--fix`: Apply valid fixes to plan file directly (agent uses Edit tool). Requires explicit use.

Flag combinations:

- `--auto`: Review only, no prompts
- `--fix`: Review + fix, with prompts
- `--auto --fix`: Review + fix, no prompts

---

**Do NOT read the plan file.** The scripts and agents handle all file reading internally. Pre-reading wastes tokens by duplicating content in the main context.

---

## Phase 1: Locate Plan File

Parse arguments to check for flags:

- If ARGUMENTS contains `--auto`: set AUTO_MODE=true
- If ARGUMENTS contains `--fix`: set FIX_MODE=true
- Extract plan path from remaining arguments

### If Path Provided

If the user provided a path argument, proceed directly to Phase 2.

### If No Path Provided

List recent plans for user selection:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/list-plans.sh"
```

Use AskUserQuestion to let user select a plan from the list.

---

## Phase 2: Run Review Script

### Execution

Run the script directly. Plan reviews typically complete within 10 minutes.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/plan-review.sh" [--auto] "[PLAN_PATH]"
```

If the script times out, inform the user that the plan may be very large
and suggest running with --auto flag to skip prompts.

The script runs with a 30-minute internal timeout (configurable via `CODEX_REVIEW_TIMEOUT_SECONDS`).

### Handle Script Output

On success, the script (`plan-review.sh`) outputs one of:

1. `EXISTS:/path/to/existing/file.md` - Previous results found for this plan
2. `/path/to/new/file.md` - New scan completed

On failure, the script writes error messages to stderr and exits with a non-zero
exit code. Do not parse stdout for errors.

### If EXISTS Response

The script found existing results for this plan.

**If FIX_MODE=true:** Stale Codex output applied as fixes could introduce incorrect edits. Automatically delete the existing file and re-run with `--auto` (same as "Delete and re-run" path). Do NOT offer to reuse stale results when `--fix` is set.

**If not --auto (and not --fix):** Ask the user:

```yaml
AskUserQuestion:
  question: "Previous review results found for this plan. What would you like to do?"
  header: "Exists"
  options:
    - label: "Use existing results"
      description: "Continue with the existing review file"
    - label: "Delete and re-run"
      description: "Remove old results and run a fresh review"
    - label: "Abort"
      description: "Cancel the review"
```

If "Use existing results": Use the EXISTS path as the Codex output
If "Delete and re-run": Delete the file, then re-run script with --auto
If "Abort": Stop and inform user

---

## Phase 3: Validate and Fix with Issue Handler

Spawn the issue-handler agent to validate Codex findings:

```yaml
Task tool:
  subagent_type: codex-review:issue-handler
  prompt: |
    REVIEW_TYPE: plan
    CODEX_OUTPUT_PATH: [output file from Phase 2]
    PLAN_PATH: [the plan file path]
    OUTPUT_PATH: [directory of CODEX_OUTPUT_PATH]/plan-review-validated-[timestamp].md
    MODE: [fix if FIX_MODE=true, otherwise validate]
```

**Example:** If `CODEX_OUTPUT_PATH` is `.codex-review/plan-review-my-feature-2025-01-15.md`,
then `OUTPUT_PATH` would be `.codex-review/plan-review-validated-2025-01-15-143022.md`.

**MODE Selection:**

- If `--fix` or `--auto --fix`: `MODE: fix` (agent creates `.bak` backup and applies fixes)
- Otherwise: `MODE: validate` (validate only, no edits)

The agent uses Opus to deeply analyze Codex findings against the plan.

---

## Phase 4: Present Results

1. Read the validated review file
2. Present a summary to the user:

```text
## Codex Plan Review Summary

**Plan:** [plan file name]
**Review Date:** [timestamp]
**Mode:** [validate|fix]

### Fixes Applied
[If FIX_MODE and fixes were applied: list what was fixed with section references]
[If FIX_MODE but no fixes applied: "No automatic fixes were applied — all concerns require manual review."]

### Validated Concerns
[List concerns that align with coding principles]

### Suggestions
[Actionable suggestions from Codex]

### Dismissed Items
[Items filtered out with reasons]

---
Full report: [validated output path]
```

If `--fix` and fixes were applied, add a note after the summary:

> N fixes applied to plan file. Backup saved as `[PLAN_PATH].bak`.

If `--fix` but no fixes were applied, add:

> No automatic fixes were applied — all concerns require manual review.

If no `--fix`: do not mention fixes (existing behavior).

---

## Error Handling

- **Plan file not found**: Re-run list-plans.sh and ask user for correct path
- **Codex not available**: Suggest `npm install -g @openai/codex` and `codex auth`
- **Empty output**: Report error and suggest checking Codex authentication
