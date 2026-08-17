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
DEJIMA_HARNESS_HOOKS="harness_state_mounts harness_register_notify harness_register_guards"

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
    local path="$1" mode="${2:-}"
    [ -n "$path" ] || return 0
    case "$path" in
        *:*)
            echo "Harness plugin emitted a mount path containing a colon: $path" >&2
            exit 1 ;;
    esac
    _guarded_stores
    _refuse_guarded_mount "harness state mount" "$path" \
        ${GUARDED_STORES[@]+"${GUARDED_STORES[@]}"}
    if [ -n "$mode" ]; then
        extra_mounts+=(-v "$path:$path:$mode")
    else
        extra_mounts+=(-v "$path:$path")
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
