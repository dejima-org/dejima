# Sourced by both init-firewall.sh (IP-based ipset allowlist) and
# dns-proxy.sh (name-based DNS allowlist) so the two can't drift apart.
#
# What belongs here is what the sandbox's own machinery cannot run without -
# the harness and its updates, and the release CDN the tools baked into the
# image fetch binaries from. Nothing else.
#
# Language ecosystems and editor tooling deliberately do not: a Python, Go or
# Rust project reaches its own package host through an approval, either
# `dejima-allow --global` once or a `.dejima/allowed-domains` line reviewed
# with the project. The distinction is not tidiness. Every name here is
# reachable from every sandbox on the host whether or not the project has any
# use for it, and - since a project's declaration is also what a hardened CI
# runner reads its allowlist from (docs/ci.md) - a name that is granted by
# being built in is a name nobody ever reviewed.
FIXED_DOMAINS=(
    "registry.npmjs.org"
    "platform.claude.com"
    "release-assets.githubusercontent.com"
)

# api.anthropic.com is allowlisted only when this session has no credential
# proxy (kill switch or API-key auth), where DNS is the only path to the API.
# With the proxy on, the session reaches the API through the forwarder rather
# than by resolving this name (under the tls transport, via entrypoint.sh's
# /etc/hosts pin), so leaving it unresolvable defeats a bypass that looks the
# name up by DNS. It is not a route block: the API's address stays reachable as an IP
# literal for as long as platform.claude.com above resolves to the same one.
# Appended here rather than to EXTRA_ALLOWED_DOMAINS because it is a public
# SaaS name: dns-proxy.sh exempts the extra list from stop-dns-rebind, and
# init-firewall.sh downgrades a failed lookup there to a warning.
if [ -z "${SANDBOX_ANTHROPIC_PROXY_SOCKET:-}" ]; then
    FIXED_DOMAINS+=("api.anthropic.com")
fi

# GitHub itself is allowlisted by IP range (see github-domains ipset,
# populated from api.github.com/meta), never by resolving these names to
# specific IPs - but the container's own tools (git, gh, curl) still need to
# resolve these names to *something* before connecting, so the DNS proxy
# needs to know they're allowed even though init-firewall.sh never digs them.
# Suffix matching means these also cover their actual subdomains in use
# (api.github.com, codeload.github.com, objects.githubusercontent.com, etc.)
# without enumerating each one.
GITHUB_DNS_SUFFIXES=(
    "github.com"
    "githubusercontent.com"
    "githubassets.com"
)

# Which ipset an allowlisted name's addresses belong in.
#
# GitHub's are restricted to port 443 by init-firewall.sh, and that
# restriction IS the read-only guarantee: no transport is left for a
# forwarded agent key to push with. allowed-domains has no port restriction,
# so a GitHub address landing there silently undoes the arrangement.
#
# dnsmasq applies the longest matching ipset= line, so dns-proxy.sh gets this
# right for free. Every other path has to ask, and two did not - the
# extra-domains loop and bin/dejima-allow's live add both appended
# unconditionally. A project declaring github.com therefore opened port 22 to
# whatever address was cached at container start, presenting as an
# intermittent startup failure because the self-check re-resolves and only
# sees the hole when the second answer matches the first.
ipset_for_domain() {
    local domain="$1" suffix
    for suffix in "${GITHUB_DNS_SUFFIXES[@]}"; do
        if [ "$domain" = "$suffix" ] || [[ "$domain" == *".$suffix" ]]; then
            printf 'github-domains'
            return 0
        fi
    done
    printf 'allowed-domains'
}
