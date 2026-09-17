# Composes the permitted set egress-policy is given, from what the sandbox's
# own machinery needs plus what this launch was configured with.
#
# Sourced by firewall-up.sh. Exports three lists, because a destination's
# permitted ports are a property of the destination and not of how it was
# named:
#
#   DEJIMA_FORGE_CLASS     reachable on HTTPS only, plus SSH with the opt-in
#   DEJIMA_OPEN_CLASS      reachable on any port but the DNS ports
#   DEJIMA_INTERNAL_CLASS  entries whose answers may point inside a private
#                          network; every one must also be in a list above
#
# What belongs in the built-in part of these lists is what the sandbox cannot
# run without - the release CDN the tools baked into the image fetch binaries
# from, the npm registry those tools update through, and whatever the SELECTED
# HARNESS declared it needs (api_domains in its manifest, arriving as
# SANDBOX_HARNESS_DOMAINS). Nothing else.
#
# The harness's names are not written here because they are the harness's: a
# name built in is inherited by every harness while a second one still lacks
# its own. registry.npmjs.org stays, because it is not only the harness's -
# nvim's mason fetches language servers through it, and [core] command = nvim
# is a supported way to run a session.
#
# Language ecosystems and editor tooling deliberately do not: a Python, Go or
# Rust project reaches its own package host through an approval, either
# `dejima-allow --global` once or a `.dejima/allowed-domains` line reviewed
# with the project. The distinction is not tidiness. Every name here is
# reachable from every sandbox on the host whether or not the project has any
# use for it, and - since a project's declaration is also what a hardened CI
# runner reads its allowlist from (docs/ci.md) - a name that is granted by
# being built in is a name nobody ever reviewed.

# Forge class. GitHub is reachable for reading - clone, fetch, gh over HTTPS -
# and never for pushing, and the port restriction is what makes that a fact
# rather than a policy: with 22 closed there is no transport left for the
# forwarded agent's real key to authenticate a push with, whatever a hook does
# or does not catch. ALLOW_GITHUB_PUSH=1 is the only thing that opens it.
#
# Suffix entries, because dnsmasq matches a domain and everything under it: one
# line covers api.github.com, codeload.github.com and the rest without
# enumerating them. Stating the class here is what keeps the restriction
# attached to the destination - an address reached by resolving one of these
# names gets the same ports as one reached from the published ranges, so a name
# cannot be the way around the range's restriction.
DEJIMA_FORGE_CLASS=(
    "github.com"
    "githubusercontent.com"
    "githubassets.com"
)

# Open class: reachable on any port, because these are destinations whose
# protocol dejima does not get to decide.
DEJIMA_OPEN_CLASS=(
    "registry.npmjs.org"
    "release-assets.githubusercontent.com"
)

DEJIMA_INTERNAL_CLASS=()

# release-assets.githubusercontent.com is under a forge-class suffix, so it ends
# up in the forge class: firewall-up.sh routes every open-class entry through
# dejima_class_for, this list included, rather than only the ones a project
# declared. It is fetched over HTTPS like everything else under that suffix, so
# the narrower class costs it nothing, and the alternative is a name that
# quietly widens the forge - which is what it did until the normalisation
# covered this list too.

# Split on spaces explicitly, not on whatever IFS the caller happens to have,
# so every consumer gets the same list from the same value. A harness declaring
# two api_domains would otherwise arrive as one glued element and fail its
# lookup, refusing to start.
if [ -n "${SANDBOX_HARNESS_DOMAINS:-}" ]; then
    IFS=' ' read -ra _dejima_harness_domains <<< "$SANDBOX_HARNESS_DOMAINS"
    DEJIMA_OPEN_CLASS+=(${_dejima_harness_domains[@]+"${_dejima_harness_domains[@]}"})
fi

# The harness's API endpoint is permitted only when this session has no
# credential proxy (kill switch or API-key auth), where DNS is the only path to
# it. With the proxy on, the session reaches the API through the forwarder
# rather than by resolving this name (under the tls transport, via
# entrypoint.sh's /etc/hosts pin), so leaving it unresolvable defeats a bypass
# that looks the name up by DNS. It is not a route block: the API's address
# stays reachable as an IP literal for as long as another permitted name
# resolves to the same one.
#
# Open class and not exempted from the answer check, because it is a public
# SaaS name: an answer for it pointing inside the operator's network is the
# thing that check exists to refuse.
#
# Which name this is comes from the provider (proxied_domain); the rule about
# when to permit it is dejima's, and stays here.
if [ -z "${SANDBOX_CREDENTIAL_PROXY_SOCKET:-}" ] \
    && [ -n "${SANDBOX_BACKEND_PROXIED_DOMAIN:-}" ]; then
    DEJIMA_OPEN_CLASS+=("$SANDBOX_BACKEND_PROXIED_DOMAIN")
fi

# Adds one entry to the open class, marking it exempt from the answer check
# when it is a destination dejima already knows is inside the operator's own
# network. That exemption is not handed out to approved domains in general:
# `.dejima/allowed-domains` is reviewed with the project and is expected to
# carry public names, and exempting a public name is what turns one
# attacker-influenced answer into egress to an internal host. A self-hosted
# forge or log sink is different - the operator configured its address, so
# there is nothing for an answer to decide.
dejima_permit_open() {
    local entry="$1" internal="${2:-}"
    [ -n "$entry" ] || return 0
    DEJIMA_OPEN_CLASS+=("$entry")
    [ "$internal" = internal ] && DEJIMA_INTERNAL_CLASS+=("$entry")
    return 0
}

# The same, in the class whose ports are restricted. For a name a forge suffix
# already covers: the suffix makes it reachable, but only an entry of its own
# makes it something the rest of the system can name - dejima_mark_internal and
# the policy's own internal_domains check both look for the exact string, and a
# name reachable by suffix alone is invisible to them.
dejima_permit_forge() {
    local entry="$1"
    [ -n "$entry" ] || return 0
    DEJIMA_FORGE_CLASS+=("$entry")
    return 0
}

# Exempts an entry from the answer check WITHOUT permitting it. The two are
# separate decisions and only one of them is a grant: whether a destination may
# be reached is an approval, and whether an answer for it may point inside the
# operator's network is this. A key that did both would mean naming a host in
# [core] internal_domains was enough to make it reachable, which is not what
# the key says it does and not what anyone reviewing an allowlist would expect
# to find in it.
#
# Returns non-zero for an entry nothing has permitted, so the caller can say
# which one rather than leaving it to be discovered as a destination that is
# quietly unreachable.
dejima_mark_internal() {
    # Case-folded on both sides, for the reason dejima_class_for gives. Here the
    # cost of comparing verbatim is not a lost restriction but a refused launch:
    # this returns non-zero for an entry nothing permits, and the caller stops
    # the container naming it - so [core] internal_domains and the key that
    # permitted the same host, differing only in case, is a configuration that
    # is correct and will not start.
    local entry="${1,,}" known
    [ -n "$entry" ] || return 0
    for known in ${DEJIMA_OPEN_CLASS[@]+"${DEJIMA_OPEN_CLASS[@]}"} \
                 ${DEJIMA_FORGE_CLASS[@]+"${DEJIMA_FORGE_CLASS[@]}"}; do
        if [ "${known,,}" = "$entry" ]; then
            DEJIMA_INTERNAL_CLASS+=("$entry")
            return 0
        fi
    done
    return 1
}

# Which class a name belongs to, by suffix. Anything under a forge-class entry
# is forge class, whoever is asking and however it arrived.
#
# This is why the file is shared rather than restated: bin/dejima-allow adds a
# domain to a session that is already running, and a forge name added to the
# open class there would be reachable on every port - the read-only guarantee
# gone, from a command whose whole output says it granted one domain. It went
# wrong exactly that way when the answer lived in two places.
dejima_class_for() {
    # Case-folded, because DNS names are case-insensitive and the resolver
    # treats them so. Comparing verbatim put GITHUB.COM in the open class while
    # github.com was forge, which is the narrower class silently lost on a
    # spelling an operator is free to use.
    local domain="${1,,}" suffix
    for suffix in ${DEJIMA_FORGE_CLASS[@]+"${DEJIMA_FORGE_CLASS[@]}"}; do
        suffix="${suffix,,}"
        if [ "$domain" = "$suffix" ] || [[ "$domain" == *".$suffix" ]]; then
            printf 'forge'
            return 0
        fi
    done
    printf 'open'
}
