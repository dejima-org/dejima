#!/bin/bash
# Sourceable helper for the per-project config tooling (bin/dejima,
# dejima-allow, dejima-dep, dejima-project).
#
# Two kinds of file are involved and they are NOT equally trusted:
#
#   .dejima/{allowed-domains,dependencies} in the project - a
#   DECLARATION. The project directory is bind-mounted read-write, so a
#   compromised session can write these. They grant nothing; they are read
#   only to compare against reality and suggest a command for the user to
#   run. Parsed, never sourced - executing a file on a session-writable
#   mount is a host-shell persistence path. declare_entry also WRITES one,
#   which is why it refuses to follow a symlink: a host-side write onto a
#   session-writable path is the one direction this split does not otherwise
#   cover.
#
#   ~/.config/dejima/{allowed-domains,dependencies} - a GLOBAL
#   APPROVAL, applying to every project.
#
#   ~/.config/dejima/projects/<slug>/* - a PROJECT APPROVAL.
#
#   Both are written only by the CLIs, which only the user runs, and neither
#   is ever mounted into the container. They are the only things that
#   actually grant anything.

# shellcheck source=dejima-config-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/dejima-config-lib.sh"
# shellcheck source=dejima-provider-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/dejima-provider-lib.sh"

DEJIMA_MAX_DECLARED=200

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
        [ "$count" -ge "$DEJIMA_MAX_DECLARED" ] && continue
        count=$((count + 1))
        if "$validator" "$line"; then
            printf 'ok %s\n' "$line"
        else
            printf 'rejected %s\n' "$line"
        fi
    done < "$file"
    if [ "$total" -gt "$DEJIMA_MAX_DECLARED" ]; then
        printf 'truncated %s\n' "$total"
    fi
    return 0
}

# Shared argument parsing for dejima-allow and dejima-dep, so the two CLIs
# cannot drift on what --project means.
#
# --project's path is OPTIONAL, so `--project X` is ambiguous: X could be the
# path or the required positional. Deciding by "is X the last token" breaks
# `dejima-dep list --project ~/p`, which has no trailing positional and would
# silently scope to the current directory instead. So:
#
#   --project takes the next token as its path only if that still leaves the
#   command its required trailing positional(s).
#
# Required counts are per-command constants the caller declares.
#
# Sets dj_global, dj_project, dj_project_set, dj_container and dj_positional.
# dj_project_set exists because "--project with no path" (the current
# directory) and "no --project at all" are different scopes that an empty
# dj_project cannot distinguish.
parse_scope_args() {
    local required="$1"; shift
    local -a args=("$@")
    local n="${#args[@]}" i=0 k tok cand after

    dj_global=0; dj_project=""; dj_project_set=0; dj_container=""
    dj_positional=()

    while [ "$i" -lt "$n" ]; do
        tok="${args[$i]}"
        case "$tok" in
            --global) dj_global=1; i=$((i + 1)) ;;
            --container)
                cand="${args[$((i + 1))]:-}"
                if [ -z "$cand" ]; then
                    echo "--container needs a container name or id." >&2
                    return 1
                fi
                dj_container="$cand"; i=$((i + 2)) ;;
            --project)
                dj_project_set=1; i=$((i + 1))
                cand="${args[$i]:-}"
                case "$cand" in ''|-*) continue ;; esac
                # Count the positionals strictly after the candidate, skipping
                # --container's value - counting that as a positional would
                # make the candidate look safe to consume when it is not.
                after=0; k=$((i + 1))
                while [ "$k" -lt "$n" ]; do
                    case "${args[$k]}" in
                        --container) k=$((k + 2)) ;;
                        -*)          k=$((k + 1)) ;;
                        *)           after=$((after + 1)); k=$((k + 1)) ;;
                    esac
                done
                if [ "$after" -ge "$required" ]; then
                    dj_project="$cand"; i=$((i + 1))
                fi ;;
            -*) echo "Unknown option: $tok" >&2; return 1 ;;
            *)  dj_positional+=("$tok"); i=$((i + 1)) ;;
        esac
    done
    return 0
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

# $project is `cd <path> && pwd`'s LOGICAL resolution: a symlinked path
# component's name survives in the string. declare_entry's makedirs/open, and
# every other plain filesystem call, resolve the same path PHYSICALLY - so
# when a component is a symlink, "$project/.dejima" and the directory that
# actually gets created or opened are not the same place.
#
# A legitimate symlinked checkout (a worktree, a bind mount, a symlinked home
# directory) looks exactly like this too, and this function cannot tell the
# two apart - only the operator running the command can, so it discloses the
# mismatch rather than refusing on it. Refusing would break the ordinary case
# outright, with no way forward.
#
# Deliberately not used to change how $project itself is resolved: doing the
# approval lookup/write physically as well would move the *approval* to
# wherever the symlink targets, turning a declaration-only redirect into an
# actual cross-project grant - strictly worse than the mismatch this discloses.
disclose_project_symlink() {
    local logical="$1" physical
    physical="$(cd -P "$logical" && pwd -P)"
    if [ "$physical" != "$logical" ]; then
        echo "Note: $logical is reached through a symlink; it resolves to" >&2
        echo "$physical, and that is where its .dejima declaration actually" >&2
        echo "lives - not $logical." >&2
    fi
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
            echo "Any declaration this call writes still goes to $path/.dejima -" >&2
            echo "the approval and the declaration do not have to share a directory." >&2
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
        corpus)          printf 'valid_corpus_rule' ;;
        tools)           printf 'valid_tool_name' ;;
        *) return 1 ;;
    esac
}

# The rules a project can declare in .dejima/corpus, each of which changes
# what the session briefing tells the agent about how to record its work.
#
# A fixed set rather than a free identifier, and refusing the unknown is the
# point: an entry nothing implements would approve cleanly, appear in the
# store, and do nothing - which reads as the rule being in force when it is
# not. There is one today.
DEJIMA_CORPUS_RULES="commit-per-step"

# An optional tool a project asks for. A name dejima ships a manifest for and
# nothing else: an entry naming a tool that does not exist would approve
# cleanly, sit in the store and install nothing, which reads as the tool being
# in force when it is not - the same reasoning as the corpus rules above.
#
# Refusing at declaration time also means the approval prompt cannot offer an
# operator a name that would silently do nothing.
valid_tool_name() {
    valid_provider_name "$1" || return 1
    provider_dir tool "$1" >/dev/null 2>&1
}

valid_corpus_rule() {
    case " $DEJIMA_CORPUS_RULES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
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

# Record an entry in the project's OWN declaration - the committed, shared
# .dejima/<kind> file. This grants nothing (see this file's header: a
# declaration is parsed, never sourced, and lives on a session-writable
# mount), which is exactly why it is safe to write from the host. What it buys
# is visibility: without it, a domain approved with --project is invisible to
# dejima-project status, to hooks/sandbox-context.sh, and to everyone else on
# the project.
#
# Validated with the same dispatch approve_entry uses, so the two can never
# disagree about what a well-formed entry is.
declare_entry() {
    local project="$1" kind="$2" entry="$3" validator
    validator="$(_approved_validator "$kind")" || return 1
    "$validator" "$entry" || { echo "Invalid $kind entry: $entry" >&2; return 1; }
    # The one write here that lands on the session-writable bind mount, so
    # the one that must not follow a symlink. A session can plant one and
    # then ask the user - via the briefing, which hands over exactly this
    # command - to run the CLI that trips it, aiming a host-privileged
    # append at ~/.config/dejima/allowed-domains (project approval becomes
    # global) or dependencies (installed as root at image build, the one
    # path with no firewall in front of it).
    #
    # Checking first is not enough: the session is normally still live when
    # the user runs this, and it chose the moment, so it can spin a rename
    # loop across any check-to-write window. The guard is the open itself.
    # O_NOFOLLOW fails outright on a symlink, the directory is opened
    # O_DIRECTORY and the file relative to that fd, and the whole
    # read-then-append goes through it - so winning the swap gets an open of
    # the replaced object, not a redirected write.
    #
    # bash cannot open a path that way, hence python3 (already a hard
    # dependency). O_NONBLOCK and the S_ISREG check cover the non-symlink
    # shapes: a planted FIFO would otherwise hang the host CLI for as long as
    # the session declined to open the other end.
    python3 - "$project/.dejima" "$kind" "$entry" "$DEJIMA_MAX_DECLARED" <<'PY'
import errno, os, stat, sys

directory, name, entry = sys.argv[1], sys.argv[2], sys.argv[3]
MAX_DECLARED = int(sys.argv[4])
# A ceiling on the read-back below, not on what a project may declare. The
# largest legitimate file is MAX_DECLARED entries of a domain's 253 bytes plus
# comments - tens of KiB - so this is orders of magnitude clear of anything
# real, and exists only to stop a session-owned file from being unbounded.
LIMIT = 1 << 20
path = os.path.join(directory, name)
why = (
    "A project's .dejima is writable by the sandboxed session, so a link or",
    "special file planted here would aim this host-side append at the approval",
    "store, or at any other file you can write.",
    "Inspect and remove it, then re-run.",
)


def refuse(*lines):
    for line in lines:
        sys.stderr.write(line + "\n")
    raise SystemExit(1)


try:
    os.makedirs(directory, 0o755)
except FileExistsError:
    pass
except OSError as exc:
    refuse("Could not create %s: %s" % (directory, exc.strerror))

try:
    dirfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
except OSError as exc:
    if exc.errno in (errno.ELOOP, errno.ENOTDIR):
        refuse("Refusing to write through %s: it is a symlink, or not a directory at all." % directory, *why)
    refuse("Could not open %s: %s" % (directory, exc.strerror))

try:
    fd = os.open(
        name,
        os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK,
        0o644,
        dir_fd=dirfd,
    )
except OSError as exc:
    if exc.errno in (errno.ELOOP, errno.ENXIO):
        refuse("Refusing to write through %s: it is a symlink or other special file." % path, *why)
    refuse("Could not write %s: %s" % (path, exc.strerror))
finally:
    os.close(dirfd)

# Before any buffered wrapper touches it: a FIFO is opened without blocking
# thanks to O_NONBLOCK, but it is not seekable, and refusing it is the point.
if not stat.S_ISREG(os.fstat(fd).st_mode):
    os.close(fd)
    refuse("Refusing to write to %s: it is not a regular file." % path, *why)

with os.fdopen(fd, "r+b") as fh:
    # Bounded, because the duplicate check has to read back a file the session
    # owns, and `truncate -s 8G` makes an arbitrarily large one at zero disk
    # cost. Reading LIMIT + 1 rather than trusting fstat's size: the file can
    # grow between the two, and this way the ceiling holds whatever it does.
    body = fh.read(LIMIT + 1)
    if len(body) > LIMIT:
        refuse(
            "Refusing to read %s back: it is larger than %d bytes." % (path, LIMIT),
            "A project's .dejima is writable by the sandboxed session, and this",
            "command has to read the file back to skip an entry already declared -",
            "so an oversized one exhausts this machine's memory instead of",
            "misdirecting the write. A real declaration is a few hundred short",
            "lines; read_declared stops reading entries at %d." % MAX_DECLARED,
            "Inspect and truncate it, then re-run.",
        )
    line = entry.encode()
    if line not in body.split(b"\n"):
        # O_APPEND, so this lands at the end whatever else has written since.
        # The leading newline is for a declaration the session left unterminated
        # - without it the append would extend that last line instead.
        fh.write((b"" if not body or body.endswith(b"\n") else b"\n") + line + b"\n")
PY
}

unapprove_entry() {
    local store="$1" kind="$2" entry="$3" tmp
    [ -f "$store/$kind" ] || return 0
    tmp="$(mktemp)"
    grep -vxF "$entry" "$store/$kind" > "$tmp" || true
    mv "$tmp" "$store/$kind"
}

# One RUN per tarball dependency, as root, before the drop to the sandbox
# user. Each unpacks into its own directory under /opt/dejima and puts that
# directory's bin/ on PATH.
#
# --strip-components=1 is what makes a single convention cover the real cases:
# a Go archive has everything under go/, an nvim release under
# nvim-linux-<arch>/, and stripping one level puts bin/ in the same place for
# both. So the spec needs no destination or layout fields, and there is
# nothing per-dependency for an operator to get wrong.
#
# The digest is checked BEFORE unpacking. A tar that is extracted first and
# verified after has already written whatever it contained.
#
# -xaf rather than -xzf: compression is detected from the archive, so xz and
# zstd releases work without the spec having to say which it is.
# DEJIMA_TARBALL_STRIP picks between the two archive shapes. "prefix" is the
# default and the one every dependency uses: everything under a single
# directory, stripped so bin/ lands in the same place whatever the release
# called its top level. "binary" is an archive that IS the executable, with no
# enclosing directory at all - stripping a component there strips the binary
# and extracts nothing, silently, leaving a layer that built fine and contains
# no tool.
#
# A parameter rather than a second emitter, because the digest-before-unpack
# below is the part that must not exist twice.
_emit_tarball_layers() {
    local spec rest name sha url dest strip
    case "${DEJIMA_TARBALL_STRIP:-prefix}" in
        binary) strip="" ;;
        *)      strip="--strip-components=1 " ;;
    esac
    for spec in "$@"; do
        [ -n "$spec" ] || continue
        rest="${spec#tarball:}"
        name="${rest%%@*}"
        rest="${rest#"$name"@}"
        sha="${rest%%:*}"
        url="${rest#"$sha":}"
        printf 'RUN mkdir -p /opt/dejima/%s && \\\n' "$name"
        printf '  wget --tries=3 --timeout=30 --waitretry=5 --retry-connrefused \\\n'
        printf '    -O /tmp/%s.tar "%s" && \\\n' "$name" "$url"
        printf '  echo "%s  /tmp/%s.tar" | sha256sum -c - && \\\n' "$sha" "$name"
        # A bare binary goes straight into the bin/ a prefix archive would
        # have brought with it, so the PATH line below is the same either way.
        dest="/opt/dejima/$name"
        [ -n "$strip" ] || dest="$dest/bin"
        printf '  mkdir -p %s && \\\n' "$dest"
        printf '  tar -C %s %s-xaf /tmp/%s.tar && \\\n' "$dest" "$strip" "$name"
        printf '  rm /tmp/%s.tar\n' "$name"
        printf 'ENV PATH=$PATH:/opt/dejima/%s/bin\n' "$name"
    done
}

# Prints a Dockerfile that layers approved packages onto the shared base
# image. Only validated tokens are interpolated (approved_entries refuses
# anything else), so a RUN line here can't become a root-context injection.
#
# Installs run at BUILD time, where there's no egress firewall - which is
# why this is a derived image rather than an install step in entrypoint.sh:
# the latter would need apt/npm/PyPI/crates.io reachable as root before
# the egress policy locks egress down.
generate_derived_dockerfile() {
    local base="$1" store="$2" entries
    entries="$(approved_entries "$store" dependencies)" \
        || { echo "refusing to build from a corrupt dependency list in $store" >&2; return 1; }
    generate_spec_dockerfile "$base" "$entries"
}

# The same, from specs handed in directly rather than read from an approval
# store. What installs the selected harness is one of these, and it comes from
# that harness's manifest rather than from an operator's approval - so it has
# no store to be read out of, and every other property of the layer should be
# identical to a dependency's.
#
# $2 is a newline-separated list. Callers are responsible for having validated
# each one (valid_dep_spec); nothing below re-checks, for the same reason
# approved_entries is the only way into the function above.
#
# $3, $4 and $5 are for a harness layer and empty for a dependency one:
# directories to create under the sandbox user's home, NAME=VALUE pairs to
# set, and files to create empty at 0600, all space-separated. They exist because the base image must name no harness -
# what a harness keeps state in, and what it wants in its environment, belong
# to that harness's own layer. Validated by the manifest types `homepath` and
# `envpair` before they reach here, which is what makes them safe to
# interpolate unquoted.
generate_spec_dockerfile() {
    local base="$1" entries="$2" dirs="${3:-}" envs="${4:-}" files="${5:-}"
    local apt npm pip cargo spec name d e f

    apt=""; npm=""; pip=""; cargo=""
    local -a tarballs=()
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        name="${spec#*:}"
        case "$spec" in
            apt:*)     apt="$apt $name" ;;
            npm:*)     npm="$npm $name" ;;
            pip:*)     pip="$pip $name" ;;
            cargo:*)   cargo="$cargo $name" ;;
            tarball:*) tarballs+=("$spec") ;;
        esac
    done <<< "$entries"

    printf 'FROM %s\n' "$base"
    printf 'USER root\n'
    if [ -n "$dirs" ]; then
        # 0700 and owned by the sandbox user, because these are the parents of
        # mounts that land inside them: Docker creates a missing parent
        # root-owned, and the session then cannot write the state it keeps
        # there. Created here rather than in the base image so an image
        # carries one harness's directories and no other's.
        printf 'RUN mkdir -p'
        for d in $dirs; do printf ' "${SANDBOX_HOME}"/%s' "$d"; done
        printf ' \\\n  && chown -R ${SANDBOX_USER}:${SANDBOX_USER}'
        for d in $dirs; do printf ' "${SANDBOX_HOME}"/%s' "$d"; done
        printf ' \\\n  && chmod 700'
        for d in $dirs; do printf ' "${SANDBOX_HOME}"/%s' "$d"; done
        printf '\n'
    fi
    if [ -n "$files" ]; then
        # Empty, 0600, owned by the session's user. A harness that reads a
        # credential from a fixed path needs SOMETHING there: an absent file
        # and an empty one are not reliably the same to it, and betting that
        # they are is how a session comes up unauthenticated in a way that
        # reads as a dejima fault.
        #
        # Created in the image rather than by the entrypoint, so a mount at
        # the same path simply shadows it - which is what happens on every
        # transport that mounts one. The entrypoint did it at runtime, which
        # meant every container created one harness's path whether or not that
        # harness was the one selected, and failed outright on an image whose
        # harness had never declared the directory it lives in.
        printf 'RUN install -o ${SANDBOX_USER} -g ${SANDBOX_USER} -m 600 /dev/null'
        for f in $files; do printf ' "${SANDBOX_HOME}"/%s' "$f"; done
        printf '\n'
    fi
    for e in $envs; do printf 'ENV %s\n' "$e"; done
    [ -n "$apt" ] && printf 'RUN apt-get update && apt-get install -y --no-install-recommends%s \\\n  && apt-get clean && rm -rf /var/lib/apt/lists/*\n' "$apt"
    [ -n "$pip" ] && printf 'RUN pip install --break-system-packages%s\n' "$pip"
    _emit_tarball_layers "${tarballs[@]+"${tarballs[@]}"}"
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
    # The base image swept its own setuid bits and file capabilities, and then
    # the apt/pip/tarball layers above installed more software on top. Sweep
    # again here, so a project declaring a dependency that happens to ship a
    # setuid binary fails its build rather than handing every session on that
    # project an escalation path the base image was careful not to have.
    printf 'RUN /usr/local/sbin/strip-privilege-bits\n'
    printf 'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]\n'
    return 0
}

# ---------------------------------------------------------------------------
# Remote access (opt-in). See docs/remote-access.md.
#
# The switch is [remote-access] enabled in the single config file: unset
# means every code path this feature adds is skipped. An old remote.conf on
# disk grants nothing - install.sh reports it as no longer read rather than
# deleting it.
# ---------------------------------------------------------------------------

# The switch is an explicit boolean, not a URL. Overloading base_url as the
# switch would quietly drop a supported setup: ntfy alone is a complete
# configuration, with base_url unset.
#
# Deliberately NOT routed through config_get, which validates the whole file
# on every read. dejima-attach reads no VALUE out of the config - to it remote
# access is simply on or off - and refusing it over a typo in an unrelated
# section would take away the terminal an operator would fix that typo from.
# The blast radius is the reason it matters here: one file holds 33 keys
# across nine sections, so a typo anywhere in it would otherwise take the
# front door down. Everything that consumes an actual value still goes
# through config_get and still refuses on a malformed file, which is the
# contrast the README draws.
remote_enabled() {
    local line section="" key value="" cur
    config_exists || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(_config_trim "$line")"
        case "$line" in
            ''|'#'*|';'*) continue ;;
            '['*']')
                cur="${line#\[}"
                section="$(_config_trim "${cur%\]}")"
                continue
                ;;
            *=*) ;;
            *) continue ;;
        esac
        [ "$section" = "remote-access" ] || continue
        key="$(_config_trim "${line%%=*}")"
        [ "$key" = "enabled" ] || continue
        value="$(_config_trim "${line#*=}")"
    done < "$(config_path)"
    [ "$value" = "on" ]
}

# A run ID as bin/dejima generates it. Shared with dejima-attach and
# dejima-notify-watch, both of which take one from an untrusted direction
# (ttyd's --url-arg; a directory name under the marker root).
valid_run_id() {
    [[ "$1" =~ ^[0-9a-f]{16}$ ]]
}

remote_state_dir() {
    printf '%s/dejima' "${XDG_RUNTIME_DIR:-/tmp}"
}

remote_ttyd_port() {
    config_get remote-access ttyd_port
}

# Empty when unset, which is the signal to pass no -t at all and leave ttyd
# on its own default. The 8-72 bound that kept one glyph from being wider
# than the viewport is now the schema's "?int:8:72", enforced at parse time
# for every read rather than only in this accessor.
remote_ttyd_font_size() {
    config_get remote-access ttyd_font_size
}

# The tmux prefix the terminal page's PREFIX, window and ZOOM buttons send.
# Empty when unset, which is the signal to pass no option at all and leave the
# page on stock tmux's C-b - the same "unset means absent, not defaulted here"
# shape ttyd_font_size has.
#
# The "chord" schema type is what rejects anything that isn't one, at parse
# time for every read rather than only in this accessor. It is narrower than
# tmux's own prefix syntax: C-\ and C-] are excluded because this value is
# interpolated into the page's client options, and a named-chord set is one
# fewer place an escaping question can be got wrong. A stock tmux does not
# use either of those two anyway.
# Whether tapping the terminal page raises the soft keyboard. Unset is the
# useful default and is deliberately NOT a bool default of off: the page
# decides per client from the pointer type, which a host-wide setting cannot
# see. Only a value the operator actually wrote is passed on.
# Whether the terminal page colour-codes its toolbar. Unset means on, which
# the page decides for itself - so, like the tap setting above, only a value
# the operator actually wrote is passed on.
remote_ttyd_button_colors() {
    config_is_set remote-access ttyd_button_colors || return 0
    config_get remote-access ttyd_button_colors
}

remote_ttyd_focus_on_tap() {
    config_is_set remote-access ttyd_focus_on_tap || return 0
    config_get remote-access ttyd_focus_on_tap
}

remote_ttyd_tmux_prefix() {
    config_get remote-access ttyd_tmux_prefix
}
