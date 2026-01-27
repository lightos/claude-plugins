---
name: second-opinion
description: Consult Codex for advisory second opinion on technical decisions - use for guidance, not automated CLI execution
---

# Second Opinion Skill

This skill teaches Claude when and how to consult Codex for independent
technical perspectives on decisions.

## When to Use Proactively

Consult Codex automatically when you encounter:

### Architectural Decisions

- Choosing between design patterns
- Deciding on data flow approaches
- Structuring complex features
- Planning major refactors

### Unfamiliar Territory

- Working with technologies you have limited experience with
- Implementing patterns you haven't used before
- Dealing with edge cases that have non-obvious solutions

### High-Stakes Changes

- Security-sensitive implementations
- Performance-critical code paths
- Changes affecting many downstream consumers
- Breaking changes to public APIs

### Explicit Uncertainty

- When you catch yourself saying "I think" or "probably"
- When multiple approaches seem equally valid
- When you're unsure about best practices in a specific domain

## User Triggers

Invoke this skill when the user says:

- "Ask Codex"
- "Get a second opinion"
- "What would Codex say"
- "Check with Codex"
- "Consult Codex about this"
- "Consult Codex to review..." (advisory, not CLI execution)
- "Ask Codex to review..." (advisory, not CLI execution)
- "Get Codex's perspective on..."
- "What does Codex think about..."

## How to Frame the Query

When consulting Codex, you must extract and frame the problem correctly:

### DO: Extract Problem + Constraints

```text
PROBLEM: Need to implement rate limiting for API endpoints
CONSTRAINTS: Using Express.js, must support per-user and global limits,
             need Redis for distributed state, must handle burst traffic
FOCUS: architecture
```

### DON'T: Include Your Current Approach

Avoid biasing Codex by describing what you were planning to do. Keep the
query focused on the problem and constraints, not your solution.

### Choose the Right Focus Area

| Focus | Use When |
|-------|----------|
| security | Authentication, authorization, data handling, input validation |
| performance | Scalability, caching, optimization, resource management |
| architecture | Design patterns, structure, separation of concerns, extensibility |
| general | Unclear which area dominates, or all areas matter equally |

## Invoking the Consultant

Use the Task tool to launch the consultant agent:

```text
Task: consultant agent
Prompt: PROBLEM: [problem statement] | CONSTRAINTS: [constraints] | FOCUS: [focus area]
```

The agent will:

1. Query Codex with a structured prompt
2. Save the response to `.codex-review/second-opinion-[timestamp].md`
3. Return "Done"

## Post-Response Handling

After receiving the Codex response:

### Silent Synthesis (Default)

When using proactively:

1. Read the saved output file
2. Compare Codex's recommendation with your planned approach
3. If aligned: proceed with your approach, confidence validated
4. If minor differences: incorporate useful suggestions silently
5. If major conflict: pause and reconsider your approach

Do NOT announce "Codex agreed with me" or "I consulted Codex and..."
unless there's a significant insight worth surfacing.

### Surface Major Conflicts

Only mention the consultation when:

- Codex identified a significant risk you missed
- Codex's approach is substantially different and worth discussing
- The user explicitly asked for Codex's opinion

In these cases, present the conflict:

```text
I consulted Codex on this decision and there's a notable difference in
approach worth considering:

**My approach:** [brief summary]
**Codex suggests:** [brief summary]
**Key difference:** [what matters]

[Your recommendation on how to proceed]
```

### User-Triggered Queries

When the user explicitly asks for Codex's opinion:

1. Run the consultation
2. Present the full structured output to the user
3. Offer your synthesis/recommendation

## Examples

### Proactive: Architecture Decision

```text
[Claude is planning a caching layer]

Internal thought: I'm considering Redis with write-through caching, but
this is a high-stakes decision with multiple valid approaches.

[Invokes consultant with FOCUS: architecture]

[Reads response, sees Codex also recommends write-through but suggests
considering cache-aside for specific read-heavy endpoints]

[Proceeds with write-through, notes cache-aside option for later optimization]
```

### User-Triggered: Explicit Request

```text
User: "Ask Codex what it thinks about using GraphQL here"

[Invokes consultant]

Claude: "Here's Codex's perspective on using GraphQL for this API:

**Recommended Approach:** [summary]
**Concerns:** [key points]
**Alternatives:** [brief list]

Based on this and our specific requirements, I recommend..."
```

### Proactive: Uncertainty

```text
[Claude is implementing OAuth integration]

Internal thought: I'm not sure whether to use PKCE or standard OAuth flow
for this mobile app scenario.

[Invokes consultant with FOCUS: security]

[Reads response, Codex strongly recommends PKCE for mobile clients]

[Proceeds with PKCE, doesn't mention consultation unless relevant]
```

## Important Notes

- Keep queries focused on the specific decision, not the entire project
- Don't over-consult - reserve for genuinely uncertain or high-stakes decisions
- The goal is bias-free input, so never describe your planned solution
- Synthesis should be invisible unless there's actionable insight for the user
