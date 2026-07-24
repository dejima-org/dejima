#!/bin/bash
# Based on the official Anthropic reference dev container:
# https://github.com/anthropics/claude-code/tree/main/.devcontainer
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fixed-domains.sh
source "$SCRIPT_DIR/fixed-domains.sh"

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy github-domains 2>/dev/null || true

# Block IPv6 outright - there's no IPv6 equivalent of the allowlist below, so
# without this, any host with IPv6 egress enabled would let a container
# bypass the entire IPv4-based firewall via an AAAA-resolved address. Only
# tolerate ip6tables being entirely unusable (IPv6 disabled at the kernel
# level, e.g. no ip6_tables module) - once it's confirmed to work at all, a
# failure partway through must fail the whole script (set -e, no more
# blanket `|| true`) rather than silently leaving IPv6 wide open.
if ip6tables -L >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -X
    ip6tables -P INPUT DROP
    ip6tables -P OUTPUT DROP
    ip6tables -P FORWARD DROP
else
    echo "ip6tables unusable - assuming IPv6 is unavailable at the kernel level"
fi

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# Allow localhost. DNS resolution goes entirely through Docker's embedded
# resolver at 127.0.0.11 (see resolv.conf), which stays on loopback, so this
# also covers DNS - no need for a separate "UDP/53 to anywhere" rule, which
# would just be an unrestricted-destination exfil channel.
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipsets with CIDR support. GitHub's ranges get their own set,
# restricted below to port 443 only: the sandbox is meant to be able to read
# from GitHub (clone/fetch/gh over HTTPS) but never push there, and blocking
# SSH (port 22) to it entirely means that's not just policy but physically
# enforced - there's no transport left for the forwarded ssh-agent's real
# key to authenticate a push with, regardless of what a hook does or
# doesn't catch.
ipset create allowed-domains hash:net
ipset create github-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    # -exist: aggregate -q collapses overlapping ranges within each of
    # web/api/git, but not necessarily across all three combined - the same
    # crash this already caused once on the allowed-domains ipset (a
    # duplicate add errors, and set -e turns that into the whole firewall,
    # and thus the whole container, failing to start).
    ipset add github-domains "$cidr" -exist
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Resolve and add other allowed domains (shared with dns-proxy.sh's name
# allowlist via fixed-domains.sh, so the two can't drift apart)
for domain in "${FIXED_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        # -exist: two domains can resolve to the same IP (e.g. pypi.org and
        # files.pythonhosted.org share Fastly edge IPs), and ipset otherwise
        # errors on a duplicate add, which -e/set -e turns into the whole
        # firewall (and thus the container) failing to start.
        ipset add allowed-domains "$ip" -exist
    done < <(echo "$ips")
done

# Resolve and add caller-supplied extra domains (e.g. a Gitea host), if any.
# Unlike the fixed domains above, failures here are non-fatal: a project may
# be run without any Gitea config set, or a host may be transiently
# unresolvable, and that shouldn't prevent the firewall from coming up.
if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
    # The script-wide IFS above drops plain space to tighten word splitting
    # elsewhere, but EXTRA_ALLOWED_DOMAINS is a space-separated list by
    # construction (entrypoint.sh joins GITEA_SSH_HOST/GITEA_API host/
    # LOKI_URL host/ALLOWED_DOMAINS with spaces) - restore it just for this
    # loop, or a multi-entry value silently collapses into one bogus token.
    IFS=' '
    for domain in $EXTRA_ALLOWED_DOMAINS; do
        # A literal IP (e.g. a monitoring host given as an IP, not a
        # hostname) needs no resolution - add it directly.
        if [[ "$domain" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "Adding $domain (extra, literal IP)"
            ipset add allowed-domains "$domain" -exist
            continue
        fi
        echo "Resolving $domain (extra)..."
        ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
        if [ -z "$ips" ]; then
            echo "WARNING: Failed to resolve extra domain $domain, skipping"
            continue
        fi

        while read -r ip; do
            if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "WARNING: Invalid IP from DNS for $domain: $ip, skipping"
                continue
            fi
            echo "Adding $ip for $domain"
            ipset add allowed-domains "$ip" 2>/dev/null || true
        done < <(echo "$ips")
    done
fi

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

echo "Host detected as: $HOST_IP"

# Only the host itself, not its whole subnet - other machines on the same
# LAN/VPC have no reason to be reachable from this container.
iptables -A INPUT -s "$HOST_IP" -j ACCEPT
iptables -A OUTPUT -d "$HOST_IP" -j NFLOG --nflog-group 1 --nflog-prefix "allow-host"
iptables -A OUTPUT -d "$HOST_IP" -j ACCEPT

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains. This isn't
# port-restricted, so it also covers git-over-ssh (port 22) to
# GITEA_SSH_HOST/GITEA_API, which are already in the ipset above - no
# separate "TCP/22 to anywhere" rule needed (that would allow SSH, or any
# raw TCP posing as it, to any host on the internet).
#
# Each terminal ACCEPT/REJECT decision below is also tagged with NFLOG so
# ulogd2 can capture every new outbound connection attempt and its verdict
# (log-shipper.sh ships these to Loki alongside dns-proxy.sh's query log).
# Only new connections reach these rules at all - the ESTABLISHED,RELATED
# rule above already short-circuits the rest of a connection's packets, so
# this logs once per attempt, not once per packet.
iptables -A OUTPUT -m set --match-set allowed-domains dst -j NFLOG --nflog-group 1 --nflog-prefix "allow"
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# GitHub gets port 443 always - read access (clone/fetch/gh over HTTPS).
# Port 22 (needed for SSH push) stays closed unless the caller explicitly
# opted in via ALLOW_GITHUB_PUSH=1 (see bin/claude-sandbox and
# git-push-guard.sh, which independently also has to allow the host before a
# push actually gets through) - default is push there stays physically
# unreachable, not just discouraged.
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set github-domains dst -j NFLOG --nflog-group 1 --nflog-prefix "allow-gh"
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set github-domains dst -j ACCEPT

if [ "${ALLOW_GITHUB_PUSH:-0}" = "1" ]; then
    echo "ALLOW_GITHUB_PUSH=1: opening port 22 to GitHub for SSH push"
    iptables -A OUTPUT -p tcp --dport 22 -m set --match-set github-domains dst -j NFLOG --nflog-group 1 --nflog-prefix "allow-gh-push"
    iptables -A OUTPUT -p tcp --dport 22 -m set --match-set github-domains dst -j ACCEPT
fi

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j NFLOG --nflog-group 2 --nflog-prefix "reject"
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# Verify GitHub SSH (port 22) matches whichever mode was requested - this is
# what makes GitHub actually read-only by default (or actually push-capable
# when ALLOW_GITHUB_PUSH=1), not just discouraged either way. A mismatch here
# means the firewall rules above and this check drifted apart - fail loudly
# rather than silently running in the wrong mode.
if [ "${ALLOW_GITHUB_PUSH:-0}" = "1" ]; then
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22" 2>/dev/null; then
        echo "Firewall verification passed - able to reach github.com:22 as expected (ALLOW_GITHUB_PUSH=1)"
    else
        echo "ERROR: Firewall verification failed - unable to reach github.com on port 22 despite ALLOW_GITHUB_PUSH=1"
        exit 1
    fi
else
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22" 2>/dev/null; then
        echo "ERROR: Firewall verification failed - was able to reach github.com on port 22"
        exit 1
    else
        echo "Firewall verification passed - unable to reach github.com:22 as expected"
    fi
fi
