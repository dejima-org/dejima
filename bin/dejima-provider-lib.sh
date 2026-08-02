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
provider_root() {
    printf '%s' "${DEJIMA_PROVIDER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
}

_provider_axis_dir() {
    case "$1" in
        forge)    printf 'forges' ;;
        workflow) printf 'workflows' ;;
        harness)  printf 'harnesses' ;;
        *) echo "unknown provider axis: $1" >&2; return 1 ;;
    esac
}

_provider_manifest_name() {
    case "$1" in
        forge)    printf 'forge.conf' ;;
        workflow) printf 'workflow.conf' ;;
        harness)  printf 'harness.conf' ;;
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

provider_dir() {
    local axis="$1" name="$2" sub axis_root dir_real
    sub="$(_provider_axis_dir "$axis")" || return 1
    if ! valid_provider_name "$name"; then
        echo "invalid $axis name: $name" >&2
        return 1
    fi
    axis_root="$(readlink -m "$(provider_root)/$sub")"
    dir_real="$(readlink -m "$(provider_root)/$sub/$name")"
    case "$dir_real/" in
        "$axis_root"/*) ;;
        *)  echo "refusing $axis '$name': it resolves outside $axis_root" >&2
            return 1 ;;
    esac
    if [ ! -d "$dir_real" ]; then
        echo "no such $axis: $name" >&2
        return 1
    fi
    printf '%s' "$dir_real"
}

provider_list() {
    local axis="$1" sub entry name
    sub="$(_provider_axis_dir "$axis")" || return 1
    for entry in "$(provider_root)/$sub"/*/; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        valid_provider_name "$name" || continue
        printf '%s\n' "$name"
    done
}

# Manifest schema. Same three-column shape as the config table: key, type,
# default. Types are the config file's own, so one validator set covers both.
_manifest_table() {
    case "$1" in
        forge) cat <<'EOF'
capabilities	?list:identifier
pr_command	?command
issue_command	?command
merge_block	?command
keys	?list:identifier
requires	?list:identifier
host_keys	?list:identifier
url_keys	?list:identifier
fixed_hosts	?list:hostname
install	?list:relpath
env_export	?list:export
EOF
            ;;
        workflow) cat <<'EOF'
requires	?list:identifier
push	bool	on
blocked_branches	?list:identifier
block_merge	bool	off
requires_worktree	bool	off
autonomy	enum:commit|push-branch|open-pr	commit
briefing	?relpath
EOF
            ;;
        harness) cat <<'EOF'
command	identifier	claude
keys	?list:identifier
resume_command	?template
briefing	?relpath
EOF
            ;;
        *) return 1 ;;
    esac
}

_manifest_spec() {
    local axis="$1" want="$2" key type default
    while IFS=$'\t' read -r key type default; do
        [ "$key" = "$want" ] || continue
        printf '%s\t%s' "$type" "$default"
        return 0
    done < <(_manifest_table "$axis")
    return 1
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
            # "gitea-pr" and "gh pr" both fit and nothing shell-active does.
            [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*( [A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]
            ;;
        relpath)
            # Joined to a provider directory, so no absolute paths and no
            # traversal - a manifest may only name a file it ships.
            [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] && [[ "$value" != *".."* ]]
            ;;
        export)
            # NAME=key or NAME=@key. The "@" form means "the contents of the
            # file at that config key" and is how a token reaches the container
            # without the path being mistaken for the secret.
            [[ "$value" =~ ^[A-Z][A-Z0-9_]*=@?[a-z][a-z0-9_]*$ ]]
            ;;
        template)
            # Prose with {{placeholders}}; the placeholder names themselves are
            # checked against the whitelist at composition time, not here.
            [[ "$value" =~ ^[-A-Za-z0-9{}\ ._:/]+$ ]]
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

manifest_validate() {
    local axis="$1" name="$2" dir file line key value type line_count
    dir="$(provider_dir "$axis" "$name")" || return 1
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
        line="$(_config_trim "$line")"
        case "$line" in
            ''|'#'*|';'*) continue ;;
            *=*) ;;
            *) echo "malformed line in $file: $line" >&2; return 1 ;;
        esac
        key="$(_config_trim "${line%%=*}")"
        value="$(_config_trim "${line#*=}")"
        if ! type="$(_manifest_type "$axis" "$key")"; then
            echo "unknown key in $file: $key" >&2
            return 1
        fi
        if ! _provider_valid_value "$type" "$value"; then
            echo "invalid value for $key in $file: $value" >&2
            return 1
        fi
    done < "$file"
    return 0
}

_manifest_type() {
    local spec
    spec="$(_manifest_spec "$1" "$2")" || return 1
    printf '%s' "${spec%%$'\t'*}"
}

_manifest_default() {
    local spec
    spec="$(_manifest_spec "$1" "$2")" || return 1
    printf '%s' "${spec#*$'\t'}"
}

# manifest_get <axis> <name> <key>
# Validates the whole manifest first, same reason config_get does: a read must
# never succeed against a file another read would reject.
manifest_get() {
    local axis="$1" name="$2" want="$3" dir file line key value found="" seen=0
    _manifest_type "$axis" "$want" >/dev/null || {
        echo "unknown $axis manifest key: $want" >&2; return 1; }
    manifest_validate "$axis" "$name" || return 1
    dir="$(provider_dir "$axis" "$name")" || return 1
    file="$dir/$(_provider_manifest_name "$axis")"
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(_config_trim "$line")"
        case "$line" in ''|'#'*|';'*) continue ;; *=*) ;; *) continue ;; esac
        key="$(_config_trim "${line%%=*}")"
        [ "$key" = "$want" ] || continue
        found="$(_config_trim "${line#*=}")"
        seen=1
    done < "$file"
    [ "$seen" = 1 ] || found="$(_manifest_default "$axis" "$want")"
    printf '%s' "$found"
}
