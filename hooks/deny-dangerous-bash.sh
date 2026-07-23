#!/usr/bin/env bash
# PreToolUse hook: block obviously destructive Bash commands regardless of permission mode.
# Exit 2 blocks the tool call and returns stderr to Claude as feedback.

command=$(jq -r '.tool_input.command // empty')

deny_patterns=(
    'rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[rR])[[:space:]]+/($|[[:space:]])'
    'rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[rR])[[:space:]]+(--no-preserve-root|~($|/)|\*)'
    ':\(\)[[:space:]]*\{[[:space:]]*:.*\|.*:.*&.*\}[[:space:]]*;[[:space:]]*:'
    'dd[[:space:]].*of=/dev/(sd|nvme|vd|hd)'
    'mkfs(\.[a-zA-Z0-9]+)?[[:space:]]'
    '>[[:space:]]*/dev/(sd|nvme|vd|hd)[a-z0-9]*($|[[:space:]])'
    'chmod[[:space:]]+-R[[:space:]]+[0-7]{3,4}[[:space:]]+/($|[[:space:]])'
    'chown[[:space:]]+-R[[:space:]].*[[:space:]]+/($|[[:space:]])'
    '(^|[[:space:]])(shutdown|reboot|poweroff|halt)([[:space:]]|$)'
    'wipefs[[:space:]]'
    'shred[[:space:]].*/dev/'
    'curl[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh)($|[[:space:]])'
    'wget[[:space:]].*-O-.*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh)($|[[:space:]])'
)

for pattern in "${deny_patterns[@]}"; do
    if [[ "$command" =~ $pattern ]]; then
        echo "Blocked by local denylist hook (~/.claude/hooks/deny-dangerous-bash.sh): command matches pattern '$pattern'" >&2
        exit 2
    fi
done

exit 0
