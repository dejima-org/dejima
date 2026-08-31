#!/bin/bash
# Provider manifests: forges, workflows, harnesses.
#
# A provider is DATA. Nothing here sources, evals or executes anything from a
# provider directory - a manifest is parsed exactly the way the config file is,
# and a briefing fragment is prose that gets substituted into and then handed
# to an agent. The one thing a provider ships that does run is a forge's bin/,
# which is copied into the image as an ordinary program the agent invokes; that
# never feeds back into any decision core makes.
#
# This matters because provider directories are on the same footing as the rest
# of the repo, and the repo can be the mounted workspace (dejima sandboxing its
# own checkout). Parsing rather than sourcing is what keeps "a session edited a
# manifest" from meaning "a session ran code on the host at the next launch".

# shellcheck source=dejima-config-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/dejima-config-lib.sh"

MAX_MANIFEST_LINES=200

# DEJIMA_PROVIDER_ROOT is a test hook, not user configuration - the real root
# is always this repo, since providers ship with the code that reads them.
# ${BASH_SOURCE[0]%/*} rather than `dirname` - this is now called often
# enough (see _provider_keys_field) that an external process per call is
# real, avoidable cost; every caller already invokes this file by a path
# containing a "/", so the two are equivalent here.
# Resolved once, here, for the same subshell reason as the schema loads below:
# filling this on first use meant filling it again in every `$(...)` that
# reached it, which was a fork apiece and hundreds of them per launch.
_PROVIDER_ROOT_CACHE="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
# Assigns rather than prints, so a caller reaching it in a loop does not pay a
# `$( )` fork per call. provider_root below is the printing form for everyone
# who wants a value in a substitution anyway.
_provider_root_into() {
    if [ -n "${DEJIMA_PROVIDER_ROOT:-}" ]; then
        printf -v "$1" '%s' "$DEJIMA_PROVIDER_ROOT"
        return 0
    fi
    # Only the repo path is cached. The test hook is re-read every call, so a
    # test that repoints it mid-process still gets the directory it just set.
    [ -n "$_PROVIDER_ROOT_CACHE" ] || _PROVIDER_ROOT_CACHE="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
    printf -v "$1" '%s' "$_PROVIDER_ROOT_CACHE"
}

provider_root() {
    local _root
    _provider_root_into _root
    printf '%s' "$_root"
}

# Same assign-instead-of-print split as _provider_root_into, for the same
# reason: provider_dir is reached once per manifest read.
_provider_axis_dir_into() {
    case "$2" in
        forge)    printf -v "$1" 'forges' ;;
        workflow) printf -v "$1" 'workflows' ;;
        harness)  printf -v "$1" 'harnesses' ;;
        # Not an axis in the select-one sense the other three are: a launch
        # enables zero or more tools, and none is the default. It is here
        # because everything else about it is the same - a manifest that is
        # data, validated by the same schema machinery, never sourced.
        tool)     printf -v "$1" 'tools' ;;
        *) echo "unknown provider axis: $2" >&2; return 1 ;;
    esac
}

_provider_axis_dir() {
    local _sub
    _provider_axis_dir_into _sub "$1" || return 1
    printf '%s' "$_sub"
}

_provider_manifest_name() {
    case "$1" in
        forge)    printf 'forge.conf' ;;
        workflow) printf 'workflow.conf' ;;
        harness)  printf 'harness.conf' ;;
        tool)     printf 'tool.conf' ;;
        *) return 1 ;;
    esac
}

# A provider name reaches the filesystem, so it is validated as a single
# path-free token before it is ever joined to a directory. "..", "a/b" and the
# empty string are refused rather than normalised - a config naming one is a
# mistake, and quietly resolving it somewhere is how a traversal becomes a
# feature.
valid_provider_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

# `readlink -m` answers memoized per path, because the containment check below
# resolves the same axis directory once per provider and provider_dir is
# reached from inside each `$( manifest_get ... )`. What is cached is one
# path's resolution, not a verdict: every caller still runs the containment
# comparison and the -d check itself.
declare -gA _PROVIDER_REAL_CACHE=()
_provider_resolve_into() {
    [ -n "${_PROVIDER_REAL_CACHE[$2]+set}" ] \
        || _PROVIDER_REAL_CACHE["$2"]="$(readlink -m "$2")"
    printf -v "$1" '%s' "${_PROVIDER_REAL_CACHE[$2]}"
}

# Resolved once per root+axis+name. The two readlinks are the containment
# check, and it is called on every manifest read; keying the cache on the
# resolved root rather than just the name is what keeps a test that repoints
# DEJIMA_PROVIDER_ROOT from being answered about the previous one.
declare -gA _PROVIDER_DIR_CACHE=()
provider_dir() {
    local axis="$1" name="$2" sub root axis_root dir_real id
    _provider_axis_dir_into sub "$axis" || return 1
    if ! valid_provider_name "$name"; then
        echo "invalid $axis name: $name" >&2
        return 1
    fi
    _provider_root_into root
    id="$root:$axis:$name"
    if [ -n "${_PROVIDER_DIR_CACHE[$id]+set}" ]; then
        printf '%s' "${_PROVIDER_DIR_CACHE[$id]}"
        return 0
    fi
    _provider_resolve_into axis_root "$root/$sub"
    _provider_resolve_into dir_real "$root/$sub/$name"
    case "$dir_real/" in
        "$axis_root"/*) ;;
        *)  echo "refusing $axis '$name': it resolves outside $axis_root" >&2
            return 1 ;;
    esac
    if [ ! -d "$dir_real" ]; then
        echo "no such $axis: $name" >&2
        return 1
    fi
    # Only a resolved, contained, existing directory is cached, so a later
    # call can never be answered from a refusal.
    _PROVIDER_DIR_CACHE[$id]="$dir_real"
    printf '%s' "$dir_real"
}

# Overrides the stub in dejima-config-lib.sh. Deliberately not an enum baked
# into the schema: the point of the axes is that adding a provider is adding a
# directory, and a schema that had to be edited too would defeat it.
_config_extra_type_valid() {
    local type="$1" value="$2"
    case "$type" in
        provider:*)
            valid_provider_name "$value" || return 1
            [ -d "$(provider_root)/$(_provider_axis_dir "${type#provider:}")/$value" ] || return 1
            return 0
            ;;
        *) return 2 ;;
    esac
}

# Fills _PROVIDER_LIST_OUT rather than printing, so the warm-up at the bottom
# of this file can walk all three axes without a `$( )` fork apiece.
declare -ga _PROVIDER_LIST_OUT=()
_provider_list_into() {
    local axis="$1" sub root entry name
    _PROVIDER_LIST_OUT=()
    _provider_axis_dir_into sub "$axis" || return 1
    _provider_root_into root
    for entry in "$root/$sub"/*/; do
        [ -d "$entry" ] || continue
        name="${entry%/}"
        name="${name##*/}"
        valid_provider_name "$name" || continue
        _PROVIDER_LIST_OUT+=("$name")
    done
}

provider_list() {
    _provider_list_into "$1" || return 1
    [ "${#_PROVIDER_LIST_OUT[@]}" -eq 0 ] || printf '%s\n' "${_PROVIDER_LIST_OUT[@]}"
}

# Manifest schema. Same three-column shape as the config table: key, type,
# default. Types are the config file's own, so one validator set covers both.
_manifest_table() {
    case "$1" in
        # hosts_allowlisted_by_core (below) means "core already allowlists
        # these hosts in its own right" - today that is true only of
        # GitHub's published ranges (see bin/dejima's ALLOW_GITHUB_PUSH
        # wiring). A forge whose hosts are not among those must leave it
        # off: turning it on grants no firewall allowance at all (its hosts
        # never reach DEJIMA_FORGE_HOSTS) plus an irrelevant GitHub push
        # grant instead.
        forge) cat <<'EOF'
capabilities	?list:identifier
pr_command	?command
issue_command	?command
merge_block	?command
repo_flags	?list:flag
repo_env	?identifier
repo_paths	?list:repopath
identity_keys	?list:identifier
disclose	?disclosures
keys	?list:keyspec
requires	?list:identifier
host_keys	?list:identifier
url_keys	?list:identifier
fixed_hosts	?list:hostname
hosts_allowlisted_by_core	bool	off
install	?list:installspec
env_export	?list:export
EOF
            ;;
        # An optional tool. Deliberately small: a tool declares what it is,
        # what installs it, what its environment needs and what the session
        # should be told about it - and nothing that could change what dejima
        # permits. There is no key here for a hook, a mount, a domain or a
        # guard, because a tool that needed one of those would be a change to
        # the boundary rather than a program on PATH, and would have to be
        # argued for rather than declared.
        tool) cat <<'EOF'
description	text
install	depspec
install_layout	enum:prefix|binary	prefix
image_env	?list:envpair
command	identifier
instructions	?relpath
EOF
            ;;
        workflow) cat <<'EOF'
requires	?list:identifier
push	bool	on
blocked_branches	?list:identifier
block_merge	bool	on
requires_worktree	bool	off
autonomy	enum:commit|push-branch|open-pr	commit
briefing	?relpath
EOF
            ;;
        harness) cat <<'EOF'
install	?depspec
image_dirs	?list:homepath
image_files	?list:homepath
image_env	?list:envpair
command	identifier	claude
command_path	?path
api_domains	?list:hostname
proxied_api_domain	?hostname
guards	?list:identifier
briefing_args	?args
briefing_path	?homepath
no_confirm_args	?args
settings_args	?args
keys	?list:keyspec
resume_command	?template
transcript_update	enum:append|rewrite	append
briefing	?relpath
EOF
            ;;
        *) return 1 ;;
    esac
}

# Parses one KEY[:TYPE[=DEFAULT]] element of a forge/harness `keys` manifest
# value into NAME<TAB>TYPE<TAB>DEFAULT - the same three columns the config
# schema table itself uses, packed into a single manifest value so a forge or
# harness declares its own [forge.<name>]/[harness.<name>] schema instead of
# that schema being hardcoded in core. One parser, used by the value
# validator below and by dejima-config-lib.sh's _config_extra_spec/
# _config_extra_keys, so those cannot drift apart on how e.g. a path key
# with a tilde-expanded default splits. Returns 1 if there is no ':' at all
# (a bare name, with no type, is not a valid element).
_provider_keyspec_parse() {
    local spec="$1" name rest type default=""
    name="${spec%%:*}"
    rest="${spec#*:}"
    [ "$rest" != "$spec" ] || return 1
    if [[ "$rest" == *=* ]]; then
        type="${rest%%=*}"
        default="${rest#*=}"
    else
        type="$rest"
    fi
    printf '%s\t%s\t%s' "$name" "$type" "$default"
}

# Read into _MFT_TYPE/_MFT_DEF on first use per axis, the way
# _config_load_schema reads the config table. Every lookup below went through
# a process substitution over the heredoc above, so a launch paid two forks
# per manifest key it resolved, several hundred times over.
declare -gA _MFT_TYPE=() _MFT_DEF=()
_MFT_LOADED=" "
_manifest_load_schema() {
    local axis="$1" key type default
    [[ "$_MFT_LOADED" == *" $axis "* ]] && return 0
    while IFS=$'\t' read -r key type default; do
        [ -n "$key" ] || continue
        _MFT_TYPE["$axis.$key"]="$type"
        _MFT_DEF["$axis.$key"]="$default"
    done < <(_manifest_table "$axis")
    # An unknown axis loads no keys, so every lookup against it still misses
    # and returns 1 - marking it loaded only stops the empty read repeating.
    _MFT_LOADED="$_MFT_LOADED$axis "
}

# Every axis, at source time, for the reason _config_load_schema is called at
# source time: manifest_get is reached through `$(...)` almost everywhere, and
# a cache populated in a subshell is discarded with it. There are three axes
# and the tables are compile-time constants, so loading all of them costs one
# pass and removes the re-read from every subshell that follows.
_manifest_load_schema forge
_manifest_load_schema workflow
_manifest_load_schema harness

# Every shipped provider's directory, resolved here for the same reason.
# provider_dir does two readlinks and a containment check per call, caches the
# result, and is then called from inside `$(manifest_get ...)` - so the cache
# was rebuilt in each subshell and the readlinks paid again. There are a
# handful of provider directories and the resolution cannot change during a
# run, so doing all of them once costs a fixed few forks and removes the
# repeat from every manifest read that follows.
#
# Failures are ignored: an unreadable or missing directory is not this loop's
# to report, and provider_dir refuses it again with its own message when
# something actually asks for it.

_manifest_spec() {
    local axis="$1" want="$2"
    _manifest_load_schema "$axis"
    [ -n "${_MFT_TYPE["$axis.$want"]+set}" ] || return 1
    printf '%s\t%s' "${_MFT_TYPE["$axis.$want"]}" "${_MFT_DEF["$axis.$want"]}"
}

# Types the config file does not have, all deliberately narrow because each
# ends up somewhere that punishes a loose one.
_provider_valid_value() {
    local type="$1" value="$2" optional=0 element
    if [ "${type:0:1}" = "?" ]; then optional=1; type="${type:1}"; fi
    if [ -z "$value" ]; then [ "$optional" = 1 ]; return; fi
    case "$type" in
        command)
            # Lands in prose an agent will run. Space-separated words only, so
            # a bare command name and a multi-word one like "gh pr" both fit
            # and nothing shell-active does.
            [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*( [A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]
            ;;
        flag)
            # A command-line option name, compared against argv by
            # docker/forge-guard.sh. The leading dash is required: without it
            # the guard would be comparing a word that could just as well be a
            # subcommand or a value.
            [[ "$value" =~ ^--?[A-Za-z0-9][A-Za-z0-9-]*$ ]]
            ;;
        repopath)
            # A repository named in a path rather than in a flag:
            # `<subcommand>:<first path segment>`, as in `api:repos` for
            # `gh api repos/<owner>/<name>/...`.
            #
            # Scoped to a subcommand because the alternative is comparing every
            # positional argument that happens to contain two slashes, and a
            # false refusal on an issue title is worse than the miss - this is
            # a fast-fail, so a wrong yes costs an honest agent a working
            # command. The guard applies it only when the subcommand is argv's
            # first word.
            case "$value" in *:*) ;; *) return 1 ;; esac
            local sub="${value%%:*}" seg="${value#*:}"
            [[ "$sub" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || return 1
            [[ "$seg" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
            ;;
        relpath)
            # Joined to a provider directory, so no absolute paths and no
            # traversal - a manifest may only name a file it ships.
            [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] && [[ "$value" != *".."* ]]
            ;;
        disclosures)
            # Which of this forge's commands write a body a person authored,
            # and what kind of artifact each one writes. Comma-separated
            # because every entry is multi-word, unlike every other list here.
            #
            #   disclose = pr:<cli> create, issue:<other cli> create
            #
            # The kind selects the marker; the marker text itself is core's
            # (docker/forge-guard.sh), so that what dejima says about agent
            # authorship cannot come out differently per forge.
            # An empty entry is a typo, not an entry to skip - the same
            # reading the list types take of a trailing separator. Checked on
            # the raw string, because word splitting discards it silently.
            case "$value" in ,*|*,) return 1 ;; esac
            [[ "$value" =~ ,[[:space:]]*, ]] && return 1
            local entry kind rest
            local IFS=,
            for entry in $value; do
                # Leading and trailing space around each comma-separated entry.
                entry="${entry#"${entry%%[![:space:]]*}"}"
                entry="${entry%"${entry##*[![:space:]]}"}"
                [ -n "$entry" ] || return 1
                case "$entry" in
                    pr:*|issue:*|comment:*) ;;
                    *) return 1 ;;
                esac
                kind="${entry%%:*}"
                rest="${entry#*:}"
                [ -n "$kind" ] || return 1
                _provider_valid_value command "$rest" || return 1
            done
            ;;
        installspec)
            # A CLI this forge puts on PATH: either a file it ships, or
            # "system:<name>" for one the image already provides.
            #
            # The second form exists because a forge CLI has to be reachable
            # behind the shadow whether or not this repo wrote it - that is
            # where docker/forge-guard.sh execs the real command through, and
            # a forge naming a command that never gets there has a merge block
            # that cannot be enforced. Declaring it here rather than special
            # -casing the name in the image build is also what keeps the
            # manifest a complete account of what this forge puts in /usr/local
            # /bin, which is the reading the audit depends on.
            case "$value" in
                system:*)
                    [[ "${value#system:}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
                    ;;
                *)  _provider_valid_value relpath "$value" ;;
            esac
            ;;
        homepath)
            # A directory the harness needs inside the sandbox user's home,
            # created in that harness's image layer. Relative to $HOME and
            # nothing else: a leading slash would put it anywhere on the
            # filesystem and `..` would walk out of the home it is scoped to,
            # and both reach a `mkdir -p` running as root at build time.
            # Unlike `relpath` a leading dot is allowed, because the
            # directories a harness keeps state in are dotfiles.
            case "$value" in
                /*|.|./*|*/..|*/../*|..|../*) return 1 ;;
                */) return 1 ;;
            esac
            [[ "$value" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]]
            ;;
        envpair)
            # NAME=VALUE, becoming an ENV line in that harness's image layer.
            # The value is deliberately narrow rather than quoted around: no
            # whitespace and nothing shell-active, so there is no quoting to
            # get wrong in a generated Dockerfile.
            [[ "$value" =~ ^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:/+-]+$ ]]
            ;;
        depspec)
            # The same grammar an operator's approved dependency goes through,
            # checked by the same function - see dejima-config-lib.sh. What a
            # harness declares here is interpolated into a Dockerfile RUN line
            # that runs at build time, so nothing shell-active may survive it.
            valid_dep_spec "$value"
            ;;
        export)
            # NAME=key or NAME=@key. The "@" form means "the contents of the
            # file at that config key" and is how a token reaches the container
            # without the path being mistaken for the secret.
            [[ "$value" =~ ^[A-Z][A-Z0-9_]*=@?[a-z][a-z0-9_]*$ ]]
            ;;
        args)
            # Same charset as template, and deliberately a separate type:
            # these are passed to the harness as arguments and never go
            # through briefing composition, so a {{...}} in one would ship
            # literally rather than being substituted. Naming it template
            # promised a substitution that does not happen.
            _provider_valid_value template "$value"
            ;;
        template)
            # Prose with {{placeholders}}; the placeholder names themselves are
            # checked against the whitelist at composition time, not here.
            [[ "$value" =~ ^[-A-Za-z0-9{}\ ._:/]+$ ]]
            ;;
        keyspec)
            # One element of a forge/harness `keys` list - see
            # _provider_keyspec_parse. The default is validated against its
            # own type with the config file's own validator, the same check a
            # value for this key would get in the config file, so a bad
            # default is caught here rather than the first time an operator's
            # config happens to omit the key. A non-optional type (no "?"
            # prefix) must have a non-empty default, mirroring the invariant
            # every hardcoded core schema row already holds: "always has a
            # value" only means something if there is one.
            local pname ptype pdefault pspec
            pspec="$(_provider_keyspec_parse "$value")" || return 1
            IFS=$'\t' read -r pname ptype pdefault <<< "$pspec"
            [[ "$pname" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
            [ -n "$ptype" ] || return 1
            if [ "${ptype:0:1}" != "?" ] && [ -z "$pdefault" ]; then
                return 1
            fi
            _config_valid_value "$ptype" "$pdefault"
            ;;
        list:*)
            # SPACE-separated, unlike the config file's colon-separated lists.
            # Deliberate - a manifest list is a set of tokens (capabilities,
            # key names, hostnames), never paths, so space reads better and a
            # colon would be surprising next to "gh pr". Because this branch
            # comes before the delegation below, config-lib's colon-splitting
            # list handler is never reached from a manifest.
            local member="${type#list:}"
            local -a elements=()
            IFS=' ' read -ra elements <<< "$value"
            for element in "${elements[@]}"; do
                _provider_valid_value "$member" "$element" || return 1
            done
            ;;
        *)
            _config_valid_value "$type" "$value"
            ;;
    esac
}

# Each manifest is parsed once per process, into _MF_VAL/_MF_SEEN, for the
# reason dejima-config-lib.sh gives for doing the same to the config file:
# every read then sees a fully validated file, and no read can succeed
# against a file another read would reject, because within a process there is
# one parse for them all to agree with. It is also what makes a read cheap -
# validating and then re-walking the same unchanged bytes on each of a
# launch's ~35 manifest_get calls was several forks per line, 35 times over.
#
# Keyed on the axis and the RESOLVED directory rather than the provider name,
# the way config_validate keys on the config path: a test that repoints
# DEJIMA_PROVIDER_ROOT mid-process is then re-parsed rather than answered
# about the root it used to have. provider_reset() is for the rarer case of a
# manifest being rewritten in place under an unchanged path; nothing shipped
# does that, and each test invokes the library in a fresh shell.
declare -gA _MF_VAL=() _MF_SEEN=() _MF_STATUS=()

provider_reset() {
    _MF_VAL=()
    _MF_SEEN=()
    _MF_STATUS=()
}

manifest_validate() {
    local axis="$1" name="$2" dir id
    dir="$(provider_dir "$axis" "$name")" || return 1
    id="$axis:$dir"
    if [ -n "${_MF_STATUS[$id]+set}" ]; then
        return "${_MF_STATUS[$id]}"
    fi
    # $? captured before anything else runs - an assignment would reset it to
    # 0 and cache every malformed manifest as valid.
    _manifest_parse "$axis" "$name" "$dir" "$id"
    _MF_STATUS[$id]=$?
    return "${_MF_STATUS[$id]}"
}

# Every shipped provider's DIRECTORY, resolved here. Same subshell reason as
# the schema loads above: provider_dir does two readlinks and a containment
# check per call, caches the result, and is reached from inside
# `$(manifest_get ...)` - so each of those subshells rebuilt the cache and
# paid the forks again. There are a handful of providers and the resolution
# cannot change during a run.
#
# Deliberately NOT the manifests. Parsing those means validating every value
# in them, and most providers are not the selected one - warming all of them
# measured slower than leaving them alone. bin/dejima warms the three it
# actually selected instead, once it knows which those are.
#
# Failures are ignored: a missing or unreadable directory is not this loop's
# to report, and provider_dir refuses it again when something asks.
#
# One `readlink -m` for every path rather than two per provider. It takes
# several operands and prints one resolved path per line, so the warm-up costs
# a single process instead of one per directory - which is most of what
# sourcing this file costs, and is paid by every `bin/dejima` invocation and
# every test that drives the library in a fresh shell. The batch only fills
# the resolution cache; provider_dir still does its own containment check
# against what it finds there.
_provider_warm_dirs() {
    local axis sub root name path i=0
    local -a axes=() names=() paths=() lines=()
    _provider_root_into root
    for axis in forge workflow harness; do
        _provider_axis_dir_into sub "$axis" || continue
        paths+=("$root/$sub")
        _provider_list_into "$axis" || continue
        for name in "${_PROVIDER_LIST_OUT[@]}"; do
            axes+=("$axis")
            names+=("$name")
            paths+=("$root/$sub/$name")
        done
    done
    mapfile -t lines < <(readlink -m -- "${paths[@]}" 2>/dev/null)
    # A path containing a newline would desync the one-line-per-operand
    # pairing. Nothing shipped can produce one - names are validated and the
    # root comes from `pwd` - but a mismatched count means the pairing cannot
    # be trusted, so the batch is dropped rather than cached wrong. provider_dir
    # then resolves each path itself, exactly as it would have.
    if [ "${#lines[@]}" -eq "${#paths[@]}" ]; then
        for path in "${paths[@]}"; do
            _PROVIDER_REAL_CACHE["$path"]="${lines[$i]}"
            i=$((i + 1))
        done
    fi
    for i in "${!names[@]}"; do
        provider_dir "${axes[$i]}" "${names[$i]}" >/dev/null 2>&1 || true
    done
}
_provider_warm_dirs

_manifest_parse() {
    local axis="$1" name="$2" dir="$3" id="$4" file line key value type line_count
    # Staged, and committed to _MF_VAL only once the whole file has passed, so
    # a manifest that is refused halfway leaves no half of itself readable.
    local -A staged=()
    file="$dir/$(_provider_manifest_name "$axis")"
    if [ ! -f "$file" ]; then
        echo "$axis $name has no manifest at $file" >&2
        return 1
    fi
    line_count=$(wc -l < "$file")
    if [ "$line_count" -gt "$MAX_MANIFEST_LINES" ]; then
        echo "$file exceeds $MAX_MANIFEST_LINES lines" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        _config_trim_into line "$line"
        case "$line" in
            ''|'#'*|';'*) continue ;;
            *=*) ;;
            *) echo "malformed line in $file: $line" >&2; return 1 ;;
        esac
        _config_trim_into key "${line%%=*}"
        _config_trim_into value "${line#*=}"
        if ! type="$(_manifest_type "$axis" "$key")"; then
            echo "unknown key in $file: $key" >&2
            return 1
        fi
        if ! _provider_valid_value "$type" "$value"; then
            echo "invalid value for $key in $file: $value" >&2
            return 1
        fi
        staged["$key"]="$value"
    done < "$file"
    if [ "${#staged[@]}" -gt 0 ]; then
        for key in "${!staged[@]}"; do
            _MF_VAL["$id:$key"]="${staged[$key]}"
            _MF_SEEN["$id:$key"]=1
        done
    fi
    return 0
}

_manifest_type() {
    _manifest_load_schema "$1"
    [ -n "${_MFT_TYPE["$1.$2"]+set}" ] || return 1
    printf '%s' "${_MFT_TYPE["$1.$2"]}"
}

_manifest_default() {
    _manifest_load_schema "$1"
    [ -n "${_MFT_TYPE["$1.$2"]+set}" ] || return 1
    printf '%s' "${_MFT_DEF["$1.$2"]}"
}

# manifest_get <axis> <name> <key>
# Validates the whole manifest first, same reason config_get does: a read must
# never succeed against a file another read would reject.
manifest_get() {
    local axis="$1" name="$2" want="$3" dir id
    _manifest_type "$axis" "$want" >/dev/null || {
        echo "unknown $axis manifest key: $want" >&2; return 1; }
    manifest_validate "$axis" "$name" || return 1
    dir="$(provider_dir "$axis" "$name")" || return 1
    id="$axis:$dir:$want"
    if [ -n "${_MF_SEEN[$id]+set}" ]; then
        printf '%s' "${_MF_VAL[$id]}"
    else
        _manifest_default "$axis" "$want"
    fi
}

# ---------------------------------------------------------------------------
# [forge.<name>] / [harness.<name>] config schema, derived from each
# provider's own `keys` manifest entry. Overrides the three
# dejima-config-lib.sh extension-point stubs (_config_extra_section_known,
# _config_extra_spec, _config_extra_keys) so the config schema table stays
# free of any one provider's name - adding a forge or harness is adding a
# directory whose manifest declares its own keys, not editing core.
# ---------------------------------------------------------------------------

# Reached from inside config_validate's own parse - each [forge.<name>] line
# calls back here - so it line-scans the `keys` field alone rather than going
# through manifest_validate. What it feeds is a config schema type check,
# never a forge action; every other field still gets a full manifest_validate
# before anything consequential reads it.
#
# Reads and validates only the `keys = ...` line of a forge/harness manifest
# - see above for why this bypasses manifest_get's full-manifest validation. Trimming is inlined (_config_trim's own logic,
# not a call to it) and the line count uses bash's own read loop instead of
# `wc -l`, both to avoid a subshell/external-process fork per manifest line:
# this runs once per key in a [forge.<name>]/[harness.<name>] section, on
# every config_validate pass that has not already been answered from cache.
_provider_keys_field() {
    local axis="$1" name="$2" dir file line key value="" seen=0 type n=0
    # An unselected axis contributes no keys - a different question from
    # whether a selection is valid. Without this, --print-config prints
    # "invalid harness name:" and fails at the thing it is for.
    [ -n "$name" ] || return 1
    dir="$(provider_dir "$axis" "$name")" || return 1
    file="$dir/$(_provider_manifest_name "$axis")"
    [ -f "$file" ] || return 1
    type="$(_manifest_type "$axis" keys)" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [ "$n" -le "$MAX_MANIFEST_LINES" ] || return 1
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in ''|'#'*|';'*) continue ;; *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        [ "$key" = keys ] || continue
        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        seen=1
    done < "$file"
    [ "$seen" = 1 ] || value="$(_manifest_default "$axis" keys)"
    _provider_valid_value "$type" "$value" || return 1
    printf '%s' "$value"
}

# A section is known only when a provider directory for its name actually
# exists - provider_dir carries the same name/containment checks
# _config_extra_type_valid already relies on for the provider: config types.
_config_extra_section_known() {
    local section="$1" axis name
    case "$section" in
        forge.*)   axis=forge;   name="${section#forge.}" ;;
        harness.*) axis=harness; name="${section#harness.}" ;;
        # An identity is the operator's own name for a set of credentials, so
        # there is no directory to check it against - only that it is a name
        # at all. Unlike a provider, an unused one is not a misconfiguration:
        # having [identity.oss] on a machine that never selects it is the
        # normal state of a second account.
        identity.*)
            name="${section#identity.}"
            valid_provider_name "$name"
            return
            ;;
        *) return 1 ;;
    esac
    provider_dir "$axis" "$name" >/dev/null 2>&1
}

# The keys an [identity.<name>] section may carry, as "<key>\t<type>" lines.
#
# ssh_key and the git identity are core's, because every forge needs the same
# two answers to "who is pushing". Everything else is declared by a forge's
# identity_keys and typed by that forge's own keys entry, so the identity
# inherits the validation the forge already wrote rather than a second copy of
# it that could disagree.
#
# A key name declared by two forges resolves to one type here, which is why a
# static test refuses that collision rather than this function guessing.
_identity_key_specs() {
    printf 'ssh_key	?path
'
    printf 'user_name	?text
'
    printf 'user_email	?text
'
    local forge key spec
    for forge in $(provider_list forge); do
        for key in $(manifest_get forge "$forge" identity_keys); do
            for spec in $(_provider_keys_field forge "$forge"); do
                [ "${spec%%:*}" = "$key" ] || continue
                # The forge's own type, with its default deliberately dropped:
                # a default belongs to the forge's section, and repeating it
                # here would make an identity that names no token look like one
                # that named the default path.
                printf '%s\t?%s\n' "$key" \
                    "$(cut -f2 <<< "$(_provider_keyspec_parse "$spec")" | sed 's/^?//')"
            done
        done
    done
}

# Looks up one [forge.<name>]/[harness.<name>] key's TYPE<TAB>DEFAULT in that
# provider's `keys` manifest entry instead of a row hardcoded in core.
_config_extra_spec() {
    local want="$1" axis rest name key spec pname ptype pdefault
    case "$want" in
        forge.*)   axis=forge ;;
        harness.*) axis=harness ;;
        identity.*)
            rest="${want#identity.}"
            key="${rest#*.}"
            [ "$key" != "$rest" ] || return 1
            while IFS=$'\t' read -r pname ptype; do
                [ "$pname" = "$key" ] || continue
                printf '%s\t' "$ptype"
                return 0
            done < <(_identity_key_specs)
            return 1
            ;;
        *) return 1 ;;
    esac
    rest="${want#*.}"
    name="${rest%%.*}"
    key="${rest#*.}"
    [ "$key" != "$rest" ] || return 1
    # No separate provider_dir check here - _provider_keys_field already
    # refuses when the directory doesn't exist, and this runs often enough
    # (see its comment) that a second containment check per call is real,
    # avoidable cost.
    for spec in $(_provider_keys_field "$axis" "$name"); do
        pname="${spec%%:*}"
        [ "$pname" = "$key" ] || continue
        IFS=$'\t' read -r pname ptype pdefault <<< "$(_provider_keyspec_parse "$spec")"
        printf '%s\t%s' "$ptype" "$pdefault"
        return 0
    done
    return 1
}

# What the selected identity says about one key, if anything.
#
# An identity answers for the credentials and the git name a PERSON brings to
# a project, which is the half a project cannot declare: .dejima/ is committed
# and shared, and a key path is per-user and per-machine. The project (or the
# operator) names an identity; the identity supplies the paths.
#
# Returns 1 for a key no identity owns, which is most of them - the caller
# then reads the config file as before. Deliberately narrow: an identity that
# could set any key would be a second config file with different rules about
# what may be in it.
#
# core.identity itself is excluded, and not merely by convention: the caller
# that consults this is bin/dejima's config_get wrapper, so answering for the
# key that names the identity would recurse into itself.
# Whether the named identity exists in the config at all - any of its keys
# being present is enough, because a section with no keys is not a section
# the parser records.
#
# The check that matters: [core] identity naming a section nobody wrote is a
# silent fall-through to the machine's defaults, which is the wrong direction
# to be wrong in. Pushing under the wrong key fails loudly; pushing under the
# default key when you asked for another one does not fail at all.
identity_exists() {
    local name="$1" key
    [ -n "$name" ] || return 1
    valid_provider_name "$name" || return 1
    while IFS=$'\t' read -r key _; do
        config_is_set "identity.$name" "$key" && return 0
    done < <(_identity_key_specs)
    return 1
}

# The credential keys the selected identity leaves to the section beneath it,
# as "<section> <key>" lines, empty when there are none.
#
# Only the selected forge's, because refusing over a credential belonging to a
# forge this launch does not use would be refusing over a value nothing reads.
#
# "Set" means written in the config file, not resolved from a schema default.
# A forge whose credential key carries a default still hands an identity that
# names none the machine's own path, and that is not caught here - see
# docs/configuration.md, which says so rather than leaving it to be found.
identity_borrowed_credentials() {
    local name="$1" forge="$2" key
    if ! config_is_set "identity.$name" ssh_key && config_is_set core ssh_key; then
        printf 'core	ssh_key
'
    fi
    for key in $(manifest_get forge "$forge" identity_keys); do
        if ! config_is_set "identity.$name" "$key" \
            && config_is_set "forge.$forge" "$key"; then
            printf 'forge.%s	%s
' "$forge" "$key"
        fi
    done
}

# Whether the selected identity, if there is one, is one a session can act
# under without borrowing from anyone.
#
# Two refusals, one reason. A name with no section resolves to nothing and
# falls through to the machine's own credentials; a section that names only
# some of them falls through for the rest. Either way a session launched as
# this identity acts under another account, and nothing says so. Pushing under
# the wrong key fails loudly; pushing under the default key when you asked for
# another one does not fail at all, which is the direction worth being careful
# about.
#
# One function rather than a check at each caller: bin/dejima's --print-config
# needs the same answer, because every value it prints resolves THROUGH the
# identity and printing this machine's credentials under an identity's name is
# the confusion the refusal exists to prevent.
#
# Guarded on the config existing rather than swallowing config_get's stderr:
# with no file at all it says so, and a selection validated without one is a
# legitimate case this must stay silent for.
# The identity in force: [core] identity when it names one, and otherwise the
# reserved `default` section when the config has one.
#
# `default` is what [core] ssh_key was without a name. Giving it one is what
# lets a host state its ordinary account the same way it states any other,
# with a git name and a forge credential beside the key rather than those
# coming from three different places.
#
# Empty when neither applies, which is the pre-identity config and still a
# supported one.
# Assigns rather than prints, and every caller uses this form. identity_get
# runs on every config_get through bin/dejima's wrapper, and `$(...)` around
# an answer this cheap costs a fork per read - which is most of what a launch
# spends on config.
identity_selected_into() {
    local __var="$1" __name=""
    if config_exists; then
        __name="$(config_get core identity)" || __name=""
        if [ -z "$__name" ] && _identity_section_present default; then
            __name=default
        fi
    fi
    printf -v "$__var" '%s' "$__name"
}

identity_selected() {
    local _n
    identity_selected_into _n
    printf '%s' "$_n"
}

# Whether a section has any key in the parsed config, read straight off the
# parse rather than through identity_exists.
#
# identity_exists walks every forge's manifest to decide which keys count, and
# bin/dejima's config_get wrapper reaches this on every single read - which
# turned a --print-config from three seconds into forty. It does not need the
# manifest: the parser refuses an unknown key outright, so anything present
# under identity.<name> in a config that validated is already one of the keys
# identity_exists would have accepted.
_identity_section_present() {
    local name="$1" k
    config_exists || return 1
    config_validate || return 1
    for k in "${!_CFG_SEEN[@]}"; do
        case "$k" in "identity.$name".*) return 0 ;; esac
    done
    return 1
}

identity_validate() {
    local forge="$1" name="" borrowed section key
    name="$(identity_selected)"

    # [core] ssh_key is the default identity under its old name, so a config
    # holding both says the same thing twice and dejima would have to pick.
    # Refused rather than ranked: which key a session pushed with is not a
    # thing to work out from precedence rules.
    if identity_exists default && config_is_set core ssh_key; then
        echo "[core] ssh_key is set and so is [identity.default], which is the same" >&2
        echo "thing under two names - the key a session gets when none is asked for." >&2
        echo "Move it into [identity.default] and remove [core] ssh_key." >&2
        echo "See docs/configuration.md, \"Identities\"." >&2
        return 1
    fi

    # Deprecated, not removed: it is how every config written before
    # identities existed says this, and those still work. Warned on every
    # launch that has it set, not only the ones using it - a config with
    # [core] ssh_key and a named identity is one migration away from the
    # refusal above, and finding that out on the launch that breaks is worse
    # than being told now.
    #
    # Every launch rather than once, because there is nowhere to record
    # "once" that a session could not reach, and a deprecation nobody sees
    # until removal is not a deprecation.
    if config_is_set core ssh_key; then
        printf '  %s[core] ssh_key is deprecated%s - it is [identity.default] ssh_key\n' \
            "${C_WARN:-}" "${C_RESET:-}" >&2
        printf '  under its old name.\n' >&2
        if [ -n "$name" ]; then
            printf '  This launch runs as %s%s%s, so it is not the key being used here.\n' \
                "${C_KEY:-}" "$name" "${C_RESET:-}" >&2
        else
            printf '  Nothing else names an account, so it is the key this launch uses.\n' >&2
        fi
        printf '  Move it into an [identity.default] section, which can carry the git\n' >&2
        printf '  name and the forge credential belonging to that same account:\n\n' >&2
        # The value in the file, not through config_get: in this process
        # config_get is bin/dejima's wrapper, so with a named identity in
        # force it answers with THAT identity's key - and printing it as the
        # thing to move would name a key the operator is not being asked to
        # touch.
        printf '      [identity.default]\n      ssh_key = %s\n\n' \
            "$(_config_get_from_file core ssh_key)" >&2
    fi

    [ -n "$name" ] || return 0

    if ! identity_exists "$name"; then
        echo "[core] identity is '$name', and no [identity.$name] section sets" >&2
        echo "anything in $(config_path). An identity that resolves to nothing would" >&2
        echo "quietly use this machine's own credentials instead - refusing rather than" >&2
        echo "doing that. See docs/configuration.md, \"Identities\"." >&2
        return 1
    fi

    borrowed="$(identity_borrowed_credentials "$name" "$forge")"
    [ -n "$borrowed" ] || return 0
    echo "[identity.$name] leaves a credential to the section beneath it, so a" >&2
    echo "session launched as '$name' would act under whichever account owns:" >&2
    while IFS=$'\t' read -r section key; do
        [ -n "$key" ] || continue
        echo "  [$section] $key" >&2
    done <<< "$borrowed"
    echo "An identity is how one session's account is kept separate from another's;" >&2
    echo "set each of those under [identity.$name], or unset it in the section named." >&2
    echo "See docs/configuration.md, \"Identities\"." >&2
    return 1
}

identity_get() {
    local section="$1" key="$2" name value pname
    [ "$section.$key" != "core.identity" ] || return 1
    # Which keys an identity could own, before working out which identity is
    # in force: this runs on every config_get, and all but a handful of keys
    # are ones no identity can answer for. Resolving the identity first meant
    # doing that work ~40 times a launch to discard it ~35 of those times.
    case "$section" in
        core)       [ "$key" = ssh_key ] || return 1 ;;
        forge.*)    ;;
        *)          return 1 ;;
    esac
    identity_selected_into name
    [ -n "$name" ] || return 1
    # The manifest lookup last, for the same reason: it forks, and by here
    # there is an identity that might actually answer.
    case "$section" in
        forge.*) _forge_owns_identity_key "${section#forge.}" "$key" || return 1 ;;
    esac
    value="$(config_get "identity.$name" "$key")" || return 1
    [ -n "$value" ] || return 1
    printf '%s' "$value"
}

# Whether one forge declared this key as naming an account rather than the
# forge itself - a credential a session acts under, not a setting like an API
# URL that every session on this host shares.
_forge_owns_identity_key() {
    local forge="$1" key="$2" k
    for k in $(manifest_get forge "$forge" identity_keys); do
        [ "$k" = "$key" ] && return 0
    done
    return 1
}

# The git name and address the identity carries, for the gitconfig copy the
# container gets. Not core config keys: the host's own ~/.gitconfig is where
# they come from without an identity, and adding a second place to set them
# globally would be a new way to get the same answer.
identity_git_field() {
    local field="$1" name
    name="$(identity_selected)" || return 1
    [ -n "$name" ] || return 1
    config_get "identity.$name" "$field"
}

# One key of the SELECTED harness, rather than of a harness named literally
# at the call site.
#
# `keys` is declared per harness, so reading one through a fixed section name
# makes it a declaration only one harness can ever be read through: a second
# harness gets selected, gets validated, and is then handed the first one's
# paths with nothing erroring anywhere. That is a silent wrong answer rather
# than a failure, which is why it is worth a helper rather than a longer
# expression at each site.
#
# Empty when no harness is selected. bin/dejima refuses to start in that
# state (there is no default, deliberately - see [core] harness), so it is
# reachable only from the standalone tools, where a harness-specific path
# that resolves to nothing is the honest answer for "no harness chosen".
harness_config_get() {
    local name
    name="$(config_get core harness)"
    [ -n "$name" ] || return 0
    config_get "harness.$name" "$1"
}

# Every guard rail dejima knows how to apply. A harness declares which of
# them it can host, in its manifest's `guards`; the ones it cannot are named
# at launch (see harness_report_guards) rather than quietly absent.
#
# Here rather than in dejima-harness-lib.sh because provider_validate_selection
# rejects a name outside this set, and a constant the validation depends on
# has to live where the validation does - providers.bats sources only this
# file, and against an empty set every guard is unknown.
DEJIMA_KNOWN_GUARDS="bash-deny push-guard merge-guard notify"

# Enumerates the keys of the SELECTED forge/harness (core.forge/core.harness,
# falling back to their schema default when no config file exists yet to
# read a selection from - e.g. an isolated call against a fresh checkout)
# rather than every installed provider's keys: --print-config is "what is
# actually in effect", and an unselected forge's keys are not.
_config_extra_keys() {
    local forge harness
    if config_exists && config_validate >/dev/null 2>&1; then
        forge="$(config_get core forge)"
        harness="$(config_get core harness)"
    else
        forge="$(config_default core.forge)"
        harness="$(config_default core.harness)"
    fi
    _config_extra_keys_for forge "$forge"
    _config_extra_keys_for harness "$harness"
}

_config_extra_keys_for() {
    local axis="$1" name="$2" spec
    for spec in $(_provider_keys_field "$axis" "$name"); do
        printf '%s.%s.%s\n' "$axis" "$name" "${spec%%:*}"
    done
}

# Space-separated set membership, for capability and requirement lists.
_set_contains() {
    local haystack=" $1 " needle="$2"
    [[ "$haystack" == *" $needle "* ]]
}

provider_validate_selection() {
    local forge="$1" workflow="$2" harness="$3"
    local caps requires need key set_n unset_n missing

    manifest_validate forge "$forge" || return 1
    manifest_validate workflow "$workflow" || return 1
    manifest_validate harness "$harness" || return 1

    # Every guard rail dejima knows how to apply. A harness declares which of
    # them it can host; the ones it cannot are named at launch rather than
    # quietly absent, because an operator who has them everywhere else would
    # otherwise have to read a manifest to find out they are gone here.
    #
    identity_validate "$forge" || return 1

    # A name outside this set is a hard error rather than an unknown guard
    # treated as absent: a typo would otherwise silently turn a guard off,
    # which is the failure this whole declaration exists to prevent.
    local guard
    for guard in $(manifest_get harness "$harness" guards); do
        case " $DEJIMA_KNOWN_GUARDS " in
            *" $guard "*) ;;
            *)
                echo "harness '$harness' declares an unknown guard: $guard" >&2
                echo "Known guards: $DEJIMA_KNOWN_GUARDS" >&2
                return 1 ;;
        esac
    done

    caps="$(manifest_get forge "$forge" capabilities)"
    requires="$(manifest_get workflow "$workflow" requires)"
    for need in $requires; do
        if ! _set_contains "$caps" "$need"; then
            echo "workflow '$workflow' requires the '$need' capability, which forge" >&2
            echo "'$forge' does not provide (it offers: ${caps:-none})." >&2
            return 1
        fi
    done

    # Autonomy names where the agent stops without asking, so it is a claim
    # about what the selected forge can actually do. Checked here rather than
    # left to the briefing: a mismatch discovered by the agent mid-task is a
    # confusing failure, and this one is knowable at launch.
    local autonomy push
    autonomy="$(manifest_get workflow "$workflow" autonomy)" || return 1
    push="$(manifest_get workflow "$workflow" push)" || return 1
    case "$autonomy" in
        open-pr)
            if ! _set_contains "$caps" pr; then
                echo "workflow '$workflow' sets autonomy = open-pr, which needs a forge" >&2
                echo "offering the 'pr' capability - '$forge' offers: ${caps:-none}." >&2
                return 1
            fi
            ;;
        push-branch)
            if [ "$push" != "on" ]; then
                echo "workflow '$workflow' sets autonomy = push-branch but push = off." >&2
                echo "It cannot stop at a push it never makes." >&2
                return 1
            fi
            ;;
    esac

    # Rule 3: a workflow that pushes needs a forge that resolves to somewhere
    # to push to. `forge = none` is how an operator who genuinely pushes
    # nowhere says so, which is what keeps this from being a refusal with no
    # remedy.
    if [ "$push" = "on" ] && [ -z "$(forge_hosts "$forge")" ]; then
        if [ -z "$(manifest_get forge "$forge" keys)" ]; then
            # A forge with no keys at all has nothing to configure - "set
            # [forge.$forge]" would be a fix that does not exist, so the only
            # honest remedies are another forge or another workflow.
            echo "workflow '$workflow' pushes, but forge '$forge' has no host to push" >&2
            echo "to and nothing to configure. Select a forge that has one ([core]" >&2
            echo "forge = github needs no host configured), or a workflow that does" >&2
            echo "not push (workflow = local-only)." >&2
        else
            echo "workflow '$workflow' pushes, but forge '$forge' resolves to no host." >&2
            echo "Configure [forge.$forge], or [core] forge = github to push to GitHub" >&2
            echo "instead, or [core] forge = none and a workflow that does not push" >&2
            echo "(workflow = local-only) if this sandbox pushes nowhere." >&2
        fi
        return 1
    fi

    # Set AND non-empty. config_is_set alone answers "did the operator write
    # this key", which is not the same question: install.sh writes every key
    # commented out at its default, so uncommenting one and not filling it in
    # yields `api =` - written, and worth nothing. Every call the forge makes
    # then fails inside the container, which is precisely what these two
    # rules exist to catch at launch instead.
    #
    # Testing the value is only safe because of the config_default skip
    # immediately below: a key with a working schema default always resolves
    # to something, so it is excluded before the emptiness test can read a
    # wholly unconfigured forge (nothing in [forge.<name>] at all) as partly
    # configured. A key with no default resolves to empty exactly when it is
    # unset or blank, which are the same thing to everything downstream.
    set_n=0 unset_n=0 missing=""
    for key in $(manifest_get forge "$forge" requires); do
        [ -z "$(config_default "forge.$forge.$key")" ] || continue
        if config_is_set "forge.$forge" "$key" && [ -n "$(config_get "forge.$forge" "$key")" ]; then
            set_n=$((set_n + 1))
        else
            unset_n=$((unset_n + 1))
            missing="${missing:+$missing }$key"
        fi
    done
    # Rule 5: a partly configured forge is a typo, not a choice. Refused, not
    # warned: `forge = none` is the way to say no forge, so a half-filled
    # section has no legitimate reading left. Still scoped to PARTIAL configuration -
    # nothing set at all is rule 3's case above, and carries its own message -
    # and, like rule 3, only when the workflow actually pushes: a non-pushing
    # workflow never invokes the forge at all, so a partially filled-in forge
    # section (e.g. only a host key, set so the firewall allows fetches) is
    # untidy rather than broken - not a typo worth refusing.
    if [ "$push" = "on" ] && [ "$set_n" -gt 0 ] && [ "$unset_n" -gt 0 ]; then
        echo "forge '$forge' is partly configured - [forge.$forge] is missing:" >&2
        echo "$missing. Set them, or set [core] forge = none if this sandbox" >&2
        echo "pushes nowhere." >&2
        return 1
    fi

    # Rule 3 only catches a wholly unconfigured forge by way of forge_hosts
    # resolving empty - but a forge like github pins fixed_hosts independent
    # of any config (the same three hosts for every operator), so forge_hosts
    # is never empty regardless of whether push_token_file is set. A forge
    # with exactly one `requires` key can also never be "partly" configured
    # (rule 5 above): it is either wholly set or wholly unset, so a wholly
    # unset single-key forge slips past both rules unless this closes it.
    # Scoped the same way rule 3 is - only when the workflow actually pushes,
    # and never for a forge with no `requires` at all.
    if [ "$push" = "on" ] && [ "$set_n" -eq 0 ] && [ "$unset_n" -gt 0 ]; then
        echo "workflow '$workflow' pushes, but forge '$forge' has none of its" >&2
        echo "required settings configured - [forge.$forge] is missing: $missing." >&2
        echo "Set them, or set [core] forge = none and a workflow that does not" >&2
        echo "push (workflow = local-only) if this sandbox pushes nowhere." >&2
        return 1
    fi
    return 0
}

# Every hostname this forge needs reachable: literal host keys, the host part
# of URL keys, and any fixed hosts. Derivation lives here rather than in a
# manifest because it is the same sed bin/dejima and the guards would each
# otherwise repeat - a provider says WHICH keys, never HOW to parse them.
forge_hosts() {
    local forge="$1" key value out=""
    for key in $(manifest_get forge "$forge" host_keys); do
        value="$(config_get "forge.$forge" "$key")" || return 1
        [ -n "$value" ] && out="${out:+$out }$value"
    done
    for key in $(manifest_get forge "$forge" url_keys); do
        value="$(config_get "forge.$forge" "$key")" || return 1
        [ -n "$value" ] || continue
        value="$(printf '%s' "$value" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*##')"
        [ -n "$value" ] && out="${out:+$out }$value"
    done
    for value in $(manifest_get forge "$forge" fixed_hosts); do
        out="${out:+$out }$value"
    done
    printf '%s' "$out"
}

# Prints one "KEY=VALUE" per line for the container environment. The "@" form
# means the value is the CONTENTS of the file the config key names - a token
# reaches the container without its path being mistaken for the secret.
forge_env_exports() {
    local forge="$1" pair name ref value path
    for pair in $(manifest_get forge "$forge" env_export); do
        name="${pair%%=*}"
        ref="${pair#*=}"
        if [ "${ref:0:1}" = "@" ]; then
            value="$(config_get "forge.$forge" "${ref:1}")" || return 1
            if [ -n "$value" ] && [ -f "$value" ]; then
                path="$value"
                value="$(<"$path")"
                if [ "$value" != "${value%%$'\n'*}" ]; then
                    echo "refusing [forge.$forge] ${ref:1}: the file at $path contains a" >&2
                    echo "newline. A credential cannot carry one - it would truncate here and" >&2
                    echo "leave a bare -e argument, which docker reads as 'pass through the" >&2
                    echo "host variable of that name'." >&2
                    return 1
                fi
            else
                value=""
            fi
        else
            value="$(config_get "forge.$forge" "$ref")" || return 1
        fi
        # An unresolved (empty) value is skipped rather than emitted as
        # `NAME=`. Harmless for a forge whose variables docker-compose.yml
        # never declares in its own `environment:` section - an absent -e
        # flag and an empty one are the same "not set" to a container either
        # way, and every such variable's consumer already treats unset and
        # empty identically. Not harmless for GH_TOKEN specifically: compose
        # DOES declare it there, carrying an independent read-only value
        # every session gets regardless of which forge is selected. `-e
        # GH_TOKEN=` on `docker compose run` overrides that entry - emitting
        # it here whenever a forge's own env_export resolves it empty would
        # silently replace a configured read-only token with nothing.
        [ -n "$value" ] || continue
        printf '%s=%s\n' "$name" "$value"
    done
}

# ---------------------------------------------------------------------------
# Session briefing composition
#
# Assembled host-side, never inside the container: hooks/sandbox-context.sh
# runs inside it, and giving it the provider directories to compose from
# would mean mounting them in - the opposite of "providers are DATA, never
# sourced". Composing here also means the result can be mounted read-only,
# so a session can never rewrite its own next briefing (see bin/dejima).
#
# The output still carries two placeholders forward - {{session_id}} and
# {{container_id}} become @@SESSION_ID@@ and @@CONTAINER_ID@@ rather than
# being resolved - because neither is known until the container is actually
# running. hooks/sandbox-context.sh (Task 5) substitutes those two at
# SessionStart, against the mounted file this function produces.
# ---------------------------------------------------------------------------

# Provider fragments are prose, not code, but they are still attacker-
# reachable if a provider directory is ever untrusted - same reasoning as
# MAX_MANIFEST_LINES above. Capped per-fragment, not for the assembled
# total, so one oversized fragment can't crowd out the rest of the briefing.
BRIEFING_FRAGMENT_MAX=16384

# The only placeholders a fragment or the core text may use. Anything else
# is a hard refusal (_briefing_substitute below), not a literal passthrough -
# an unrecognized {{key}} reaching an agent's context verbatim is exactly the
# kind of silent drift this whole function exists to prevent.
_BRIEFING_WHITELIST="pr_command issue_command forge_name forge_ssh_host blocked_branches container_id project_dir workspace_dir session_id resume_command writable_mounts network_allowlist no_confirm_args harness_state_dir"

_briefing_whitelisted() {
    _set_contains "$_BRIEFING_WHITELIST" "$1"
}

# The preamble: what the sandbox is, what survives it, and why the network
# allowlist is load-bearing for the agent too. Lives here, not in any
# provider directory - see the module-level comment. A quoted heredoc, so
# backticks and $ signs are literal and need no escaping.
_briefing_core_preamble() {
    cat <<'BRIEFING_EOF'
You are running inside the dejima Docker container, not directly on
the user's machine, with
{{no_confirm_args}} active (no tool-use confirmations).

What this means:
- The workspace directory is bind-mounted read-write and is the real
  project. ~/shared is also a real, persistent host directory (not part of
  the project) - use it to hand the user a file (a screenshot, a temp
  script) without touching the project checkout, or to pick up something
  they left there for you. Your harness keeps its own state on the host too,
  so this session's transcript outlives the container - the work is
  recoverable on the host with the command at the end of this
  briefing.{{writable_mounts}} Everything else is disposable: installed system
  packages, anything outside the mounted paths, and the container itself go
  away when this run ends.
- A headless browser is installed: playwright, with chromium, importable
  from any directory in either module system. If you change something with a
  user interface, look at it rather than describing what it should look like,
  and leave the screenshot in ~/shared.
- Outbound network is restricted to an allowlist (Anthropic's API, the npm
  registry, {{network_allowlist}}, plus anything
  approved via dejima-allow). Requests to anything else will simply
  fail to connect. That restriction is not only a limit on your reach: it
  is also what bounds where a prompt injection or a compromised dependency
  in this session could send the user's code or fetch its next instruction
  from. You cannot audit yourself for that from the inside, so the
  allowlist is load-bearing for you too, not just for the host - working
  around it would give up that protection, not merely lift the one limit
  it appears to. If a task needs one more domain and nothing else, that's
  a quick fix, not a reason to stop. Tell the user to run, from a terminal
  outside the sandbox, whichever of these matches why the domain is needed:
    dejima-allow --container {{container_id}} <domain>  # just this session
    dejima-allow --project <path> <domain>              # this project, always
    dejima-allow --global <domain>                      # every project
  Pick deliberately rather than asking for all three: a domain this project
  needs is --project, not --global - a global grant widens every other
  project's firewall too, which is rarely what one project's dependency
  calls for. --project also records the domain in the project's own
  .dejima/allowed-domains, so it is shared with everyone working on it
  rather than living on one machine. Quote that --container value exactly as
  written here - it is this container's real ID, not something to infer.
  And a domain can be an action rather than a source: a deploy hook, a
  payment or production API acts on the world the moment it is called, with
  no diff for anyone to review afterwards. Do not ask for one of those to
  finish a task - say what you need and let the operator decide.
- The project directory is mounted whole, so it can hold things that are not
  code: a .env, a database dump, a key someone left in the tree. Say so if
  you find one, and do not open, copy or send it anywhere unless the task
  actually requires it.
- Stay within the task you were given. Since there are no permission
  prompts here, be more conservative than usual about anything destructive,
  irreversible, or outside the project directory.
BRIEFING_EOF
}

# The worktree-under-the-mount paragraph. It reads like workflow advice but
# is a containment fact - get it wrong and real work is silently discarded
# when the container exits - so it is core, not provider prose, and a
# workflow can only opt into it (requires_worktree = on), never edit or omit
# it. _briefing_resolve_worktree splices this into the workflow fragment at
# its `<!-- core: worktree -->` marker.
_briefing_core_worktree() {
    cat <<'BRIEFING_EOF'
- The worktree MUST live under the mounted project directory itself, e.g.
  `git worktree add .worktrees/<branch> -b <branch>` run from the project
  root - never `../<branch>` or any other path outside it, including
  anywhere under $HOME. Only the exact directory bind-mounted into this
  container is backed by real storage on the host - what looks like the
  project's own parent directory is not, so a worktree created there is
  real work that just gets thrown away. Add
  `.worktrees/` to `.git/info/exclude` (not `.gitignore` - this is
  sandbox-local, not something to commit) so it doesn't clutter `git
  status` for the user's real checkout.
- A worktree isolates the working tree, NOT `.git/config`, which is shared
  with the parent checkout. A bare `git config <key> <value>` run from
  inside a worktree writes to the user's real repository config, not to
  anything scoped to your branch. Use `git -C <path> config` against a
  throwaway repo when setting config for a test or a repro. This matters
  beyond a stray `user.name`: `core.hooksPath`, `credential.helper` and
  `!`-aliases all execute on the host, and the same unscoped command
  reaches them.
BRIEFING_EOF
}

# Only when GitHub is a push destination this session. The default is off for
# a reason the agent cannot infer from having the ability: docs/security.md,
# "GitHub push". An agent that finds a real bug in a dependency and helpfully
# opens a pull request on it has not made a mistake about permissions - it
# has done something the operator was supposed to decide, and added to a queue
# maintainers are already drowning in. Saying so here is cheaper than
# discovering it afterwards, and the flag is exactly when it becomes possible.
# What a project gets for declaring .dejima/corpus: a rule about commit
# granularity, and the reason for it.
#
# The reason is not style. A plan step is only usable as evidence if the file's
# state immediately before it and immediately after it can both be recovered
# from history - before from the commit's parent, after from the commit. One
# commit carrying several steps that touch the same file destroys that: the
# third step's "after" already contains the fourth's and the fifth's, and
# splitting the diff to attribute a hunk per step would mean constructing a
# file state that never existed in the repository. So the information has to
# be put into the history when the work is done, or it is not recoverable
# afterwards by any amount of cleverness.
#
# Measured rather than assumed, on two repositories with the same author and
# the same planning workflow: the one committing per step yielded usable
# material from its steps, and the one committing once per task yielded none,
# with every step after the first to touch a given file discarded.
#
# The bullet about deletion is measured too, and names branch deletion rather
# than squashing on purpose. Verified here: a squash-merge with the branch
# retained leaves both step commits reachable in a fresh clone, because a clone
# fetches remote branches; the same squash-merge with the branch deleted first
# leaves none. Squashing is what an operator notices; deleting the branch is
# what several forges do by default, and it is the one that destroys the
# record.
#
# Deliberately says nothing about what the corpus is for or who collects it.
# That is the operator's business, and a briefing that argued for it would be
# dejima making a case rather than stating a rule the project already adopted.
_briefing_core_corpus() {
    cat <<'BRIEFING_EOF'
This project keeps its history as usable evidence of how the work was done
(it declares .dejima/corpus). That puts one requirement on how you commit:

- Give every plan step that changes a file its own commit, and say so in the
  step. Not one commit at the end covering five steps.
- A step that only reads files or runs tests needs no commit. This is about
  steps that write, not ceremony.
- Do not squash a task's step commits together before committing them. What
  happens at merge time is survivable: a clone fetches remote branches, so a
  squash-merge still leaves the step commits reachable through the branch ref.
  What does not survive is the branch being DELETED afterwards, which removes
  the last thing pointing at them. Several forges offer that as a
  merge-time default. If this one does, say so rather than assuming the record
  is safe, because everything above can be done perfectly and still yield
  nothing.

The reason is that a step is only legible later if the file's state before it
and after it can both be read back from history: before from the commit's
parent, after from the commit. When one commit carries several steps that
touch the same file, no step in it can be isolated any more, and reconstructing
one would mean inventing a file state the repository never held. Nothing can
recover that afterwards, which is why it has to be done while the work is.
BRIEFING_EOF
}

_briefing_core_github_push() {
    cat <<'BRIEFING_EOF'
- GitHub push is enabled for this session, for the repository you were
  pointed at and nothing else. Do NOT push a branch, open a pull request, or
  file an issue on any other project, however good the change would be. An
  unsolicited pull request is a cost imposed on maintainers who did not ask
  for it, not a contribution, and it arrives under the operator's name. If
  you find a real bug somewhere else, say so in your reply and let them
  decide what to do about it.
BRIEFING_EOF
}

_briefing_core_closing_a() {
    cat <<'BRIEFING_EOF'
If a task genuinely needs something else the sandbox can't provide -
broader network access than a domain or two, host-level or system changes,
GUI/hardware access - stop and explain clearly to the user what you need
and why, instead of trying to work around the firewall or sandbox yourself.
They can continue this exact session outside the container by running on
the host:
BRIEFING_EOF
}

# Reads a provider's optional briefing fragment (the `briefing` manifest key
# on the workflow/harness axes), capped at BRIEFING_FRAGMENT_MAX bytes.
# Prints nothing, successfully, when the axis has no briefing key set - a
# provider is not required to add prose to the session briefing.
#
# `rel` is already validated traversal-free (relpath), but the filesystem
# entry it names can still itself be a symlink - e.g. a compromised session
# on the read-write project mount replacing a provider's briefing.md with a
# symlink to an arbitrary host file. provider_dir only contains the
# directory; the file within it gets the same readlink -m / prefix-check
# treatment here, refusing anything that resolves outside that directory,
# dangling included, before head -c ever reads through it.
_briefing_provider_fragment() {
    local axis="$1" name="$2" rel dir file file_real
    rel="$(manifest_get "$axis" "$name" briefing)" || return 1
    if [ -z "$rel" ]; then
        printf ''
        return 0
    fi
    dir="$(provider_dir "$axis" "$name")" || return 1
    file="$dir/$rel"
    file_real="$(readlink -m "$file")"
    case "$file_real" in
        "$dir"/*) ;;
        *)  echo "refusing $axis '$name' briefing fragment: '$rel' resolves outside $dir" >&2
            return 1 ;;
    esac
    if [ ! -f "$file_real" ]; then
        echo "$axis '$name' names a briefing fragment that does not exist: $file" >&2
        return 1
    fi
    head -c "$BRIEFING_FRAGMENT_MAX" "$file_real"
}

# Splices the core worktree-containment paragraph into the workflow
# fragment's `<!-- core: worktree -->` marker when the workflow opts in
# (requires_worktree = on). The workflow can only turn this on or off - the
# marker's position in its own prose is the only say it gets, and the text
# itself always comes from _briefing_core_worktree, never from the fragment.
# A workflow that opts in but omits the marker is refused outright, not
# silently short a paragraph.
_briefing_resolve_worktree() {
    local workflow="$1" text="$2" requires
    requires="$(manifest_get workflow "$workflow" requires_worktree)" || return 1
    if [ "$requires" != "on" ]; then
        printf '%s' "$text"
        return 0
    fi
    case "$text" in
        *'<!-- core: worktree -->'*) ;;
        *)
            echo "workflow '$workflow' sets requires_worktree = on but its briefing" >&2
            echo "fragment has no '<!-- core: worktree -->' marker" >&2
            return 1
            ;;
    esac
    awk -v repl="$(_briefing_core_worktree)" '
        $0 == "<!-- core: worktree -->" { print repl; next }
        { print }
    ' <<< "$text"
}

# Resolves `<!-- requires: CONDITION -->` ... `<!-- end -->` spans: the
# enclosed provider prose survives only when CONDITION holds, and both
# marker lines are always dropped. Two condition shapes: a bare word is a
# forge capability (checked against $caps), `autonomy=VALUE` checks the
# workflow's own autonomy setting ($autonomy). One marker syntax for both,
# per the brief - visible to whoever edits the prose, not hidden in here.
_briefing_apply_gates() {
    local text="$1" caps="$2" autonomy="$3"
    awk -v caps=" $caps " -v autonomy="$autonomy" '
        /^<!-- requires: .* -->$/ {
            cond = $0
            sub(/^<!-- requires: /, "", cond)
            sub(/ -->$/, "", cond)
            if (index(cond, "autonomy=") == 1) {
                skip = (substr(cond, 10) == autonomy) ? 0 : 1
            } else {
                skip = (index(caps, " " cond " ") > 0) ? 0 : 1
            }
            next
        }
        /^<!-- end -->$/ { skip = 0; next }
        { if (!skip) print }
    ' <<< "$text"
}

# Resolves one whitelisted key to its literal value. forge_ssh_host is the
# one deliberately lenient case: it is informational, not load-bearing, so a
# missing config file (composing without one, as some tests and a fresh
# checkout do) yields an empty substitution rather than the hard failure
# config_get would otherwise give - the parenthetical it renders just
# disappears rather than composition refusing altogether.
_briefing_resolve_key() {
    local key="$1" forge="$2" workflow="$3" harness="$4" host=""
    case "$key" in
        pr_command)       manifest_get forge "$forge" pr_command ;;
        issue_command)    manifest_get forge "$forge" issue_command ;;
        forge_name)       printf '%s' "$forge" ;;
        forge_ssh_host)
            if config_exists 2>/dev/null; then
                host="$(config_get "forge.$forge" ssh_host 2>/dev/null)" || host=""
            fi
            [ -z "$host" ] || printf ' (%s)' "$host"
            ;;
        # What the session may actually reach, phrased for the selected forge
        # rather than assembled from two placeholders. Materially different
        # postures, and the agent acts on this sentence: GitHub is read-only
        # by default; a forge with hosts of its own adds them; a forge whose
        # hosts are the ones core already allowlists (hosts_allowlisted_by_core
        # - the same manifest key bin/dejima reads to open the push grant) has
        # no separate host to name, and when the workflow pushes, calling that
        # access read-only would be false in the direction that matters.
        #
        # Driven off that key rather than off the forge's name: it is the one
        # thing that actually decides the posture, so anything else here would
        # be core guessing at what a manifest already states.
        network_allowlist)
            local hosts=""
            if [ "$(manifest_get forge "$forge" hosts_allowlisted_by_core)" = "on" ]; then
                if [ "$(manifest_get workflow "$workflow" push)" = "on" ]; then
                    printf '%s' "GitHub, which this session can also push to"
                else
                    printf '%s' "GitHub read-only"
                fi
            else
                if [ -n "$(manifest_get forge "$forge" host_keys)$(manifest_get forge "$forge" url_keys)$(manifest_get forge "$forge" fixed_hosts)" ]; then
                    hosts=", the configured $forge host"
                    if config_exists 2>/dev/null; then
                        local h
                        h="$(config_get "forge.$forge" ssh_host 2>/dev/null)" || h=""
                        [ -z "$h" ] || hosts="$hosts ($h)"
                    fi
                fi
                printf '%s' "GitHub read-only$hosts"
            fi
            ;;
        blocked_branches) manifest_get workflow "$workflow" blocked_branches ;;
        project_dir)      printf '%s' "${WORKSPACE_DIR:-}" ;;
        workspace_dir)    printf '%s' "${WORKSPACE_DIR:-}" ;;
        resume_command)   manifest_get harness "$harness" resume_command ;;
        # The flags that put the harness in no-confirmation mode. From the
        # manifest rather than written into the preamble, because the
        # preamble's sentence is about the state the session is in and every
        # harness names that state differently - claiming
        # --dangerously-skip-permissions to a Cline session would be telling
        # it about a flag it does not have.
        no_confirm_args)  manifest_get harness "$harness" no_confirm_args ;;
        # Where this harness keeps this workspace's state on the host. Only
        # the plugin can say: it is the plugin that decides how state is
        # sliced per project, and for a harness that keeps one index over
        # every session it has ever run, that slicing is the whole of R4.
        # Empty when the harness has no such directory, which is why the
        # resolver is a hook call rather than a config key.
        harness_state_dir) harness_hook harness_briefing_state_dir "${WORKSPACE_DIR:-}" ;;
        writable_mounts)
            if [ -n "${DEJIMA_RW_MOUNTS:-}" ]; then
                printf '\n  These host directories are bind-mounted read-write at their own paths and\n  outlive the container too: %s.\n ' "$DEJIMA_RW_MOUNTS"
            fi
            ;;
        *)
            echo "internal error: no resolver for whitelisted briefing key: $key" >&2
            return 1
            ;;
    esac
}

# Substitutes every literal occurrence of $marker in $text with $value.
# Deliberately not ${text//marker/value}: bash 5.2's patsub_replacement (on
# by default) makes a literal "&" in the replacement expand to the matched
# text, so e.g. a [mounts] read_write value like /tmp/x/R&D (the path type
# explicitly permits "&") would leave the marker in place instead of being
# substituted, and _briefing_substitute's own trailing check would then
# refuse the whole composition as an unresolved placeholder. Same fix as
# hooks/sandbox-context.sh's _briefing_subst, and for the same reason - the
# two never share a process, so this is a second copy rather than a shared
# one.
_briefing_subst() {
    local text="$1" marker="$2" value="$3" out=""
    while [ "$text" != "${text#*"$marker"}" ]; do
        out="$out${text%%"$marker"*}$value"
        text="${text#*"$marker"}"
    done
    printf '%s%s' "$out" "$text"
}

# Substitutes every {{key}} in the assembled text. session_id and
# container_id are deliberately NOT resolved here - see the module comment -
# they are rewritten to the @@...@@ markers hooks/sandbox-context.sh (Task 5)
# fills in at SessionStart. Everything else must be in the whitelist or this
# refuses outright; nothing unrecognized ever reaches the container as a
# literal {{key}}.
_briefing_substitute() {
    local text="$1" forge="$2" workflow="$3" harness="$4"
    local -a tokens
    local tok key value

    mapfile -t tokens < <(printf '%s' "$text" | grep -oE '\{\{[a-z_]+\}\}' | sort -u)
    for tok in ${tokens[@]+"${tokens[@]}"}; do
        key="${tok#\{\{}"
        key="${key%\}\}}"
        case "$key" in
            session_id|container_id) continue ;;
        esac
        if ! _briefing_whitelisted "$key"; then
            echo "refusing unknown briefing placeholder: $tok" >&2
            return 1
        fi
        value="$(_briefing_resolve_key "$key" "$forge" "$workflow" "$harness")" || return 1
        text="$(_briefing_subst "$text" "$tok" "$value")"
    done

    text="$(_briefing_subst "$text" '{{session_id}}' '@@SESSION_ID@@')"
    text="$(_briefing_subst "$text" '{{container_id}}' '@@CONTAINER_ID@@')"

    case "$text" in
        *'{{'*|*'}}'*)
            echo "refusing: an unresolved placeholder remains after briefing composition" >&2
            return 1
            ;;
    esac
    printf '%s' "$text"
}

# briefing_compose FORGE WORKFLOW HARNESS
# Prints the assembled session briefing: the core preamble, the workflow
# fragment (with the worktree paragraph and capability/autonomy gates
# resolved), the core closing text, and the harness fragment (today, just
# the resume command) - in that reading order. Every {{key}} is substituted
# except {{session_id}}/{{container_id}}, deferred as @@SESSION_ID@@ and
# @@CONTAINER_ID@@ for the hook that mounts this at session start.
# A tool's manifest, plus the one rule its schema cannot express.
#
# image_env becomes a Dockerfile ENV, which every process in the container
# inherits - not just the tool that declared it. A harness may set a bare name
# there because a harness IS the container's main process; a tool is one
# program among many and may not.
#
# This is not hypothetical. rtk shipped with NO_COLOR=1, reasoning that its
# output lands in a model's context where an escape sequence is noise. The
# reasoning was fine, the scope was wrong, and a launch with that tool enabled
# lost colour in the harness, git, ls and everything else. The rule that would
# have caught it is that a tool's variables must be namespaced to the tool.
#
# Uppercased, with anything that is not alphanumeric folded to an underscore,
# so a tool named `my-tool` claims `MY_TOOL_*`.
tool_validate() {
    local name="$1" prefix pair varname
    manifest_validate tool "$name" || return 1
    prefix="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]' '_')_"
    for pair in $(manifest_get tool "$name" image_env); do
        varname="${pair%%=*}"
        case "$varname" in
            "$prefix"*) continue ;;
        esac
        echo "tool '$name' declares image_env $varname, which is not its own." >&2
        echo "A tool's image_env reaches every process in the container, so a bare" >&2
        echo "name like NO_COLOR or DO_NOT_TRACK changes the harness and everything" >&2
        echo "else too. Name it ${prefix}something, or do not set it." >&2
        return 1
    done
}

# That the authorship marker is added for the session, so it does not add one.
#
# Every issue and pull request on a project worked on this way opens with that
# line, so an agent reading the existing ones concludes it is the house style
# and writes it into the body - and the shadow then added a second. Each
# doubled artifact taught the next agent to do the same. docker/forge-guard.sh
# refuses to add a second now, which holds whatever the session does; this is
# the other half, which stops it being written in the first place.
_briefing_core_disclosure() {
    printf '%s' "Bodies you write for the forge - pull requests, issues, comments - are
marked as agent-written before they are sent. Do not write that line
yourself: it is added for you, and one is what the artifact should carry.
The existing issues on a project all open with it for this reason, not
because it was typed."
}

# What the session is told about the optional tools this launch enabled.
#
# The heading is core's and the body is each tool's own instructions.md, so a
# tool describes itself once and every harness gets the same words. Nothing
# here can change what the session may do - a tool's manifest has no key for
# that - which is what makes rendering a project-selectable fragment into the
# briefing safe at all.
_briefing_core_tools() {
    local tools="$1" tool frag dir out=""
    out="Extra tools this session has, beyond the usual shell:"
    for tool in $tools; do
        dir="$(provider_dir tool "$tool")" || continue
        frag="$(manifest_get tool "$tool" instructions)" || frag=""
        out+=$'\n\n'
        out+="- **$tool** - $(manifest_get tool "$tool" description)"
        if [ -n "$frag" ] && [ -f "$dir/$frag" ]; then
            out+=$'\n\n'
            out+="$(sed 's/^/  /' "$dir/$frag")"
        fi
    done
    printf '%s' "$out"
}

briefing_compose() {
    local forge="$1" workflow="$2" harness="$3"
    local caps autonomy workflow_frag harness_frag text

    manifest_validate forge "$forge" || return 1
    manifest_validate workflow "$workflow" || return 1
    manifest_validate harness "$harness" || return 1

    caps="$(manifest_get forge "$forge" capabilities)" || return 1
    autonomy="$(manifest_get workflow "$workflow" autonomy)" || return 1

    workflow_frag="$(_briefing_provider_fragment workflow "$workflow")" || return 1
    workflow_frag="$(_briefing_resolve_worktree "$workflow" "$workflow_frag")" || return 1
    workflow_frag="$(_briefing_apply_gates "$workflow_frag" "$caps" "$autonomy")"

    harness_frag="$(_briefing_provider_fragment harness "$harness")" || return 1

    text="$(_briefing_core_preamble)"
    text+=$'\n\n'
    text+="$workflow_frag"
    text+=$'\n\n'
    if [ "${DEJIMA_GITHUB_PUSH:-off}" = "on" ]; then
        text+="$(_briefing_core_github_push)"
        text+=$'\n\n'
    fi
    if [ "${DEJIMA_CORPUS:-off}" = "on" ]; then
        text+="$(_briefing_core_corpus)"
        text+=$'\n\n'
    fi
    # Optional tools, from DEJIMA_TOOLS. A tool the session is not told about
    # is one it will not use, so the manifest's instructions fragment is the
    # whole of the wiring for a harness: dejima renders it rather than letting
    # the tool's own installer patch a config, which is the difference
    # docs/tools.md draws between a hardened tool and a bare install.
    if [ -n "${DEJIMA_TOOLS:-}" ]; then
        text+="$(_briefing_core_tools "${DEJIMA_TOOLS}")"
        text+=$'\n\n'
    fi
    # Only when something actually discloses. A session told about a marker
    # nothing adds would be told a falsehood, and would then reasonably write
    # one itself - which is the failure this paragraph exists to stop.
    if [ -n "${DEJIMA_DISCLOSE:-}" ]; then
        text+="$(_briefing_core_disclosure)"
        text+=$'\n\n'
    fi
    # The harness fragment closes the briefing: it supplies both the resume
    # command closing_a has just promised and the sentence about where the
    # session history it resumes from actually lives. Both are the harness's
    # own facts - Claude Code resumes from a bind-mounted ~/.claude, Cline
    # from a per-project state directory named in the command itself - and
    # core stating either one meant stating Claude Code's.
    #
    # $requirements and $project_doc (the missing-dependency report and
    # .dejima.md) stay hook-computed and hook-appended after this - they read
    # container-local and workspace-local state a host-side compose has no
    # business resolving.
    text+="$(_briefing_core_closing_a)"
    text+=$'\n\n'
    text+="$harness_frag"

    _briefing_substitute "$text" "$forge" "$workflow" "$harness"
}
