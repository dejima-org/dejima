#!/bin/bash
# Idempotent installer for dejima. Registers the selected harness's guard
# hooks wherever that harness reads them from, and puts
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
link_bin dejima-epitaph

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
    # An operator with GITEA_SSH_HOST/GITEA_API still exported was pushing to
    # a Gitea/Forgejo instance before the config file existed, so the starter
    # config keeps them pushing: forge and workflow are written out
    # explicitly rather than left at the (non-pushing) shipped defaults, and
    # gitea's own keys are enumerated so there is somewhere for the seeds to
    # land - _config_keys enumerates only the SELECTED forge's keys, and with
    # no config file yet that selection is the default, `none`.
    _starter_forge="$(config_default core.forge)"
    _starter_workflow="$(config_default core.workflow)"
    _starter_extra_keys=""
    if [ -n "${GITEA_SSH_HOST:-}" ] || [ -n "${GITEA_API:-}" ]; then
        _starter_forge=gitea
        _starter_workflow=worktree-pr
        _starter_extra_keys="$(_config_extra_keys_for forge gitea)"
    fi
    # Seeded from any legacy variables still exported, so the one-time
    # migration is a review rather than a retyping. Everything else is
    # written commented-out at its schema default, so the file doubles as
    # the reference for what can be set.
    {
        printf '# dejima configuration. See README.md.\n'
        printf '# Every key below is shown at its default; uncomment to change one.\n'
        printf '#\n'
        printf '# [core] harness, forge and workflow are written out uncommented, so\n'
        printf '# this file states what it selects rather than inheriting a future\n'
        printf '# default. harness has none at all - dejima refuses to start unset.\n'
        printf '#\n'
        printf '# Those two decide whether this sandbox pushes at all. The shipped\n'
        printf '# default is forge = none with workflow = local-only: the agent\n'
        printf '# commits locally and pushes NOWHERE. To push, set workflow to\n'
        printf '# worktree-pr (push + open a PR) or branch-push, and set forge to\n'
        printf '# gitea (fill in [forge.gitea]) or github (fill in [forge.github]\n'
        printf '# push_token_file). A pushing workflow whose forge resolves to no\n'
        printf '# host is refused at launch, not launched with pushing quietly\n'
        printf '# broken.\n\n'
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
                core.harness)              _seed="claude-code" ;;
                core.forge)                _seed="$_starter_forge" ;;
                core.workflow)             _seed="$_starter_workflow" ;;
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
        done < <(_config_keys; [ -z "$_starter_extra_keys" ] || printf '%s\n' "$_starter_extra_keys")
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

# Guard registration, after the starter config above rather than before it:
# where dejima's guards go, and in what shape, is the selected harness's
# business, and on a fresh install that selection is the one just seeded.
# Registering before reading it would mean writing one harness's config for
# an operator who has chosen another.
#
# Delegated to the harness's plugin, which is also what gates each guard on
# the harness having declared it (see `guards` in its manifest).
echo
source "$SCRIPT_DIR/bin/dejima-harness-lib.sh"
_harness="$(config_get core harness 2>/dev/null)" || _harness=""
if [ -z "$_harness" ]; then
    echo "No [core] harness is set in $CONFIG_FILE, so no guard hooks were"
    echo "registered. Set one and re-run ./install.sh."
else
    DEJIMA_HARNESS_NAME="$_harness"
    harness_plugin_load "$_harness"
    if declare -F harness_register_guards >/dev/null 2>&1; then
        echo "Registering $_harness's guard hooks"
        harness_register_guards "$SCRIPT_DIR" "$BACKUP_DIR"
    else
        echo "Harness '$_harness' installs no guard hooks."
        echo
    fi
fi

if [ -f "$(config_root)/remote.conf" ]; then
    echo
    echo "Note: $(config_root)/remote.conf is no longer read - its keys moved to the"
    echo "[remote-access] section of $CONFIG_FILE. Left in place for you to remove."
fi

# The [core] forge/workflow defaults changed from gitea+worktree-pr to
# none+local-only, which silently stops an existing sandbox pushing if the
# operator was relying on the defaults. Reported for the same reason the
# remote.conf note above is: a config that means something different after an
# upgrade than it did before must not change meaning quietly. Only for a
# config that PARSES - config_is_set cannot distinguish "absent" from "the
# file is broken", and a broken config already fails loudly at launch.
if config_exists && config_validate 2>/dev/null; then
    if ! config_is_set core forge || ! config_is_set core workflow; then
        echo
        echo "Note: the defaults for [core] forge and [core] workflow have changed."
        echo "They were 'gitea' and 'worktree-pr'; they are now 'none' and 'local-only'."
        echo "$CONFIG_FILE does not set both of them explicitly, so this"
        echo "sandbox now commits locally and pushes NOWHERE where it used to push and"
        echo "open a Gitea/Forgejo PR."
        echo
        echo "To keep pushing, write both lines out under [core]:"
        echo "    forge = gitea"
        echo "    workflow = worktree-pr"
        echo "(with [forge.gitea] ssh_host and api filled in, which that pair has always"
        echo "required). To confirm the new behaviour instead, write 'forge = none' and"
        echo "'workflow = local-only' explicitly and this note stops appearing."
    fi
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
