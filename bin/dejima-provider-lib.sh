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
provider_root() {
    printf '%s' "${DEJIMA_PROVIDER_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)}"
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
    local axis="$1" name="$2" sub root axis_root dir_real
    sub="$(_provider_axis_dir "$axis")" || return 1
    if ! valid_provider_name "$name"; then
        echo "invalid $axis name: $name" >&2
        return 1
    fi
    root="$(provider_root)"
    axis_root="$(readlink -m "$root/$sub")"
    dir_real="$(readlink -m "$root/$sub/$name")"
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
keys	?list:keyspec
requires	?list:identifier
host_keys	?list:identifier
url_keys	?list:identifier
fixed_hosts	?list:hostname
hosts_allowlisted_by_core	bool	off
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
keys	?list:keyspec
resume_command	?template
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
            # a bare command name and a multi-word one like "gh pr" both fit
            # and nothing shell-active does.
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

# ---------------------------------------------------------------------------
# [forge.<name>] / [harness.<name>] config schema, derived from each
# provider's own `keys` manifest entry. Overrides the three
# dejima-config-lib.sh extension-point stubs (_config_extra_section_known,
# _config_extra_spec, _config_extra_keys) so the config schema table stays
# free of any one provider's name - adding a forge or harness is adding a
# directory whose manifest declares its own keys, not editing core.
# ---------------------------------------------------------------------------

# config_validate re-parses the whole config on every config_get (~thirty per
# launch), and each [forge.<name>] line calls back here. Going through
# manifest_validate would mean that many full-manifest validations, so this
# line-scans the `keys` field alone. Every other field still gets a full
# manifest_validate before anything consequential reads it - this feeds a
# config schema type check, never a forge action.
#
# Cached per axis+name for this command substitution only. bash forks a new
# subshell per config_get, so it dedupes the keys of one section against each
# other rather than across a launch: a cheap partial win, not a cross-process
# cache this file has no way to invalidate.
declare -gA _PROVIDER_KEYS_CACHE
_provider_keys_cached() {
    local axis="$1" name="$2" cache_key="$axis:$name"
    if [ -z "${_PROVIDER_KEYS_CACHE[$cache_key]+set}" ]; then
        _PROVIDER_KEYS_CACHE[$cache_key]="$(_provider_keys_field "$axis" "$name")" || return 1
    fi
    printf '%s' "${_PROVIDER_KEYS_CACHE[$cache_key]}"
}

# Reads and validates only the `keys = ...` line of a forge/harness manifest
# - see _provider_keys_cached above for why this bypasses manifest_get's
# full-manifest validation. Trimming is inlined (_config_trim's own logic,
# not a call to it) and the line count uses bash's own read loop instead of
# `wc -l`, both to avoid a subshell/external-process fork per manifest line -
# this runs once per key in a [forge.<name>]/[harness.<name>] section on
# EVERY config_validate pass (config_validate itself runs on every
# config_get, "on the order of thirty" times per launch), so a per-line fork
# here is a per-line fork thirty times over.
_provider_keys_field() {
    local axis="$1" name="$2" dir file line key value="" seen=0 type n=0
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
        *) return 1 ;;
    esac
    provider_dir "$axis" "$name" >/dev/null 2>&1
}

# Looks up one [forge.<name>]/[harness.<name>] key's TYPE<TAB>DEFAULT in that
# provider's `keys` manifest entry instead of a row hardcoded in core.
_config_extra_spec() {
    local want="$1" axis rest name key spec pname ptype pdefault
    case "$want" in
        forge.*)   axis=forge ;;
        harness.*) axis=harness ;;
        *) return 1 ;;
    esac
    rest="${want#*.}"
    name="${rest%%.*}"
    key="${rest#*.}"
    [ "$key" != "$rest" ] || return 1
    # No separate provider_dir check here - _provider_keys_cached (via
    # _provider_keys_field) already refuses when the directory doesn't exist,
    # and this runs often enough (see _provider_keys_field's comment) that a
    # second containment check per call is real, avoidable cost.
    for spec in $(_provider_keys_cached "$axis" "$name"); do
        pname="${spec%%:*}"
        [ "$pname" = "$key" ] || continue
        IFS=$'\t' read -r pname ptype pdefault <<< "$(_provider_keyspec_parse "$spec")"
        printf '%s\t%s' "$ptype" "$pdefault"
        return 0
    done
    return 1
}

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
    for spec in $(_provider_keys_cached "$axis" "$name"); do
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
    # to push to. Deferred through Phase 2 because refusing an unconfigured
    # forge had no correct alternative to offer - `forge = none` now exists,
    # so an operator who genuinely pushes nowhere has an honest way to say it
    # and this stops being a refusal with no remedy.
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
    # Rule 5: a partly configured forge is a typo, not a choice. Refused rather
    # than warned now that `forge = none` exists: previously the only way to
    # say "I don't use a forge" was to leave one half-filled, so refusing would
    # have broken a supported state. Still scoped to PARTIAL configuration -
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
_BRIEFING_WHITELIST="pr_command issue_command forge_name forge_ssh_host blocked_branches container_id project_dir workspace_dir session_id resume_command writable_mounts network_allowlist"

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
--dangerously-skip-permissions active (no tool-use confirmations).

What this means:
- The workspace directory is bind-mounted read-write and is the real
  project. ~/shared is also a real, persistent host directory (not part of
  the project) - use it to hand the user a file (a screenshot, a temp
  script) without touching the project checkout, or to pick up something
  they left there for you. ~/.claude is bind-mounted too, so this session's
  transcript and its project memory outlive the container - the work is
  recoverable on the host with the `--resume` command at the end of this
  briefing.{{writable_mounts}} Everything else is disposable: installed system
  packages, anything outside the mounted paths, and the container itself go
  away when this run ends.
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
    bin/dejima-allow --container {{container_id}} <domain>  # just this session
    bin/dejima-allow --project <path> <domain>              # this project, always
    bin/dejima-allow --global <domain>                      # every project
  Pick deliberately rather than asking for all three: a domain this project
  needs is --project, not --global - a global grant widens every other
  project's firewall too, which is rarely what one project's dependency
  calls for. --project also records the domain in the project's own
  .dejima/allowed-domains, so it is shared with everyone working on it
  rather than living on one machine. Quote that --container value exactly as
  written here - it is this container's real ID, not something to infer.
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

# $requirements and $project_doc (the missing-dependency report and
# .dejima.md) stay hook-computed and hook-appended after this - they read
# container-local and workspace-local state a host-side compose has no
# business resolving, and moving them is Task 5's job, not this one.
_briefing_core_closing_b() {
    cat <<'BRIEFING_EOF'
(session history is shared via the bind-mounted ~/.claude, so it will pick
up right where this left off).
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
    text+="$(_briefing_core_closing_a)"
    text+=$'\n\n'
    text+="$harness_frag"
    text+=$'\n\n'
    text+="$(_briefing_core_closing_b)"

    _briefing_substitute "$text" "$forge" "$workflow" "$harness"
}
