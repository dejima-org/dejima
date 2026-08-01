# Sourced by both init-firewall.sh (IP-based ipset allowlist) and
# dns-proxy.sh (name-based DNS allowlist) so the two can't drift apart.
FIXED_DOMAINS=(
    "registry.npmjs.org"
    "platform.claude.com"
    "gitlab.com"
    "pypi.org"
    "files.pythonhosted.org"
    "release-assets.githubusercontent.com"
    "proxy.golang.org"
    "sum.golang.org"
)

# api.anthropic.com is allowlisted only when this session has no credential
# proxy (kill switch or API-key auth), where DNS is the only path to the API.
# With the proxy on, entrypoint.sh pins the name to loopback in /etc/hosts, and
# leaving it unresolvable defeats a bypass of that pin which looks the name up
# by DNS. It is not a route block: the API's address stays reachable as an IP
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
