# Shared library: loading a harness plugin, and the interface it declares
# through. Sourced by bin/dejima. Not on PATH and not executable.
#
# Three tiers, and which one a thing belongs in is the whole design:
#
#   core      - the mechanism, and every enforcement point.
#   manifest  - data. harnesses/<name>/harness.conf. Never sourced, never
#               executed. Selects among named core mechanisms, supplies paths.
#   plugin    - bin/harness/<name>.sh. The harness-specific remainder, as
#               code, in this repository, supported one harness at a time.
#
# A feature belongs in the manifest if it can be stated as a value. It moves
# here only when it cannot: opencode resolving its state directory through a
# database, Claude Code pairing file-history to transcripts by session id.
# "Add a manifest key" is the answer until it demonstrably is not.
#
# Plugins live under bin/ rather than beside their manifest because
# dejima-audit's tcb_snapshot covers install.sh, bin/, hooks/, docker/ and
# test/ - and not harnesses/. Host-side plugin code under harnesses/ would be
# code that runs on the host and that a session could edit in dejima's own
# checkout without raising a CRITICAL, which is the exact class the audit
# exists to catch. Under bin/ it is covered for free, and "manifests are
# data, never executed" (docs/security.md) stays true word for word.
#
# Plugins are SOURCED, not invoked. They are part of the trusted computing
# base, so the risk worth designing against is not a careless plugin - it is
# three plugins implementing the security model three different ways.
# Sourcing lets a plugin use core's own primitives (_refuse_guarded_mount,
# sanitize, ws_slug, harness_config_get) rather than re-deriving them, which
# is what keeps one security model instead of one per harness. An invoked
# protocol would also put a new text parser on the launch path, and every
# parsing bug this repository has had is in that family.
#
# The rule that replaces isolation: A PLUGIN COMPUTES, CORE ENFORCES.
# A plugin declares through the emit_* functions below, which validate at the
# point of declaration. It never touches extra_mounts itself - a static test
# holds that, because a plugin that appended directly would skip the guarded-
# store refusal, and would skip it differently in each harness.

# The hooks core will call. A plugin defines the ones its harness needs and
# omits the rest; anything else it defines is a name core does not call, and
# the static test refuses it rather than letting it look wired up.
DEJIMA_HARNESS_HOOKS="harness_prepare_config harness_state_mounts harness_register_notify harness_register_guards harness_host_exec_surfaces harness_config_dirs harness_staged_config harness_extract_epitaphs harness_transform_transcript harness_guards_registered"

# What an operator loses when a harness cannot host a given guard. The set
# itself is DEJIMA_KNOWN_GUARDS in dejima-provider-lib.sh, next to the
# manifest schema and the validation that rejects a name outside it: a
# constant the validation depends on must live where the validation does, or
# a caller that loads only provider-lib validates against an empty set and
# rejects every guard there is.
_guard_description() {
    case "$1" in
        bash-deny)   printf 'obviously destructive shell commands are not refused' ;;
        push-guard)  printf 'pushes to hosts and branches outside the allowed set are not refused' ;;
        merge-guard) printf 'the agent can merge its own pull requests' ;;
        notify)      printf 'remote access gets no waiting/done notifications' ;;
        *)           printf 'unknown guard' ;;
    esac
}

# Whether the selected harness declared a given guard. Core gates the work
# on this rather than on whether the plugin happens to define a hook: a
# harness that forgot the declaration but implemented the hook would get a
# guard the launch message has just told the operator it does not have.
harness_has_guard() {
    case " $(manifest_get harness "$DEJIMA_HARNESS_NAME" guards) " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Whether the harness is actually wired to run dejima's hooks. A harness that
# cannot answer is assumed wired: absence of a check is not evidence of a
# problem, and refusing on it would break every harness that has no such
# concept.
harness_guards_wired() {
    declare -F harness_guards_registered >/dev/null 2>&1 || return 0
    harness_guards_registered
}

# Says which guards the selected harness cannot host. Silent when it hosts
# them all, which is the common case and must not become noise an operator
# learns to scroll past - the point is that the line only appears when
# something really is missing.
harness_report_guards() {
    local harness="$1" declared guard missing=()
    declared="$(manifest_get harness "$harness" guards)"
    for guard in $DEJIMA_KNOWN_GUARDS; do
        case " $declared " in
            *" $guard "*) ;;
            *) missing+=("$guard") ;;
        esac
    done
    [ "${#missing[@]}" -gt 0 ] || return 0
    printf '  %sharness %s does not support %s of dejima'"'"'s guards:%s\n' \
        "$C_WARN" "$harness" "${#missing[@]}" "$C_RESET" >&2
    for guard in "${missing[@]}"; do
        printf '    %s%s%s - %s\n' "$C_KEY" "$guard" "$C_RESET" "$(_guard_description "$guard")" >&2
    done
    printf '  The container still bounds this session; these are the fast-fail\n' >&2
    printf '  guards it does not get. See docs/development.md.\n' >&2
}

# Sources the selected harness's plugin. Hard error when it is missing:
# support is per harness and deliberate (see "Adding a new harness" in
# docs/development.md), so a harness with a manifest and no plugin is a
# half-finished integration rather than a lightweight one.
harness_plugin_load() {
    local name="$1" plugin
    [ -n "$name" ] || return 0
    # Resolved from this file's own location, not from a caller's SCRIPT_DIR:
    # install.sh sets that to the repo root while bin/dejima sets it to bin/,
    # and a library that only works for one of its callers is a trap for the
    # next one.
    plugin="$(cd "${BASH_SOURCE[0]%/*}" && pwd)/harness/$name.sh"
    if [ ! -f "$plugin" ]; then
        echo "No harness plugin for '$name' at $plugin." >&2
        echo "A supported harness has both a manifest and a plugin; see" >&2
        echo "\"Adding a new harness\" in docs/development.md." >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$plugin"
}

# Calls one hook of the loaded plugin, if it defines it. Absence is normal:
# not every harness needs every hook, and the manifest is where a harness
# says what it cannot do at all.
harness_hook() {
    local hook="$1"; shift
    declare -F "$hook" >/dev/null 2>&1 || return 0
    "$hook" "$@"
}

# --- what a plugin declares through --------------------------------------
#
# Each of these validates and then appends to core's own state. A plugin
# calls them; it does not reach past them.

# A host path mounted into the container at the same path. $2 is the mode
# ("ro", or empty for read-write).
#
# The guarded-store refusal runs here, at the point of declaration, so it
# cannot be skipped by a plugin that forgot it: a harness state directory
# that overlapped the approval or audit or epitaph store would otherwise
# hand a session exactly what those stores exist to withhold, and a harness
# is precisely the kind of thing whose paths are computed rather than
# written down.
emit_mount() {
    emit_mount_at "$1" "$1" "${2:-}"
}

# Whether two absolute paths are the same or one contains the other. Here
# rather than in bin/dejima because the mount checks below are its only
# non-trivial user, and a check that cannot be exercised without starting a
# launch is one nothing exercises.
_paths_overlap() {
    local a="${1%/}" b="${2%/}"
    # Stripping a trailing slash turns the filesystem root into the empty
    # string, and root contains every path there is - which the prefix
    # comparisons below cannot say, because "//" is not a prefix of "/usr".
    # Without this, "/" overlapped nothing: `[mounts] readonly = /` passed the
    # guarded-store refusal and mounted every store at once.
    if [ -z "$a" ] || [ -z "$b" ]; then return 0; fi
    [ "$a" = "$b" ] && return 0
    case "$a/" in "$b"/*) return 0 ;; esac
    case "$b/" in "$a"/*) return 0 ;; esac
    return 1
}

# Container paths dejima itself relies on. A mount landing on one of these
# replaces something the sandbox needs: the wrapper that pins the no-confirm
# flags, the settings layer the guards are registered in, the briefing, the
# marker directory remote access watches. A plugin is trusted code, but the
# whole point of declaring through here is that core is the one checking.
DEJIMA_CONTAINER_PATHS="/usr/local/bin /etc/dejima /etc/dejima-harness /etc/dejima-settings.json /run/dejima-notify /etc/resolv.conf /etc/hosts"

# A host path mounted at a DIFFERENT path in the container. $3 is the mode
# ("ro", or empty for read-write).
#
# The two paths differ when a harness keys its own state somewhere dejima
# cannot safely follow. opencode derives its storage directory from the git
# remote, which lives in the mounted workspace and a session can rewrite in
# one command - so a mount computed from it is a mount whose destination the
# session chooses. Keeping the SOURCE keyed by dejima's own workspace slug
# and letting only the TARGET follow the harness makes that fail safe: a
# session that rewrites the remote sends the harness looking at a container
# path nothing is mounted at, which is empty rather than someone else's.
emit_mount_at() {
    local src="$1" target="$2" mode="${3:-}" guarded
    [ -n "$src" ] && [ -n "$target" ] || return 0
    case "$src$target" in
        *:*)
            echo "Harness plugin emitted a mount path containing a colon: $src:$target" >&2
            exit 1 ;;
    esac
    case "$target" in
        /*) ;;
        *)  echo "Harness plugin emitted a relative mount target: $target" >&2
            exit 1 ;;
    esac
    # The source is a host path, so it gets the store refusal. The target is
    # a container path and cannot expose a host store - what it can do is
    # shadow something the sandbox needs.
    _guarded_stores
    _refuse_guarded_mount "harness state mount" "$src" \
        ${GUARDED_STORES[@]+"${GUARDED_STORES[@]}"}
    for guarded in $DEJIMA_CONTAINER_PATHS; do
        if _paths_overlap "$(readlink -m "$target")" "$guarded"; then
            echo "Refusing harness mount at $target: it overlaps $guarded," >&2
            echo "which the sandbox needs in place inside the container." >&2
            exit 1
        fi
    done
    if [ -n "$mode" ]; then
        extra_mounts+=(-v "$src:$target:$mode")
    else
        extra_mounts+=(-v "$src:$target")
    fi
}

# An environment variable for the container. Name-checked because it becomes
# a `-e NAME=value` argument, and a name carrying a space or an `=` would
# split into something else entirely.
emit_env() {
    local name="$1" value="${2:-}"
    case "$name" in
        ''|*[!A-Za-z0-9_]*)
            echo "Harness plugin emitted an invalid environment variable name: $name" >&2
            exit 1 ;;
    esac
    extra_mounts+=(-e "$name=$value")
}

# --- host-execution surfaces ---------------------------------------------
#
# Paths a harness causes to run ON THE HOST, unsandboxed, from configuration
# a session can reach. Claude Code's statusline is the instance that exists:
# settings.json's statusLine.command names a script the host runs, so a
# session that can write that file has a way onto the host that no container
# boundary sees.
#
# Declared by the plugin rather than by the manifest, and the reason is a
# trust boundary rather than convenience. dejima-audit's `ack` derives a
# finding's id by stripping a FIXED label from the front of the finding text
# - anchored deliberately, because an unanchored match lets chosen text
# derive an id in the wrong namespace and baseline an approval that never
# matches while the real finding is counted as acknowledged (#45). Those
# labels are therefore part of a parser's grammar. Manifests are data, and
# provider directories are NOT in tcb_snapshot's list, so in the self-mount
# case a session can edit one without raising a CRITICAL. A plugin is under
# bin/, which the audit does watch. The label stays a literal in trusted
# code; it just lives with the harness that owns it.
#
# Each surface carries its own namespace, so ids stay stable per harness and
# no rename is forced on anyone's baseline.
DEJIMA_HOST_EXEC=()

# namespace, leaf, path, label. The id is "<namespace>:<leaf>", which is what
# a baseline stores, so neither may change for a harness already in use.
emit_host_exec() {
    local ns="$1" leaf="$2" path="$3" label="$4"
    [ -n "$path" ] || return 0
    case "$ns" in
        ''|*[!a-z0-9-]*)
            echo "Harness plugin emitted an invalid host-exec namespace: $ns" >&2
            exit 1 ;;
    esac
    # The leaf lands in an id, which is compared against baseline entries and
    # written into a report; a tab or newline in either would split a record.
    case "$leaf$label" in
        *$'\t'*|*$'\n'*)
            echo "Harness plugin emitted a host-exec leaf or label containing a tab or newline" >&2
            exit 1 ;;
    esac
    [ -n "$leaf" ] && [ -n "$label" ] || {
        echo "Harness plugin emitted a host-exec surface with no leaf or label" >&2
        exit 1
    }
    DEJIMA_HOST_EXEC+=("$ns"$'\t'"$leaf"$'\t'"$path"$'\t'"$label")
}

# Asks the loaded plugin for its surfaces. Empty when no harness is selected
# or the harness has none, which is a normal state rather than an error.
host_exec_load() {
    DEJIMA_HOST_EXEC=()
    harness_hook harness_host_exec_surfaces
}

# The host path behind an id, or nothing if that id is not a host-exec one.
host_exec_path_for_id() {
    local id="$1" rec ns leaf path label
    for rec in ${DEJIMA_HOST_EXEC[@]+"${DEJIMA_HOST_EXEC[@]}"}; do
        IFS=$'\t' read -r ns leaf path label <<< "$rec"
        [ "$id" = "$ns:$leaf" ] || continue
        printf '%s' "$path"
        return 0
    done
    return 1
}

# Whether an id names a host-execution surface. Used where severity is
# decided: every one of these is CRITICAL, because the whole category is
# "runs on the host, outside everything".
host_exec_is_id() { host_exec_path_for_id "$1" >/dev/null; }

# --- config parity -------------------------------------------------------
#
# The harness's own configuration directories, carried from the host so a
# session has the operator's setup. Which directories exist, what each holds
# and whether a session may write it are facts about the harness; that the
# read-only ones are read-only, and that a discovered symlink target is
# refused when it overlaps a guarded store, are dejima's.
DEJIMA_CONFIG_DIRS=()

# path, mode ("ro" or empty for read-write), and whether to follow symlinks
# out of it ("scan", or empty).
#
# The scan flag is per directory rather than applied to every read-only one:
# an entry in hooks/ or skills/ is routinely a symlink into a dotfiles
# checkout, which has to be mounted for the link to resolve inside the
# container, while plugins/ is bookkeeping a harness writes for itself.
emit_config_dir() {
    local path="$1" mode="${2:-}" scan="${3:-}"
    [ -n "$path" ] || return 0
    case "$mode" in
        ''|ro) ;;
        *) echo "Harness plugin emitted an invalid config-dir mode: $mode" >&2; exit 1 ;;
    esac
    case "$scan" in
        ''|scan) ;;
        *) echo "Harness plugin emitted an invalid config-dir flag: $scan" >&2; exit 1 ;;
    esac
    DEJIMA_CONFIG_DIRS+=("$path"$'\t'"$mode"$'\t'"$scan")
}

harness_config_dirs_load() {
    DEJIMA_CONFIG_DIRS=()
    harness_hook harness_config_dirs
}

# --- staged config -------------------------------------------------------
#
# Config files carried from the host as COPIES rather than mounts. A
# single-file bind mount is pinned to the dentry at its path, so a host-side
# rename unlinks it and the mount silently detaches (#47, #48); and a mount
# landing on a symlink resolves through it, protecting the target while
# leaving the link replaceable. Staging closes both: Docker resolves the path
# once, setting up the staging mount, and entrypoint.sh installs a root-owned
# copy the session cannot write back through.
#
# The staging tree MIRRORS the destination, so no mapping has to be passed
# into the container and parsed there: /etc/dejima-harness/<rel> is installed
# at $HOME/<rel>. The mode comes from whether the source is executable, which
# is the distinction that already existed - a statusline is run, a settings
# file is read.
DEJIMA_STAGED_CONFIG=()

# host path, and the path under $HOME it is installed at.
emit_staged_config() {
    local src="$1" rel="$2"
    [ -n "$src" ] && [ -n "$rel" ] || return 0
    # The relative path becomes a location under $HOME inside the container.
    # Anything that could climb out of it, or that is not relative at all, is
    # a plugin bug rather than something to normalise quietly.
    case "$rel" in
        /*|*..*|*$'\t'*|*$'\n'*)
            echo "Harness plugin emitted an invalid staged-config path: $rel" >&2
            exit 1 ;;
    esac
    DEJIMA_STAGED_CONFIG+=("$src"$'\t'"$rel")
}

harness_staged_config_load() {
    DEJIMA_STAGED_CONFIG=()
    harness_hook harness_staged_config
}

# --- epitaphs ------------------------------------------------------------
#
# What a session leaves when its context is compacted away. Where the store
# is, that nothing mounts it, that each file is 0600 under a 0700 directory,
# and that a directory appears only once something is kept in it are dejima's
# (see bin/dejima-epitaph). What a compaction looks like in a transcript, and
# which fields describe it, are the harness's.
#
# The note below is dejima's promise about the artefact rather than the
# harness's, so it is defined here and handed to the plugin to write, not
# left for each harness to phrase its own way.
DEJIMA_EPITAPH_NOTE="Written by the session and preserved verbatim. The transcript it came
from is writable from inside the container, so this records what was
there rather than vouching for it."
