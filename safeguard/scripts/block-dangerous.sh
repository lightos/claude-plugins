#!/usr/bin/env bash
set -uo pipefail

# Safeguard - Block dangerous bash commands
# Reads tool input JSON from stdin, outputs decision JSON to stdout

# Check bash version (need 4+ for associative arrays)
if ((BASH_VERSINFO[0] < 4)); then
    echo '{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"ERROR: safeguard plugin requires Bash 4+. macOS users: brew install bash"}'
    exit 0
fi

# Check for jq dependency
if ! command -v jq &>/dev/null; then
    echo '{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"ERROR: safeguard plugin requires jq. Install with: brew install jq (macOS) or apt install jq (Linux)"}'
    exit 0
fi

# Read tool input from stdin
TOOL_INPUT=$(cat)

# Extract command from tool input
COMMAND=$(echo "$TOOL_INPUT" | jq -r '.tool_input.command // empty')

if [[ -z "$COMMAND" ]]; then
    # No command found, allow
    echo '{}'
    exit 0
fi

# Find config directory (with fallback)
find_config_dir() {
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && [[ -d "$CLAUDE_PROJECT_DIR/.claude" ]]; then
        echo "$CLAUDE_PROJECT_DIR/.claude/.safeguard"
    elif [[ -d "$PWD/.claude" ]]; then
        echo "$PWD/.claude/.safeguard"
    else
        echo "$HOME/.claude/.safeguard"
    fi
}

CONFIG_DIR=$(find_config_dir)
CONFIG_FILE="$CONFIG_DIR/config.json"

# Default protection settings (all ON except network-exfil and containers)
declare -A DEFAULT_ENABLED=(
    ["system-destruction"]=true
    ["system-control"]=true
    ["git-commits"]=true
    ["git-pushes"]=true
    ["git-destructive"]=true
    ["remote-code-exec"]=true
    ["network-exfil"]=false
    ["containers"]=false
)

# Load config or use defaults
is_category_enabled() {
    local category="$1"
    if [[ -f "$CONFIG_FILE" ]]; then
        local enabled
        # Use | tostring to handle booleans properly (jq's // treats false as falsy)
        enabled=$(jq -r ".enabled[\"$category\"] | tostring" "$CONFIG_FILE" 2>/dev/null)
        if [[ "$enabled" == "true" ]]; then
            return 0
        elif [[ "$enabled" == "false" ]]; then
            return 1
        fi
    fi
    # Use default
    [[ "${DEFAULT_ENABLED[$category]:-false}" == "true" ]]
}

# Check if category has a one-time allow flag
has_allow_flag() {
    local category="$1"
    local flag_file="$CONFIG_DIR/.allow-$category"
    local consumed_file="$CONFIG_DIR/.consumed-$category-$$"

    if [[ -f "$flag_file" ]]; then
        # Atomically try to consume the flag by renaming it
        # This prevents TOCTOU race conditions where multiple processes
        # could both read and consume the same flag
        if ! mv "$flag_file" "$consumed_file" 2>/dev/null; then
            # Another process consumed it first
            return 1
        fi

        # Check if flag is stale (older than 60 seconds)
        local now
        now=$(date +%s)
        local flag_time
        flag_time=$(cat "$consumed_file" 2>/dev/null || echo "0")

        # Validate flag_time is numeric
        if ! [[ "$flag_time" =~ ^[0-9]+$ ]]; then
            rm -f "$consumed_file"
            return 1
        fi

        if (( now - flag_time < 60 )); then
            # Flag is valid - already consumed by rename
            rm -f "$consumed_file"
            return 0
        else
            # Flag is stale, remove it
            rm -f "$consumed_file"
        fi
    fi
    return 1
}

# Output block message
block_command() {
    local category="$1"
    local risk_level="$2"
    local reason="$3"
    local escaped_cmd
    escaped_cmd=$(printf '%s' "$COMMAND" | sed 's/"/\\"/g' | head -c 500)

    local message="BLOCKED: \`$escaped_cmd\`

Category: $category
Risk Level: $risk_level
Reason: $reason

IMPORTANT: You MUST use AskUserQuestion to ask the user if they want to allow this command. Present two options:
1. 'No, cancel this operation' (MUST be first option, this is the default)
2. 'Yes, allow this one time'

If the user selects 'Yes', run /safeguard:allow-dangerous $category and then retry the original command."

    # Escape for JSON
    message=$(echo "$message" | jq -Rs .)

    echo "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"},\"systemMessage\":$message}"
    exit 0
}

# Check if allowed by flag
check_and_maybe_block() {
    local category="$1"
    local risk_level="$2"
    local reason="$3"

    if ! is_category_enabled "$category"; then
        return 1  # Category disabled, don't block
    fi

    if has_allow_flag "$category"; then
        return 1  # Has valid allow flag, don't block
    fi

    block_command "$category" "$risk_level" "$reason"
}

# Helper: check if command matches pattern (using bash built-in regex)
matches() {
    local pattern="$1"
    [[ "$COMMAND" =~ $pattern ]]
}

# ============================================================================
# PATTERN MATCHING (using bash built-in regex - no subprocess spawning)
# ============================================================================

# System Destruction (CRITICAL)
if is_category_enabled "system-destruction"; then
    # rm -rf on dangerous paths
    pattern='rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|[a-zA-Z]*f[a-zA-Z]*r)[a-zA-Z]*[[:space:]]+(/|~|\$HOME|/etc|/usr|/var|/bin|/sbin|/lib|/boot|/dev|/proc|/sys)([[:space:]]|$|/)'
    if matches "$pattern"; then
        check_and_maybe_block "system-destruction" "CRITICAL" "Recursive forced deletion of critical system paths can destroy your entire system."
    fi

    # rm -rf . (current directory) - but NOT ./something
    pattern='rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|[a-zA-Z]*f[a-zA-Z]*r)[a-zA-Z]*[[:space:]]+\.([[:space:]]|$)'
    if matches "$pattern"; then
        check_and_maybe_block "system-destruction" "CRITICAL" "Recursive forced deletion of current directory can destroy your project."
    fi

    # dd writing to disk devices (Linux: sd/hd/nvme/vd/mmcblk, macOS: disk)
    pattern='dd[[:space:]]+.*of=/dev/(sd[a-z]|hd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z]|mmcblk[0-9]+|disk[0-9]+)'
    if matches "$pattern"; then
        check_and_maybe_block "system-destruction" "CRITICAL" "Writing directly to disk devices can corrupt or destroy all data."
    fi

    # mkfs on real devices
    pattern='mkfs(\.[a-z0-9]+)?[[:space:]]+.*(/dev/(sd[a-z]|hd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z]|mmcblk[0-9]+|disk[0-9]+))'
    if matches "$pattern"; then
        check_and_maybe_block "system-destruction" "CRITICAL" "Formatting disk devices destroys all data on them."
    fi

    # Fork bombs
    pattern=':\(\)[[:space:]]*\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:[[:space:]]*&[[:space:]]*\}[[:space:]]*;?[[:space:]]*:'
    if matches "$pattern"; then
        check_and_maybe_block "system-destruction" "CRITICAL" "Fork bombs crash the system by exhausting process limits."
    fi

    # Redirect to disk device
    pattern='>[[:space:]]*/dev/(sd[a-z]|hd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z]|mmcblk[0-9]+|disk[0-9]+)'
    if matches "$pattern"; then
        check_and_maybe_block "system-destruction" "CRITICAL" "Redirecting output to disk devices can corrupt the filesystem."
    fi

    # shred on system files
    pattern='shred[[:space:]]+.*(/etc|/usr|/var|/bin|/sbin|/lib|/boot)'
    if matches "$pattern"; then
        check_and_maybe_block "system-destruction" "CRITICAL" "Shredding system files makes recovery impossible."
    fi

    # wipefs
    pattern='wipefs[[:space:]]+.*(/dev/(sd[a-z]|hd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z]|mmcblk[0-9]+|disk[0-9]+))'
    if matches "$pattern"; then
        check_and_maybe_block "system-destruction" "CRITICAL" "Wiping filesystem signatures destroys partition data."
    fi
fi

# System Control (CRITICAL)
if is_category_enabled "system-control"; then
    # Shutdown/reboot commands
    pattern='(^|[^[:alnum:]_])(shutdown|reboot|halt|poweroff)([^[:alnum:]_]|$)'
    if matches "$pattern"; then
        check_and_maybe_block "system-control" "CRITICAL" "System power commands will interrupt all running processes."
    fi

    # Kill init process
    pattern='kill[[:space:]]+(-[0-9]+[[:space:]]+)?1([^0-9]|$)|kill[[:space:]]+-9[[:space:]]+1([^0-9]|$)'
    if matches "$pattern"; then
        check_and_maybe_block "system-control" "CRITICAL" "Killing PID 1 (init) will crash the entire system."
    fi

    # Recursive chmod on root or system dirs
    pattern='chmod[[:space:]]+(-[a-zA-Z]*R[a-zA-Z]*[[:space:]]+|[a-zA-Z]*R[a-zA-Z]*[[:space:]]+.*)(777|666)[[:space:]]+(/|/etc|/usr|/var|/bin|/sbin)'
    if matches "$pattern"; then
        check_and_maybe_block "system-control" "CRITICAL" "Recursive permission changes on system directories can break security."
    fi

    # Recursive chown on system dirs
    pattern='chown[[:space:]]+-[a-zA-Z]*R[a-zA-Z]*[[:space:]]+[^[:space:]]+[[:space:]]+(/|/etc|/usr|/var|/bin|/sbin)([[:space:]]|$)'
    if matches "$pattern"; then
        check_and_maybe_block "system-control" "CRITICAL" "Recursive ownership changes on system directories can break the system."
    fi

    # Flush iptables
    pattern='iptables[[:space:]]+-F'
    if matches "$pattern"; then
        check_and_maybe_block "system-control" "HIGH" "Flushing iptables removes all firewall rules, exposing the system."
    fi

    # Stop critical services
    pattern='systemctl[[:space:]]+stop[[:space:]]+(sshd|systemd|init|dbus|NetworkManager)'
    if matches "$pattern"; then
        check_and_maybe_block "system-control" "HIGH" "Stopping critical system services can make the system unusable."
    fi
fi

# Git Commits (HIGH)
if is_category_enabled "git-commits"; then
    pattern='(^|[^[:alnum:]_])git[[:space:]]+commit([^[:alnum:]_]|$)'
    if matches "$pattern"; then
        check_and_maybe_block "git-commits" "HIGH" "Git commits should only be made when explicitly requested to ensure proper review."
    fi
fi

# Git Pushes (HIGH)
if is_category_enabled "git-pushes"; then
    pattern='(^|[^[:alnum:]_])git[[:space:]]+push([^[:alnum:]_]|$)'
    if matches "$pattern"; then
        # All pushes require permission (including --force-with-lease)
        check_and_maybe_block "git-pushes" "HIGH" "Git pushes can affect remote repositories and should only be done when explicitly requested."
    fi
fi

# Git Destructive Operations (HIGH)
if is_category_enabled "git-destructive"; then
    # git reset --hard
    pattern='git[[:space:]]+reset[[:space:]]+--hard'
    if matches "$pattern"; then
        check_and_maybe_block "git-destructive" "HIGH" "Hard reset discards all uncommitted changes permanently."
    fi

    # git clean -f
    pattern='git[[:space:]]+clean[[:space:]]+(-[a-zA-Z]*f|[a-zA-Z]*f)'
    if matches "$pattern"; then
        check_and_maybe_block "git-destructive" "HIGH" "Git clean with force removes untracked files permanently."
    fi

    # Force push (without --force-with-lease)
    pattern_force='git[[:space:]]+push[[:space:]]+.*(--force([[:space:]]|$)|[[:space:]]-f([[:space:]]|$))'
    pattern_force_with_lease='--force-with-lease'
    if matches "$pattern_force" && ! matches "$pattern_force_with_lease"; then
        check_and_maybe_block "git-destructive" "HIGH" "Force push without --force-with-lease can overwrite others' work."
    fi

    # git branch -D (force delete)
    pattern='git[[:space:]]+branch[[:space:]]+(-[a-zA-Z]*D|[a-zA-Z]*D)'
    if matches "$pattern"; then
        check_and_maybe_block "git-destructive" "HIGH" "Force deleting branches can lose work that hasn't been merged."
    fi

    # git tag -d
    pattern='git[[:space:]]+tag[[:space:]]+(-[a-zA-Z]*d|[a-zA-Z]*d)'
    if matches "$pattern"; then
        check_and_maybe_block "git-destructive" "MEDIUM" "Deleting tags can affect release history and deployments."
    fi

    # git merge --no-verify
    pattern='git[[:space:]]+merge[[:space:]]+.*--no-verify'
    if matches "$pattern"; then
        check_and_maybe_block "git-destructive" "MEDIUM" "Merging with --no-verify skips important pre-merge hooks."
    fi

    # git rebase
    pattern='(^|[^[:alnum:]_])git[[:space:]]+rebase([^[:alnum:]_]|$)'
    if matches "$pattern"; then
        check_and_maybe_block "git-destructive" "MEDIUM" "Rebasing rewrites history and can cause issues with shared branches."
    fi
fi

# Remote Code Execution (HIGH)
if is_category_enabled "remote-code-exec"; then
    # curl/wget piped to shell (including sudo/env variants)
    pattern='(curl|wget)[[:space:]]+.*\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?(/usr)?(/bin/)?(ba)?sh'
    if matches "$pattern"; then
        check_and_maybe_block "remote-code-exec" "HIGH" "Piping remote content to shell executes untrusted code."
    fi

    # Downloading and executing
    pattern='(curl|wget)[[:space:]]+.*;[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'
    if matches "$pattern"; then
        check_and_maybe_block "remote-code-exec" "HIGH" "Downloading and executing remote scripts is dangerous."
    fi
fi

# Network Exfiltration (HIGH) - OFF by default
if is_category_enabled "network-exfil"; then
    # scp - block all remote transfers except to localhost/127.0.0.1/::1
    pattern_scp='scp[[:space:]]'
    pattern_localhost='@(localhost|127\.0\.0\.1|::1):'
    if matches "$pattern_scp" && ! matches "$pattern_localhost"; then
        check_and_maybe_block "network-exfil" "HIGH" "SCP can transfer sensitive files to external hosts."
    fi

    # rsync - block all remote transfers except to localhost/127.0.0.1/::1
    pattern_rsync='rsync[[:space:]]+.*@'
    if matches "$pattern_rsync" && ! matches "$pattern_localhost"; then
        check_and_maybe_block "network-exfil" "HIGH" "Rsync can transfer sensitive files to external hosts."
    fi

    # netcat
    pattern='(^|[^[:alnum:]_])(nc|netcat)([^[:alnum:]_]|$)'
    if matches "$pattern"; then
        check_and_maybe_block "network-exfil" "HIGH" "Netcat can establish arbitrary network connections."
    fi

    # curl POST with file upload
    pattern='curl[[:space:]]+.*(-X[[:space:]]*POST|--request[[:space:]]*POST).*(-d[[:space:]]*@|--data-binary[[:space:]]*@|--data[[:space:]]*@|-F[[:space:]]+.*=@)'
    if matches "$pattern"; then
        check_and_maybe_block "network-exfil" "HIGH" "Curl POST with file data can exfiltrate sensitive information."
    fi

    # ssh with remote command
    pattern="ssh[[:space:]]+[^'\"]*['\"].*['\"]"
    if matches "$pattern"; then
        check_and_maybe_block "network-exfil" "MEDIUM" "SSH with remote commands can execute arbitrary code on remote systems."
    fi
fi

# Container Operations (HIGH) - OFF by default
if is_category_enabled "containers"; then
    # docker rm -f
    pattern='docker[[:space:]]+rm[[:space:]]+(-[a-zA-Z]*f|[a-zA-Z]*f)'
    if matches "$pattern"; then
        check_and_maybe_block "containers" "HIGH" "Force removing containers can lose unsaved work."
    fi

    # docker rmi -f
    pattern='docker[[:space:]]+rmi[[:space:]]+(-[a-zA-Z]*f|[a-zA-Z]*f)'
    if matches "$pattern"; then
        check_and_maybe_block "containers" "MEDIUM" "Force removing images may break dependent containers."
    fi

    # docker system prune -a -f
    pattern='docker[[:space:]]+system[[:space:]]+prune[[:space:]]+.*-a.*-f|docker[[:space:]]+system[[:space:]]+prune[[:space:]]+.*-f.*-a'
    if matches "$pattern"; then
        check_and_maybe_block "containers" "HIGH" "Docker system prune -a -f removes all unused images and containers."
    fi

    # docker volume rm
    pattern='docker[[:space:]]+volume[[:space:]]+rm'
    if matches "$pattern"; then
        check_and_maybe_block "containers" "HIGH" "Removing Docker volumes deletes persistent data."
    fi

    # kubectl delete namespace
    pattern='kubectl[[:space:]]+delete[[:space:]]+namespace'
    if matches "$pattern"; then
        check_and_maybe_block "containers" "CRITICAL" "Deleting Kubernetes namespaces removes all resources within them."
    fi

    # kubectl delete pod/deployment --all
    pattern='kubectl[[:space:]]+delete[[:space:]]+(pod|deployment)[[:space:]]+.*--all'
    if matches "$pattern"; then
        check_and_maybe_block "containers" "HIGH" "Deleting all pods/deployments can cause service outages."
    fi
fi

# Command is allowed
echo '{}'
exit 0
