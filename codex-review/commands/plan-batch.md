---
description: Batch review and optionally fix multiple implementation plans using Codex
argument-hint: "[--auto] [--fix] <plan-paths...> | --glob <pattern>"
allowed-tools: ["Bash", "Read", "Task", "AskUserQuestion"]
---

**Do NOT read any plan files, codex output files, or validated reports.** All file I/O happens in scripts and agents. Pre-reading wastes tokens by duplicating content in the main context.

# Codex Batch Plan Review

Review multiple Claude Code implementation plans using OpenAI Codex as a second opinion.

## Prerequisites

- `codex` CLI must be installed and authenticated
- `jq` must be installed (for summary generation)
- Plan files must exist

## Flags

- `--auto`: Non-interactive mode. Deletes previous results, no prompts. Does NOT imply `--fix`.
- `--fix`: Apply valid fixes to plan files directly (agents use Edit tool). Requires explicit use.
- `--glob <pattern>`: Expand a glob pattern to find plan files.

Flag combinations:

- `--auto`: Review only, no prompts
- `--fix`: Review + fix, with prompts
- `--auto --fix`: Review + fix, no prompts

---

## Phase 1: Collect Plan Paths

Parse ARGUMENTS to extract flags and plan paths.

### If `--glob` is used

Expand the glob pattern to get plan file paths:

```bash
# Example: expand glob (handles spaces in filenames)
for f in PATTERN; do [[ -e "$f" ]] && printf '%s\n' "$f"; done
```

### If paths provided directly

Use the paths as-is. Verify at least one path was provided.

### If no paths provided

List recent plans for user selection:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/list-plans.sh"
```

Use AskUserQuestion to let user select plans (multiSelect: true).

---

## Phase 2: Run Batch Review Script

Run a single blocking call to the batch review script:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/plan-review-batch.sh" [--auto] PATH1 PATH2 PATH3 ...
```

Pass `--auto` if the user specified `--auto`.

**This is ONE blocking bash call.** Do not run plans individually. Do not use background execution or polling.

### Handle Exit Codes

- **Exit 0**: All plans reviewed successfully. Proceed to Phase 3.
- **Exit 2**: Partial failure — some plans failed. The last stdout line is `MANIFEST:<path>`.
  - If `--auto`: Report which plans failed, continue with successes.
  - If not `--auto`: Use AskUserQuestion:

    ```yaml
    AskUserQuestion:
      question: "Some plan reviews failed. Continue with the successful ones?"
      header: "Partial fail"
      options:
        - label: "Continue"
          description: "Process successful reviews, skip failures"
        - label: "Abort"
          description: "Cancel the batch review"
    ```

- **Exit 1**: All plans failed. Report the error and stop.

### Extract Manifest Path

The last line of stdout is `MANIFEST:<path>`. Extract the manifest path for subsequent phases.

---

## Phase 3: Spawn Validation Agent(s)

Determine agent count based on number of successful plans in the manifest.

### 5 or fewer successful plans: 1 agent

```yaml
Task tool:
  subagent_type: codex-review:issue-handler-batch
  prompt: |
    MANIFEST_PATH: [manifest path from Phase 2]
    OUTPUT_DIR: .codex-review
    MODE: [validate or fix]
```

Set MODE based on flags:

- User passed `--fix` → `MODE: fix`
- Otherwise → `MODE: validate`

### More than 5 successful plans: 2 agents (sharding)

Split the manifest into two sub-manifests by even/odd index:

1. Read the manifest file
2. Create two sub-manifests:
   - `MANIFEST-s1.json` — entries at indices 0, 2, 4, 6, ...
   - `MANIFEST-s2.json` — entries at indices 1, 3, 5, 7, ...
3. Write both sub-manifests using jq:

   ```bash
   jq '{"plans": [.plans | to_entries[] | select(.key % 2 == 0) | .value]}' MANIFEST
   jq '{"plans": [.plans | to_entries[] | select(.key % 2 == 1) | .value]}' MANIFEST
   ```

4. Spawn 2 agents in parallel, each with their sub-manifest:

```yaml
Task tool (agent 1):
  subagent_type: codex-review:issue-handler-batch
  prompt: |
    MANIFEST_PATH: [path to sub-manifest-s1.json]
    OUTPUT_DIR: .codex-review
    MODE: [validate or fix]

Task tool (agent 2):
  subagent_type: codex-review:issue-handler-batch
  prompt: |
    MANIFEST_PATH: [path to sub-manifest-s2.json]
    OUTPUT_DIR: .codex-review
    MODE: [validate or fix]
```

**Do NOT read any output files from the agents.** They write reports to files and return "Done".

---

## Phase 4: Print Summary

Run the summary script with the original manifest path:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/plan-review-summary.sh" [manifest path]
```

Print the script's stdout directly to the user. **Do NOT read any report files** — the summary script extracts counts from .meta.json sidecars.

If `--fix` was used, add a note:

```text
Fixes have been applied to plan files. Backup files (.bak) were created before editing.
```

---

## Error Handling

- **No plan files found**: Report error and suggest providing paths or using `--glob`
- **Codex not available**: Suggest `npm install -g @openai/codex` and `codex auth`
- **jq not available**: Suggest installation for summary generation
- **Agent returns error**: Report which plans failed validation
