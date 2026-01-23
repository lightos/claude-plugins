# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** open a public GitHub issue
2. Email the maintainer at: **<lightos@gmail.com>** (or open a private security advisory on GitHub)
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## Security Considerations

### These plugins execute shell commands

Both `codex-review` and `coderabbit-fix` execute shell scripts that:

- Run external CLI tools (`codex`, `coderabbit`, `jq`)
- Read and write files in the working directory
- Parse and process user-provided file paths

### Best Practices

- Only run these plugins on trusted codebases
- Review generated reports before acting on them
- Keep dependencies (`codex`, `coderabbit`, `jq`) updated
- Use in isolated environments when reviewing untrusted code

### Data Handling

- Review artifacts (`.codex-review/`, `.coderabbit-results/`) may contain:
  - File paths from your system
  - Code snippets from reviewed files
  - Session identifiers
- These directories are gitignored by default
- Delete them before sharing your repository if concerned

## Acknowledgments

We appreciate responsible disclosure of security issues.
