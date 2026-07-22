#!/bin/bash
# Restricts DNS resolution itself to an allowlist, rather than only
# filtering the IP connections made afterward: without this, Docker's
# embedded resolver at 127.0.0.11 will still resolve *any* domain even once
# the firewall is locked down (verified: `dig` on a non-allowlisted domain
# resolves fine, only the subsequent connect gets blocked), so a compromised
# session could exfiltrate data by encoding it into query names to an
# attacker-controlled domain. Runs a local dnsmasq bound to 127.0.0.1 with
# no fallback resolver, forwarding only allowlisted names to Docker's real
# resolver; everything else gets no upstream configured at all, so it fails
# outright instead of leaking the query. Must run before init-firewall.sh so
# that script's own dig calls (and everything afterward) go through it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fixed-domains.sh
source "$SCRIPT_DIR/fixed-domains.sh"

CONF_FILE=/etc/dnsmasq-sandbox.conf
SERVERS_FILE=/etc/dnsmasq-sandbox-servers.conf
LOG_FILE=/var/log/dnsmasq.log

touch "$LOG_FILE"
chown dnsmasq:dnsmasq "$LOG_FILE" 2>/dev/null || true

# server=/domain/upstream lines live in their own file (rather than the main
# conf) since dnsmasq only re-reads a --servers-file on SIGHUP - lets
# bin/claude-sandbox-allow add a domain to a running session by appending a
# line here and signaling the container's dnsmasq, no restart needed.
{
    for domain in "${FIXED_DOMAINS[@]}" "${GITHUB_DNS_SUFFIXES[@]}" ${EXTRA_ALLOWED_DOMAINS:-}; do
        # Literal IPs (e.g. a monitoring host given as an IP, not a hostname)
        # don't need a DNS entry - there's nothing to resolve.
        if [[ "$domain" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            continue
        fi
        echo "server=/$domain/127.0.0.11"
    done
} > "$SERVERS_FILE"

{
    cat <<EOF
no-resolv
no-hosts
bind-interfaces
# IPv6 is blocked outright at the firewall (see init-firewall.sh's
# ip6tables policies) - strip AAAA answers too so nothing wastes a
# connection attempt on an address that can never actually be reached.
filter-AAAA
listen-address=127.0.0.1
port=53
servers-file=$SERVERS_FILE
log-queries
log-facility=$LOG_FILE
user=dnsmasq
pid-file=/var/run/dnsmasq-sandbox.pid
EOF

    # init-firewall.sh's ipset population is a one-time snapshot at
    # container start; a domain that's been allowed can still start failing
    # to connect later if its CDN edge rotates to an IP that was never added
    # (pypi.org/files.pythonhosted.org/GitHub's release-assets CDN all do
    # this), and a domain like crates.io being allowed doesn't help
    # index.crates.io/static.crates.io, which real traffic actually hits.
    # These lines keep the ipsets topped up for the life of the session:
    # every time dnsmasq actually answers a query for one of these domains,
    # the resolved IP gets added too, on top of the upfront snapshot -
    # dnsmasq tolerates the target ipset not existing yet at this point
    # (verified: it logs the attempt and still answers the query
    # normally), so this is safe even though it's generated before
    # init-firewall.sh creates the ipsets moments later.
    #
    # This only covers domains known at container start (FIXED_DOMAINS,
    # GITHUB_DNS_SUFFIXES, EXTRA_ALLOWED_DOMAINS) - a domain added mid-session
    # via bin/claude-sandbox-allow only gets the one-time add it already
    # does, not ongoing tracking, since --ipset= can't live in the
    # SIGHUP-reloadable servers-file (dnsmasq only allows --server/
    # --rev-server there).
    for domain in "${FIXED_DOMAINS[@]}" ${EXTRA_ALLOWED_DOMAINS:-}; do
        if [[ "$domain" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            continue
        fi
        echo "ipset=/$domain/allowed-domains"
    done
    for domain in "${GITHUB_DNS_SUFFIXES[@]}"; do
        echo "ipset=/$domain/github-domains"
    done
} > "$CONF_FILE"

dnsmasq --conf-file="$CONF_FILE"

# dnsmasq daemonizes and returns almost immediately, but give it a moment to
# actually be answering before repointing resolv.conf at it.
ready=0
for _ in $(seq 1 20); do
    if dig +time=1 +tries=1 @127.0.0.1 api.anthropic.com >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.2
done
if [ "$ready" -ne 1 ]; then
    echo "ERROR: dnsmasq did not come up in time" >&2
    exit 1
fi

echo "nameserver 127.0.0.1" > /etc/resolv.conf
