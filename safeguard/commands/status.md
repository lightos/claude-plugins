---
description: Show current safeguard protection status
---

# Safeguard Status

Show the current status of all safeguard protections.

## Instructions

1. Read and display the current configuration:

```bash
CONFIG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/.safeguard"
CONFIG_FILE="$CONFIG_DIR/config.json"

echo "=== Safeguard Protection Status ==="
echo ""

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Configuration file: $CONFIG_FILE"
    echo ""
    # Show all known categories, merging config values with defaults for new categories
    for cat in system-destruction system-control git-commits git-pushes git-destructive remote-code-exec database-destructive network-exfil containers; do
        val=$(jq -r ".enabled[\"$cat\"] // empty" "$CONFIG_FILE" 2>/dev/null)
        if [[ "$val" == "true" ]]; then
            echo "$cat: ON"
        elif [[ "$val" == "false" ]]; then
            echo "$cat: OFF"
        else
            echo "$cat: not configured (OFF)"
        fi
    done
else
    echo "No custom configuration found. Using defaults:"
    echo ""
    echo "system-destruction: ON (default)"
    echo "system-control: ON (default)"
    echo "git-commits: ON (default)"
    echo "git-pushes: ON (default)"
    echo "git-destructive: ON (default)"
    echo "remote-code-exec: ON (default)"
    echo "database-destructive: ON (default)"
    echo "network-exfil: OFF (default)"
    echo "containers: OFF (default)"
fi

echo ""
echo "=== Active Allow Flags ==="
if [[ -d "$CONFIG_DIR" ]]; then
    flags=$(ls -la "$CONFIG_DIR"/.allow-* 2>/dev/null || true)
    if [[ -n "$flags" ]]; then
        echo "$flags"
    else
        echo "No active bypass flags."
    fi
else
    echo "No active bypass flags."
fi
```

1. Format the output nicely for the user, showing:
   - Which categories are enabled vs disabled
   - Any active one-time bypass flags
   - The config file location

1. Remind the user they can use `/safeguard:config` to change settings or
   `/safeguard:allow-dangerous <category>` for one-time bypasses.
