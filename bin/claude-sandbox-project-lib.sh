#!/bin/bash
# Sourceable helper for the per-project config tooling (bin/claude-sandbox,
# claude-sandbox-allow, claude-sandbox-dep, claude-sandbox-project).
#
# Two kinds of file are involved and they are NOT equally trusted:
#
#   .claude-sandbox/{allowed-domains,dependencies} in the project - a
#   DECLARATION. The project directory is bind-mounted read-write, so a
#   compromised session can write these. They grant nothing; they are read
#   only to compare against reality and suggest a command for the user to
#   run. Parsed, never sourced - executing a file on a session-writable
#   mount is a host-shell persistence path.
#
#   ~/.config/claude-sandbox/{allowed-domains,dependencies} - a GLOBAL
#   APPROVAL, applying to every project.
#
#   ~/.config/claude-sandbox/projects/<slug>/* - a PROJECT APPROVAL.
#
#   Both are written only by the CLIs, which only the user runs, and neither
#   is ever mounted into the container. They are the only things that
#   actually grant anything.

CLAUDE_SANDBOX_MAX_DECLARED=200

# Same expression bin/claude-sandbox-allow validates with - a declared
# domain has to survive being written into a dnsmasq server=/domain/ line.
valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,62}\.)*[a-zA-Z0-9-]{1,63}$ ]]
}

# <ecosystem>:<name>. The character class is deliberately narrow: an
# approved spec gets interpolated into a generated Dockerfile RUN line, so
# anything shell-active here would be a root-context injection at build.
# The name must start with an alphanumeric - without that, a leading dash
# (e.g. "--allow-unauthenticated") validates as a name and lands in the
# generated RUN line as an option instead, quietly weakening apt/pip/npm/
# cargo's own signature/lockfile checks.
valid_dep_spec() {
    [[ "$1" =~ ^(apt|npm|pip|cargo):[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

# read_declared <file> <validator-fn>
# Prints "ok <entry>" / "rejected <entry>" per entry, plus a final
# "truncated <total>" when the cap kicked in. Invalid entries are reported
# rather than dropped - a project declaring something malformed should be
# visibly refused, not silently ignored.
read_declared() {
    local file="$1" validator="$2" line count=0 total=0
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        total=$((total + 1))
        [ "$count" -ge "$CLAUDE_SANDBOX_MAX_DECLARED" ] && continue
        count=$((count + 1))
        if "$validator" "$line"; then
            printf 'ok %s\n' "$line"
        else
            printf 'rejected %s\n' "$line"
        fi
    done < "$file"
    if [ "$total" -gt "$CLAUDE_SANDBOX_MAX_DECLARED" ]; then
        printf 'truncated %s\n' "$total"
    fi
    return 0
}

config_root() {
    printf '%s' "${CLAUDE_SANDBOX_CONFIG_DIR:-$HOME/.config/claude-sandbox}"
}

# The global store is config_root() itself, not a subdirectory of it - the
# two filenames below can never collide with projects/<slug>, since a slug
# is a sanitized absolute path and always begins with "-".
ensure_global_store() {
    local dir
    dir="$(config_root)"
    mkdir -p "$dir"
    printf '%s' "$dir"
}

# Same sanitization docker/log-shipper.sh uses for its Loki project key, so
# one project has one identity everywhere in this repo.
project_slug() {
    printf '%s' "$1" | sed 's/[^a-zA-Z0-9-]/-/g'
}

# The store a writer must use: whatever a reader would resolve to, created
# for this exact path only when nothing above already covers it. Creating one
# per path unconditionally would be wrong in the workflow inheritance exists
# for - the first approval made from inside a worktree would create a store
# that shadows the project's for every later read, silently un-applying
# everything the worktree had been inheriting.
#
# Recording into the ancestor widens its scope instead, which is the lesser
# surprise but still a surprise, so it says so. The path file is what makes a
# slug collision detectable (resolve_project_store checks it at every level):
# two different projects can sanitize to the same slug, and silently applying
# one project's approvals to another would be a real grant the user never made.
ensure_project_store() {
    local path="$1" dir existing owner
    existing="$(resolve_project_store "$path")" || return 1
    if [ -n "$existing" ]; then
        owner="$(cat "$existing/path" 2>/dev/null)"
        if [ -z "$owner" ]; then
            # A store with no path file (an interrupted write, a hand-made
            # directory) has no collision guard at all, and attaching to it
            # would leave it that way permanently. Heal it - which ancestor
            # it belongs to is whichever one's slug produced this directory,
            # not necessarily $path, and recording the wrong one would make
            # every later read from the real owner look like a collision.
            owner="$path"
            while [ "$(config_root)/projects/$(project_slug "$owner")" != "$existing" ]; do
                owner="$(dirname "$owner")"
            done
            printf '%s\n' "$owner" > "$existing/path"
        fi
        if [ "$owner" != "$path" ]; then
            echo "Note: recorded under the existing approvals for $owner, which" >&2
            echo "$path inherits - so it applies to $owner and everything under it." >&2
        fi
        printf '%s' "$existing"
        return 0
    fi
    dir="$(config_root)/projects/$(project_slug "$path")"
    mkdir -p "$dir"
    printf '%s\n' "$path" > "$dir/path"
    printf '%s' "$dir"
}

# Nearest ancestor with a store, so a git worktree under the project (the
# workflow sandbox-context.sh tells agents to use) inherits the project's
# approvals instead of silently getting none.
resolve_project_store() {
    local path="$1" dir
    if [[ "$path" != /* ]]; then
        echo "resolve_project_store: path must be absolute, got: $path" >&2
        return 1
    fi
    while [ -n "$path" ] && [ "$path" != "/" ]; do
        dir="$(config_root)/projects/$(project_slug "$path")"
        if [ -d "$dir" ]; then
            if [ -f "$dir/path" ] && [ "$(cat "$dir/path")" != "$path" ]; then
                echo "Project slug collision: $dir belongs to $(cat "$dir/path"), not $path" >&2
                return 1
            fi
            printf '%s' "$dir"
            return 0
        fi
        path="$(dirname "$path")"
    done
    return 0
}

_approved_validator() {
    case "$1" in
        allowed-domains) printf 'valid_domain' ;;
        dependencies)    printf 'valid_dep_spec' ;;
        *) return 1 ;;
    esac
}

# Approvals are host-side and trusted, so an entry that fails validation
# means a bug or tampering, not user error - refuse rather than proceed.
approved_entries() {
    local store="$1" kind="$2" file validator line
    validator="$(_approved_validator "$kind")" || return 1
    file="$store/$kind"
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        if ! "$validator" "$line"; then
            echo "corrupt approval entry in $file: $line" >&2
            return 1
        fi
        printf '%s\n' "$line"
    done < "$file"
    return 0
}

approve_entry() {
    local store="$1" kind="$2" entry="$3" validator
    validator="$(_approved_validator "$kind")" || return 1
    "$validator" "$entry" || { echo "Invalid $kind entry: $entry" >&2; return 1; }
    touch "$store/$kind"
    grep -qxF "$entry" "$store/$kind" || printf '%s\n' "$entry" >> "$store/$kind"
}

unapprove_entry() {
    local store="$1" kind="$2" entry="$3" tmp
    [ -f "$store/$kind" ] || return 0
    tmp="$(mktemp)"
    grep -vxF "$entry" "$store/$kind" > "$tmp" || true
    mv "$tmp" "$store/$kind"
}

# Prints a Dockerfile that layers approved packages onto the shared base
# image. Only validated tokens are interpolated (approved_entries refuses
# anything else), so a RUN line here can't become a root-context injection.
#
# Installs run at BUILD time, where there's no egress firewall - which is
# why this is a derived image rather than an install step in entrypoint.sh:
# the latter would need apt/npm/PyPI/crates.io reachable as root before
# init-firewall.sh locks egress down.
generate_derived_dockerfile() {
    local base="$1" store="$2" entries apt npm pip cargo spec name
    entries="$(approved_entries "$store" dependencies)" \
        || { echo "refusing to build from a corrupt dependency list in $store" >&2; return 1; }

    apt=""; npm=""; pip=""; cargo=""
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        name="${spec#*:}"
        case "$spec" in
            apt:*)   apt="$apt $name" ;;
            npm:*)   npm="$npm $name" ;;
            pip:*)   pip="$pip $name" ;;
            cargo:*) cargo="$cargo $name" ;;
        esac
    done <<< "$entries"

    printf 'FROM %s\n' "$base"
    printf 'USER root\n'
    [ -n "$apt" ] && printf 'RUN apt-get update && apt-get install -y --no-install-recommends%s \\\n  && apt-get clean && rm -rf /var/lib/apt/lists/*\n' "$apt"
    [ -n "$pip" ] && printf 'RUN pip install --break-system-packages%s\n' "$pip"
    printf 'USER ${SANDBOX_USER}\n'
    [ -n "$npm" ] && printf 'RUN npm install -g%s\n' "$npm"
    if [ -n "$cargo" ]; then
        # The base image has no Rust toolchain - a cargo: spec is the only
        # thing that pulls one in, so projects without one pay nothing.
        printf 'RUN curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path\n'
        printf 'ENV PATH=$PATH:${SANDBOX_HOME}/.cargo/bin\n'
        printf 'RUN cargo install%s\n' "$cargo"
    fi
    # Restore the base image's privilege posture no matter what the layers
    # above left behind - entrypoint.sh must still start as root and drop
    # via gosu, with no escalation path for the session user.
    printf 'USER root\n'
    printf 'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]\n'
    return 0
}
