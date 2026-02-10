---
name: review
description: Runs Codex CLI to review code changes, validate plans, or review GitHub Pull Requests via automated command execution
---

# Codex Review Skill

This skill runs automated code reviews using OpenAI's Codex CLI.

## When to Use

Trigger this skill when the user:

- Wants to run automated code review via Codex CLI
- Mentions reviewing uncommitted changes
- Asks for external validation of their work
- Wants to check their implementation plan before proceeding
- Says "run codex review" or "code review"
- Wants to review a GitHub Pull Request

## CRITICAL: Do NOT Pre-Read Files

Before invoking any review command:

- Do NOT read plan files, code files, or any content that will be reviewed
- Do NOT read research documents, context files, or supporting materials
- The review scripts and agents handle all file reading internally
- Pre-reading wastes tokens by duplicating content in the main context

## Determine Review Type

When invoked, determine which review type is appropriate:

### Code Review

Use when the user:

- Has uncommitted changes and wants them reviewed
- Asks for a code review or second opinion on changes
- Mentions "review my diff" or similar

**Run:** `/codex-review:code` command

### Plan Review

Use when the user:

- Has a plan file and wants it validated
- Asks for feedback on an implementation plan
- Mentions "review my plan" or similar

Do NOT read the plan files first. Pass paths only.

**Single plan** (e.g., "review this plan", "review fancy-giggling-sun"):
**Run:** `/codex-review:plan <path>`

**Multiple plans** (e.g., "review all my plans", "review plans/*.md", "review these 9 plans"):
**Run:** `/codex-review:plan-batch`

If ambiguous whether single or batch, ask the user which mode.

### Pull Request Review

Use when the user:

- Mentions a PR number (e.g., "review PR #123", "check PR 45")
- Asks for a pull request review
- Mentions "review this PR" or similar

**Run:** `/codex-review:code --pr <number>` command

Extract the PR number from the user's message and pass it to the command.

## Clarification

If unclear which type the user needs, ask:

```yaml
AskUserQuestion:
  question: "What would you like me to review with Codex?"
  header: "Review Type"
  options:
    - label: "Code changes"
      description: "Review uncommitted git changes"
    - label: "Pull Request"
      description: "Review a GitHub PR by number"
    - label: "Implementation plan"
      description: "Review a plan file before implementation"
```

## Auto Mode

If the user explicitly wants fixes applied automatically, or wants no prompts:

- For code: `/codex-review:code --auto`
- For single plan: `/codex-review:plan --auto`
- For multiple plans: `/codex-review:plan-batch --auto`
- For multiple plans with fixes: `/codex-review:plan-batch --auto --fix`

## Scope Limitation

When executing reviews:

- Do NOT spawn additional agents outside this plugin's defined agents
- Do NOT launch explore/validation tasks beyond what the commands specify
- The issue-handler agent handles all validation — do not duplicate this work
