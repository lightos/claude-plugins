---
name: config
description: Configure safeguard protection categories interactively
---

# Configure Safeguard Protections

You are configuring the safeguard plugin's protection categories.

## Protection Categories

| Category           | Description                                      | Default |
|--------------------|--------------------------------------------------|---------|
| system-destruction | rm -rf, dd to disk, mkfs, fork bombs, shred      | ON      |
| system-control     | shutdown, reboot, kill init, chmod/chown on root | ON      |
| git-commits        | All git commit commands                          | ON      |
| git-pushes         | All git push commands                            | ON      |
| git-destructive    | reset --hard, clean -f, force push, branch -D    | ON      |
| remote-code-exec   | curl\|sh, wget\|bash, piped URLs to shell        | ON      |
| network-exfil      | scp, rsync, netcat, curl POST with files         | OFF     |
| containers         | docker rm/rmi -f, kubectl delete, prune          | OFF     |

## Instructions

1. First, read the current config if it exists:

```bash
CONFIG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/.safeguard"
CONFIG_FILE="$CONFIG_DIR/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
    cat "$CONFIG_FILE"
fi
```

2. Use AskUserQuestion to ask about EACH category sequentially.
   For each category, ask:

   "Enable **{category}** protection? ({description})"

   Options:
   - "Keep enabled" or "Enable" (depending on current state)
   - "Disable"

3. After all questions, write the config:

```bash
CONFIG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/.safeguard"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.json" << 'EOF'
{
  "enabled": {
    "system-destruction": true,
    "system-control": true,
    "git-commits": true,
    "git-pushes": true,
    "git-destructive": true,
    "remote-code-exec": true,
    "network-exfil": false,
    "containers": false
  }
}
EOF
```

(Replace true/false based on user's choices)

4. Show final summary of enabled/disabled categories.

## Quick Configuration Options

If the user wants to skip the interactive flow, offer these presets:

- **"strict"** - All categories ON
- **"standard"** - All except network-exfil and containers (default)
- **"git-only"** - Only git-related categories
- **"minimal"** - Only system-destruction and system-control
- **"off"** - All categories OFF (not recommended)
