#!/bin/bash
set -Eeuo pipefail
# The container's startup has to be able to say why it stopped. Under `set -e`
# alone it cannot: the script aborts with no output, the container exits, and
# the only symptom anywhere is that the session never appeared - which reads as
# the sandbox being broken rather than as one command having failed. This is
# also what makes such a failure distinguishable from the checks below that
# refuse deliberately, and say so (#59).
trap 'status=$?; echo "ERROR: entrypoint.sh aborted at line $LINENO (exit $status): $BASH_COMMAND" >&2' ERR

# DEJIMA_FORGE_HOSTS is resolved host-side by bin/dejima (forge_hosts, in
# dejima-provider-lib.sh) from whichever forge is configured, so this file
# does not derive or name any one forge's hostnames itself.
#
# LOKI_URL (a full URL) still needs its own derivation here - Loki's host
# has to be reachable for log-shipper.sh to actually deliver anything.
loki_host=""
if [ -n "${LOKI_URL:-}" ]; then
    loki_host=$(echo "$LOKI_URL" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*##')
fi

extra_domains="${DEJIMA_FORGE_HOSTS:-} ${loki_host} ${ALLOWED_DOMAINS:-}"

if [ "${ENABLE_FIREWALL:-1}" = "1" ]; then
    # dns-proxy.sh must run first: it repoints /etc/resolv.conf at a local
    # dnsmasq that only resolves allowlisted names, so init-firewall.sh's own
    # dig calls (and everything afterward) go through the same restriction.
    EXTRA_ALLOWED_DOMAINS="${extra_domains}" /usr/local/bin/dns-proxy.sh
    EXTRA_ALLOWED_DOMAINS="${extra_domains}" /usr/local/bin/init-firewall.sh

    # NFLOG groups only exist once init-firewall.sh has run, so ulogd2 (the
    # NFLOG consumer) and the Loki shipper start after it. Both are
    # best-effort visibility on top of the enforcement above, not required
    # for it - log-shipper.sh itself no-ops if LOKI_URL isn't set. Runs as
    # its own unprivileged `ulogd` user (opens the NFLOG socket and output
    # files first, then drops), not root - it's parsing headers from
    # attacker-influenceable packets (whatever a compromised session sends),
    # so a bug in it shouldn't be a path back to root in the container.
    #
    # `ulogd -d` daemonizes immediately and always exits 0 from this shell's
    # point of view, regardless of whether the daemon itself goes on to
    # start successfully - so `set -e` above won't catch a failure here (nor
    # should it: logging is best-effort, not something worth failing the
    # whole container over). Check separately so a failure is at least
    # visible instead of silently producing no logs.
    /usr/sbin/ulogd -d -u ulogd -c /etc/ulogd-sandbox.conf
    sleep 0.5
    if ! pgrep -x ulogd >/dev/null; then
        echo "WARNING: ulogd2 failed to start - connection logging will be unavailable (see /var/log/ulogd.log)" >&2
    fi
    # Unlike ulogd2 above, this one stays root - deliberately, not an
    # oversight. What it ships is an oversight log of the session running
    # beside it, and letting the sandbox user own the shipper would let a
    # compromised session tamper with or kill its own logging. Root buys
    # tamper-resistance that a security log needs and a best-effort netflow
    # counter does not.
    #
    # What it reads is dnsmasq's query log and ulogd2's output, both written
    # by root-owned daemons here and neither session-writable.
    /usr/local/bin/log-shipper.sh &
fi

# A normal login/ssh session always chowns the allocated pty to the logging
# in user; this container's entrypoint skips that (there's no login/sshd
# involved), leaving the tty root-owned. nvim's clipboard fallback needs to
# write to it directly as the sandbox user, so fix the ownership up here,
# before dropping privileges.
if [ -t 1 ]; then
    chown "$SANDBOX_USER" "$(tty)" 2>/dev/null || true
fi

# Point git's github.com credential helper at `gh`, which reads GH_TOKEN -
# only possible now, not at image build time, since that's a runtime
# secret. Combined with the firewall restricting github.com to port 443
# only, this is what makes GitHub read-only from inside the sandbox: no
# write-capable credential for it, and SSH (which could use the forwarded
# agent's real key) can't reach it at all. Skipped if GH_TOKEN isn't set -
# github.com HTTPS still works anonymously for public repos either way.
if [ -n "${GH_TOKEN:-}" ]; then
    gosu "$SANDBOX_USER" gh auth setup-git
fi

# Dedicated headless SSH identity (optional - see bin/dejima's
# SANDBOX_SSH_KEY and README "Headless git push"): a purpose-built key
# mounted read-only, independent of whatever forwarded agent socket the
# SSH_AUTH_SOCK mount above provides. Loaded into a fresh agent owned by
# the sandbox user rather than left forwarded, so it keeps working for the
# rest of this container's life even after whatever client connection
# forwarded the *other* agent goes away.
#
# Mounted at /root (not under $SANDBOX_HOME) so only this root-run block
# can ever read it - copied out, loaded into the agent, and the copy
# deleted, all before dropping to the sandbox user below.
SANDBOX_SSH_KEY_SRC="/root/.ssh-sandbox-key-src"
if [ -s "$SANDBOX_SSH_KEY_SRC" ]; then
    install -o "$SANDBOX_USER" -g "$SANDBOX_USER" -m 600 "$SANDBOX_SSH_KEY_SRC" "$SANDBOX_HOME/.ssh/sandbox-key"
    eval "$(gosu "$SANDBOX_USER" ssh-agent -s)" >/dev/null
    gosu "$SANDBOX_USER" ssh-add "$SANDBOX_HOME/.ssh/sandbox-key"
    rm -f "$SANDBOX_HOME/.ssh/sandbox-key"
    export SSH_AUTH_SOCK
fi

# The guards that do not depend on the harness. Both shadow a name on PATH, so
# they catch the command whatever ran it - which is what lets a harness with no
# way to intercept a tool call still get them. Neither is a boundary: a session
# that means to get past either can call the real binary by its full path,
# exactly as it could have used a tool a hook did not cover. They stop an eager
# agent doing the obvious thing by accident, which is what the hooks they
# replace were for (docs/security.md).
#
# Linked here rather than COPYed into place at build time because both depend
# on values that are only known per launch: which hosts this forge may be
# pushed to, and which subcommand this workflow blocks.
if [ -n "${DEJIMA_PUSH_HOSTS:-}${DEJIMA_BLOCKED_BRANCHES:-}" ]; then
    # /usr/local/bin precedes /usr/bin, so this shadows git without moving it
    # and the guard execs /usr/bin/git directly.
    ln -sf /usr/local/lib/dejima/git-guard.sh /usr/local/bin/git
fi

# Every CLI the shadow has something to do about: the one whose merge a
# workflow blocks, and every one that writes a body the session authored. More
# than one, because a forge can have a CLI per artifact rather than one with
# subcommands, and because a forge with nothing blocked can still have
# something to disclose.
#
# The first word of each record names the CLI. The real one is already behind
# the symlink this replaces (see install-forge-bins.sh), so the guard has a
# fixed path to exec.
_shadow_clis() {
    [ -z "${DEJIMA_MERGE_BLOCK:-}" ] || printf '%s\n' "${DEJIMA_MERGE_BLOCK%% *}"
    # "<kind> <cli> <subcommand>...", so the CLI is the second word.
    [ -z "${DEJIMA_DISCLOSE:-}" ] || printf '%s\n' "$DEJIMA_DISCLOSE" |
        while read -r _ _cli _; do
            [ -z "$_cli" ] || printf '%s\n' "$_cli"
        done
}

_shadow_cli_list="$(_shadow_clis | sort -u)"
if [ -n "$_shadow_cli_list" ]; then
    while read -r _cli; do
        [ -n "$_cli" ] || continue
        case "$_cli" in
            */*|.*|'')
                echo "entrypoint: refusing forge command name: $_cli" >&2
                exit 1 ;;
        esac
        if [ -x "/usr/local/lib/dejima/forge/$_cli" ]; then
            ln -sf /usr/local/lib/dejima/forge-guard.sh "/usr/local/bin/$_cli"
        else
            # Naming a command this forge does not ship is a misconfiguration
            # that would otherwise be silent - the guard would never be
            # reached, and the block or the disclosure would look enforced.
            echo "entrypoint: this forge's manifest names '$_cli', which forge" >&2
            echo "'${DEJIMA_FORGE_NAME:-?}' does not install. Nothing is being enforced." >&2
            exit 1
        fi
    done <<< "$_shadow_cli_list"
fi

# Put the harness wrapper on PATH under the harness's own command name,
# ahead of the real binary, so every invocation gets the no-confirm flags -
# including the ones dejima never sees, an interactive shell or an editor
# plugin's terminal. Linked here rather than COPYed at build time because
# the image is shared across harnesses and the selection is per launch.
#
# Root-owned in a root-owned directory: the sandbox user must not be able to
# replace the wrapper with something that drops the flags, or reinstate the
# real binary's name ahead of it.
#
# Skipped when SANDBOX_HARNESS_COMMAND is unset, which is a container started
# without bin/dejima (test/runtime.bats). Refused when it is set to anything
# but a bare command name: it becomes a path under /usr/local/bin, and a
# value with a slash in it would write somewhere else entirely.
if [ -n "${SANDBOX_HARNESS_COMMAND:-}" ]; then
    case "$SANDBOX_HARNESS_COMMAND" in
        */*|.*|'')
            echo "entrypoint: refusing harness command name: $SANDBOX_HARNESS_COMMAND" >&2
            exit 1 ;;
    esac
    # Refuse a name that already resolves to something else on PATH. The
    # manifest's `identifier` type permits any bare name, and the wrapper is
    # linked into /usr/local/bin, which comes first - so a harness declaring
    # `command = gosu`, or `find`, or `install`, would shadow a binary the
    # rest of this script then invokes as root. Resolved through PATH rather
    # than by checking one directory, because those are what the entrypoint
    # actually calls.
    #
    # Two resolutions are legitimate: the real binary being shadowed, and the
    # wrapper itself from an earlier start. The manifest is trusted, so this
    # turns a bad one into a clean refusal rather than closing a hole.
    _wrapper=/usr/local/bin/dejima-harness-wrapper
    _existing="$(command -v "$SANDBOX_HARNESS_COMMAND" 2>/dev/null || true)"
    if [ -n "$_existing" ]; then
        _existing_real="$(readlink -f "$_existing" 2>/dev/null || printf '%s' "$_existing")"
        if [ "$_existing_real" != "$_wrapper" ] \
           && [ "$_existing_real" != "$(readlink -f "${SANDBOX_HARNESS_REAL:-}" 2>/dev/null)" ]; then
            echo "entrypoint: refusing harness command '$SANDBOX_HARNESS_COMMAND':" >&2
            echo "it already resolves to $_existing_real, which is not this harness." >&2
            exit 1
        fi
    fi
    ln -sf "$_wrapper" "/usr/local/bin/$SANDBOX_HARNESS_COMMAND"
fi

# The harness's config arrives staged read-only under /etc/dejima-harness
# and is copied into place here rather than bind-mounted at its real path. A
# copy can't be detached by a host-side rename the way a single-file mount
# can (#47, #48), and it closes the one case no mount could: a file that is
# a symlink into a dotfiles checkout. Docker resolves the symlink when it
# sets up the staging mount, so what lands here is already the real content.
#
# The staging tree mirrors the destination - /etc/dejima-harness/<rel> is
# installed at $SANDBOX_HOME/<rel> - so nothing about any one harness's paths
# is written here, and no mapping has to be passed in and parsed.
#
# Root-owned and read-only, so a harness's own attempts to rewrite them keep
# failing visibly rather than appearing to succeed. A compromised session can
# still unlink and replace them - they sit in a directory it owns - but that
# change is now container-local and can't reach the host, which is the whole
# reason these are read-only.
#
# Mode from the source: an executable one is something the harness runs (a
# statusline), a plain one is something it reads. -type f skips symlinks, so
# nothing here follows a link out of the staging tree.
if [ -d /etc/dejima-harness ]; then
    while IFS= read -r -d '' staged; do
        rel="${staged#/etc/dejima-harness/}"
        dest="$SANDBOX_HOME/$rel"
        mkdir -p "$(dirname "$dest")"
        if [ -x "$staged" ]; then
            install -o root -g root -m 555 "$staged" "$dest"
        else
            install -o root -g root -m 444 "$staged" "$dest"
        fi
    done < <(find /etc/dejima-harness -type f -print0)
fi

# The harness's own writable state. Unlike the staged config above, these are
# owned by the sandbox user and stay writable: they are what the harness
# rewrites as it runs - a plugin registry, a catalogue, an install marker -
# and a harness that cannot record what it just did is a harness that redoes
# it, or refuses to load what it already has.
#
# Nothing written here reaches the host. The host's copy was mounted read-only
# into the staging tree and read once; what the session has is a copy of it.
# That is the whole reason this is a copy rather than a mount.
#
# A destination with nothing staged for it is created empty and left that way.
# That is not a no-op: it is how a directory whose CONTENTS are bind-mounted
# individually comes to be owned by the sandbox user. Docker creates a mount's
# missing parents as root, so without this the session could read the mounted
# entries and add nothing beside them - which is exactly what it needs to do
# when the harness installs a version it did not have.
#
# chown is not recursive past a staged copy, and does not need to be: the
# copied trees hold no mounts, and the directories that do hold mounts have
# nothing staged for them, so the walk never descends into one.
for _rel in ${SANDBOX_HARNESS_SEED:-}; do
    case "$_rel" in
        /*|*..*)
            echo "entrypoint: refusing harness seed path '$_rel': it must be" >&2
            echo "relative to the sandbox user's home and must not contain '..'." >&2
            exit 1 ;;
    esac
    _dest="$SANDBOX_HOME/$_rel"
    if [ -e "/etc/dejima-seed/$_rel" ]; then
        mkdir -p "$(dirname "$_dest")"
        # -T so a directory source lands AS the destination rather than
        # inside it on a second run, and --no-preserve=ownership because the
        # host's uid is not necessarily this container's.
        cp -a -T --no-preserve=ownership "/etc/dejima-seed/$_rel" "$_dest" 2>/dev/null \
            || cp -a -T "/etc/dejima-seed/$_rel" "$_dest"
        chown -R "$SANDBOX_USER:$SANDBOX_USER" "$_dest"
    else
        mkdir -p "$_dest"
        chown "$SANDBOX_USER:$SANDBOX_USER" "$_dest"
    fi
done

# The briefing, rendered before the session starts, for a harness that is not
# handed it by a session-start hook. Two routes and one rendering: the manifest
# names a flag in `briefing_args` for a harness that takes the text on its
# command line, or a `briefing_path` for one that reads a file.
#
# A hook is a size-limited channel, which is why the argument route exists at
# all. Claude Code persists a large SessionStart payload to a file and injects
# a short preview in its place - 9KB arrived whole here, 21KB did not - and a
# composed briefing plus a project's own .dejima.md runs well past that, so
# most of the briefing silently never reached the session. A system prompt has
# no such limit, and unlike anything in the conversation it cannot be compacted
# away later either.
#
# Rendered here rather than composed here. The text is composed host-side and
# mounted read-only at DEJIMA_BRIEFING_FILE; what is added is only what the
# container can resolve - this container's own id, the gap between what the
# project declares it needs and what this image has, and the project's
# .dejima.md. That is the same code the hook runs, for the same reason.
#
# Root-owned and read-only, like the staged config above: a session that could
# write this would be writing its own next briefing. A failure is fatal rather
# than skipped - a session that does not know it is sandboxed is the one thing
# the briefing exists to prevent, and starting one silently is worse than not
# starting it.
DEJIMA_BRIEFING_RENDERED=/etc/dejima/briefing-rendered
if [ -n "${SANDBOX_HARNESS_BRIEFING_ARGS:-}" ] || [ -n "${SANDBOX_HARNESS_BRIEFING_PATH:-}" ]; then
    mkdir -p /etc/dejima
    # Written and renamed, so a harness starting while this is written reads
    # either the whole briefing or no file at all.
    if ! /usr/local/lib/dejima/dejima-briefing-render.sh "" "$PWD" \
            > "$DEJIMA_BRIEFING_RENDERED.part"; then
        rm -f "$DEJIMA_BRIEFING_RENDERED.part"
        echo "entrypoint: could not render the session briefing. Refusing to" >&2
        echo "start a session that would not know it is sandboxed." >&2
        exit 1
    fi
    chown root:root "$DEJIMA_BRIEFING_RENDERED.part"
    chmod 444 "$DEJIMA_BRIEFING_RENDERED.part"
    mv "$DEJIMA_BRIEFING_RENDERED.part" "$DEJIMA_BRIEFING_RENDERED"
fi

# The file route. `briefing_path` is relative to the sandbox user's home.
if [ -n "${SANDBOX_HARNESS_BRIEFING_PATH:-}" ]; then
    # Already validated as a homepath in the manifest. Checked again because
    # this is where it becomes a path, and the manifest is data that core is
    # supposed to be the one enforcing against.
    case "$SANDBOX_HARNESS_BRIEFING_PATH" in
        /*|*..*)
            echo "entrypoint: refusing harness briefing path '$SANDBOX_HARNESS_BRIEFING_PATH':" >&2
            echo "it must be relative to the sandbox user's home and must not contain '..'." >&2
            exit 1 ;;
    esac
    briefing_dest="$SANDBOX_HOME/$SANDBOX_HARNESS_BRIEFING_PATH"
    mkdir -p "$(dirname "$briefing_dest")"
    cp "$DEJIMA_BRIEFING_RENDERED" "$briefing_dest.part"
    chown root:root "$briefing_dest.part"
    chmod 444 "$briefing_dest.part"
    mv "$briefing_dest.part" "$briefing_dest"
fi

# The argument route. dejima-harness-wrapper reads the file and passes it with
# the flag the manifest names, so every invocation of the harness carries the
# briefing and not only the entrypoint's. The hook reads the second variable
# and reduces itself to the session id, which is the one thing this cannot
# carry - the harness has not started here, so the id does not exist yet.
if [ -n "${SANDBOX_HARNESS_BRIEFING_ARGS:-}" ]; then
    export DEJIMA_BRIEFING_RENDERED
    export DEJIMA_BRIEFING_VIA_ARGS=1
fi

# TCP front door for the host-side credential proxy (see bin/dejima and
# bin/dejima-anthropic-proxy): the proxy listens on a bind-mounted unix
# socket, and anthropic-proxy-forwarder.js pipes bytes into it. Only started
# when this session actually has a proxy socket.
#
# In the default tls transport the harness's proxied_api_domain is pointed at
# loopback here and the forwarder terminates TLS for it, so the harness runs
# with no base-URL override and no placeholder token - it is indistinguishable
# from a stock install, which is the whole point (see docs/security.md). The hosts
# entry deliberately lives inside this guard rather than in compose's
# extra_hosts: under [credentials] proxy = off nothing listens on :443, and
# an unconditional entry would black-hole the real API on exactly the path
# that has to keep working.
SANDBOX_ANTHROPIC_TRANSPORT="${SANDBOX_ANTHROPIC_TRANSPORT:-tls}"
export SANDBOX_ANTHROPIC_TRANSPORT
# Checked here rather than in bin/dejima because every launch reaches this
# script, including a bare `docker run` (see test/runtime.bats). The two halves
# branch on opposite polarity - bin/dejima treats anything but `loopback` as
# tls, this script and the forwarder treat anything but `tls` as loopback - so
# a typo would configure them for different transports and fail every API call
# with nothing pointing back at the cause.
case "$SANDBOX_ANTHROPIC_TRANSPORT" in
    tls|loopback) ;;
    *)
        echo "FATAL: SANDBOX_ANTHROPIC_TRANSPORT is set to '$SANDBOX_ANTHROPIC_TRANSPORT'." >&2
        echo "The only valid values are 'tls' (the default) and 'loopback'; they are" >&2
        echo "case-sensitive. Not starting the session - an unrecognised value would" >&2
        echo "otherwise be read as one transport here and the other by bin/dejima." >&2
        exit 1
        ;;
esac
if [ -n "${SANDBOX_ANTHROPIC_PROXY_SOCKET:-}" ]; then
    forwarder_port=18300
    # Which name the terminator answers for is the selected harness's, from
    # `proxied_api_domain` in its manifest - this image is shared by every
    # harness and must name none of them. Empty here means a harness declared
    # a credential proxy it gave no endpoint for: the terminator would come up
    # answering for nothing, the session would reach the real API directly,
    # and the credential the proxy exists to withhold would be the one in use.
    proxied_domain="${SANDBOX_HARNESS_PROXIED_DOMAIN:-}"
    if [ -z "$proxied_domain" ]; then
        echo "FATAL: a credential proxy socket is mounted, but the selected harness" >&2
        echo "declares no proxied_api_domain for the terminator to stand in front of." >&2
        echo "Not starting the session - traffic would reach the API unintercepted." >&2
        exit 1
    fi
    if [ "$SANDBOX_ANTHROPIC_TRANSPORT" = "tls" ]; then
        forwarder_port=443
        # Generated here, in the container, rather than on the host: the key
        # never touches host disk and there is no host state to clean up. It
        # is readable by the sandbox user because the forwarder stays
        # unprivileged - and worthless to anyone else, since the only thing
        # that trusts this anchor is this container, which is already reading
        # that traffic in the clear.
        tls_dir=/etc/dejima-anthropic-tls
        mkdir -p "$tls_dir"
        # set -e aborts the script on openssl's nonzero exit either way, so a
        # failure here never proceeds to chown/export a missing cert - but
        # discarding its stderr would make that abort silent-but-loud (dies,
        # says nothing why). Captured instead of routed straight to /dev/null
        # so the one line that explains the failure survives to the FATAL
        # block below; openssl's success-path chatter is just progress dots.
        if ! openssl_err=$(openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -keyout "$tls_dir/key.pem" -out "$tls_dir/cert.pem" \
            -subj "/CN=$proxied_domain" \
            -addext "subjectAltName=DNS:$proxied_domain" 2>&1); then
            echo "FATAL: openssl failed to generate the TLS terminator cert for $proxied_domain." >&2
            echo "$openssl_err" >&2
            echo "Not starting the session - API traffic would have no valid cert to trust." >&2
            echo "On the HOST, set [credentials] transport = loopback in" >&2
            # The tilde is prose an operator reads, not a path this expands.
            # shellcheck disable=SC2088
            echo "~/.config/dejima/config, or [credentials] proxy = off to launch without" >&2
            echo "the proxy (the real OAuth credential is then mounted into the" >&2
            echo "container) - then relaunch dejima." >&2
            exit 1
        fi
        chown "$SANDBOX_USER" "$tls_dir/key.pem" "$tls_dir/cert.pem"
        chmod 600 "$tls_dir/key.pem"
        chmod 644 "$tls_dir/cert.pem"
        export SANDBOX_ANTHROPIC_TLS_CERT="$tls_dir/cert.pem"
        export SANDBOX_ANTHROPIC_TLS_KEY="$tls_dir/key.pem"
        # /etc/hosts wins over DNS in getaddrinfo, so this bypasses the DNS
        # proxy entirely - which is why fixed-domains.sh leaves the name off
        # the allowlist whenever there is a proxy socket.
        echo "127.0.0.1 $proxied_domain" >> /etc/hosts
        # The trust anchor for the cert above. NODE_EXTRA_CA_CERTS rather than
        # the system store: it needs no update-ca-certificates run, and it is
        # the single most ordinary variable a corporate environment sets.
        export NODE_EXTRA_CA_CERTS="$tls_dir/cert.pem"
    fi
    gosu "$SANDBOX_USER" node /usr/local/bin/anthropic-proxy-forwarder.js &
    # Node's own startup (V8 init, module load, then finally binding the
    # listen socket) isn't instant - without this wait, a request that
    # arrives right after this script proceeds (an automated test's
    # immediate check; in principle also a very fast-starting real client)
    # can race ahead of the bind and see a connection refused. Bash's own
    # /dev/tcp is enough to probe this without a curl/nc dependency.
    forwarder_bound=0
    for _ in $(seq 1 50); do
        (exec 3<>/dev/tcp/127.0.0.1/$forwarder_port) 2>/dev/null && exec 3>&- && forwarder_bound=1 && break
        sleep 0.1
    done
    # Loud, not silent. bin/dejima already refuses to launch when the
    # host-side proxy fails to start, for the same reason: every quiet
    # fallback from here either exposes the credential or, in tls mode, sends
    # API traffic to a loopback port nothing is listening on and produces a
    # connection error nobody can trace back to this.
    if [ "$forwarder_bound" != "1" ]; then
        echo "FATAL: the credential-proxy forwarder never bound 127.0.0.1:$forwarder_port." >&2
        echo "Not starting the session - API traffic would have no working path to the" >&2
        echo "host-side proxy. On the HOST, set [credentials] transport = loopback in" >&2
        # shellcheck disable=SC2088
        echo "~/.config/dejima/config, or [credentials] proxy = off to launch without" >&2
        echo "the proxy (the real OAuth credential is then mounted into the" >&2
        echo "container) - then relaunch dejima." >&2
        exit 1
    fi
fi

# Compose can't conditionally omit an env entry, so these arrive as empty
# strings when the proxy is disabled - empty must mean "absent" for Claude
# Code, not "set to empty", or a disabled proxy wouldn't restore today's
# behavior byte-for-byte.
[ -n "${ANTHROPIC_BASE_URL:-}" ] || unset ANTHROPIC_BASE_URL
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || unset ANTHROPIC_AUTH_TOKEN

# Unset is the ordinary case (remote access is opt-in) and says nothing.
# Set-but-unusable is worth a startup line because of how it presents: the
# marker directory's source is created per launch and removed on exit, so
# restarting the container rather than relaunching `dejima` leaves it gone,
# and Docker answers a missing bind source by creating one root-owned. The
# hook's `[ -d ]` guard then passes and every notification fails EACCES,
# while the session is also missing from `dejima-attach` because its registry
# entry went with the same directory - three unrelated-looking symptoms.
#
# Reported, not repaired: chowning would restore notifications while the
# session stayed absent from the registry, looking fixed with half the
# feature broken. Relaunching is the remedy, and the message can say so.
if [ -n "${DEJIMA_NOTIFY_DIR:-}" ]; then
    if [ ! -d "$DEJIMA_NOTIFY_DIR" ]; then
        echo "WARNING: remote access is enabled, but $DEJIMA_NOTIFY_DIR is not a directory." >&2
        echo "Notifications will not be delivered for this session." >&2
    elif ! gosu "$SANDBOX_USER" test -w "$DEJIMA_NOTIFY_DIR"; then
        echo "WARNING: remote access is enabled, but $DEJIMA_NOTIFY_DIR is not writable by" >&2
        echo "$SANDBOX_USER - so notifications will fail, and this session will not appear in" >&2
        echo "dejima-attach. This is what a container that was RESTARTED rather than" >&2
        echo "relaunched looks like: bin/dejima creates the marker directory per launch and" >&2
        echo "removes it on exit, and Docker recreated the missing bind source as root." >&2
        echo "Stop this container and start a new session with 'dejima' to restore both." >&2
    fi
fi

# Test harness hook (test/): everything above this point is the real
# startup sequence - DNS proxy, firewall, IPv6 block, logging,
# privilege-drop prep. Skip execing $SANDBOX_CMD so the suite can `docker
# exec` into a live, fully-initialized container and assert against it,
# exercising the actual code path instead of a reimplementation of it that
# could drift out of sync.
if [ "${SANDBOX_TEST_MODE:-0}" = "1" ]; then
    exec gosu "$SANDBOX_USER" sleep infinity
fi

# Drop root -> the sandbox user for the actual session; that user has no
# sudo/setuid path back to root after this, so it can't re-run
# init-firewall.sh itself to widen the allowlist mid-session.
#
# SANDBOX_CMD is what actually runs as that user - the selected harness's
# own command unless [core] command overrides it (e.g. to `nvim`) for an
# editor-driven workflow; pair that with SANDBOX_NVIM_CONFIG (see bin/dejima)
# to bring in a real config for it instead of running unconfigured.
# No default. Naming one harness here would make this image that harness's,
# and would name a binary an image built for a different one does not contain
# - an exec failure reading as a broken sandbox rather than as the container
# having been started without the thing that selects a harness.
if [ -z "${SANDBOX_CMD:-}" ]; then
    echo "entrypoint: SANDBOX_CMD is unset, so there is no command to run." >&2
    echo "It is set from the selected harness's manifest by bin/dejima, which" >&2
    echo "is how a session starts. To poke at this image by hand, pass a" >&2
    echo "command: docker run --entrypoint sh ..." >&2
    exit 1
fi
exec gosu "$SANDBOX_USER" $SANDBOX_CMD "$@"
