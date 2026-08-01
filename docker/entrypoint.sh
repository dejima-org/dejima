#!/bin/bash
set -euo pipefail

# Derive the Gitea API hostname from GITEA_API (a full URL) so it can be
# firewall-allowlisted alongside GITEA_SSH_HOST.
gitea_api_host=""
if [ -n "${GITEA_API:-}" ]; then
    gitea_api_host=$(echo "$GITEA_API" | sed -E 's#^[a-zA-Z]+://([^/]+).*#\1#')
fi

# Same for LOKI_URL (also a full URL) - Loki's host needs to be reachable
# for log-shipper.sh to actually deliver anything.
loki_host=""
if [ -n "${LOKI_URL:-}" ]; then
    loki_host=$(echo "$LOKI_URL" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*##')
fi

extra_domains="${GITEA_SSH_HOST:-} ${gitea_api_host} ${loki_host} ${ALLOWED_DOMAINS:-}"

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
# isn't mounted wholesale any more, so there is nothing to mask (#50). Give
# Claude Code the empty file the old mask used to provide rather than betting
# that an absent credentials file behaves the same as an empty one. Skipped
# when something is already there, which means SANDBOX_CREDENTIAL_PROXY=0
# mounted the real credential in deliberately (see bin/dejima).
if [ ! -e "$SANDBOX_HOME/.claude/.credentials.json" ]; then
    install -o "$SANDBOX_USER" -g "$SANDBOX_USER" -m 600 /dev/null "$SANDBOX_HOME/.claude/.credentials.json"
fi

# Loopback bridge for the host-side credential proxy (see bin/dejima
# and bin/dejima-anthropic-proxy): Claude Code talks HTTP to
# 127.0.0.1:18300, the forwarder pipes bytes into the bind-mounted unix
# socket. Only started when this session actually has a proxy socket.
if [ -n "${SANDBOX_ANTHROPIC_PROXY_SOCKET:-}" ]; then
    gosu "$SANDBOX_USER" node /usr/local/bin/anthropic-proxy-forwarder.js &
    # Node's own startup (V8 init, module load, then finally binding the
    # listen socket) isn't instant - without this wait, a request that
    # arrives right after this script proceeds (an automated test's
    # immediate check; in principle also a very fast-starting real client)
    # can race ahead of the bind and see a connection refused. Bash's own
    # /dev/tcp is enough to probe this without a curl/nc dependency.
    for _ in $(seq 1 50); do
        (exec 3<>/dev/tcp/127.0.0.1/18300) 2>/dev/null && exec 3>&- && break
        sleep 0.1
    done
fi

# Compose can't conditionally omit an env entry, so these arrive as empty
# strings when the proxy is disabled - empty must mean "absent" for Claude
# Code, not "set to empty", or a disabled proxy wouldn't restore today's
# behavior byte-for-byte.
[ -n "${ANTHROPIC_BASE_URL:-}" ] || unset ANTHROPIC_BASE_URL
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || unset ANTHROPIC_AUTH_TOKEN

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
# SANDBOX_CMD is what actually runs as that user - defaults to bare `claude`
# (the wrapped binary on PATH, see claude-wrapper.sh) so a fresh clone of
# this repo works with no editor setup at all. Override it (e.g. to `nvim`)
# for a custom editor-driven workflow; pair with SANDBOX_NVIM_CONFIG (see
# bin/dejima) to bring in a real config for it instead of running
# unconfigured.
exec gosu "$SANDBOX_USER" ${SANDBOX_CMD:-claude} "$@"
