#!/bin/bash
# Idempotent installer for dejima. Symlinks this repo's hooks into
# ~/.claude/hooks, registers them in ~/.claude/settings.json, and puts
# bin/dejima, bin/dejima-allow, bin/dejima-dep, bin/dejima-project,
# bin/dejima-audit and the opt-in remote-access scripts on PATH. Safe to
# re-run - every step is a no-op if already done, and every change is
# printed as it happens.
#
# It never enables anything: the remote-access scripts do nothing without
# [remote-access] enabled = on in ~/.config/dejima/config, and the user units
# in systemd/ are left for the operator to install by hand.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.dejima-backup"

echo "dejima install.sh"
echo "Repo: $SCRIPT_DIR"
echo

missing=()
for tool in docker jq python3; do
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
echo "Found required tools: docker, docker compose v2, jq, python3"
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
link_hook merge-guard.sh

# Symlink from before the gitea-merge-guard.sh -> merge-guard.sh rename
# points at a hooks/ path that no longer exists. Only remove it if it's
# actually dangling - the same check the claude-sandbox-* cleanup below
# uses for bin/, so an operator's own file at this name is left alone.
old_merge_guard="$HOME/.claude/hooks/gitea-merge-guard.sh"
if [ -L "$old_merge_guard" ] && [ ! -e "$old_merge_guard" ]; then
    echo "Removing: dangling pre-rename symlink $old_merge_guard"
    rm -f "$old_merge_guard"
fi

# Linked so it exists at a stable path for the read-only ~/.claude/hooks
# mount, but deliberately NOT passed to register_hook below: bin/dejima
# registers it per session, into a throwaway settings copy, and only when
# remote access is configured. Registering it here would fire it for every
# unsandboxed host session too, where it has no marker directory to write to.
link_hook dejima-notify.sh

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
register_hook PreToolUse Bash merge-guard.sh \
    "blocks the configured forge's merge command inside the sandbox"
register_hook PreToolUse Bash deny-dangerous-bash.sh \
    "blocks obviously destructive Bash commands"
echo

BIN_DIR="$HOME/.local/bin"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "Warning: $BIN_DIR is not on PATH - add it to your shell profile to run 'dejima' by name instead of the full path." >&2
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

# Symlinks from before the claude-sandbox -> dejima rename point at bin/
# paths that no longer exist. Only remove ones that are actually dangling -
# anything still resolving belongs to some other install, not to us.
for old in claude-sandbox claude-sandbox-allow claude-sandbox-dep claude-sandbox-project; do
    old_dest="$BIN_DIR/$old"
    if [ -L "$old_dest" ] && [ ! -e "$old_dest" ]; then
        echo "Removing: dangling pre-rename symlink $old_dest"
        rm -f "$old_dest"
    fi
done

link_bin dejima
link_bin dejima-allow
link_bin dejima-dep
link_bin dejima-project
# The exit-time audit is a user-facing CLI, not just bin/dejima's helper:
# the startup warning about unacknowledged CRITICAL findings tells the
# operator to run `dejima-audit ack`, which is only true once it is on PATH.
link_bin dejima-audit

# Remote access (opt-in, see docs/remote-access.md). All three are inert
# without [remote-access] enabled = on - they refuse to run at all - so
# linking unconditionally adds no front door and costs nothing. The user
# units in systemd/ are deliberately NOT copied or enabled here: standing up
# a front door is an explicit operator decision, and this script never
# touches systemd.
link_bin dejima-attach
link_bin dejima-ttyd
link_bin dejima-notify-watch
echo

# From the library rather than duplicated here: remote_enabled and the
# config accessors have one definition each (which honour DEJIMA_CONFIG_DIR
# through config_root), and a second copy of any of them would drift without
# anything noticing.
# shellcheck source=bin/dejima-project-lib.sh
source "$SCRIPT_DIR/bin/dejima-project-lib.sh"
# [forge.<name>]/[harness.<name>] keys below come from the selected
# provider's manifest, not a row hardcoded in dejima-config-lib.sh - needs
# dejima-provider-lib.sh sourced for that lookup to resolve.
# shellcheck source=bin/dejima-provider-lib.sh
source "$SCRIPT_DIR/bin/dejima-provider-lib.sh"

CONFIG_FILE="$(config_path)"
if config_exists; then
    echo "Config: $CONFIG_FILE already exists - leaving it alone."
else
    mkdir -p "$(config_root)"
    echo "Writing a starter config to $CONFIG_FILE"
    # Seeded from any legacy variables still exported, so the one-time
    # migration is a review rather than a retyping. Everything else is
    # written commented-out at its schema default, so the file doubles as
    # the reference for what can be set.
    {
        printf '# dejima configuration. See README.md.\n'
        printf '# Every key below is shown at its default; uncomment to change one.\n\n'
        _section=""
        while IFS= read -r _key; do
            [ -n "$_key" ] || continue
            _leaf="${_key##*.}"
            _sec="${_key%.*}"
            _default="$(config_default "$_key")"
            if [ "$_sec" != "$_section" ]; then
                printf '\n[%s]\n' "$_sec"
                _section="$_sec"
            fi
            _seed=""
            case "$_key" in
                forge.gitea.ssh_host)      _seed="${GITEA_SSH_HOST:-}" ;;
                forge.gitea.api)           _seed="${GITEA_API:-}" ;;
                core.command)              _seed="${SANDBOX_CMD:-}" ;;
                core.ssh_key)              _seed="${SANDBOX_SSH_KEY:-}" ;;
                mounts.readonly)           _seed="${SANDBOX_EXTRA_MOUNTS:-}" ;;
                mounts.nvim_config)        _seed="${SANDBOX_NVIM_CONFIG:-}" ;;
                logging.loki_url)          _seed="${LOKI_URL:-}" ;;
                credentials.transport)     _seed="${SANDBOX_ANTHROPIC_TRANSPORT:-}" ;;
                # The schema default dropped the old ${XDG_DATA_HOME:-...}
                # fallback in favour of a literal ~/.local/share/... path - an
                # operator with XDG_DATA_HOME set would otherwise silently get
                # a fresh, empty audit store and lose sight of prior
                # unacknowledged CRITICAL findings. Seed from the old formula
                # so that migration is something to review, not something
                # invisible.
                audit.dir)
                    [ -n "${XDG_DATA_HOME:-}" ] && _seed="$XDG_DATA_HOME/dejima/audit"
                    ;;
                audit.baselines_dir)
                    [ -n "${XDG_DATA_HOME:-}" ] && _seed="$XDG_DATA_HOME/dejima/baselines"
                    ;;
            esac
            if [ -n "$_seed" ]; then
                printf '%s = %s\n' "$_leaf" "$_seed"
            else
                printf '# %s = %s\n' "$_leaf" "$_default"
            fi
        done < <(_config_keys)
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

if [ -f "$(config_root)/remote.conf" ]; then
    echo
    echo "Note: $(config_root)/remote.conf is no longer read - its keys moved to the"
    echo "[remote-access] section of $CONFIG_FILE. Left in place for you to remove."
fi

echo "Done. Try: $BIN_DIR/dejima ~/some/project"
echo "(or just 'dejima ~/some/project' once $BIN_DIR is on PATH)"
echo
# Conditional, because the unconditional version is a false statement to the
# operator most likely to see it: someone with a front door already up,
# re-running this after a git pull.
if remote_enabled; then
    echo "Remote access is configured ($CONFIG_FILE); this script did not start or stop anything."
    echo "See docs/remote-access.md."
else
    echo "Remote access is available but not configured - nothing is listening."
    echo "See docs/remote-access.md to turn it on."
fi
