---
description: Run Codex code review on codebase, uncommitted changes, branch comparison, or GitHub PR
argument-hint: "[--auto] [--full|--base <branch>|--commit <sha>|--range <sha>..<sha>|--pr [number]] [project-path]"
allowed-tools: ["Bash", "Read", "Task", "AskUserQuestion"]
---

# Codex Code Review

Review code changes using OpenAI Codex as a second opinion.

## Prerequisites

- `codex` CLI must be installed and authenticated
- Target directory must be a git repository
- For PR reviews: `gh` CLI installed and authenticated (`gh auth login`)

## Flags

- `--auto`: Non-interactive mode. Deletes previous results, applies fixes, no prompts.
- `--full`: Scan all git-tracked files (not just changes). May timeout on large codebases.
- `--base <branch>`: Compare current HEAD against specified branch (e.g., `--base main`).
- `--commit <sha>`: Review changes introduced by a specific commit.
- `--range <sha1>..<sha2>`: Review changes in a commit range. Use `..` for tree-to-tree diff, `...` for PR-style (merge-base) diff.
- `--pr [number]`: Review a GitHub Pull Request by number. If no number provided, lists recent PRs for interactive selection. Requires `gh` CLI authenticated.

---

## Phase 1: Run Review Script

Parse arguments:

- If ARGUMENTS contains `--auto`: set AUTO_FLAG="--auto"
- If ARGUMENTS contains `--full`: set FULL_FLAG="--full"
- If ARGUMENTS contains `--base <branch>`: set BASE_FLAG="--base \<branch\>"
- If ARGUMENTS contains `--commit <sha>`: set COMMIT_FLAG="--commit \<sha\>"
- If ARGUMENTS contains `--range <sha>..<sha>`: set RANGE_FLAG="--range \<range\>"
- If ARGUMENTS contains `--pr <N>`: set PR_FLAG="--pr \<N\>"
- If ARGUMENTS contains `--pr` without number: set PR_FLAG="--pr"
- Extract project path (default: current directory)

### Execution Strategy

**For standard reviews (default, --base, uncommitted):**
Run the script directly. Most reviews complete within the Bash tool's 10-minute limit.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/code-review.sh" ${AUTO_FLAG} ${BASE_FLAG} "${PROJECT_PATH:-.}"
```

**For full codebase scans (--full flag):**
Full scans can exceed 10 minutes on large codebases. Run in background and inform user:

```bash
# Use run_in_background: true
"${CLAUDE_PLUGIN_ROOT}/scripts/code-review.sh" --auto --full "${PROJECT_PATH:-.}"
```

After starting the background task, inform the user:
> "Full codebase scan started in background. This may take 10-30 minutes.
> Check back with 'check on my code review' or re-run this command to see results."

Then **end your turn** - do NOT poll or use TaskOutput.
When user checks back, look for existing results in `.codex-review/`.

The script runs with a 30-minute internal timeout (configurable via `CODEX_REVIEW_TIMEOUT_SECONDS`).

### Handle Script Output

On success, the script (`code-review.sh`) outputs one of:

1. `EXISTS:/path/to/existing/file.md` - Previous results found
2. `/path/to/new/file.md` - New scan completed

The script also outputs status to stderr:

- `MODE:full (<N> files)` - Scanning all git-tracked files
- `MODE:commit:<sha>` - Reviewing single commit
- `MODE:range:<sha1>..<sha2> (<N> commits)` - Reviewing commit range
- `MODE:uncommitted` - Reviewing uncommitted changes
- `MODE:base:<branch> (<N> commits)` - Reviewing commits vs base
- `MODE:base:<branch> (<N> commits, auto-detected)` - Auto-detected base
- `MODE:pr:#<number> (<N> files, +A/-D)` - Reviewing Pull Request
- `SELECT_PR:` - Interactive PR selection needed (script exits 0)
- `WARNING: Uncommitted changes will be included in scan` - When --full with dirty tree
- `WARNING: Uncommitted changes ignored (using --commit)` - When --commit overrides
- `WARNING: Uncommitted changes ignored (using --range)` - When --range overrides
- `WARNING: Uncommitted changes ignored (using --pr)` - When --pr overrides
- `WARNING: Uncommitted changes exist but will be ignored` - When --base overrides
- `WARNING: Merge commit - showing first-parent diff` - When --commit targets a merge
- `WARNING: PR is CLOSED` or `WARNING: PR is MERGED` - PR state warning
- `INFO: PR is from a fork` - PR is from a forked repository

On failure, the script writes error messages to stderr:

- `ERROR:NO_CHANGES: <message>` - No changes to review
- `ERROR:NO_BASE: <message>` - Could not detect base branch
- `ERROR:EMPTY_RANGE: <message>` - No changes in specified range
- `ERROR: Commit '<sha>' not found or ambiguous` - Invalid commit SHA
- `ERROR: PR #<number> not found or inaccessible` - PR doesn't exist or no access
- `ERROR: gh CLI not found` - GitHub CLI not installed
- `ERROR: gh CLI not authenticated` - Need to run `gh auth login`
- `ERROR: Failed to get PR diff` - Could not retrieve PR diff
- `ERROR: <message>` - General errors

### If ERROR:NO_CHANGES or ERROR:NO_BASE Response

When the script returns `ERROR:NO_CHANGES` or `ERROR:NO_BASE`, offer the user options:

```yaml
AskUserQuestion:
  question: "No changes detected. Would you like to specify a base branch for comparison?"
  header: "No changes"
  options:
    - label: "Specify base branch"
      description: "Enter a branch name to compare against (e.g., main, develop)"
    - label: "Abort"
      description: "Cancel the review"
```

If "Specify base branch": Ask for branch name, then re-run with `--base <branch>`
If "Abort": Stop and inform user

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

### If SELECT_PR Response

The script outputs `SELECT_PR:` when `--pr` is used without a number. Run the list-prs script to get recent PRs:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/list-prs.sh" "${PROJECT_PATH:-.}"
```

Then use AskUserQuestion to let user select a PR:

```yaml
AskUserQuestion:
  question: "Which Pull Request would you like to review?"
  header: "Select PR"
  options:
    - label: "#123 [OPEN] feature-branch: Add new feature"
      description: "Review PR #123"
    # ... (generate from list-prs.sh output, up to 4 options)
```

Extract the PR number from selection (e.g., "#123" → "123") and re-run the script with `--pr <number>`.

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
- **No changes (ERROR:NO_CHANGES)**: Offer to specify a base branch for comparison
- **No base branch (ERROR:NO_BASE)**: Offer to specify a base branch manually
- **Branch not found**: Inform user the specified branch doesn't exist
- **Codex not available**: Suggest `npm install -g @openai/codex` and `codex auth`
