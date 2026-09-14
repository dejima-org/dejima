#!/bin/bash
# Brings up this network namespace's egress control: the packet filter, the
# restricted resolver, and the log producers that watch them. All of that is
# docker/egress-policy; this file is what turns a launch's configuration into
# the permitted set that policy is given.
#
# Its own script rather than a block inside entrypoint.sh because the namespace
# it acts on and the session that runs in it need not be in the same container.
# What this does is a property of a network namespace; everything else an
# entrypoint does is a property of a container.
#
# Called with the caller's environment: DEJIMA_FORGE_HOSTS, LOKI_URL,
# ALLOWED_DOMAINS, ALLOW_GITHUB_PUSH, GH_TOKEN, ENABLE_FIREWALL and the harness
# values fixed-domains.sh reads. It resolves nothing host-side itself.
set -Eeuo pipefail
# Same reason as entrypoint.sh's: under `set -e` alone a failure here aborts
# with no output, and the only symptom is a container that never appeared (#59).
trap 'status=$?; echo "ERROR: firewall-up.sh aborted at line $LINENO (exit $status): $BASH_COMMAND" >&2' ERR

# shellcheck source=caps-lib.sh
source /usr/local/bin/caps-lib.sh
# shellcheck source=fixed-domains.sh
source /usr/local/bin/fixed-domains.sh

[ "${ENABLE_FIREWALL:-1}" = "1" ] || exit 0

# DEJIMA_FORGE_HOSTS is resolved host-side by bin/dejima (forge_hosts, in
# dejima-provider-lib.sh) from whichever forge is configured, so this file does
# not derive or name any one forge's hostnames itself. Marked internal: a
# self-hosted forge is routinely on the operator's own network, and its address
# is something they configured rather than something an answer decides.
for _host in ${DEJIMA_FORGE_HOSTS:-}; do
    dejima_permit_open "$_host" internal
done

# LOKI_URL is a full URL and still needs its own derivation here - Loki's host
# has to be reachable for log-shipper.sh to deliver anything. Internal for the
# same reason as the forge.
if [ -n "${LOKI_URL:-}" ]; then
    dejima_permit_open "$(echo "$LOKI_URL" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*##')" internal
fi

# A model the operator serves themselves, from [backend.<name>] base_url. Same
# class as the forge and Loki and exempted for the same reason: they configured
# the address, so there is nothing for an answer to decide - and a self-served
# endpoint is on their own network about as often as not.
dejima_permit_open "${DEJIMA_BACKEND_HOST:-}" internal

# Approved domains, from `dejima-allow --global` and the project's own
# `.dejima/allowed-domains`. NOT marked internal: these are reviewed with the
# project and expected to be public names, and the whole value of the answer
# check is that a public name answered with an internal address is refused. An
# approved domain that really is internal makes the container say so at start,
# naming the entry - see egress-policy's check on the permitted names.
#
# Added in its own class rather than all in one. A forge-class name in the open
# class would get the resolver a line more specific than the forge suffix entry,
# feeding the open-class set, and the port restriction would rest on the forge's
# published ranges alone - one layer where the design has two. A project
# declaring github.com is the ordinary way to reach that.
#
# Recorded rather than skipped, even though the suffix entry already makes it
# reachable: [core] internal_domains is checked against these lists by exact
# string, so a name reachable only by suffix reads as one nothing permits, and
# the launch stops on a configuration that is in fact correct.
for _domain in ${ALLOWED_DOMAINS:-}; do
    if [ "$(dejima_class_for "$_domain")" = forge ]; then
        dejima_permit_forge "$_domain"
    else
        dejima_permit_open "$_domain"
    fi
done

# Declared internal destinations, for the case the check above names: an
# operator whose approved domain genuinely points inside their network says so
# here rather than losing the check for every other name.
#
# This exempts; it does not permit. Reaching a destination is an approval and
# lives in the lists above, and a key that did both would make naming a host
# here enough to reach it - which is not what it says it does, and is a grant
# nobody reviewing an allowlist would think to look for.
#
# Naming something nothing permitted is a disagreement inside the operator's
# own configuration, so it stops the container here rather than leaving a
# destination silently unreachable and an exemption silently unused.
_unknown=""
for _domain in ${DEJIMA_INTERNAL_DOMAINS:-}; do
    dejima_mark_internal "$_domain" || _unknown="$_unknown $_domain"
done
if [ -n "$_unknown" ]; then
    echo "ERROR: [core] internal_domains names destinations nothing permits:$_unknown" >&2
    echo "That key exempts a name from the check that refuses an answer pointing" >&2
    echo "inside a private network. It does not make the name reachable - approve" >&2
    echo "it as well, per project or globally:" >&2
    echo "" >&2
    for _domain in $_unknown; do
        echo "  dejima-allow --global $_domain" >&2
    done
    exit 1
fi

_join() { local IFS=' '; echo "${*:-}"; }

EGRESS_FORGE_NAMES="$(_join ${DEJIMA_FORGE_CLASS[@]+"${DEJIMA_FORGE_CLASS[@]}"})"
EGRESS_ALLOWED_NAMES="$(_join ${DEJIMA_OPEN_CLASS[@]+"${DEJIMA_OPEN_CLASS[@]}"})"
EGRESS_INTERNAL_OK="$(_join ${DEJIMA_INTERNAL_CLASS[@]+"${DEJIMA_INTERNAL_CLASS[@]}"})"
# What the policy should call that list when it tells an operator to add
# something to it. It knows the variable it reads; only dejima knows the
# configuration key an operator actually sets.
EGRESS_INTERNAL_OK_HINT='[core] internal_domains'
export EGRESS_FORGE_NAMES EGRESS_ALLOWED_NAMES EGRESS_INTERNAL_OK EGRESS_INTERNAL_OK_HINT
export EGRESS_FORGE_SSH="${ALLOW_GITHUB_PUSH:-0}"
# The published-ranges endpoint is rate-limited per source address when
# unauthenticated, across everything on the host - so a host starting sandboxes
# in a loop exhausts it and every launch after that fails on a credential that
# was available. Same read-only token `gh` already gets (docker-compose.yml),
# sent to the API it belongs to and nowhere else.
[ -n "${GH_TOKEN:-}" ] && export EGRESS_FORGE_META_AUTH="Authorization: Bearer $GH_TOKEN"

/usr/local/sbin/egress-policy apply

# Best-effort visibility on top of the enforcement above, not part of it -
# log-shipper.sh no-ops if LOKI_URL isn't set. It stays root, deliberately:
# what it ships is an oversight log of the session running beside it, and
# letting the sandbox user own the shipper would let a compromised session
# tamper with or kill its own logging. Root buys tamper-resistance that a
# security log needs.
#
# Root, and nothing else: it parses content the session's own traffic decides,
# and needs no capability to read two files its uid already opens or to POST
# them. So it keeps the uid that makes it untamperable and holds none of the
# rest.
#
# It outlives this script, and reparents to the container's init when this one
# exits - which is where a daemon watching a session belongs. Started from the
# entrypoint, it was a child of the very session process it exists to watch.
drop_caps -- -c 'exec "$@"' dejima /usr/local/bin/log-shipper.sh &
