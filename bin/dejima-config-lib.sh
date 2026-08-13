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
# _config_spec and _config_keys read it, so a key cannot be lookup-able but
# missing from --print-config's enumeration.
#
# A "?" type prefix means empty is legal, distinguishing a setting that is
# meaningfully absent (ssh_key, loki_url) from one that must always have a
# value (firewall, share_dir).
#
# The axis keys are `provider:<axis>`, validated against the provider root
# rather than a fixed enum, so adding a provider is adding a directory.
# [forge.<name>] and [harness.<name>] keys are absent here for the same
# reason - enumerating them would make a new forge need a core edit. They
# resolve through the _config_extra_* functions below, stubbed here and
# overridden by dejima-provider-lib.sh, against each provider's own `keys`
# manifest entry.
# ---------------------------------------------------------------------------
_config_table() {
    cat <<'EOF'
core.harness	provider:harness
core.forge	provider:forge	none
core.workflow	provider:workflow	local-only
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
epitaph.enabled	bool	on
epitaph.dir	path	~/.local/share/dejima/epitaphs
epitaph.loki	bool	off
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
# The schema table, read into memory once per process. _config_table is a
# heredoc, so every call forked a `cat`; _config_spec called it per lookup and
# the validator called _config_spec per line, so a single config_get forked it
# dozens of times. The table is a compile-time constant - reading it more than
# once per process cannot produce a different answer.
declare -gA _CFG_TYPE=() _CFG_DEF=()
_CFG_SCHEMA_LOADED=0
_config_load_schema() {
    [ "$_CFG_SCHEMA_LOADED" = 1 ] && return 0
    local key type default
    while IFS=$'\t' read -r key type default; do
        [ -n "$key" ] || continue
        _CFG_TYPE["$key"]="$type"
        _CFG_DEF["$key"]="$default"
    done < <(_config_table)
    _CFG_SCHEMA_LOADED=1
}

_config_spec() {
    _config_load_schema
    if [ -n "${_CFG_TYPE[$1]+x}" ]; then
        printf '%s\t%s' "${_CFG_TYPE[$1]}" "${_CFG_DEF[$1]}"
        return 0
    fi
    _config_extra_spec "$1"
}

# config_type/config_default without the command substitution, for the two
# hot callers (the validator and the getter, both once per line). A core key
# is answered straight out of the schema map; only a provider key still pays
# for a subshell, and there are a handful of those rather than one per line.
_config_type_into() {
    local _spec
    _config_load_schema
    if [ -n "${_CFG_TYPE[$2]+x}" ]; then
        printf -v "$1" '%s' "${_CFG_TYPE[$2]}"
        return 0
    fi
    _spec="$(_config_extra_spec "$2")" || return 1
    [ -n "$_spec" ] || return 1
    printf -v "$1" '%s' "${_spec%%$'\t'*}"
}

config_type() {
    local _t
    _config_type_into _t "$1" || return 1
    printf '%s' "$_t"
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
        core|github|mounts|credentials|logging|audit|remote-access|epitaph) return 0 ;;
        *) _config_extra_section_known "$1" ;;
    esac
}

_config_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# The same trim, in place, into the named variable. Identical semantics; the
# difference is that it costs nothing. `$(_config_trim ...)` forks a subshell
# per call, and the parser calls it twice per line - so on a thirty-line
# config that was sixty forks per pass, and the file used to be walked twice
# for every single config_get. printf -v is a builtin, so this forks not at
# all. _config_trim is kept because it is a published shape other scripts and
# tests call.
_config_trim_into() {
    local _s="${2-}"
    _s="${_s#"${_s%%[![:space:]]*}"}"
    _s="${_s%"${_s##*[![:space:]]}"}"
    printf -v "$1" '%s' "$_s"
}

# Validates the whole file. Returns 1 and explains the FIRST problem found -
# reporting one actionable line beats a list the operator has to read
# bottom-up.
# Parsed once per process, into _CFG_VAL/_CFG_SEEN. Every read used to walk
# the whole file twice - once to validate it and once to find the key - so a
# launch's ~30 reads meant ~60 passes over the same unchanged bytes, each
# forking twice per line. Parsing once preserves the property the header
# describes exactly: every read still sees a fully validated file, and no read
# can succeed against a file another read would reject, because within a
# process there is now only one parse for them all to agree with.
#
# Keyed on the config path so a test that repoints DEJIMA_CONFIG_DIR mid-
# process re-parses rather than answering from the previous file's cache.
# config_reset() is for the rarer case of the same path being rewritten in
# place; nothing shipped does that today (install.sh writes the file but never
# reads a value back).
declare -gA _CFG_VAL=() _CFG_SEEN=()
_CFG_PARSED_PATH=""
_CFG_PARSE_STATUS=1

config_reset() {
    _CFG_VAL=()
    _CFG_SEEN=()
    _CFG_PARSED_PATH=""
    _CFG_PARSE_STATUS=1
}

config_validate() {
    local conf
    conf="$(config_path)"
    if [ "$_CFG_PARSED_PATH" = "$conf" ]; then
        return "$_CFG_PARSE_STATUS"
    fi
    # $? captured before anything else runs - an assignment would reset it to
    # 0 and cache every malformed config as valid.
    _config_parse "$conf"
    _CFG_PARSE_STATUS=$?
    _CFG_PARSED_PATH="$conf"
    return "$_CFG_PARSE_STATUS"
}

_config_parse() {
    local conf="$1" line section="" key value type
    _CFG_VAL=()
    _CFG_SEEN=()
    if [ ! -f "$conf" ]; then
        echo "no dejima config at $conf" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        _config_trim_into line "$line"
        case "$line" in
            ''|'#'*|';'*)
                continue
                ;;
            '['*']')
                section="${line#\[}"
                section="${section%\]}"
                _config_trim_into section "$section"
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
        _config_trim_into key "${line%%=*}"
        _config_trim_into value "${line#*=}"
        if ! _config_type_into type "$section.$key"; then
            echo "unknown key in $conf: [$section] $key" >&2
            return 1
        fi
        if ! _config_valid_value "$type" "$value"; then
            echo "invalid value for [$section] $key in $conf: $value" >&2
            return 1
        fi
        # Last assignment wins, which is why this overwrites rather than
        # keeping the first.
        _CFG_VAL["$section.$key"]="$value"
        _CFG_SEEN["$section.$key"]=1
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
    local section="$1" want="$2" type found
    if ! _config_type_into type "$section.$want"; then
        echo "unknown config key: [$section] $want" >&2
        return 1
    fi
    config_validate || return 1
    if [ -n "${_CFG_SEEN[$section.$want]+x}" ]; then
        found="${_CFG_VAL[$section.$want]}"
    else
        found="$(config_default "$section.$want")"
    fi
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
    local section="$1" want="$2" _t
    if ! _config_type_into _t "$section.$want"; then
        echo "unknown config key: [$section] $want" >&2
        return 1
    fi
    config_exists || return 1
    config_validate || return 1
    [ -n "${_CFG_SEEN[$section.$want]+x}" ]
}

config_get_bool() {
    local value
    value="$(config_get "$1" "$2")" || return 1
    [ "$value" = "on" ] && printf '1' || printf '0'
}
