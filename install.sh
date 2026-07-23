#!/bin/bash
# Idempotent installer for claude-sandbox. Symlinks this repo's hooks into
# ~/.claude/hooks, registers them in ~/.claude/settings.json, and puts
# bin/claude-sandbox + bin/claude-sandbox-allow on PATH. Safe to re-run -
# every step is a no-op if already done, and every change is printed as it
# happens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.claude-sandbox-backup"

echo "claude-sandbox install.sh"
echo "Repo: $SCRIPT_DIR"
echo

missing=()
for tool in docker jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done
if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    missing+=("docker compose (v2 plugin)")
fi
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing required tool(s): ${missing[*]}" >&2
    echo "Install them and re-run this script." >&2
    exit 1
fi
echo "Found required tools: docker, docker compose v2, jq"
echo

mkdir -p "$HOME/.claude/hooks"

link_hook() {
    local name="$1" src="$SCRIPT_DIR/hooks/$1" dest="$HOME/.claude/hooks/$1"
    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
        echo "Skipping: $name already linked to this repo's copy"
        return
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        mkdir -p "$BACKUP_DIR"
        echo "Moving: existing ~/.claude/hooks/$name to $BACKUP_DIR/$name"
        mv "$dest" "$BACKUP_DIR/$name"
    fi
    echo "Linking: $name ($src -> $dest)"
    ln -s "$src" "$dest"
}

link_hook sandbox-context.sh
link_hook git-push-guard.sh

# deny-dangerous-bash.sh is a general (non-sandbox-gated) hook that may
# already be owned by another install (e.g. dotfiles) - only claim it if
# nothing else already provides it, so this repo works fully standalone
# without clobbering an existing setup.
deny_dest="$HOME/.claude/hooks/deny-dangerous-bash.sh"
if [ -e "$deny_dest" ] || [ -L "$deny_dest" ]; then
    echo "Skipping: deny-dangerous-bash.sh already present at $deny_dest (leaving it as-is)"
else
    echo "Linking: deny-dangerous-bash.sh ($SCRIPT_DIR/hooks/deny-dangerous-bash.sh -> $deny_dest)"
    ln -s "$SCRIPT_DIR/hooks/deny-dangerous-bash.sh" "$deny_dest"
fi
echo

SETTINGS="$HOME/.claude/settings.json"
if [ ! -f "$SETTINGS" ]; then
    echo "Creating $SETTINGS"
    echo '{}' > "$SETTINGS"
fi

register_hook() {
    local event="$1" matcher="$2" script_name="$3" description="$4"
    if jq -e --arg s "$script_name" \
        "[.hooks.${event}[]?.hooks[]?.command // empty] | any(test(\$s))" \
        "$SETTINGS" >/dev/null 2>&1; then
        echo "Skipping: $script_name already registered as a $event hook"
        return
    fi
    echo "Registering $script_name as a $event hook in $SETTINGS ($description)"
    local tmp
    tmp=$(mktemp)
    jq --arg matcher "$matcher" --arg cmd "\$HOME/.claude/hooks/$script_name" \
        ".hooks.${event} = ((.hooks.${event} // []) + [{\"matcher\": \$matcher, \"hooks\": [{\"type\": \"command\", \"command\": \$cmd}]}])" \
        "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
}

register_hook SessionStart "startup|resume|clear|compact" sandbox-context.sh \
    "injects sandbox context on session start"
register_hook PreToolUse Bash git-push-guard.sh \
    "blocks pushes outside the allowed host(s)/branches"
register_hook PreToolUse Bash deny-dangerous-bash.sh \
    "blocks obviously destructive Bash commands"
echo

BIN_DIR="$HOME/.local/bin"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "Warning: $BIN_DIR is not on PATH - add it to your shell profile to run 'claude-sandbox' by name instead of the full path." >&2
fi
mkdir -p "$BIN_DIR"

link_bin() {
    local name="$1" src="$SCRIPT_DIR/bin/$1" dest="$BIN_DIR/$1"
    if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
        echo "Skipping: $name already linked to this repo's copy"
        return
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        mkdir -p "$BACKUP_DIR"
        echo "Moving: existing $dest to $BACKUP_DIR/$name"
        mv "$dest" "$BACKUP_DIR/$name"
    fi
    echo "Linking: $name ($src -> $dest)"
    ln -s "$src" "$dest"
}

link_bin claude-sandbox
link_bin claude-sandbox-allow
echo

echo "Done. Try: $BIN_DIR/claude-sandbox ~/some/project"
echo "(or just 'claude-sandbox ~/some/project' once $BIN_DIR is on PATH)"
