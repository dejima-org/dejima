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
set -Eeuo pipefail
# Same reasoning as init-firewall.sh's: this runs before the firewall in the
# container's startup, and a silent `set -e` abort here is indistinguishable
# from the sandbox never starting for any other reason (#59).
trap 'status=$?; echo "ERROR: dns-proxy.sh aborted at line $LINENO (exit $status): $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fixed-domains.sh
source "$SCRIPT_DIR/fixed-domains.sh"

CONF_FILE=/etc/dnsmasq-sandbox.conf
SERVERS_FILE=/etc/dnsmasq-sandbox-servers.conf
LOG_FILE=/var/log/dnsmasq.log

# Every allowlisted name below is forwarded to Docker's embedded resolver at
# 127.0.0.11, which only exists for containers on a user-defined network
# (compose creates one for the real sandbox). On the default bridge the
# container gets the host's own nameservers instead, dnsmasq has nothing to
# forward to, and the readiness probe at the bottom fails ~24s later with a
# generic timeout that says nothing about why. Falling back to whatever
# resolver is in resolv.conf isn't an option: init-firewall.sh deliberately
# has no egress rule for UDP/53 to an arbitrary destination (see its comment
# on keeping DNS on loopback), so that would just move the failure. Fail
# here instead, naming the actual cause.
if ! grep -qE '^nameserver[[:space:]]+127\.0\.0\.11[[:space:]]*$' /etc/resolv.conf; then
    echo "ERROR: Docker's embedded resolver (127.0.0.11) is not this container's" >&2
    echo "nameserver, so the DNS allowlist has no upstream to forward to. Attach" >&2
    echo "the container to a user-defined docker network (compose does this by" >&2
    echo "default); the default bridge network does not provide the resolver." >&2
    echo "Current /etc/resolv.conf nameservers:" >&2
    grep -E '^nameserver' /etc/resolv.conf >&2 || echo "  (none)" >&2
    exit 1
fi

touch "$LOG_FILE"
chown dnsmasq:dnsmasq "$LOG_FILE" 2>/dev/null || true

# server=/domain/upstream lines live in their own file (rather than the main
# conf) since dnsmasq only re-reads a --servers-file on SIGHUP - lets
# bin/dejima-allow add a domain to a running session by appending a
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
# Reject (and log) any answer for FIXED_DOMAINS/GITHUB_DNS_SUFFIXES that
# resolves to a private RFC1918/loopback/link-local address. Without this,
# a hijacked upstream answer for one of those public domains could resolve
# to an internal address, and since allowed-domains is matched with no
# port restriction (see init-firewall.sh), the top-up below would then
# hand out full TCP-any-port egress to that internal host - turning one
# attacker-influenced public domain into a general internal-network pivot.
# Exempted per-domain below for EXTRA_ALLOWED_DOMAINS, which are expected
# to legitimately be internal hosts (a self-hosted Gitea/Loki instance).
stop-dns-rebind
listen-address=127.0.0.1
port=53
servers-file=$SERVERS_FILE
log-queries
log-facility=$LOG_FILE
user=dnsmasq
pid-file=/var/run/dnsmasq-sandbox.pid
EOF

    # EXTRA_ALLOWED_DOMAINS (the configured forge's hosts and LOKI_URL's, plus
    # the approved domains the launcher passes in ALLOWED_DOMAINS) are
    # expected to potentially be internal/self-hosted addresses, unlike
    # FIXED_DOMAINS/GITHUB_DNS_SUFFIXES above, which are always public SaaS
    # domains - exempt just these from stop-dns-rebind so a legitimately
    # internal forge or Loki host still resolves.
    for domain in ${EXTRA_ALLOWED_DOMAINS:-}; do
        if [[ "$domain" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            continue
        fi
        echo "rebind-domain-ok=/$domain/"
    done

    # init-firewall.sh's ipset population is a one-time snapshot at
    # container start; without ongoing tracking, a domain can start failing
    # again when its CDN edge rotates to an IP that was never added
    # (pypi.org/files.pythonhosted.org/GitHub's release-assets CDN all do
    # this). A single wildcard keeps allowed-domains topped up for every
    # name dnsmasq ever answers: only allowlisted names have an upstream at
    # all (no-resolv + servers-file), so "gets answered" and "is
    # allowlisted" are the same set - including domains added mid-session
    # by bin/dejima-allow, which previously only got a one-time
    # snapshot (ipset= can't live in the SIGHUP-reloadable servers-file).
    # The explicit github-domains lines below still win for GitHub names -
    # dnsmasq applies the longest matching ipset= domain - which is what
    # keeps GitHub IPs out of this port-unrestricted set (github-domains
    # is restricted to 443 by init-firewall.sh; that's the read-only
    # guarantee).
    echo "ipset=/#/allowed-domains"
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
