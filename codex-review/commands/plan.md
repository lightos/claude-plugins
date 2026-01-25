---
description: Get a second-opinion review of a Claude Code implementation plan
argument-hint: "[--auto] <plan-file-path>"
allowed-tools: ["Bash", "Read", "Task", "AskUserQuestion"]
---

# Codex Plan Review

Review a Claude Code implementation plan using OpenAI Codex as a second opinion.

## Prerequisites

- `codex` CLI must be installed and authenticated
- Plan file must exist

## Flags

- `--auto`: Non-interactive mode. Deletes previous results, no prompts.

---

## Phase 1: Locate Plan File

Parse arguments to check for `--auto` flag:

- If ARGUMENTS contains `--auto`: set AUTO_MODE=true
- Extract plan path from remaining arguments

### If Path Provided

If the user provided a path argument, proceed directly to Phase 2.

**Do NOT read the plan file** - the script validates existence and returns clear errors.

### If No Path Provided

List recent plans for user selection:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/list-plans.sh"
```

Use AskUserQuestion to let user select a plan from the list.

---

## Phase 2: Run Review Script

Execute the plan review script:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/plan-review.sh" [--auto] "[PLAN_PATH]"
```

**Timeout:** Use `timeout: 600000` (10 minutes) when calling the Bash tool.

### Handle Script Output

On success, the script (`plan-review.sh`) outputs one of:

1. `EXISTS:/path/to/existing/file.md` - Previous results found for this plan
2. `/path/to/new/file.md` - New scan completed

On failure, the script writes error messages to stderr and exits with a non-zero
exit code. Do not parse stdout for errors.

### If EXISTS Response (and not --auto)

The script found existing results for this plan. Ask the user:

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

## Phase 3: Validate with Issue Handler

Spawn the issue-handler agent to validate Codex findings:

```yaml
Task tool:
  subagent_type: codex-review:issue-handler
  prompt: |
    REVIEW_TYPE: plan
    CODEX_OUTPUT_PATH: [output file from Phase 2]
    PLAN_PATH: [the plan file path]
    OUTPUT_PATH: [directory of CODEX_OUTPUT_PATH]/plan-review-validated-[timestamp].md
    MODE: validate
```

**Example:** If `CODEX_OUTPUT_PATH` is `.codex-review/plan-review-my-feature-2025-01-15.md`,
then `OUTPUT_PATH` would be `.codex-review/plan-review-validated-2025-01-15-143022.md`.

**Note:** Plan reviews always use `MODE: validate` - autofix does not apply to plans.

The agent uses Opus to deeply analyze Codex findings against the plan.

---

## Phase 4: Present Results

1. Read the validated review file
2. Present a summary to the user:

```text
## Codex Plan Review Summary

**Plan:** [plan file name]
**Review Date:** [timestamp]

### Validated Concerns
[List concerns that align with coding principles]

### Suggestions
[Actionable suggestions from Codex]

### Dismissed Items
[Items filtered out with reasons]

---
Full report: [validated output path]
```

---

## Error Handling

- **Plan file not found**: Re-run list-plans.sh and ask user for correct path
- **Codex not available**: Suggest `npm install -g @openai/codex` and `codex auth`
- **Empty output**: Report error and suggest checking Codex authentication
