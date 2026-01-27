#!/usr/bin/env bash
set -euo pipefail

# Parse CodeRabbit raw output into structured JSON

INPUT="${1:-.coderabbit-results/raw-output.txt}"
OUTPUT="${2:-.coderabbit-results/issues.json}"

awk '
function json_escape(s) {
  gsub(/[\\]/, "\\\\\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\r/, "", s)
  gsub(/\n/, "\\n", s)
  gsub(/\b/, "\\b", s)
  gsub(/\f/, "\\f", s)
  return s
}

function trim(s) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}

function output_issue() {
  if (file == "") return

  # Print comma before all but first issue
  if (issue_count > 0) printf ",\n"
  issue_count++

  # Clean up multi-line fields
  gsub(/[[:space:]]+/, " ", comment)
  gsub(/[[:space:]]+/, " ", prompt)
  comment = trim(comment)
  prompt = trim(prompt)

  printf "    {\n"
  printf "      \"id\": %d,\n", issue_count
  printf "      \"file\": \"%s\",\n", json_escape(file)
  printf "      \"line\": %d,\n", line
  printf "      \"type\": \"%s\",\n", json_escape(type)
  printf "      \"description\": \"%s\",\n", json_escape(comment)
  printf "      \"aiPrompt\": \"%s\"\n", json_escape(prompt)
  printf "    }"
}

BEGIN {
  print "{"
  print "  \"issues\": ["
  issue_count = 0
  section = ""
  file = ""; line = 0; type = ""; comment = ""; prompt = ""
}

/^=+$/ {
  output_issue()
  section = ""
  file = ""; line = 0; type = ""; comment = ""; prompt = ""
  next
}

/^File:/ {
  file = substr($0, 7)
  file = trim(file)
  next
}

/^Line:/ {
  linestr = substr($0, 6)
  # Handle "1 to 16" format - take first number
  if (match(linestr, /[0-9]+/)) {
    line = substr(linestr, RSTART, RLENGTH) + 0
  }
  next
}

/^Type:/ {
  type = substr($0, 6)
  type = trim(type)
  next
}

/^Comment:/ {
  section = "comment"
  next
}

/^Prompt for AI Agent:/ {
  section = "prompt"
  next
}

section == "comment" {
  comment = comment " " $0
}

section == "prompt" {
  prompt = prompt " " $0
}

END {
  # Output last issue (will not have trailing separator)
  output_issue()
  print ""
  print "  ],"
  printf "  \"total\": %d\n", issue_count
  print "}"
}
' "$INPUT" > "$OUTPUT"

count=$(jq '.total' "$OUTPUT" 2>/dev/null || echo 0)
echo "Parsed $count issues to $OUTPUT"
