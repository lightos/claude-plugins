---
description: Run Codex code review on uncommitted changes
argument-hint: "[--auto] [project-path]"
allowed-tools: ["Bash", "Read", "Task", "AskUserQuestion"]
---

# Codex Code Review

Review uncommitted code changes using OpenAI Codex as a second opinion.

## Prerequisites

- `codex` CLI must be installed and authenticated
- Target directory must be a git repository with uncommitted changes

## Flags

- `--auto`: Non-interactive mode. Deletes previous results, applies fixes, no prompts.

---

## Phase 1: Run Review Script

Parse arguments to check for `--auto` flag:

- If ARGUMENTS contains `--auto`: set AUTO_MODE=true
- Extract project path (default: current directory)

Execute the code review script:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/code-review.sh" [--auto] "${PROJECT_PATH:-.}"
```

### Handle Script Output

On success, the script (`code-review.sh`) outputs one of:

1. `EXISTS:/path/to/existing/file.md` - Previous results found
2. `/path/to/new/file.md` - New scan completed

On failure, the script writes error messages to stderr and exits with a non-zero
exit code. Do not parse stdout for errors.

### If EXISTS Response (and not --auto)

The script found existing results. Ask the user:

```yaml
AskUserQuestion:
  question: "Previous code review results found. What would you like to do?"
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

## Phase 2: Validate and Handle Issues

Spawn the issue-handler agent to validate Codex findings:

```yaml
Task tool:
  subagent_type: codex-review:issue-handler
  prompt: |
    REVIEW_TYPE: code
    CODEX_OUTPUT_PATH: [output file from Phase 1]
    OUTPUT_PATH: [directory of CODEX_OUTPUT_PATH]/code-review-validated-[timestamp].md
    MODE: [fix if --auto, otherwise validate]
```

**Example:** If `CODEX_OUTPUT_PATH` is `.codex-review/code-review-2025-01-15.md`,
then `OUTPUT_PATH` would be `.codex-review/code-review-validated-2025-01-15-143022.md`.

**MODE Selection:**

- If user ran `/codex-review:code --auto`: `MODE: fix` (agent applies fixes)
- If user ran `/codex-review:code` (default): `MODE: validate` (validate only)

The agent uses Opus to deeply analyze Codex findings against actual code.

---

## Phase 3: Present Results

1. Read the validated review file
2. Present a summary to the user:

```text
## Codex Code Review Summary

**Changes Reviewed:** [from git diff --stat]
**Review Date:** [timestamp]
**Mode:** [validate|fix]

### Fixes Applied
[If MODE: fix, list what was fixed with file:line references]

### Flagged for Manual Review
[Issues that need user attention]

### Validated Concerns
[List concerns with file:line references]

### Security Findings
[Any security-related issues]

### Suggestions
[Actionable suggestions]

### Dismissed Items
[Items filtered out with reasons]

---
Full report: [validated output path]
```

---

## Error Handling

- **Not a git repo**: Inform user to run from within a git repository
- **No changes**: Inform user no uncommitted changes found
- **Codex not available**: Suggest `npm install -g @openai/codex` and `codex auth`
