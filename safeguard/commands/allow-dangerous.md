---
description: One-time bypass for the next dangerous command in a specific category
arguments:
  - name: category
    description: The protection category to allow
    required: true
---

# Allow Dangerous Command

You are setting a one-time bypass flag for the safeguard plugin.

## Instructions

1. Validate the category argument is one of:
   - `system-destruction`
   - `system-control`
   - `git-commits`
   - `git-pushes`
   - `git-destructive`
   - `remote-code-exec`
   - `database-destructive`
   - `network-exfil`
   - `containers`

2. If invalid, list the valid categories and ask the user to specify.

3. **REQUIRED: Use AskUserQuestion to get explicit user confirmation:**
   - Question: "Allow a **{{category}}** command to bypass safeguard protection?"
   - Options: "No, keep it blocked" (first/default), "Yes, allow one time"
   - If user selects "No", stop here and do NOT create the flag
   - Only proceed to step 4 if user explicitly selects "Yes"

4. If user confirmed, create the allow flag file:

```bash
# Create the safeguard config directory if needed
CONFIG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/.safeguard"
mkdir -p "$CONFIG_DIR"

# Create the timestamped flag file
echo "$(date +%s)" > "$CONFIG_DIR/.allow-{{category}}"
```

1. Confirm to the user: "Safeguard bypass enabled for **{{category}}**.
   The next command in this category will be allowed.
   This expires in 60 seconds or after one use."

1. Now retry the original command that was blocked.

## Important

- This flag is consumed after ONE command is allowed
- The flag expires after 60 seconds as a safety measure
- Each category requires its own allow flag
