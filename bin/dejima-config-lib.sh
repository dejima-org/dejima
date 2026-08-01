#!/bin/bash
# The single dejima config file: schema, parser, accessors.
#
# This is the base layer - it sources nothing, so dejima-project-lib.sh can
# source it without a cycle. config_root() lives here rather than there for
# exactly that reason.
#
# The file is PARSED, never sourced. It is hand-edited by the operator and
# holds values that decide a sandbox's firewall, its credentials and its
# mounts; executing it would make a typo a shell injection and would put the
# config on the same footing as code.
#
# Every read validates the WHOLE file, not just the requested key - the same
# stance remote_conf_get took before this replaced it. A config that does not
# parse means the operator got something wrong, and the alternative to
# refusing is launching a sandbox configured differently from what they
# believe they configured. A launch performs on the order of thirty reads and
# so re-parses thirty times; the file is tens of lines, and the cost buys the
# property that no read can succeed against a file another read would reject.

# ---------------------------------------------------------------------------
# Schema
#
# Three TAB-separated columns: key, type, default. One source of truth - both
# _config_spec and _config_keys read this, so a key cannot exist for lookup
# but be missing from enumeration (which is what --print-config walks).
#
# A "?" prefix on the type means the empty string is a legal value. Without
# it, empty is rejected: the distinction is between a setting that is
# meaningfully absent (ssh_key, loki_url) and one that must always have a
# value (firewall, share_dir).
#
# The three axis keys accept exactly one value each in this phase. They exist
# now so a config written today stays valid when Phase 2 widens them to a
# directory lookup.
# ---------------------------------------------------------------------------
_config_table() {
    cat <<'EOF'
core.harness	enum:claude-code	claude-code
core.forge	enum:gitea	gitea
core.workflow	enum:worktree-pr	worktree-pr
core.command	identifier	claude
core.firewall	bool	on
core.share_dir	path	~/.local/share/dejima/shared
core.ssh_key	?path
core.known_hosts	path	~/.ssh/known_hosts
harness.claude-code.projects_dir	path	~/.claude/projects
harness.claude-code.statusline_path	path	~/.claude/statusline.sh
forge.gitea.ssh_host	?hostname
forge.gitea.api	?url
forge.gitea.token_file	path	~/.config/gitea/token
github.token_file	path	~/.config/gh/sandbox-token
mounts.readonly	?list:path
mounts.nvim_config	?path
credentials.proxy	bool	on
credentials.transport	enum:tls|loopback	tls
logging.loki_url	?url
logging.conversation	bool	off
audit.dir	path	~/.local/share/dejima/audit
audit.baselines_dir	path	~/.local/share/dejima/baselines
audit.keep	int:1:1000	10
audit.strict	bool	off
remote-access.ntfy_url	?url
remote-access.base_url	?url
remote-access.ttyd_port	int:1:65535	7681
remote-access.ttyd_font_size	?int:8:72
remote-access.debounce	int:0:86400	60
EOF
}

# Prints "TYPE<TAB>DEFAULT" for a known key; returns 1 for anything else,
# which is what makes an unknown key in the config file fatal.
_config_spec() {
    local want="$1" key type default
    while IFS=$'\t' read -r key type default; do
        [ "$key" = "$want" ] || continue
        printf '%s\t%s' "$type" "$default"
        return 0
    done < <(_config_table)
    return 1
}

config_type() {
    local spec
    spec="$(_config_spec "$1")" || return 1
    printf '%s' "${spec%%$'\t'*}"
}

config_default() {
    local spec
    spec="$(_config_spec "$1")" || return 1
    printf '%s' "${spec#*$'\t'}"
}

_config_keys() {
    local key rest
    while IFS=$'\t' read -r key rest; do
        [ -n "$key" ] || continue
        printf '%s\n' "$key"
    done < <(_config_table)
}

# Moved here from dejima-project-lib.sh so this file has no dependencies and
# can be the layer that one sources, rather than the other way round.
config_root() {
    printf '%s' "${DEJIMA_CONFIG_DIR:-$HOME/.config/dejima}"
}

config_path() {
    printf '%s/config' "$(config_root)"
}
