# Sourced by every entrypoint in this image. Nothing here runs on its own.
#
# The startup sequence needs real capabilities - it builds the packet filter,
# binds an NFLOG socket, chowns files and drops privilege twice. Nothing after
# it does, and a bounding set survives execve: a process that reaches uid 0
# anywhere downstream recovers its permitted set from whatever bounding set it
# inherited. So an unprivileged session whose effective set is empty still sits
# inside a tree holding every capability the container declares.
#
# `drop_caps` is how anything that outlives a startup script is started, and it
# is what makes a declared floor a description of the root phase rather than of
# the session's whole life.
#
# capsh, not `setpriv --bounding-set`, which is the obvious tool and silently
# the wrong one: without CAP_SETPCAP it exits 0 having changed nothing, so a
# container that lost the capability would run every session with the full set
# and report success at every step. capsh refuses out loud, which is the only
# behaviour worth having here.
#
# `-- -c 'exec "$@"'` runs the command through capsh's shell and immediately
# replaces it, so nothing is left between the caller and the process.
drop_caps() {
    exec capsh --drop=all "$@"
}

# Checked rather than assumed, because the failure it prevents is invisible:
# capsh would abort each drop_caps call, and in an entrypoint the last of those
# is the session, so the container would die at the point it looked ready.
# Named here instead, against the file the floor actually lives in.
#
# Called once by each top-level entrypoint rather than from drop_caps: it is a
# precondition of the whole script, and the point is to refuse before doing
# work rather than partway through it.
require_setpcap() {
    if capsh --decode="$(awk '/^CapEff:/ {print $2}' /proc/self/status)" \
        | grep -q cap_setpcap; then
        return 0
    fi
    echo "${0##*/}: this container does not hold CAP_SETPCAP, so the capabilities" >&2
    echo "the startup sequence needs cannot be taken away again before the session" >&2
    echo "starts - it would run inside a tree holding all of them." >&2
    echo "Refusing to start rather than running with a floor that is not the one" >&2
    echo "docker/docker-compose.yml declares. Add SETPCAP to its cap_add." >&2
    exit 1
}
