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
    # oversight. It now also tails session transcripts (see
    # SANDBOX_LOG_CONVERSATION) that the sandboxed session itself writes, so
    # it is parsing attacker-influenceable content the same way ulogd2 parses
    # attacker-influenceable packets. But what it produces here is itself an
    # oversight/audit log of that same session - letting the sandbox user
    # (the thing being surveilled) also own the shipper would let a
    # compromised session tamper with or kill its own logging; root buys
    # tamper-resistance that a security log needs and a best-effort netflow
    # counter doesn't. The variables it handles are quoted and no `eval` is
    # used, so a crafted transcript can influence what gets shipped, not
    # execute anything here.
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
    ln -sf /usr/local/bin/dejima-harness-wrapper \
        "/usr/local/bin/$SANDBOX_HARNESS_COMMAND"
fi

# ~/.claude config files arrive staged read-only under /etc/dejima-claude
# (see the mount inventory in docker-compose.yml) and get copied into place
# here rather than bind-mounted at their real paths. A copy can't be
# detached by a host-side rename the way a single-file mount can (#47, #48),
# and it closes the one case no mount could: a statusline.sh that is a
# symlink into a dotfiles checkout. Docker resolves the symlink when it sets
# up the staging mount, so what lands here is already the real content.
#
# Root-owned and read-only, so the `#` memory shortcut and /memory keep
# failing visibly against ~/.claude/CLAUDE.md instead of appearing to
# succeed. A compromised session can still unlink and replace them - they
# sit in a directory it owns - but that change is now container-local and
# can't reach the host, which is the whole reason these were read-only.
if [ -d /etc/dejima-claude ]; then
    for staged in settings.json CLAUDE.md; do
        if [ -f "/etc/dejima-claude/$staged" ]; then
            install -o root -g root -m 444 "/etc/dejima-claude/$staged" "$SANDBOX_HOME/.claude/$staged"
        fi
    done
    if [ -f /etc/dejima-claude/statusline.sh ]; then
        install -o root -g root -m 555 /etc/dejima-claude/statusline.sh "$SANDBOX_HOME/.claude/statusline.sh"
    fi
fi

# The real OAuth credential no longer enters the container at all - ~/.claude
# isn't mounted wholesale any more, so there is nothing to mask (#50). What
# lands at this path instead depends on the transport: the tls one needs a
# well-formed fake credential, because Claude Code authenticates from this
# file rather than from an ANTHROPIC_AUTH_TOKEN, and bin/dejima mounts one.
# Nothing is mounted for the loopback transport, so give Claude Code the
# empty file the old mask used to provide rather than betting that an absent
# credentials file behaves the same as an empty one. Either way this is
# skipped when something is already there - which also covers
# [credentials] proxy = off mounting the real credential in deliberately.
if [ ! -e "$SANDBOX_HOME/.claude/.credentials.json" ]; then
    install -o "$SANDBOX_USER" -g "$SANDBOX_USER" -m 600 /dev/null "$SANDBOX_HOME/.claude/.credentials.json"
fi

# TCP front door for the host-side credential proxy (see bin/dejima and
# bin/dejima-anthropic-proxy): the proxy listens on a bind-mounted unix
# socket, and anthropic-proxy-forwarder.js pipes bytes into it. Only started
# when this session actually has a proxy socket.
#
# In the default tls transport, api.anthropic.com is pointed at loopback here
# and the forwarder terminates TLS for it, so Claude Code runs with no
# ANTHROPIC_BASE_URL and no placeholder token - it is indistinguishable from a
# stock install, which is the whole point (see docs/security.md). The hosts
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
            -subj "/CN=api.anthropic.com" \
            -addext "subjectAltName=DNS:api.anthropic.com" 2>&1); then
            echo "FATAL: openssl failed to generate the TLS terminator cert for api.anthropic.com." >&2
            echo "$openssl_err" >&2
            echo "Not starting the session - API traffic would have no valid cert to trust." >&2
            echo "On the HOST, set [credentials] transport = loopback in" >&2
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
        echo "127.0.0.1 api.anthropic.com" >> /etc/hosts
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
exec gosu "$SANDBOX_USER" ${SANDBOX_CMD:-claude} "$@"
