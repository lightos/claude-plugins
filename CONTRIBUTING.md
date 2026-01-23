# Contributing to Claude Plugins

Thank you for your interest in contributing to this project!

## How to Contribute

### Reporting Issues

- Use GitHub Issues to report bugs or suggest features
- Include steps to reproduce for bugs
- Specify your OS and bash version (`bash --version`)

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Run linters:
   - `find . -name '*.md' -exec markdownlint {} +`
   - `find . -name '*.sh' -exec shellcheck {} +`
5. Test on both Linux and macOS if possible
6. Commit with clear messages
7. Push and open a Pull Request

### Code Style

**Shell Scripts:**

- Use `#!/usr/bin/env bash` shebang
- Include `set -euo pipefail` for safety
- Add dependency checks with helpful install instructions
- Support cross-platform (Linux/macOS) where possible
- Use ShellCheck to lint scripts

**Markdown:**

- Follow markdownlint rules (see `.markdownlint.json`)
- Use fenced code blocks with language identifiers

### Plugin Structure

Each plugin follows this structure:

```text
plugin-name/
  .claude-plugin/
    plugin.json       # Plugin manifest
  agents/             # Agent definitions
  commands/           # Command definitions
  skills/             # Skill definitions
  scripts/            # Helper scripts
  README.md           # Plugin documentation
```

### Testing

- Test scripts manually with sample inputs
- Verify cross-platform compatibility
- Check that all dependencies are documented

## Questions?

Open an issue for questions about contributing.
