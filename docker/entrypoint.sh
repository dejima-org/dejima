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

# Dedicated headless SSH identity (optional - see bin/claude-sandbox's
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

# Test harness hook (docker/claude-sandbox/test/): everything above this
# point is the real startup sequence - DNS proxy, firewall, IPv6 block,
# logging, privilege-drop prep. Skip execing nvim (which needs a real tty)
# so the suite can `docker exec` into a live, fully-initialized container
# and assert against it, exercising the actual code path instead of a
# reimplementation of it that could drift out of sync.
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
# bin/claude-sandbox) to bring in a real config for it instead of running
# unconfigured.
exec gosu "$SANDBOX_USER" ${SANDBOX_CMD:-claude} "$@"
