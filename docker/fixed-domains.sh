# Sourced by both init-firewall.sh (IP-based ipset allowlist) and
# dns-proxy.sh (name-based DNS allowlist) so the two can't drift apart.
FIXED_DOMAINS=(
    "registry.npmjs.org"
    "api.anthropic.com"
    "gitlab.com"
    "pypi.org"
    "files.pythonhosted.org"
    "release-assets.githubusercontent.com"
    "proxy.golang.org"
    "sum.golang.org"
)

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
