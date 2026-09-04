#!/bin/bash
# PID 1 of the filter container: brings this launch's egress control up, says
# so, and then holds the network namespace open for the sandbox to join.
#
# The sandbox is a separate container that joins this namespace and declares no
# network capability of its own. Capabilities are per process, so it cannot
# alter the filter installed here even at uid 0 - which is the whole reason the
# two are separate. See docs/security.md.
#
# Nothing a session runs ever executes in here. This container holds the
# privilege; the one beside it holds the session.
set -Eeuo pipefail
trap 'status=$?; echo "ERROR: filter-entrypoint.sh aborted at line $LINENO (exit $status): $BASH_COMMAND" >&2' ERR

# shellcheck source=caps-lib.sh
source /usr/local/bin/caps-lib.sh
require_setpcap

/usr/local/bin/firewall-up.sh

# Written last, and only on the success path above - `set -e` means a firewall
# that failed to come up never reaches this line. bin/dejima waits for this
# file before it starts the sandbox, so the ordering that makes the arrangement
# fail-closed is a fact about the filesystem rather than about how long a
# launcher guessed the firewall would take.
#
# Under /run, which is a tmpfs: a container that is restarted rather than
# relaunched must not inherit a marker saying its filter is up before it is.
: > /run/dejima-firewall-ready
echo "filter: egress control is up; holding the namespace for the session"

# Held open by a process that does nothing else. The namespace lives as long as
# a process is in it, and this container is started with an init that forwards
# SIGTERM, so `docker stop` ends it promptly rather than waiting out a timeout.
exec sleep infinity
