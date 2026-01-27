# Safeguard Plugin

A Claude Code plugin that blocks dangerous bash commands with category-based
protection and one-time bypass mechanism.

## Features

- **PreToolUse hook** that intercepts bash commands before execution
- **8 protection categories** with independent enable/disable
- **One-time bypass** mechanism for intentional dangerous operations
- **Clear feedback** when commands are blocked, with user prompts to allow

## Installation

### Prerequisites

- **jq** - Required for JSON parsing
  - macOS: `brew install jq`
  - Ubuntu/Debian: `apt install jq`
  - Alpine: `apk add jq`

### Install Plugin

```bash
# Add to your Claude Code plugins
claude /plugin add /path/to/safeguard
```

## Protection Categories

| Category           | Default | Description                                       |
|--------------------|---------|---------------------------------------------------|
| system-destruction | ON      | rm -rf, dd to disk, mkfs, fork bombs, shred       |
| system-control     | ON      | shutdown, reboot, kill init, chmod/chown on root  |
| git-commits        | ON      | All git commit commands                           |
| git-pushes         | ON      | All git push commands                             |
| git-destructive    | ON      | reset --hard, clean -f, force push, branch -D     |
| remote-code-exec   | ON      | curl\|sh, wget\|bash, piped URLs to shell         |
| network-exfil      | OFF     | scp, rsync, netcat, curl POST with files          |
| containers         | OFF     | docker rm/rmi -f, kubectl delete, prune           |

## Commands

### `/safeguard:status`

Show current protection status and active bypass flags.

### `/safeguard:config`

Interactive configuration to enable/disable protection categories.

Presets available:

- **strict** - All categories ON
- **standard** - All except network-exfil and containers (default)
- **git-only** - Only git-related categories
- **minimal** - Only system-destruction and system-control
- **off** - All categories OFF (not recommended)

### `/safeguard:allow-dangerous <category>`

Create a one-time bypass for the next command in the specified category.

Example:

```bash
/safeguard:allow-dangerous git-pushes
```

The bypass:

- Expires after 60 seconds
- Is consumed after one use
- Only applies to the specified category

## How It Works

1. When Claude attempts to run a bash command, the PreToolUse hook intercepts it
2. The command is checked against patterns for each enabled category
3. If blocked, Claude receives a message explaining:
   - What command was blocked
   - Why it's dangerous
   - Instructions to ask the user if they want to proceed
4. Claude uses AskUserQuestion to prompt the user
5. If the user approves, Claude runs `/safeguard:allow-dangerous <category>`
   and retries

## Configuration Storage

Configuration is stored in: `$CLAUDE_PROJECT_DIR/.claude/.safeguard/config.json`

Fallback locations:

1. `$CLAUDE_PROJECT_DIR/.claude/.safeguard/`
2. `$PWD/.claude/.safeguard/`
3. `$HOME/.claude/.safeguard/`

## Testing

Run the pattern matching tests:

```bash
cd safeguard
./tests/test-patterns.sh
```

## Limitations

This is a **safeguard, not a security boundary**. Pattern matching can be
bypassed through:

- Indirection: `sh -c 'rm -rf /'`
- Variable expansion: `rm -rf "$HOME"`
- Wrappers: `xargs rm -rf`, `find -exec rm`
- Encoding: Base64 commands

The plugin catches accidental dangerous commands but won't stop a determined
attacker.

## License

MIT
