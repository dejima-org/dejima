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
# stance the old remote.conf accessor took before this replaced it. A config
# that does not parse means the operator got something wrong, and the alternative to
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
# The three axis keys are `provider:<axis>` - validated by looking the name
# up under the provider root (see _config_extra_type_valid below and
# dejima-provider-lib.sh) rather than a fixed enum, so adding a provider is
# adding a directory, not editing this schema.
#
# [forge.<name>] and [harness.<name>] keys are absent from this table for the
# same reason: enumerating a forge's own keys here would mean a new forge
# needs a core edit, which is exactly what the provider axes are for.
# Those two sections are resolved instead through the _config_extra_*
# functions below, stubbed here and overridden by dejima-provider-lib.sh once
# it is sourced, against the type+default each provider's own `keys` manifest
# entry declares (see _provider_keyspec_parse there).
# ---------------------------------------------------------------------------
_config_table() {
    cat <<'EOF'
core.harness	provider:harness	claude-code
core.forge	provider:forge	gitea
core.workflow	provider:workflow	worktree-pr
core.command	identifier	claude
core.firewall	bool	on
core.share_dir	path	~/.local/share/dejima/shared
core.ssh_key	?path
core.known_hosts	path	~/.ssh/known_hosts
github.token_file	path	~/.config/gh/sandbox-token
mounts.readonly	?list:path
mounts.read_write	?list:path
mounts.nvim_config	?path
credentials.proxy	bool	on
credentials.transport	enum:tls|loopback	tls
logging.loki_url	?url
logging.conversation	bool	off
audit.dir	path	~/.local/share/dejima/audit
audit.baselines_dir	path	~/.local/share/dejima/baselines
audit.keep	int:1:1000	10
audit.strict	bool	off
audit.diffs	bool	on
remote-access.enabled	bool	off
remote-access.ntfy_url	?url
remote-access.base_url	?url
remote-access.ttyd_port	int:1:65535	7681
remote-access.ttyd_font_size	?int:8:72
remote-access.ttyd_tmux_prefix	?chord
remote-access.debounce	int:0:86400	60
EOF
}

# Extension point for [forge.<name>]/[harness.<name>] keys, which this layer
# cannot enumerate on its own - see the _config_table comment above. Stub
# returns 1 (not found); overridden by dejima-provider-lib.sh, which prints
# the same "TYPE<TAB>DEFAULT" shape _config_spec itself does so a
# manifest-sourced entry is indistinguishable from a hardcoded one to every
# caller.
_config_extra_spec() { return 1; }

# Prints "TYPE<TAB>DEFAULT" for a known key; returns 1 for anything else,
# which is what makes an unknown key in the config file fatal.
_config_spec() {
    local want="$1" key type default
    while IFS=$'\t' read -r key type default; do
        [ "$key" = "$want" ] || continue
        printf '%s\t%s' "$type" "$default"
        return 0
    done < <(_config_table)
    _config_extra_spec "$want"
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

# Extension point mirroring _config_extra_spec: the forge/harness keys this
# layer cannot enumerate on its own. Stub prints nothing; overridden by
# dejima-provider-lib.sh.
_config_extra_keys() { :; }

_config_keys() {
    local key rest
    while IFS=$'\t' read -r key rest; do
        [ -n "$key" ] || continue
        printf '%s\n' "$key"
    done < <(_config_table)
    _config_extra_keys
}

# Moved here from dejima-project-lib.sh so this file has no dependencies and
# can be the layer that one sources, rather than the other way round.
config_root() {
    printf '%s' "${DEJIMA_CONFIG_DIR:-$HOME/.config/dejima}"
}

config_path() {
    printf '%s/config' "$(config_root)"
}

# ---------------------------------------------------------------------------
# Value validation
#
# Deliberately narrow, for the same reason the old remote.conf validator was:
# these values reach a dnsmasq server= line, a curl -H header, a docker -v argument
# and a URL handed to a phone. Anything shell-active, any whitespace, and
# anything that could split a header must not survive validation.
# ---------------------------------------------------------------------------

# Moved here from dejima-project-lib.sh, unchanged: a declared domain has to
# survive being written into a dnsmasq server=/domain/ line. Defining it here
# rather than in both files keeps one definition, which is what stops the two
# drifting apart.
valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,62}\.)*[a-zA-Z0-9-]{1,63}$ ]]
}

# Extension point for types this layer cannot judge on its own. A stub here,
# overridden by dejima-provider-lib.sh when that is sourced - which is what
# lets the schema name a provider: type without this file having to know what
# a provider is. Returns 0 valid, 1 invalid, 2 "not a type I handle", so an
# unknown type stays fatal rather than being waved through by a hook that
# simply did not recognise it.
_config_extra_type_valid() { return 2; }

_config_valid_value() {
    local type="$1" value="$2" optional=0

    if [ "${type:0:1}" = "?" ]; then
        optional=1
        type="${type:1}"
    fi
    if [ -z "$value" ]; then
        # Empty is legal only under "?". A non-empty value still gets fully
        # type-checked below either way - "optional" means "may be absent",
        # never "may be anything".
        [ "$optional" = 1 ]
        return
    fi

    case "$type" in
        bool)
            [[ "$value" =~ ^(on|off)$ ]]
            ;;
        int:*:*)
            local range min max
            range="${type#int:}"
            min="${range%%:*}"
            max="${range##*:}"
            [[ "$value" =~ ^[0-9]+$ ]] || return 1
            [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]
            ;;
        enum:*)
            # Exact membership, not a substring test. Splitting on "|" and
            # comparing each member is what stops the whole member list from
            # validating as a value: "|tls|loopback|" contains "|tls|loopback|",
            # so a delimiter-padded substring check accepts it.
            local -a allowed=()
            local member
            IFS='|' read -ra allowed <<< "${type#enum:}"
            for member in "${allowed[@]}"; do
                [ "$value" = "$member" ] && return 0
            done
            return 1
            ;;
        path)
            # A ":" would split the host:container:mode triple in a docker -v
            # argument - docker-compose.yml mounts share_dir as
            # "${SANDBOX_SHARE_DIR}:${HOME}/shared", so an embedded colon
            # silently mounts a different source at a different target rather
            # than failing. A newline is refused for the same reason
            # bin/dejima already refuses one in a workspace path.
            #
            # Deliberately nothing else: spaces and other shell-active
            # characters stay legal, because every consumer quotes this value
            # and a validator that rejected them would only break operators
            # whose home directory has a space in it. The list: type splits on
            # ":" before reaching here, so a colon-separated list is unaffected.
            case "$value" in
                *:*|*$'\n'*) return 1 ;;
            esac
            [[ "$value" == /* || "$value" == "~/"* || "$value" == "~" ]]
            ;;
        list:*)
            local member="${type#list:}" element
            # Declared local, and deliberately so: this function recurses into
            # itself once per element, and a shared global here would be
            # clobbered mid-loop the moment any member type also used it.
            local -a elements=()
            # Colon-separated, like $PATH. An empty element (a stray "::" or
            # a trailing colon) is a config typo, not an entry to skip.
            IFS=':' read -ra elements <<< "$value"
            for element in "${elements[@]}"; do
                _config_valid_value "$member" "$element" || return 1
            done
            ;;
        hostname)
            valid_domain "$value"
            ;;
        url)
            # The same character set the old remote.conf validator used, plus a
            # required http(s) scheme. Deliberately narrower than RFC 3986: these values
            # reach a curl -H header, an nginx comparison, a firewall
            # allowlist and prose an agent reads, so ";", "&", "$", backticks
            # and parentheses must not survive even though a URL may legally
            # contain them. Held in a variable and expanded unquoted, which is
            # the only reliable way to keep the shell from eating a
            # metacharacter before the regex engine ever sees it.
            local re='^https?://[A-Za-z0-9:/._~?=%@+-]+$'
            [[ "$value" =~ $re ]]
            ;;
        identifier)
            [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
            ;;
        chord)
            # A tmux control chord, as the remote terminal page's PREFIX,
            # window and ZOOM buttons send. Narrower than tmux's own prefix
            # syntax - C-\ and C-] are excluded - because the value is
            # interpolated into the page's client options.
            [[ "$value" =~ ^[Cc]-([A-Za-z@_?]|[Ss]pace)$ ]]
            ;;
        *)
            _config_extra_type_valid "$type" "$value"
            case $? in
                0) return 0 ;;
                1) return 1 ;;
                *) echo "config: unknown schema type: $type" >&2; return 1 ;;
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

config_exists() {
    [ -f "$(config_path)" ]
}

# Extension point for [forge.<name>]/[harness.<name>] sections - a section is
# known only when a provider directory for <name> actually exists, which
# needs dejima-provider-lib.sh (provider_dir). Stub refuses everything;
# overridden once that file is sourced.
_config_extra_section_known() { return 1; }

_config_section_known() {
    case "$1" in
        core|github|mounts|credentials|logging|audit|remote-access) return 0 ;;
        *) _config_extra_section_known "$1" ;;
    esac
}

_config_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Validates the whole file. Returns 1 and explains the FIRST problem found -
# reporting one actionable line beats a list the operator has to read
# bottom-up.
config_validate() {
    local conf line section="" key value type
    conf="$(config_path)"
    if [ ! -f "$conf" ]; then
        echo "no dejima config at $conf" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(_config_trim "$line")"
        case "$line" in
            ''|'#'*|';'*)
                continue
                ;;
            '['*']')
                section="${line#\[}"
                section="${section%\]}"
                section="$(_config_trim "$section")"
                if ! _config_section_known "$section"; then
                    echo "unknown section [$section] in $conf" >&2
                    return 1
                fi
                continue
                ;;
            *=*)
                ;;
            *)
                echo "malformed line in $conf: $line" >&2
                return 1
                ;;
        esac
        if [ -z "$section" ]; then
            echo "key outside any section in $conf: $line" >&2
            return 1
        fi
        key="$(_config_trim "${line%%=*}")"
        value="$(_config_trim "${line#*=}")"
        if ! type="$(config_type "$section.$key")"; then
            echo "unknown key in $conf: [$section] $key" >&2
            return 1
        fi
        if ! _config_valid_value "$type" "$value"; then
            echo "invalid value for [$section] $key in $conf: $value" >&2
            return 1
        fi
    done < "$conf"
    return 0
}

# Expands a leading "~" to $HOME, per element for a list type. Only for path
# types: a tilde inside a URL is a legal path character and must survive.
_config_expand() {
    local type="$1" value="$2" element out=""
    case "$type" in
        \?*) type="${type:1}" ;;
    esac
    case "$type" in
        path)
            printf '%s' "${value/#\~/$HOME}"
            ;;
        list:path)
            [ -n "$value" ] || return 0
            local -a elements=()
            IFS=':' read -ra elements <<< "$value"
            for element in "${elements[@]}"; do
                out="${out:+$out:}${element/#\~/$HOME}"
            done
            printf '%s' "$out"
            ;;
        *)
            printf '%s' "$value"
            ;;
    esac
}

# config_get <section> <key>
# The value, or the schema default when the key is absent from the file.
# "Absent" and "present but empty" are deliberately different: `ssh_key =`
# means no key, while omitting the line entirely means the default. Tracking
# that with a separate flag rather than testing the value for emptiness is
# what keeps `share_dir =` from silently becoming the default path.
_config_get_from_file() {
    local section="$1" want="$2" conf line cur="" key value type
    local found="" seen=0
    if ! type="$(config_type "$section.$want")"; then
        echo "unknown config key: [$section] $want" >&2
        return 1
    fi
    config_validate || return 1
    conf="$(config_path)"
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(_config_trim "$line")"
        case "$line" in
            ''|'#'*|';'*) continue ;;
            '['*']')
                cur="${line#\[}"
                cur="$(_config_trim "${cur%\]}")"
                continue
                ;;
        esac
        [ "$cur" = "$section" ] || continue
        key="$(_config_trim "${line%%=*}")"
        [ "$key" = "$want" ] || continue
        value="$(_config_trim "${line#*=}")"
        # Last assignment wins, so keep going rather than break.
        found="$value"
        seen=1
    done < "$conf"
    [ "$seen" = 1 ] || found="$(config_default "$section.$want")"
    _config_expand "$type" "$found"
}

# Thin wrapper so other callers are unaffected - bin/dejima redefines
# config_get itself, after sourcing this file, to consult per-launch flag
# overrides first and fall back to _config_get_from_file.
config_get() { _config_get_from_file "$@"; }

# config_is_set <section> <key>
# Whether the key APPEARS in the config file, as distinct from having a
# value: a key with a schema default always has a value, so "has a value" is
# the wrong question for anything asking what the operator configured.
config_is_set() {
    local section="$1" want="$2" conf line cur="" key
    if ! config_type "$section.$want" >/dev/null; then
        echo "unknown config key: [$section] $want" >&2
        return 1
    fi
    config_exists || return 1
    config_validate || return 1
    conf="$(config_path)"
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(_config_trim "$line")"
        case "$line" in
            ''|'#'*|';'*) continue ;;
            '['*']')
                cur="${line#\[}"
                cur="$(_config_trim "${cur%\]}")"
                continue
                ;;
        esac
        [ "$cur" = "$section" ] || continue
        key="$(_config_trim "${line%%=*}")"
        [ "$key" = "$want" ] && return 0
    done < "$conf"
    return 1
}

config_get_bool() {
    local value
    value="$(config_get "$1" "$2")" || return 1
    [ "$value" = "on" ] && printf '1' || printf '0'
}
