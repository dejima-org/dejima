# Shared library: which release a checkout is on. Sourced by bin/dejima (for
# --version and the startup banner) and bin/dejima-update-check (to say what
# the remote has that this does not). Not on PATH and not executable.
#
# A release is a date - 2026.10.12 - and the git tag on `main` is where it
# lives. Nothing in the tree records it, which is the point: a VERSION file
# says what was released and goes on saying it while a checkout is pulled
# past that release, and the one moment the answer matters is the moment it
# would be wrong. `git describe` cannot drift from history.
#
# A date rather than a version number because the question an operator has is
# how old theirs is, and because MAJOR.MINOR would be a promise about
# compatibility and patch lines that SECURITY.md explicitly does not make:
# the tip of `main` is the only supported version, and a tag is a record of
# what shipped rather than something to stay on.

# The release this checkout is on, as one word.
#
#   2026.10.12     exactly that release
#   2026.10.12+37  thirty-seven commits past it, so on no release
#   unreleased     a git checkout with no release tag yet
#   unknown        no git at all, e.g. an unpacked tarball
#
# A second release on one day is 2026.10.12b - see docs/release.md - which
# needs nothing here: the match below accepts it and sort -V orders it after
# the bare date.
#
# Local-only git, so none of the transport configuration dejima-update-check
# has to work around is in the path here.
dejima_version() {  # <repo root>
    local root="$1" tag n
    git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    # Only tags that look like a release. A tag someone pushed for anything
    # else must not become the answer to "which release is this".
    tag="$(git -C "$root" describe --tags --abbrev=0 --match '[0-9]*' 2>/dev/null)" || tag=""
    [ -n "$tag" ] || { printf 'unreleased'; return 0; }
    n="$(git -C "$root" rev-list --count "$tag..HEAD" 2>/dev/null)" || n=0
    case "${n:-0}" in
        0|"") printf '%s' "$tag" ;;
        *)    printf '%s+%s' "$tag" "$n" ;;
    esac
}

# The release part alone, for comparing two of them. `2026.10.12+37` and
# `2026.10.12` are the same release; what differs is whether the checkout
# stopped there.
dejima_version_release() {  # <version>
    printf '%s' "${1%%+*}"
}
