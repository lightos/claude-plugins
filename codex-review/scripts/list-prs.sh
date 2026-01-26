#!/usr/bin/env bash
set -euo pipefail

# List recent PRs for interactive selection
# Usage: list-prs.sh [project-path]

PROJECT_PATH="${1:-.}"

# Validate project path
if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "ERROR: Project path does not exist: $PROJECT_PATH" >&2
    exit 1
fi
PROJECT_PATH=$(cd "$PROJECT_PATH" && pwd)

# Check for gh CLI
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found" >&2
    echo "Install from: https://cli.github.com/" >&2
    exit 1
fi

# Check gh authentication
if ! (cd "$PROJECT_PATH" && gh auth status &>/dev/null); then
    echo "ERROR: gh CLI not authenticated. Run: gh auth login" >&2
    exit 1
fi

# List recent PRs (open first, then recently updated closed/merged)
echo "Recent Pull Requests:" >&2
(cd "$PROJECT_PATH" && gh pr list --limit 5 --state all --json number,title,state,headRefName,updatedAt \
    --jq 'sort_by(.updatedAt) | reverse | .[] | "#\(.number) [\(.state)] \(.headRefName): \(.title)"')
