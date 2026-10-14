#!/usr/bin/env bats
#
# Asserts on the RUNNER, not on this repository. Every other suite here tests
# dejima's code; this one tests the machine executing it, because the controls
# in docs/ci.md live in a runner's config.yaml and a host's firewall - set up
# by dejima-ci-hardener, on a machine this repository never touches, so no
# amount of reviewing this repository can check them.
#
# It exists because both failures that matter look exactly like success from
# inside a job. Nothing in a job's log mentions whether the Docker socket was
# mounted into it, and a job that can reach an off-list resolver still passes
# every check that only inspects DOCKER-USER. Neither shows up as a red run;
# they show up as nothing at all.
#
# DEJIMA_CI_TIER says which runner this is supposed to be, set by the workflow
# rather than sniffed, so landing on the wrong runner is a failure rather than
# a different set of assertions quietly being chosen. Unset means this is not
# a CI runner and there is nothing here to assert.
#
# Its values are the names of the jobs whose environment they verify -
# `confined` and `privileged` - rather than a separate vocabulary. Those are
# the same words the runner labels and dejima-ci-hardener's roles use, so a
# reader looking at a red `runner-env (privileged)` should not have to work out
# which job that corresponds to.

setup() {
    [ -n "${DEJIMA_CI_TIER:-}" ] || skip "not on a CI runner (DEJIMA_CI_TIER unset)"
    case "$DEJIMA_CI_TIER" in
        confined|privileged) ;;
        *) echo "unknown DEJIMA_CI_TIER: $DEJIMA_CI_TIER" >&2; return 1 ;;
    esac
}

# An off-list destination that would answer if it were reachable. This matters
# more than it looks: pointing these at an address that never answers - a
# documentation range, say - would pass in an environment with no network at
# all, which is the exact failure this suite exists to detect.
OFF_LIST_IP=1.1.1.1

# The positive control's destination. Overridable because it has to be a name
# THIS runner allows, and an allowlist is per-operator - hardcoding one would
# fail on a runner that is correctly configured for a different set.
ALLOWED_HOST=${DEJIMA_CI_ALLOWED_HOST:-deb.debian.org}

connects() {  # connects HOST PORT -> 0 if a TCP connection completes
    python3 - "$1" "$2" <<'PY'
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=6).close()
except OSError:
    sys.exit(1)
PY
}

# --- the grant that decides everything --------------------------------------

@test "the confined jobs are not handed the Docker daemon" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "asserted for the confined runner"
    # act_runner mounts /var/run/docker.sock into every job container unless
    # container.docker_host is "-". An unset value is the default, and the
    # default mounts - so this is the assertion that a runner was actually
    # configured rather than merely intended.
    [ ! -e /var/run/docker.sock ] || {
        echo "this runner grants job containers the Docker socket, which is" >&2
        echo "root-equivalent on the runner host. Set container.docker_host: \"-\"" >&2
        echo "in its config.yaml - see dejima-ci-hardener." >&2
        false
    }
}

@test "the privileged job does have the daemon it is scheduled for" {
    [ "$DEJIMA_CI_TIER" = privileged ] || skip "asserted for the privileged runner"
    # The positive control for the label routing. Without it, a privileged
    # job that landed on a hardened runner would fail later and obscurely, and
    # a confined job that landed on this one would be caught only by the test
    # above - one direction of a two-direction problem.
    [ -e /var/run/docker.sock ]
}

# The two directions above are each one job's answer: the confined runner must
# not have the docker socket and the privileged one must. That the two jobs land
# on DIFFERENT runners does not follow from either, and a suite cannot see it -
# it runs in one job. Comparing the two jobs' results is the workflow's to do.

# --- egress, for the tier the rules actually apply to ------------------------
#
# Deliberately scoped to the confined runner. The privileged job runs in the
# HOST network namespace - that is the grant they exist for - so the bridge
# rules dejima-ci-hardener installs do not sit in front of them at all. Their
# egress is the host's own, which this repository's examples do not define.
# Asserting an allowlist there would test nothing and pass anyway, which is
# the failure mode this whole suite is about.

@test "an allowlisted destination is reachable" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # The positive control for everything below. Without it, a runner with no
    # network at all passes every negative assertion in this file.
    run getent hosts "$ALLOWED_HOST"
    [ "$status" -eq 0 ] || {
        echo "$ALLOWED_HOST did not resolve, so the negative checks below" >&2
        echo "would pass for the wrong reason. Check the resolver and the" >&2
        echo "allowlist rendered from .dejima/allowed-domains on main - or set" >&2
        echo "DEJIMA_CI_ALLOWED_HOST to a name this runner does allow." >&2
        false
    }
    run connects "$ALLOWED_HOST" 80
    [ "$status" -eq 0 ]
}

@test "a name that is on no allowlist does not resolve" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # .invalid is reserved by RFC 2606 precisely so that it never resolves
    # anywhere - but here it has to be REFUSED by a resolver that answers for
    # allowlisted names, which the positive control above establishes.
    run getent hosts example.invalid
    [ "$status" -ne 0 ]
}

@test "a job cannot reach a resolver of its own choosing" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # The check most easily left out, and the one that decides whether the DNS
    # allowlist means anything: a job that can query any resolver it likes can
    # resolve anything it likes, whatever dnsmasq is configured with. Traffic
    # to the resolver on the bridge gateway is addressed to the host, so it is
    # an INPUT packet and never passes through DOCKER-USER - filtering only
    # DOCKER-USER leaves this open.
    run connects "$OFF_LIST_IP" 53
    [ "$status" -ne 0 ] || {
        echo "reached $OFF_LIST_IP:53, so this job can use any resolver it likes and" >&2
        echo "the DNS allowlist is decorative. The INPUT rules are missing -" >&2
        echo "re-run dejima-ci-firewall on the runner host." >&2
        false
    }
}

@test "a destination that is on no allowlist is unreachable" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # An IP literal rather than a name, so this tests the firewall rather than
    # the resolver. Reaching it by name would fail at DNS first and prove
    # nothing about DOCKER-USER.
    run connects "$OFF_LIST_IP" 443
    [ "$status" -ne 0 ] || {
        echo "reached $OFF_LIST_IP:443, so this job has unrestricted egress." >&2
        echo "" >&2
        echo "If the DNS checks above passed, the resolver is fine and the packet" >&2
        echo "filter is not - which usually means DOCKER-USER is empty. Docker" >&2
        echo "recreates its own chains on every daemon start, so a 'systemctl" >&2
        echo "restart docker' drops these rules and nothing looks different" >&2
        echo "afterwards. Check with: iptables -S DOCKER-USER" >&2
        echo "" >&2
        echo "dejima-ci-hardener's dejima-ci-firewall.service reapplies them on" >&2
        echo "every Docker start, which is the fix rather than a one-off re-run." >&2
        false
    }
}

@test "IPv6 egress is not an unfiltered way around all of the above" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # An address family with no allowlist is not a smaller hole than the one
    # the rules above close; on a runner with IPv6 egress it is the same hole.
    #
    # Unlike the checks above, this one passes for two different reasons - v6
    # rejected, or v6 never configured - and both are acceptable outcomes, so
    # it is not given a positive control. What it rules out is the third case:
    # a runner with working IPv6 egress and rules written only for v4.
    run connects 2606:4700:4700::1111 443
    [ "$status" -ne 0 ]
}
