#!/bin/bash
# Default-deny egress firewall for the sandbox, allowlisting only GitHub's
# published ranges, the fixed/extra domains below, and the Docker host
# itself. The overall shape (ipset + iptables, GitHub ranges via api.github.com/meta,
# allowlist domains resolved via dig) follows the same idea sketched in
# Anthropic's public reference dev container
# (https://github.com/anthropics/claude-code/tree/main/.devcontainer), but
# everything here - IPv6 blocking, ulogd2 verdict logging, the GitHub
# push/pull split, GH_TOKEN auth, and the extra-domains allowlist - is this
# project's own.
set -Eeuo pipefail
IFS=$'\n\t'

# Nothing here may die quietly. Under `set -e` a failure aborts with no output
# and the container simply never appears, which reads as the sandbox being
# broken rather than one command failing. Three CI failures went to two
# instances of exactly that (#59), neither leaving a line to go on.
#
# This is the floor; the explicit `exit 1` paths below say more. -E extends it
# into functions and subshells, where it would not fire at all.
#
# A failure inside a command substitution reports twice, from the subshell and
# from the containing statement. Worth the noise: for `x=$(a | b)` the first
# line is the only thing saying whether it was `a` or `b`.
trap 'status=$?; echo "ERROR: init-firewall.sh aborted at line $LINENO (exit $status): $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fixed-domains.sh
source "$SCRIPT_DIR/fixed-domains.sh"

# Docker's embedded-DNS NAT rules live in the same table we're about to
# flush - snapshot them first so they can be reinstated afterward.
docker_dns_nat_rules=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Reset to a known-empty state before laying down the real ruleset.
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
#
# The `else` below used to log that the family was presumably off at the
# kernel level, and continue. That inferred a fact about the WORLD from a fact
# about a TOOL, and the two are not the same condition: a container whose kernel
# lacks ip6_tables, on a host with IPv6 enabled, took that branch, logged a
# reassuring line, and ran with IPv6 live and unfiltered. Nothing failed,
# because the only thing that had happened was a check that could not tell.
#
# So the branch asks the kernel instead. /proc/net/if_inet6 lists every IPv6
# address on every interface, and it is the netns's own view - present with
# `::1` alone when the stack is up and nothing is reachable, absent entirely
# when IPv6 is compiled out.
#
# Loopback does not count. Refusing to start over `::1` would refuse every
# container that has no IPv6 connectivity at all, which is a false refusal
# for the common case. What matters is an address on an interface that leaves
# the box.
_ipv6_off_box() {
    [ -e /proc/net/if_inet6 ] || return 1
    # address ifindex prefixlen scope flags devname
    awk '$6 != "lo" { found = 1 } END { exit !found }' /proc/net/if_inet6
}

if ip6tables -L >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -X
    ip6tables -P INPUT DROP
    ip6tables -P OUTPUT DROP
    ip6tables -P FORWARD DROP
elif _ipv6_off_box; then
    echo "ip6tables is unusable here, and IPv6 is live on an interface that" >&2
    echo "leaves this container. Turning the family off in this network" >&2
    echo "namespace, since it cannot be filtered." >&2
    # Written to /proc directly rather than through sysctl(8), which is one
    # more thing that has to be in the image for the firewall to hold. Per
    # interface as well as `all`, because which of those flushes existing
    # addresses has varied across kernels.
    for _conf in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [ -w "$_conf" ] || continue
        echo 1 > "$_conf" 2>/dev/null || true
    done
    if _ipv6_off_box; then
        echo "" >&2
        echo "IPv6 is still up and there is no way to filter it from here, so" >&2
        echo "every rule below would be bypassable by an AAAA-resolved address." >&2
        echo "Refusing to start rather than reporting a boundary that is not" >&2
        echo "there. Either give the container a usable ip6tables (the" >&2
        echo "ip6_tables module on the host), or disable IPv6 for its network." >&2
        exit 1
    fi
    echo "IPv6 is off in this namespace."
else
    echo "ip6tables unusable, and no IPv6 address outside loopback - nothing to filter"
fi

# Reinsert just the rules captured above - nothing else Docker had set up in
# nat comes back, so the reset above stays meaningful.
if [ -n "$docker_dns_nat_rules" ]; then
    echo "Reinstating captured Docker DNS rules"
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$docker_dns_nat_rules" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules were present to restore"
fi

# Allow localhost. Every DNS query this container makes starts here: to
# dnsmasq on 127.0.0.1, and from there to Docker's embedded resolver on
# 127.0.0.11 (see resolv.conf). What this rule does NOT cover is the hop
# after that, where the embedded resolver forwards an external name to the
# host's nameservers - see the owner-matched rule further down, which is
# there because that hop can leave this namespace. Still no "UDP/53 to
# anywhere" rule, which would be an unrestricted-destination exfil channel.
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

# Pull GitHub's published IP ranges so GitHub traffic can be allowed without
# opening up the entire internet.
echo "Looking up GitHub's IP ranges..."
# Authenticated whenever GH_TOKEN is set: unauthenticated /meta is capped at
# 60 requests per hour per source IP, shared across every container start and
# everything else on the host, so a session that starts sandboxes in a loop
# exhausts it and every subsequent launch fails here. Same read-only token
# `gh` already gets (see docker-compose.yml), sent to the API it belongs to.
gh_auth=()
if [ -n "${GH_TOKEN:-}" ]; then
    gh_auth=(-H "Authorization: Bearer $GH_TOKEN")
fi

# Bounded, retried, and reported. All three were missing, and the combination
# was worse than any of them alone (#59).
#
# `curl -s` with no --max-time has no deadline at all - it waits as long as the
# kernel keeps retrying the SYN. And under `set -euo pipefail` at the top of
# this file, a curl that exits non-zero takes the whole script down ON THE
# ASSIGNMENT, so every diagnostic below it is unreachable in exactly the case
# that needs one: the container dies having printed nothing after the line
# above, and the operator - or CI - sees only "the container never became
# ready". The `|| status=$?` is what keeps the failure ours to report.
#
# Retried because both failure modes here are transient. A blip costs a few
# seconds instead of the launch; and a burst of container starts can trip
# GitHub's secondary rate limit, which answers 403 with a JSON body rather
# than a transport error - so the retry has to wrap the response check too,
# not just the transfer. curl's own --retry would not cover that case.
fetch_github_ranges() {
    local attempt status body
    for attempt in 1 2 3; do
        status=0
        # -S so curl's own reason ("Operation timed out after ...") reaches
        # stderr and therefore `docker logs`; -s alone would swallow it.
        body=$(curl -sS --connect-timeout 5 --max-time 10 \
            ${gh_auth[@]+"${gh_auth[@]}"} https://api.github.com/meta) || status=$?
        if [ "$status" -ne 0 ]; then
            echo "  attempt $attempt/3: curl exited $status" >&2
        elif [ -z "$body" ]; then
            echo "  attempt $attempt/3: empty response" >&2
        elif ! printf '%s' "$body" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
            # An API error - rate limiting, a bad token - comes back as a JSON
            # body carrying a `message` and no ranges. Surface it rather than
            # reporting the response as malformed, which points at the wrong
            # thing entirely.
            echo "  attempt $attempt/3: $(printf '%s' "$body" \
                | jq -re '.message' 2>/dev/null || echo 'response carried no ranges')" >&2
        else
            printf '%s' "$body"
            return 0
        fi
        # `if`, not `[ ... ] && sleep`: the AND-list's status on the last
        # attempt is 1, which set -e would take as the script failing here
        # rather than falling through to the message below.
        if [ "$attempt" -lt 3 ]; then
            sleep $((attempt * 2))
        fi
    done
    return 1
}

if ! gh_ranges=$(fetch_github_ranges); then
    echo "ERROR: could not fetch GitHub's IP ranges from api.github.com/meta." >&2
    echo "Tried three times over ~36s; the reason for each attempt is above." >&2
    echo "The sandbox cannot start without them - the firewall would deny every" >&2
    echo "GitHub range, so git, gh and the API would all fail once inside." >&2
    exit 1
fi

echo "Loading GitHub's ranges into the ipset..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: GitHub meta returned a malformed CIDR range: $cidr"
        exit 1
    fi
    echo "  + $cidr"
    # -exist: aggregate -q collapses overlapping ranges within each of
    # web/api/git, but not necessarily across all three combined - the same
    # crash this already caused once on the allowed-domains ipset (a
    # duplicate add errors, and set -e turns that into the whole firewall,
    # and thus the whole container, failing to start).
    ipset add github-domains "$cidr" -exist
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Resolve and add other allowed domains (shared with dns-proxy.sh's name
# allowlist via fixed-domains.sh, so the two can't drift apart)
# Same treatment as the GitHub fetch above, and for the same reason: this loop
# was `ips=$(dig ... | awk ...)`, which under `set -o pipefail` dies on the
# ASSIGNMENT when dig exits non-zero - silently, before the "returned nothing"
# check below can run. It aborted a CI container twice, at a different domain
# each time, with the log simply stopping mid-loop (#59).
#
# Retried because a lookup here is the first traffic through a dnsmasq that
# entrypoint.sh started moments ago, and because a CDN's resolver being briefly
# unavailable should cost a second, not the container. +time/+tries bound each
# attempt: dig's defaults are 5s x 3 tries, so a single unanswered lookup could
# spend 15s of a startup budget on its own.
resolve_domain() {
    local domain="$1" attempt status answer ips
    for attempt in 1 2 3; do
        status=0
        answer=$(dig +noall +answer +time=3 +tries=1 A "$domain" 2>&1) || status=$?
        if [ "$status" -ne 0 ]; then
            echo "  attempt $attempt/3: dig exited $status${answer:+ - $answer}" >&2
        else
            ips=$(printf '%s\n' "$answer" | awk '$4 == "A" {print $5}')
            if [ -n "$ips" ]; then
                printf '%s\n' "$ips"
                return 0
            fi
            # A CNAME-only answer, an empty one, or a rebind rejection. Printing
            # what did come back separates "no such name" from "dnsmasq refused
            # this answer", which look identical from an empty A list.
            echo "  attempt $attempt/3: no A records${answer:+ - $answer}" >&2
        fi
        if [ "$attempt" -lt 3 ]; then
            sleep "$attempt"
        fi
    done
    return 1
}

for domain in "${FIXED_DOMAINS[@]}"; do
    echo "Looking up $domain..."
    if ! ips=$(resolve_domain "$domain"); then
        echo "ERROR: DNS lookup for $domain failed - each attempt is above." >&2
        echo "The firewall cannot allowlist a domain it cannot resolve, and the" >&2
        echo "sandbox would start with that domain unreachable, so this is fatal." >&2
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: $domain resolved to something that isn't an IPv4 address: $ip"
            exit 1
        fi
        echo "  + $ip ($domain)"
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
    # construction (entrypoint.sh joins DEJIMA_FORGE_HOSTS/LOKI_URL host/
    # ALLOWED_DOMAINS with spaces) - restore it just for this
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
        # Through resolve_domain like the fixed domains, which is what makes
        # the comment above true. `ips=$(dig ... | awk ...)` did not merely
        # fail to warn on a failing dig - under `set -o pipefail` it took the
        # whole script down on the assignment, so "non-fatal" held for a
        # domain that resolved to nothing and not for one whose lookup errored.
        if ! ips=$(resolve_domain "$domain"); then
            echo "WARNING: Failed to resolve extra domain $domain, skipping"
            continue
        fi

        # Not always allowed-domains: that set carries no port restriction,
        # so a GitHub address landing in it is reachable on 22 as well and the
        # read-only guarantee is gone. See ipset_for_domain.
        target_set=$(ipset_for_domain "$domain")
        while read -r ip; do
            if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "WARNING: Invalid IP from DNS for $domain: $ip, skipping"
                continue
            fi
            echo "Adding $ip for $domain (-> $target_set)"
            ipset add "$target_set" "$ip" 2>/dev/null || true
        done < <(echo "$ips")
    done
fi

# The Docker host's IP, taken from the container's default route - needed
# below so the sandbox can still reach services running on the host itself.
HOST_IP=$(ip -4 route show default | awk '{print $3; exit}')
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Couldn't determine the Docker host's IP from the default route"
    exit 1
fi

echo "Docker host IP: $HOST_IP"

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

# Docker's embedded resolver forwards external names to the host's
# nameservers, and on some versions does it from inside THIS namespace. Those
# queries then traverse the chain below and match nothing - the host's
# resolver is neither in an ipset nor the bridge gateway - so they hit the
# catch-all REJECT and every lookup SERVFAILs. Only the first hop stays on
# loopback. Two hosts with byte-identical /etc/resolv.conf behaved
# differently, so this is version-dependent and cannot be assumed either way.
#
# --uid-owner 0 keeps this from being the hole the DNS allowlist closes: the
# forwarding socket is dockerd's (root), the session is `node` with no sudo,
# so it still cannot address a resolver directly. This newly permits DNS only
# from processes already root in a NET_ADMIN container, which could flush the
# ruleset anyway.
#
# Guarded, not asserted: xt_owner is a module, and a kernel without it should
# leave a container that says why (the DNS self-check below) rather than one
# that aborts here.
if iptables -A OUTPUT -p udp --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null; then
    iptables -A OUTPUT -p tcp --dport 53 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null \
        || echo "WARNING: could not add the TCP/53 rule for root-owned sockets - large answers may fail" >&2
else
    echo "WARNING: the iptables owner match is unavailable, so Docker's embedded" >&2
    echo "resolver cannot forward out of this namespace. If DNS works anyway this" >&2
    echo "host forwards elsewhere and nothing is wrong; the self-check below says which." >&2
fi

# Then allow only specific outbound traffic to allowed domains. This isn't
# port-restricted, so it also covers git-over-ssh (port 22) to the
# configured forge's hosts, which are already in the ipset above - no
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
# opted in via ALLOW_GITHUB_PUSH=1 (see bin/dejima and
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

echo "Firewall rules applied. Self-checking..."

# DNS before either connectivity check, because both of those resolve a name
# before they connect and neither can tell you that resolution is what failed.
# The negative control is the trap: with DNS dead it fails for the wrong
# reason and prints "example.com is unreachable, as it should be", so a
# container with no working DNS at all reports a passing check and then dies
# on the positive control naming a host rather than the cause. Reading that
# output backwards took an afternoon; it should take one line.
if ! dns_probe=$(dig +short +time=3 +tries=2 A api.github.com 2>&1) || [ -z "$dns_probe" ]; then
    echo "ERROR: self-check failed - DNS does not resolve inside the sandbox." >&2
    echo >&2
    echo "The path is: this container -> dnsmasq on 127.0.0.1 (dns-proxy.sh) ->" >&2
    echo "Docker's embedded resolver on 127.0.0.11 -> the host's nameservers." >&2
    echo "Only the first two hops are on loopback. If Docker forwards the last" >&2
    echo "one from inside this namespace, it traverses the OUTPUT chain, matches" >&2
    echo "nothing, and is rejected - which reads as SERVFAIL, not as a firewall." >&2
    echo >&2
    echo "  dig said: ${dns_probe:-(empty answer)}" >&2
    echo "  packets taken by the catch-all OUTPUT reject so far:" >&2
    iptables -L OUTPUT -vn 2>/dev/null \
        | awk '/icmp-admin-prohibited/ {print "    " $1 " packets, " $2 " bytes"}' >&2
    echo "  dnsmasq's last words:" >&2
    tail -5 /var/log/dnsmasq.log 2>/dev/null | sed 's/^/    /' >&2
    exit 1
fi
echo "self-check ok - DNS resolves an allowlisted name"

# --max-time as well as --connect-timeout on both self-checks: a connect that
# succeeds and then stalls is not covered by --connect-timeout, and while these
# two sit inside `if` (so set -e cannot take the script down the way it could
# above), a stalled transfer here still hangs the container's startup with no
# deadline of its own.
if curl --connect-timeout 5 --max-time 15 https://example.com >/dev/null 2>&1; then
    echo "ERROR: self-check failed - a non-allowlisted host (example.com) was reachable"
    exit 1
else
    echo "self-check ok - example.com is unreachable, as it should be"
fi

# Confirm the allowlist itself actually works, not just that the default-deny does.
#
# Retried, unlike the negative control above, because the two ask opposite
# questions. This one asserts something CAN be reached, and a transient DNS
# answer or a CDN edge rotating mid-boot answers it wrongly in the direction
# that kills the container - which is how it presented, one container failing
# here while a dozen others in the same CI run came up fine. The example.com
# check must NOT be retried: there a single success is the real answer, and
# retrying would only be asking until it says what we want.
github_reachable=0
for attempt in 1 2 3; do
    if curl --connect-timeout 5 --max-time 15 https://api.github.com/zen >/dev/null 2>&1; then
        github_reachable=1
        break
    fi
    echo "  attempt $attempt/3: api.github.com not reachable yet" >&2
    # `if`, not `[ ... ] && sleep` - see fetch_github_ranges above for what
    # that costs on the last attempt under set -e.
    if [ "$attempt" -lt 3 ]; then
        sleep $((attempt * 2))
    fi
done
if [ "$github_reachable" -ne 1 ]; then
    echo "ERROR: self-check failed - api.github.com should be reachable but wasn't"
    exit 1
else
    echo "self-check ok - api.github.com is reachable, as expected"
fi

# Verify GitHub SSH (port 22) matches whichever mode was requested - this is
# what makes GitHub actually read-only by default (or actually push-capable
# when ALLOW_GITHUB_PUSH=1), not just discouraged either way. A mismatch here
# means the firewall rules above and this check drifted apart - fail loudly
# rather than silently running in the wrong mode.
if [ "${ALLOW_GITHUB_PUSH:-0}" = "1" ]; then
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22" 2>/dev/null; then
        echo "self-check ok - github.com:22 is reachable, as expected with ALLOW_GITHUB_PUSH=1"
    else
        echo "ERROR: self-check failed - github.com:22 should be reachable under ALLOW_GITHUB_PUSH=1 but wasn't"
        exit 1
    fi
else
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22" 2>/dev/null; then
        echo "ERROR: self-check failed - github.com:22 was reachable without ALLOW_GITHUB_PUSH=1"
        exit 1
    else
        echo "self-check ok - github.com:22 is unreachable, as it should be"
    fi
fi
