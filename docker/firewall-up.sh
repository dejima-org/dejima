#!/bin/bash
# Brings up this network namespace's egress control: the DNS proxy, the packet
# filter, and the two log producers that watch them.
#
# Its own script rather than a block inside entrypoint.sh because the namespace
# it acts on and the session that runs in it need not be in the same container.
# What this does is a property of a network namespace; everything else an
# entrypoint does is a property of a container.
#
# Called with the caller's environment: DEJIMA_FORGE_HOSTS, LOKI_URL,
# ALLOWED_DOMAINS, ENABLE_FIREWALL and the harness values fixed-domains.sh
# reads. It resolves nothing host-side itself.
set -Eeuo pipefail
# Same reason as entrypoint.sh's: under `set -e` alone a failure here aborts
# with no output, and the only symptom is a container that never appeared (#59).
trap 'status=$?; echo "ERROR: firewall-up.sh aborted at line $LINENO (exit $status): $BASH_COMMAND" >&2' ERR

# shellcheck source=caps-lib.sh
source /usr/local/bin/caps-lib.sh

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
    #
    # Root, and nothing else: it parses content the session's own traffic
    # decides, and it needs no capability to read two files its gid already
    # opens or to POST them. So it keeps the uid that makes it untamperable
    # and holds none of the rest.
    #
    # It outlives this script, and reparents to the container's init when this
    # one exits - which is where a daemon watching a session belongs. Started
    # from the entrypoint, it was a child of the very session process it exists
    # to keep an eye on.
    drop_caps -- -c 'exec "$@"' dejima /usr/local/bin/log-shipper.sh &
fi
