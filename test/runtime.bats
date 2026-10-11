#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Behavioral checks against a live container running the real entrypoint.sh
# (SANDBOX_TEST_MODE=1 - see entrypoint.sh - runs the actual DNS
# proxy/firewall/logging setup, then execs `sleep infinity` as node instead
# of nvim so the suite can attach). One container is shared across the whole
# file (setup_file/teardown_file, not setup/teardown) since spinning up a
# fresh one per test would make this suite too slow to actually get run.
#
# Needs Docker. Set SKIP_BUILD=1 to reuse whatever dejima:latest is
# already built, for fast iteration - the default is to always rebuild, so a
# stale image can't produce a false pass.
#
# Safety: every packet-filter mutation below happens inside the
# test container's own network namespace (no --network host, no bind mounts
# of host paths) - none of it touches the host's real firewall state, same
# as any other container. Container/network names are derived from
# BATS_RUN_TMPDIR, whose basename is the `bats-run-XXXXXX` bats makes once per
# run: unique across runs, and stable across setup_file, every test, and
# teardown_file. Both properties are needed and they pull in opposite
# directions, so neither obvious shortcut works.
#
# Not $$: bats reruns this file's top-level code in a fresh subshell per test,
# so $$ is a *different* value in every test, setup_file and teardown_file,
# silently pointing each at containers that do not match.
#
# Not BATS_FILE_TMPDIR either, which is what this used to say. Its PATH is
# unique, but its basename is the file's index within the run - `0` for the
# only file here, in every run there has ever been. So the names were the
# constants `dejima-test-0` and `dejima-test-net-0`, and the collision this
# comment promised could never happen was in fact guaranteed: a run whose
# teardown did not complete left a network of that name with a container still
# attached, `docker network rm` could not remove it, and the next run died in
# setup_file on `network with name dejima-test-net-0 already exists`.
#
# The `dejima-test-` prefix is this suite's own namespace. Nothing else may use
# it, which is what makes the reclaim in setup_file safe.

# The cap_add list from the compose file, one per line. A minimal reader for
# one known block rather than a YAML parser: the alternative is this suite
# hardcoding a second copy of the capability floor and the two disagreeing
# silently, which is exactly the failure the floor exists to prevent.
compose_cap_add() {
    awk '
        /^    cap_add:/      { in_block = 1; next }
        in_block && /^      - / { sub(/^      - /, ""); print; next }
        in_block && !/^      / { in_block = 0 }
    ' "$BATS_TEST_DIRNAME/../docker/docker-compose.yml"
}

# localhost/ for the same reason bin/dejima uses it: a bare name is a Docker
# Hub name to anything that pushes, and nothing built here is meant to leave
# the host (#53).
IMAGE=localhost/dejima:latest

# What a session actually runs: the base image plus the selected harness's own
# layer, built in setup_file. Exported there because bats re-runs this file's
# top-level code in a fresh process per test, so a plain assignment would not
# survive - and re-defaulted here for the same reason, since the export has to
# win over the line that re-runs.
SESSION_IMAGE="${SESSION_IMAGE:-$IMAGE}"

# How old a leftover network of this suite's must be before setup_file will
# reap it along with whatever is still attached. Hours, not minutes: the only
# thing it has to be longer than is a real run of this file, and the only
# thing it has to be shorter than is an operator's patience with a runner
# filling up with dead containers.
REAP_AFTER=$((6 * 60 * 60))

container_name() { echo "dejima-test-$(basename "$BATS_RUN_TMPDIR")"; }
# The file-wide container's filter. teardown_file removes it by name, like
# the session container beside it - teardown's pattern deliberately skips
# both, since they have to survive every test in the file.
filter_name() { echo "dejima-test-filter-$(basename "$BATS_RUN_TMPDIR")"; }
network_name() { echo "dejima-test-net-$(basename "$BATS_RUN_TMPDIR")"; }

# A container for ONE test, named the same way and for the same reasons: a
# leftover from a run that died mid-test must not be adoptable - or, worse,
# collide with - the next run's. `docker run` refuses a name in use, so a
# constant one turns any failed run into a failing run afterwards, on a
# long-lived runner, until someone clears it by hand.
test_container_name() { echo "dejima-test-$1-$(basename "$BATS_RUN_TMPDIR")"; }

# The Anthropic arrangement, in one place.
#
# dejima-credential-proxy defaults none of this any more (#171): which upstream,
# which credential kind, which header and what shape are all the caller's to
# state, because a default is one backend's arrangement wearing every
# backend's name. Three copies of the same eight flags in this file would be
# three places for them to drift from what bin/dejima actually launches, so
# there is one - and static.bats pins that bin/dejima still passes the same set.
#
# Sets PROXY_PID, which every caller's teardown already kills.
start_credential_proxy() {  # <socket> <credentials> <upstream> <oauth-endpoint>
    "$BATS_TEST_DIRNAME/../bin/dejima-credential-proxy" \
        --socket "$1" --credentials "$2" --upstream "$3" \
        --credential-kind anthropic-oauth \
        --oauth-endpoint "$4" \
        --oauth-client-id "9d1c250a-e61b-44d9-88ed-5944d1962f5e" \
        --auth-header Authorization \
        --auth-format "Bearer {token}" \
        --strip-header x-api-key \
        --ensure-header "anthropic-beta=oauth-2025-04-20" &
    PROXY_PID=$!
}

# Every container here must go on network_name(), never the default bridge:
# the restricted resolver forwards to Docker's embedded resolver at
# 127.0.0.11, which only exists on a user-defined network. On the default
# bridge it has nowhere to forward and startup dies in egress-policy.
#
# Readiness is the FINAL `sleep infinity` (entrypoint.sh's SANDBOX_TEST_MODE
# exec), matched exactly. A bare `pgrep -x sleep` also matches the startup
# sequence's own short sleeps, and proceeding on one of those asserts against
# a container with no firewall yet - turning egress assertions into vacuous
# passes, since everything is still reachable.
#
# 120s rather than 60: the forge ranges fetch retries, and losing two
# attempts costs ~26s (#59), which on a runner that just spent minutes
# unpacking an image turns a recovery into a spurious failure. A longer
# budget only delays reporting a stuck startup; nothing here passes on a
# timeout.
# `docker wait` returns on exit, but the json-file log driver writes
# asynchronously, so reading right then can return a log that stops
# mid-stream. That presented as a container "aborting" partway through
# the egress policy's name sweep at a different name each run, and survived
# three fixes before the giveaway: no message from an ERR trap that cannot be
# bypassed. Nothing had aborted; the read was short.
#
# Two identical consecutive reads means the driver has caught up.
# Content-neutral on purpose - waiting for an expected string would pass or
# fail on the very thing the caller is about to assert.
settled_logs() {
    local container="$1" current previous=""
    for _ in $(seq 1 20); do
        current=$(docker logs "$container" 2>&1)
        if [ -n "$current" ] && [ "$current" = "$previous" ]; then
            break
        fi
        previous="$current"
        sleep 0.25
    done
    printf '%s' "$current"
}

wait_ready() {
    local container="$1"
    for _ in $(seq 1 120); do
        if docker exec "$container" pgrep -x -f 'sleep infinity' >/dev/null 2>&1; then
            return 0
        fi
        # A container that has already exited is never going to become ready,
        # and polling it for the full two minutes turns a startup failure - an
        # aborted entrypoint, say - into a wait long enough to read as a hang.
        # The reason is in its logs, which are printed either way; this only
        # decides how long it takes to see them.
        if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = false ]; then
            echo "container $container exited during startup - log:" >&2
            settled_logs "$container" >&2
            return 1
        fi
        sleep 1
    done
    echo "container $container never reached the post-entrypoint sleep - startup log:" >&2
    settled_logs "$container" >&2
    return 1
}

# $IMAGE is a single mutable tag on a shared daemon, and SKIP_BUILD=1 - which
# CI sets, having built the image in an earlier step - means this file does not
# build it either. Nothing in that arrangement ties the image to the checkout,
# and when the two disagree every assertion in this file is being made against
# code that is not under test.
#
# That is not a theoretical worry. It cost six CI rounds: a container kept
# stopping partway through the egress policy, and the fixes that were supposed
# to make it explain itself - an ERR trap, a resolver that reports on every
# path - produced no output at all, because the script running in the container
# was not the script in the commit. A stale image looks exactly like a bug in
# the code you are reading, which is the worst way for it to present.
#
# One container start, three files, compared by content rather than by any
# claim about how the image was produced.
# One value from the selected harness's manifest. bin/dejima resolves these
# and passes them into the container; a container started here has to do the
# same or it is testing an arrangement that never occurs.
# BATS_TEST_DIRNAME, not $SANDBOX_DIR: bats runs each test in its own process
# and does not carry setup_file's plain assignments into it, so a fixture
# variable is set here and empty in every test body. This is called from both.
# The symptom is not an error but an empty value - which, for the proxied
# domain, means a container that refuses to start because the harness appears
# to have declared no endpoint.
harness_manifest_value() {
    sed -n "s/^$1 *= *//p" "$BATS_TEST_DIRNAME/../harnesses/claude-code/harness.conf"
}

# The same, for the selected model backend. proxied_domain lives off the
# harness manifest onto this one (#171): a harness reaches whichever endpoint
# it is configured for, so the name the terminator answers for belongs to the
# endpoint rather than to the program talking to it.
backend_manifest_value() {
    sed -n "s/^$1 *= *//p" "$BATS_TEST_DIRNAME/../backends/anthropic/backend.conf"
}

# The selected harness's image layer, on top of $1, tagged for this run so
# teardown_file's sweep finds it. Prints the new tag.
build_harness_layer() {
    local base="$1" tag df ctx
    tag="localhost/dejima-test-harness:$(basename "$BATS_RUN_TMPDIR")"
    df="$(mktemp)"
    # An empty build context, for the reason bin/dejima uses one: a build
    # whose context is a directory anything else can write is a way into the
    # image it then runs.
    ctx="$(mktemp -d)"
    # shellcheck source=../bin/dejima-project-lib.sh
    source "$BATS_TEST_DIRNAME/../bin/dejima-project-lib.sh"
    generate_spec_dockerfile "$base" "" \
        "$(manifest_get harness claude-code image_dirs)" \
        "$(manifest_get harness claude-code image_env)" \
        "$(manifest_get harness claude-code image_files)" > "$df"
    if ! docker build -q -t "$tag" -f "$df" "$ctx" >&2; then
        rm -rf "$df" "$ctx"
        echo "could not build the harness layer this suite runs on" >&2
        return 1
    fi
    rm -rf "$df" "$ctx"
    printf '%s' "$tag"
}

assert_image_matches_checkout() {
    local expected actual
    expected=$(cd "$BATS_TEST_DIRNAME/../docker" && md5sum egress-policy firewall-up.sh entrypoint.sh | awk '{print $1}')
    # egress-policy is installed into sbin, the other two into bin, so the
    # paths are given in full rather than cd-ed to.
    actual=$(docker run --rm --entrypoint sh "$IMAGE" -c \
        'md5sum /usr/local/sbin/egress-policy /usr/local/bin/firewall-up.sh /usr/local/bin/entrypoint.sh' 2>&1 | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo "The image tagged $IMAGE was not built from this checkout." >&2
        echo >&2
        echo "checkout (docker/):  $(echo "$expected" | tr '\n' ' ')" >&2
        echo "image:               $(echo "$actual" | tr '\n' ' ')" >&2
        echo >&2
        echo "Every test in this file would be asserting against different code than" >&2
        echo "the one in the working tree, so they are not run. Rebuild it:" >&2
        echo >&2
        echo "  docker build -t $IMAGE -f docker/Dockerfile ." >&2
        echo >&2
        echo "In CI this means the build step and the test step disagreed - most" >&2
        echo "likely another job retagged $IMAGE in between, since the tag is shared" >&2
        echo "and carries no version." >&2
        return 1
    fi
}

setup_file() {
    # These two are setup_file's own. bats runs every test in a separate
    # process and does not carry a plain assignment here into it, so anything
    # a test body can reach - directly, or through a helper it calls - has to
    # derive its own paths from BATS_TEST_DIRNAME, which bats exports. A
    # helper that read one of these was set in the fixture and empty in every
    # test, which is not an error, just a wrong answer.
    SANDBOX_DIR="$BATS_TEST_DIRNAME/../docker"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    local container network
    container=$(container_name)
    network=$(network_name)

    if [ "${SKIP_BUILD:-0}" != "1" ]; then
        docker build -q -t "$IMAGE" -f "$SANDBOX_DIR/Dockerfile" "$REPO_ROOT" >&2
    fi
    assert_image_matches_checkout

    # What a session runs is the base image plus its harness's own layer: the
    # directories that harness keeps state in, the files it needs seeded, its
    # environment. Several assertions in this file are about exactly that - a
    # staged statusline landing in a ~/.claude the session can unlink inside,
    # an empty credentials file it can read - and booting the base image alone
    # tests an image no session is ever given.
    #
    # Built through bin/dejima's own generator, from the manifest, so this
    # fixture cannot drift from what a real launch produces. The harness's
    # PACKAGE is deliberately left out: nothing here runs the harness binary,
    # and an npm install would put a network fetch on the critical path of
    # every run of this file. A test that does run it needs the install spec
    # passed here too.
    # Assigned before export: `export VAR="$(cmd)"` returns the export's
    # status, so a failed build would leave this empty, the default at the top
    # of the file would quietly substitute the base image, and the suite would
    # test an image no session runs while blaming the tests.
    local session_image
    session_image="$(build_harness_layer "$IMAGE")" || {
        echo "could not build the harness layer - see above" >&2
        return 1
    }
    [ -n "$session_image" ] || { echo "the harness layer built to an empty tag" >&2; return 1; }
    export SESSION_IMAGE="$session_image"

    docker rm -f "$container" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true

    # A run killed between `network create` and teardown_file leaves its
    # network behind with its container still attached, and an attached
    # network cannot be removed - so the `|| true` above passes over it. Names
    # are unique per run, so that no longer blocks the next run the way the
    # old constant names did; it accumulates instead, one dead container and
    # network per killed run, on a long-lived privileged runner.
    #
    # So this reaps them, scoped to this suite's own `dejima-test-net-` prefix
    # and to networks older than REAP_AFTER. An unattached one goes on sight.
    # An attached one is only ever this suite's own leftovers, but a live run
    # elsewhere on the host has one too, and there is no way to tell "abandoned"
    # from "in use" by inspection - so age is the discriminator, set far longer
    # than any run of this suite takes. A concurrent run's network is minutes
    # old and is never touched.
    # Every name here is _-prefixed and used nowhere else in this file. The
    # loop variables of a sweep must not be the plain nouns the rest of
    # setup_file uses: `while read -r container` would leave $container
    # holding the last endpoint it saw, and every `docker run --name
    # "$container"` below would then use that instead - a failure that only
    # appears once there is something to reap, which is to say only when this
    # code matters.
    local _stale _age _endpoint _dead _created
    while IFS= read -r _stale; do
        [ -n "$_stale" ] || continue
        [ "$_stale" != "$network" ] || continue
        docker network rm "$_stale" >/dev/null 2>&1 && continue
        # Still attached. Reap only if it is old enough to be abandoned.
        _age="$(docker network inspect -f '{{.Created}}' "$_stale" 2>/dev/null)" || continue
        _age="$(date -d "$_age" +%s 2>/dev/null)" || continue
        [ "$(( $(date +%s) - _age ))" -gt "$REAP_AFTER" ] || continue
        while IFS= read -r _endpoint; do
            [ -n "$_endpoint" ] || continue
            docker rm -f "$_endpoint" >/dev/null 2>&1 || true
            # An endpoint can outlive the container that owned it, which is
            # what an unclean daemon stop - a host reboot, most often - leaves
            # behind: nothing is running, `network rm` still reports active
            # endpoints, and removing containers does not help. Forcing the
            # disconnect is the way out of that state.
            docker network disconnect -f "$_stale" "$_endpoint" >/dev/null 2>&1 || true
        done < <(docker network inspect -f '{{range .Containers}}{{.Name}}
{{end}}' "$_stale" 2>/dev/null)
        docker network rm "$_stale" >/dev/null 2>&1 || true
    done < <(docker network ls --filter name=^dejima-test-net- --format '{{.Name}}' 2>/dev/null)

    # And this suite's own containers, which the loop above only reaches while
    # they are still attached to a network it is reclaiming. A reboot stops
    # them and releases their endpoints, so the network goes on sight and the
    # containers are never seen again - accumulating for the life of the host.
    #
    # Same age guard. A stopped container of this suite's is already strong
    # evidence of abandonment, since every one it starts is `docker run -d`
    # and running, but the guard costs nothing and keeps one rule here.
    while IFS= read -r _dead; do
        [ -n "$_dead" ] || continue
        [ "$_dead" != "$container" ] || continue
        _created="$(docker inspect -f '{{.Created}}' "$_dead" 2>/dev/null)" || continue
        _created="$(date -d "$_created" +%s 2>/dev/null)" || continue
        [ "$(( $(date +%s) - _created ))" -gt "$REAP_AFTER" ] || continue
        docker rm -f "$_dead" >/dev/null 2>&1 || true
    done < <(docker ps -a --filter name=^dejima-test- --filter status=exited \
                 --filter status=created --format '{{.Names}}' 2>/dev/null)

    # And the images this suite builds - harness, override, derived - which
    # nothing reaps across runs (#26). The per-test teardown removes only the
    # CURRENT run's suffix, so an abandoned run's images have no reaper at all.
    # They hold no subnet, so this is disk rather than the network's kind of
    # harm; it is also the largest thing here by disk, since each is built
    # FROM the session image.
    #
    # Same age guard as above, for the same reason: a concurrent run's images
    # are minutes old. The prefix is checked again on the name rather than
    # trusted to the CLI filter, so the reap can only ever reach this suite's
    # own namespace.
    local _img _born _suffix
    _suffix="$(basename "$BATS_RUN_TMPDIR")"
    while IFS= read -r _img; do
        [ -n "$_img" ] || continue
        # Both spellings, because the images this suite builds were renamed to
        # localhost/ (#53) after this reap was written against the bare form,
        # and for two releases it therefore matched nothing. A reap whose
        # pattern stops matching is not a reap that fails - it is one that
        # silently does nothing, which is indistinguishable from having
        # nothing to do, so nothing anywhere reported it.
        #
        # Matching both is also what stops the next rename doing it again.
        case "$_img" in dejima-test-*|localhost/dejima-test-*) ;; *) continue ;; esac
        case "$_img" in *":$_suffix") continue ;; esac
        _born="$(docker image inspect -f '{{.Created}}' "$_img" 2>/dev/null)" || continue
        _born="$(date -d "$_born" +%s 2>/dev/null)" || continue
        [ "$(( $(date +%s) - _born ))" -gt "$REAP_AFTER" ] || continue
        docker rmi -f "$_img" >/dev/null 2>&1 || true
    done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)

    docker network create "$network" >/dev/null

    # No DEJIMA_FORGE_HOSTS/LOKI_URL: this suite only asserts the default
    # allowlist and enforcement, which shouldn't depend on either.
    #
    # GH_TOKEN is forwarded rather than dropped, and every container start in
    # this file does the same. It doesn't change the allowlist - it only
    # authenticates the api.github.com/meta fetch, which returns the same
    # ranges either way. What it changes is the quota: that endpoint allows 60
    # requests an hour per source IP unauthenticated, and this file starts
    # sixteen containers, so two runs in an hour exhaust it and every container
    # after that dies in the egress policy with a rate limit error rather than
    # anything to do with what was being tested.
    # Locally it's usually unset and expands empty, which the policy and the
    # entrypoint treat exactly as absent - so the no-token path stays the
    # default here and only CI, where the volume is, passes a real one.
    # The harness's own domains, which bin/dejima resolves from the manifest
    # and passes in - the image no longer names any harness's endpoints, so a
    # container started without these gets none of them. Read from the
    # manifest rather than written here, so this fixture cannot drift from
    # what a real launch supplies.
    # The capability posture of both halves comes from the code that declares
    # each, never from a copy here - see start_pair.
    start_pair "" "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e ANTHROPIC_BASE_URL= \
        -e ANTHROPIC_AUTH_TOKEN= \
        -e SANDBOX_HARNESS_DOMAINS="$(harness_manifest_value api_domains)" \
        -e SANDBOX_BACKEND_PROXIED_DOMAIN="$(backend_manifest_value proxied_domain)"
}

teardown_file() {
    # Session first: it is the one joined to the other's network namespace, and
    # taking the holder away from under it is the arrangement bin/dejima orders
    # deliberately rather than incidentally.
    docker rm -f "$(container_name)" >/dev/null 2>&1 || true
    docker rm -f "$(filter_name)" >/dev/null 2>&1 || true
    docker network rm "$(network_name)" >/dev/null 2>&1 || true
}

teardown() {
    # Host listeners started by start_host_listener (unset for every other
    # test - each test re-sources this file in its own shell, so nothing
    # leaks in from the previous one). Killing them here rather than at the
    # end of the test body is what makes the teardown unconditional: bats
    # runs test bodies under errexit, so any failed assertion abandons the
    # rest of the body, and a kill sitting there would leave a python
    # process holding a port on the operator's host. teardown runs in the
    # same shell as the body even after the body aborted, so the PIDs it
    # set are visible here. An EXIT trap in the body is not the
    # alternative - it replaces the one bats installs and the run dies
    # reporting zero executed tests.
    local pid
    for pid in ${HOST_LISTENER_PIDS:-}; do kill "$pid" 2>/dev/null || true; done
    # Every PER-TEST container and image this run made, found by the run's own
    # suffix rather than enumerated. The list here was twenty lines that had to
    # be kept in step with twenty test bodies by hand, and it silently stopped
    # matching any of them the moment the names changed - which is the shape of
    # leak that fills a long-lived runner and then fails the next run on a name
    # conflict.
    #
    # The file-wide container is excluded by name, not by luck: this runs after
    # EVERY test, and it is the one container that has to survive all of them.
    # test_container_name() puts a purpose between the prefix and the suffix,
    # so the file-wide name is the only one with nothing there.
    local suffix keep keep_filter
    suffix="$(basename "$BATS_RUN_TMPDIR")"
    keep="$(container_name)"
    # And its filter, which is named to end in the same suffix so that every
    # PER-TEST filter is swept by the pattern below. That makes the file-wide
    # one match too, and removing it after the first test would take the
    # network namespace out from under the container every later test uses.
    keep_filter="$(filter_name)"
    local c
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [ "$c" != "$keep" ] || continue
        [ "$c" != "$keep_filter" ] || continue
        docker rm -f "$c" >/dev/null 2>&1 || true
    done < <(docker ps -a --filter "name=^dejima-test-.*$suffix\$" \
                 --format '{{.Names}}' 2>/dev/null)
    docker images -q "localhost/dejima-test-*:$suffix" 2>/dev/null \
        | xargs -r docker rmi -f >/dev/null 2>&1 || true
    # Volumes too, for the same reason and in the same namespace: a test that
    # makes one removes it itself, and this is what covers the run that was
    # interrupted between the two.
    docker volume ls -q --filter "name=^dejima-test-.*$suffix\$" 2>/dev/null \
        | xargs -r docker volume rm >/dev/null 2>&1 || true
}

# The capability list bin/dejima gives the filter container, read out of the
# launcher for the same reason compose_cap_add reads the session's out of the
# compose file: a copy here would drift, and the whole point is that what the
# suite starts is what a launch starts.
launcher_filter_cap_add() {
    sed -n '/^docker run -d --init \\$/,/^    "\${SANDBOX_IMAGE_REPO}/p' \
        "$BATS_TEST_DIRNAME/../bin/dejima" \
        | grep -oE '\-\-cap-add [A-Z_]+' | awk '{print $2}'
}

# The pair a launch actually starts: a filter container that owns the network
# namespace and brings the egress control up, and a session container that
# joins it. Every fixture in this file has to build the same thing, because a
# session container on its own has no firewall at all - bringing one up is the
# filter container's job, and the session declares nothing it would take.
#
# The environment goes to BOTH, which is deliberately not what bin/dejima does
# (it hands the filter container a curated list). Here it is the right choice:
# a fixture that varies ALLOW_GITHUB_PUSH or a forge host is varying what the
# FIREWALL does, and making twenty-odd call sites each declare which half their
# variables belong to would be twenty-odd chances to send one to the wrong
# container - which fails by passing, since a firewall told nothing simply
# allowlists less.
#
# Both capability floors come from the code that declares them, neither from a
# list here.
start_pair() {  # <purpose|""> <image> [docker run args...]
    local purpose="$1" image="$2"; shift 2
    local session filter
    if [ -z "$purpose" ]; then
        session="$(container_name)"
        filter="$(filter_name)"
    else
        session="$(test_container_name "$purpose")"
        # The suffix stays last so `teardown`'s name filter, which is anchored
        # on it, removes these too. A leaked filter container holds a network
        # namespace open and the next run collides with its name.
        filter="$(test_container_name "$purpose-filter")"
    fi

    # The run's cached GitHub ranges, when the job fetched them. Each filter
    # fetched its own, which is twenty-seven requests in about five minutes
    # across this suite - inside the hourly ceiling a token buys, and exactly
    # the burst GitHub's secondary limit answers with a 403 (#357).
    #
    # Read-only, and only ever this one file. egress-policy refuses a file://
    # source unless SANDBOX_TEST_MODE is set, which start_pair's callers supply
    # and no launch does.
    #
    # Absent when the job could not fetch, or when the suite is run by hand
    # outside CI: every container then fetches for itself, which is the
    # behaviour this replaces rather than a failure.
    local -a meta=()
    if [ -r /tmp/dejima-ci/github-meta.json ]; then
        meta=(-v /tmp/dejima-ci/github-meta.json:/run/forge-meta-cache.json:ro
              -e EGRESS_FORGE_META_URL=file:///run/forge-meta-cache.json
              -e SANDBOX_TEST_MODE=1)
    fi

    local -a fcaps=() scaps=()
    while IFS= read -r cap; do fcaps+=(--cap-add="$cap"); done < <(launcher_filter_cap_add)
    while IFS= read -r cap; do scaps+=(--cap-add="$cap"); done < <(compose_cap_add)
    [ "${#fcaps[@]}" -gt 0 ] || { echo "no --cap-add found in bin/dejima's filter run" >&2; return 1; }
    [ "${#scaps[@]}" -gt 0 ] || { echo "no cap_add found in docker-compose.yml" >&2; return 1; }

    # The cache goes to the FILTER only: it is the half that fetches the ranges,
    # and the session container has no business holding a path that names them.
    docker run -d --init --name "$filter" \
        --cap-drop=ALL "${fcaps[@]}" \
        --security-opt=no-new-privileges:true \
        --sysctl net.ipv4.ip_unprivileged_port_start=0 \
        --network "$(network_name)" \
        ${meta[@]+"${meta[@]}"} \
        "$@" \
        --entrypoint /usr/local/bin/filter-entrypoint.sh \
        "$image" >/dev/null
    wait_filter "$filter" || return 1

    # --init, because docker-compose.yml sets `init: true` and the difference
    # is not cosmetic: it makes PID 1 an init that forwards signals to the
    # session rather than the session itself. Every fixture here ran without
    # one, so nothing in this suite had a tini to fail - which is how a floor
    # that left tini unable to signal its own child shipped green.
    docker run -d --init --name "$session" \
        --cap-drop=ALL "${scaps[@]}" \
        --security-opt=no-new-privileges:true \
        --network "container:$filter" \
        "$@" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$image" >/dev/null
    wait_ready "$session"
}

# The filter container is up when it says its egress control is, which is the
# same marker bin/dejima waits for rather than a second opinion about it.
wait_filter() {
    local container="$1"
    for _ in $(seq 1 120); do
        if docker exec "$container" test -f /run/dejima-firewall-ready 2>/dev/null; then
            return 0
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = false ]; then
            echo "filter container $container exited during startup - log:" >&2
            settled_logs "$container" >&2
            return 1
        fi
        sleep 1
    done
    echo "filter container $container never reported its firewall up - log:" >&2
    settled_logs "$container" >&2
    return 1
}

dexec() {
    docker exec "$(container_name)" "$@"
}

# Into the container the egress control is in. nft, dnsmasq and
# ulogd2 all live there, so a check about any of them aimed at the session
# container asks the wrong process - and fails rather than passes, which is
# the better direction but still the wrong question.
dexec_filter() {
    docker exec "$(filter_name)" "$@"
}

dexec_node() {
    docker exec -u node "$(container_name)" "$@"
}

# The session process itself, found by what it is rather than by being PID 1.
#
# The entrypoint execs it, so here it IS PID 1 - but only because these
# containers are started with a bare `docker run`. docker-compose.yml sets
# `init: true`, so in a real launch PID 1 is the init that reaps for the
# session and the session is its child, holding different credentials and a
# different capability set. A capability assertion read from PID 1 would be
# about one process in this suite and another in production, and the one it
# would miss is the one that matters.
#
# `sleep infinity` is entrypoint.sh's SANDBOX_TEST_MODE exec, matched the way
# wait_ready matches it.
session_pid() {  # [container], defaulting to the file-wide one
    docker exec "${1:-$(container_name)}" pgrep -x -f 'sleep infinity' 2>/dev/null | head -1
}

@test "the container's user actually matches overridden SANDBOX_USER/UID/GID/HOME build args, not just the defaults" {
    local test_image="localhost/dejima-test-override:$(basename "$BATS_RUN_TMPDIR")"
    local test_container="$(test_container_name override)"
    local sandbox_dir="$BATS_TEST_DIRNAME/../docker"
    local repo_root="$BATS_TEST_DIRNAME/.."

    docker build -q -t "$test_image" \
        --build-arg SANDBOX_USER=testuser \
        --build-arg SANDBOX_UID=1234 \
        --build-arg SANDBOX_GID=1234 \
        --build-arg SANDBOX_HOME=/home/testuser \
        -f "$sandbox_dir/Dockerfile" "$repo_root" >&2

    start_pair override "$test_image" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}"

    run docker exec -u testuser "$test_container" whoami
    [ "$status" -eq 0 ]
    [ "$output" = "testuser" ]

    run docker exec -u testuser "$test_container" printenv HOME
    [ "$status" -eq 0 ]
    [ "$output" = "/home/testuser" ]

    run docker exec -u testuser "$test_container" id -u
    [ "$output" = "1234" ]
}

@test "a dedicated SANDBOX_SSH_KEY loads into its own in-container agent with no forwarded socket at all" {
    local key_dir test_container
    key_dir="$BATS_TEST_TMPDIR"
    ssh-keygen -t ed25519 -N '' -f "$key_dir/testkey" >/dev/null

    test_container="$(test_container_name sshkey)"
    start_pair sshkey "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -v "$key_dir/testkey:/root/.ssh-sandbox-key-src:ro"

    # A fresh `docker exec` is a sibling of the session, not a descendant of
    # the exec chain entrypoint.sh set SSH_AUTH_SOCK in, so it doesn't inherit
    # that export the way a real session's nvim/terminal children would (nvim
    # itself *is* that same process, continued via exec, not a separate one) -
    # read the value back out of the SESSION's environment instead of assuming
    # docker exec sees it.
    #
    # The session's, specifically, and not PID 1's. Under `init: true` PID 1 is
    # the init, and this variable is not one Docker passed in: entrypoint.sh
    # creates it, by starting an agent, in a process that is tini's CHILD. So
    # PID 1 is the one process in the container that has never heard of it.
    run docker exec -u node "$test_container" sh -c "
        export SSH_AUTH_SOCK=\$(cat /proc/$(session_pid "$test_container")/environ | tr '\0' '\n' | grep ^SSH_AUTH_SOCK= | cut -d= -f2-)
        ssh-add -l
    "
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run docker exec -u node "$test_container" test -e /home/node/.ssh/sandbox-key
    [ "$status" -ne 0 ]

    # The regression this guards against: /root/.ssh-sandbox-key-src is the
    # bind-mounted original, still present for the container's whole life
    # (unlike the deleted copy above, this can't be rm'd from inside). If
    # it were reachable by the sandbox user, that user's uid matching the
    # host's (see Dockerfile) would make the raw key directly readable,
    # defeating the point of only ever exposing it via the agent socket.
    run docker exec -u node "$test_container" cat /root/.ssh-sandbox-key-src
    [ "$status" -ne 0 ]
}

@test "~/.claude.json mount is a discarded per-session copy - a write inside the container never reaches the host source it was seeded from" {
    # In the real bin/dejima flow, the file mounted at
    # ~/.claude.json is always a *generated* per-session copy (see
    # SANDBOX_CLAUDE_JSON_FILE in bin/dejima), never the real
    # ~/.claude.json - so nothing written to it in the container, including
    # Claude Code's own atomic write-temp-then-rename on startup, can ever
    # reach the real file. host_copy here stands in for that real file: it's
    # seeded with the same content as the mounted file but never mounted
    # itself, so it can only change if something actually writes back to the
    # real source - which must not happen.
    local test_container="$(test_container_name claudejson)"
    local mounted_copy="$BATS_TEST_TMPDIR/claude.json"
    local host_copy="$BATS_TEST_TMPDIR/claude-json-original.json"

    echo '{"marker": "test-value"}' > "$mounted_copy"
    chmod 666 "$mounted_copy"
    cp "$mounted_copy" "$host_copy"

    start_pair claudejson "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -v "$mounted_copy:/home/node/.claude.json"

    # Simulate the write Claude Code itself does against this path at
    # startup (before login even completes - see docker-compose.yml's
    # comment on this mount).
    run docker exec -u node "$test_container" sh -c 'echo "{\"marker\": \"changed-by-container\"}" > $HOME/.claude.json'
    [ "$status" -eq 0 ]

    run docker exec -u node "$test_container" cat /home/node/.claude.json
    [[ "$output" == *"changed-by-container"* ]]

    run cat "$host_copy"
    [[ "$output" == *"test-value"* ]]
    [[ "$output" != *"changed-by-container"* ]]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
}



@test "IPv6 is refused outright, not allow-listed alongside IPv4" {
    # The property, stated as the absence of a permit path rather than as a
    # connection that fails. A connection to a v6 address fails identically on
    # a host with no v6 route at all, so a probe alone passes whether the
    # family is refused or merely absent - and inferring the second from the
    # first is the bug the firewall this replaced spent two rounds on.
    run dexec_filter nft list chain inet egress_policy egress
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"policy drop"* ]] \
        || { echo "the egress chain does not default to drop: $output"; return 1; }

    # The refusal is there, and it is the first rule - below the established or
    # loopback passes it would be a rule a v6 packet can get past, since
    # loopback carries ::1 and a flow permitted once stays permitted.
    local first
    first=$(grep -vE '^\s*(table|chain|\}|#|type filter hook|$)' <<< "$output" | head -1)
    [[ "$first" == *"meta nfproto ipv6"* ]] \
        || { echo "the first rule is not the v6 refusal: $first"; return 1; }

    # And nothing else in the chain names a v6 destination. That is what the
    # regression looked like: not the refusal missing, but permit rules beside
    # it - this test used to REQUIRE those rules and so asserted the
    # regression.
    local permits
    permits=$(grep 'ip6 ' <<< "$output" | grep -v 'nfproto ipv6' || true)
    [ -z "$permits" ] \
        || { echo "the chain allow-lists IPv6 destinations:"; echo "$permits"; return 1; }

    # Inbound too, where the refusal is a drop rather than a reject.
    run dexec_filter nft list chain inet egress_policy inbound
    [ "$status" -eq 0 ]
    [[ "$output" == *"meta nfproto ipv6"* ]] \
        || { echo "inbound does not refuse v6: $output"; return 1; }
}




@test "the resolver hands out no AAAA, so a permitted name cannot produce a v6 address" {
    # The second layer, and the one that decides what a client even tries. With
    # the filter refusing v6 and the resolver still answering AAAA, a permitted
    # name would cost every client a connection attempt to an address that can
    # never work - which presents as a slow destination rather than as a policy.
    #
    # The upstream is asked first, because "no AAAA came back" is only evidence
    # if there was an AAAA to come back. A probe name that quietly loses its
    # records would otherwise turn this into a check that passes because the
    # thing it depends on broke.
    #
    # As the resolver's account, in the filter container. Not as root: the rule
    # permitting root to reach a resolver matches on port 53, and the runtime's
    # embedded resolver is reached through a DNAT that has already rewritten
    # the port - which is the same reason the test below asserts root does not
    # reach past it. The forwarder's own rule is portless, and that is what
    # makes this question askable.
    local upstream truth
    upstream=$(dexec_filter head -1 /run/egress-policy/upstream-resolvers)
    [ -n "$upstream" ] || { echo "no upstream resolver recorded"; return 1; }
    truth=$(dexec_filter gosu egress-resolver \
                dig +short +time=3 +tries=2 "@$upstream" AAAA registry.npmjs.org || true)
    if [ -z "$truth" ]; then
        skip "registry.npmjs.org has no AAAA upstream either; this check would prove nothing"
    fi

    # It does have them out there. So the resolver returning none is the policy
    # doing something, not the name being unremarkable.
    run dexec dig +short AAAA registry.npmjs.org
    [ "$status" -eq 0 ]
    [ -z "$output" ] \
        || { echo "the resolver answered AAAA for a permitted name: $output"; return 1; }

    # And the A record still comes back, or the check above passes because
    # nothing resolves at all.
    run dexec dig +short A registry.npmjs.org
    [ -n "$output" ] \
        || { echo "the name does not resolve at all, so the AAAA check proves nothing"; return 1; }
}

@test "a v6 address the session somehow learns is still refused by the filter" {
    # Belt and braces for the layer above: if something got a v6 address by a
    # route the resolver does not control - a literal in a config file, an
    # address embedded in a URL - the packet filter is what stops it.
    #
    # Unconditional, and it does not assert the speed of the failure: on a host
    # with no v6 route this fails before reaching the filter, which is a
    # different mechanism with the same outcome, and the ruleset test above is
    # what distinguishes them.
    run dexec sh -c 'curl -s -o /dev/null --connect-timeout 5 --max-time 8 "https://[2606:4700:4700::1111]/"; echo "rc=$?"'
    [[ "$output" == *"rc="* ]]
    [[ "$output" != *"rc=0"* ]] \
        || { echo "a v6 address was reachable: $output"; return 1; }
}


@test "a name that is not permitted does not resolve, rather than being left to fail later" {
    # The query itself carries data out, so a name nobody permitted must not
    # reach an upstream at all - which is a different and earlier thing than
    # the connection that would follow being refused.
    run dexec dig definitely-not-on-the-allowlist.example.org
    [[ "$output" == *"status: NXDOMAIN"* || "$output" == *"status: REFUSED"* ]] \
        || { echo "an unpermitted name resolved: $output"; return 1; }
}

@test "a refused lookup is recorded, because it never becomes a connection" {
    # The connection log cannot account for it - there is no connection - and
    # this is the record that matters most: an attempt to resolve something
    # unpermitted is the exfiltration attempt.
    dexec dig +time=2 +tries=1 exfil-probe.example.org >/dev/null 2>&1 || true
    local found=""
    local i
    for i in 1 2 3 4 5 6; do
        if dexec_filter grep -q 'exfil-probe.example.org' /var/log/egress-policy/lookups.ndjson 2>/dev/null; then
            found=yes; break
        fi
        sleep 0.5
    done
    [ -n "$found" ] \
        || { echo "the refused lookup left no record"; dexec_filter tail -5 /var/log/egress-policy/lookups.ndjson; return 1; }
    run dexec_filter sh -c "grep -F 'exfil-probe.example.org' /var/log/egress-policy/lookups.ndjson | tail -1"
    [[ "$output" == *'"outcome": "refused"'* ]] \
        || { echo "recorded, but not as a refusal: $output"; return 1; }
    [[ "$output" == *'"reason": "not-permitted"'* ]] \
        || { echo "recorded without saying why: $output"; return 1; }
}

@test "an allowlisted domain resolves via the DNS proxy" {
    run dexec dig +short registry.npmjs.org
    [ -n "$output" ]
}

@test "the session user cannot address a resolver directly, so the DNS allowlist is not bypassable" {
    # Reaching a resolver outside this namespace is restricted by uid: the
    # forwarder, and root, because the container runtime's own resolver
    # forwards onwards from in here and every lookup times out without it.
    # `node` is neither - no sudo, no setuid binary, no way to change uid - so
    # this is the assertion that the opening stops short of the session. If it
    # could reach a resolver of its own choosing it could carry data out in the
    # query name itself, which is the exact thing the name allowlist exists to
    # prevent and something no allowlist of *names* can catch once the
    # *resolver* is attacker-chosen.
    #
    # 1.1.1.1 rather than an unrouted address: it answers if it is reachable,
    # so a pass here means the packet was stopped and not that the probe was
    # aimed at nothing.
    run dexec_node dig +short registry.npmjs.org
    [ -n "$output" ]

    run dexec_node dig +time=2 +tries=1 @1.1.1.1 definitely-not-allowed.example.org
    [ "$status" -ne 0 ]

    # And the runtime's embedded resolver, which is on loopback and which the
    # root exception does NOT reach past: the session user addressing it
    # directly is the query-name channel, and it stays closed.
    run dexec_node dig +time=2 +tries=1 @127.0.0.11 definitely-not-allowed.example.org
    [ "$status" -ne 0 ] \
        || { echo "the session user reached the runtime's resolver: $output"; return 1; }
}

@test "api.anthropic.com resolves in proxy-off mode (kill switch / API-key auth)" {
    # api.anthropic.com is left off the allowlist when the credential proxy is
    # on, so a bypass of the /etc/hosts pin that resolves the name by DNS gets
    # no address. When the proxy is off (kill switch or API-key auth), DNS is
    # the only path to the API and fixed-domains.sh allowlists it. This file's
    # shared container runs with no SANDBOX_CREDENTIAL_PROXY_SOCKET, so it is
    # in proxy-off mode and the name must resolve.
    run dexec dig +short api.anthropic.com
    [ -n "$output" ]
}

@test "a non-allowlisted destination is unreachable" {
    run dexec curl --connect-timeout 5 -s -o /dev/null https://example.com
    [ "$status" -ne 0 ]
}

@test "GitHub is reachable on port 443" {
    # Retried, and only because this is a POSITIVE assertion: more attempts
    # can only turn a pass into a pass. The unreachability assertions below
    # are never retried - there, a retry could hide a hole that opens once.
    #
    # It failed once on CI with nothing to go on: no curl exit code, no HTTP
    # status, no way to tell DNS from the address sets from the far end.
    # Everything else in that run said the firewall was right - the port-22
    # push grant reached GitHub, so the forge set held real addresses - which left one
    # five-second connect against a live third-party service as the only
    # explanation, and no evidence to confirm it with. Hence the diagnostics
    # as much as the retries.
    local attempt code rc=0
    for attempt in 1 2 3; do
        code="$(dexec curl --connect-timeout 5 -s -o /dev/null \
                     -w '%{http_code}' https://api.github.com/zen 2>&1)" && return 0
        rc=$?
        sleep 2
    done
    echo "api.github.com:443 unreachable after 3 attempts." >&2
    echo "last curl exit: $rc, last output: '$code'" >&2
    echo "exit 6 is DNS, 7 or 28 is the route or the firewall; an HTTP code" >&2
    echo "with a non-zero exit means the connection worked. Check with" >&2
    echo "'nft list set inet egress_policy forge_v4' in the filter container." >&2
    false
}

@test "GitHub is NOT reachable on port 22 (push transport is physically absent)" {
    run dexec timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22"
    [ "$status" -ne 0 ]
}

@test "a seeded plugin tree is writable, and a mounted version is not" {
    # The arrangement plugin updates depend on, asserted in a real container
    # because ownership is the whole point and only Docker produces it: it
    # creates a bind mount's missing parents as root, so the levels above an
    # installed version have to be seeded or the session owns nothing along
    # the path.
    #
    # The failure this guards against is a plugin that will not load. Claude
    # Code installs an update by materialising the new version beside the old,
    # at cache/<marketplace>/<plugin>/<newversion>/, and then rewriting its
    # registry. With the tree mounted read-only it could do neither, and the
    # only way out was to run Claude Code on the host and restart.
    local test_container seed ver
    test_container="$(test_container_name seed)"
    seed="$(mktemp -d)"
    # A host tree shaped like a real one: bookkeeping, a marketplace checkout,
    # and one installed version.
    mkdir -p "$seed/state/.claude/plugins/marketplaces/mkt" \
             "$seed/state/.claude/plugins/cache/mkt/alpha"
    printf '{"installed":true}\n' > "$seed/state/.claude/plugins/installed_plugins.json"
    printf 'catalog\n' > "$seed/state/.claude/plugins/marketplaces/mkt/entry"
    mkdir -p "$seed/version"
    printf 'shipped\n' > "$seed/version/plugin.json"

    ver=/home/node/.claude/plugins/cache/mkt/alpha/1.0.0
    start_pair seed "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e SANDBOX_HARNESS_SEED=".claude/plugins/installed_plugins.json .claude/plugins/marketplaces .claude/plugins/cache .claude/plugins/cache/mkt .claude/plugins/cache/mkt/alpha" \
        -v "$seed/state/.claude/plugins/installed_plugins.json:/etc/dejima-seed/.claude/plugins/installed_plugins.json:ro" \
        -v "$seed/state/.claude/plugins/marketplaces:/etc/dejima-seed/.claude/plugins/marketplaces:ro" \
        -v "$seed/version:$ver:ro"

    # The seeded copies arrived, and belong to the session.
    run docker exec "$test_container" cat /home/node/.claude/plugins/installed_plugins.json
    [[ "$output" == *'"installed":true'* ]] || { echo "registry not seeded: $output"; return 1; }
    run docker exec "$test_container" cat /home/node/.claude/plugins/marketplaces/mkt/entry
    [ "$output" = "catalog" ] || { echo "marketplace not seeded: $output"; return 1; }

    # Writable, which the mount it replaced was not - this is the registry
    # rewrite that used to fail.
    run docker exec -u node "$test_container" \
        bash -c 'printf "{\"installed\":false}\n" > /home/node/.claude/plugins/installed_plugins.json'
    [ "$status" -eq 0 ] || { echo "the registry is not writable: $output"; return 1; }

    # A new version can be created beside the mounted one. This is the update.
    run docker exec -u node "$test_container" mkdir -p "$ver/../1.1.0"
    [ "$status" -eq 0 ] || { echo "cannot install a new version: $output"; return 1; }

    # And the installed version itself is still read-only, which is why it can
    # be shared from the host at all.
    run docker exec -u node "$test_container" bash -c "printf x > $ver/tamper"
    [ "$status" -ne 0 ] || { echo "an installed version is writable from the session"; return 1; }
    run docker exec "$test_container" cat "$ver/plugin.json"
    [ "$output" = "shipped" ] || { echo "the mounted version changed: $output"; return 1; }

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$seed"
}

@test "ALLOW_GITHUB_PUSH=1 opens port 22 to GitHub" {
    local test_container="$(test_container_name ghpush)"
    start_pair ghpush "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e ALLOW_GITHUB_PUSH=1

    run docker exec "$test_container" timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22"
    [ "$status" -eq 0 ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
}

@test "a github-forge launch boots, and its port 22 comes from the push grant" {
    # The container half of test/config.bats' "the github forge's hosts reach
    # the push guard, never the extra-domains allowlist" - the environment
    # asserted there, handed to a real container here. Selecting `forge =
    # github` with a pushing workflow resolves to exactly this: no
    # DEJIMA_FORGE_HOSTS (core already allowlists GitHub's ranges) and the
    # push grant open.
    #
    # It has to be a boot test, because the failure it guards against was the
    # container not starting at all: with those three hostnames in
    # DEJIMA_FORGE_HOSTS, firewall-up.sh puts them in the open class, which
    # carries no port restriction, the policy's own startup self-check finds
    # github.com:22 reachable without ALLOW_GITHUB_PUSH=1, and the filter
    # container dies before the session ever starts.
    local test_container="$(test_container_name ghforge)"
    local test_filter="$(test_container_name ghforge-filter)"
    start_pair ghforge "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e DEJIMA_FORGE_HOSTS= \
        -e DEJIMA_PUSH_HOSTS="github.com ssh.github.com api.github.com" \
        -e ALLOW_GITHUB_PUSH=1

    # Coming up at all is half the assertion, and start_pair waited for both
    # halves: a filter whose startup self-checks failed never reports ready.

    # Port 22 open, and open through the path that says so out loud.
    run docker exec "$test_container" timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22"
    [ "$status" -eq 0 ]
    # The FILTER container's log, because the policy prints this and the
    # policy is what moved. The connect check above stays in the
    # session container for the opposite reason: reachability is a claim about
    # the session, and it is the half of this test that would still pass on a
    # grant that was never announced.
    #
    # Polled rather than read once, for the reason settled_logs documents: the
    # json-file driver's writes lag the process that produced them, so a single
    # read taken here can stop short of a line printed seconds earlier. That is
    # how this failed in CI - with the port-22 assertion directly above passing,
    # ie. with the branch that prints this line demonstrably taken. Waiting on
    # the line cannot mask its absence: one never printed still fails, later.
    local want="forge ssh=1" logs=""
    for _ in $(seq 1 40); do
        logs=$(docker logs "$test_filter" 2>&1)
        case "$logs" in *"$want"*) break ;; esac
        sleep 0.25
    done
    [[ "$logs" == *"$want"* ]]

    # And the other half of the widening this avoids: GitHub's names keep the
    # check that refuses an answer pointing inside a private network, which the
    # open-class path would have exempted them from.
    run docker exec "$test_filter" grep 'rebind-domain-ok=/github.com/' /run/egress-policy/resolver.conf
    [ "$status" -ne 0 ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
}


@test "a GitHub name declared as an extra domain stays port-restricted, so push stays unreachable" {
    # A project's declared domains widen what a session can reach. They must
    # not widen how. GitHub's addresses are confined to 443, and that is the
    # entire read-only guarantee - with 22 shut there is no transport left for
    # the forwarded ssh-agent's key to push with, whatever a hook does or does
    # not catch.
    #
    # The open class carries no port restriction, so before the class was
    # attached to the destination rather than to the path it arrived by, this
    # put GitHub's address there and opened 22. It surfaced as an intermittent
    # startup failure rather than as a silent hole only because the port-22
    # self-check re-resolves the name: it catches the hole when GitHub's second
    # answer matches the first, and misses it when the name has rotated in
    # between. This test does not depend on that coin flip.
    local test_container="$(test_container_name ghextra)"
    local test_filter="$(test_container_name ghextra-filter)"
    start_pair ghextra "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e DEJIMA_FORGE_HOSTS= \
        -e ALLOWED_DOMAINS="github.com api.github.com"

    # Coming up at all is part of the assertion, and start_pair waited for it:
    # the port-22 self-check runs during the FILTER container's startup, and
    # with the address in the wrong class it fails that boot rather than this one.

    # Resolved inside the container, through the same resolver that answered
    # during startup - so this asks about the address actually permitted, not
    # one a fresh lookup from elsewhere happened to return.
    local ip
    ip=$(docker exec "$test_container" dig +short A github.com | head -1)
    [ -n "$ip" ]

    # In the forge class's name set, which the clamp restricts to 443...
    run docker exec "$test_filter" nft get element inet egress_policy fname_v4 "{ $ip }"
    [ "$status" -eq 0 ] || { echo "github.com's address is not in the forge class: $output"; return 1; }

    # ...and not in the open class's, which has no port restriction at all.
    run docker exec "$test_filter" nft get element inet egress_policy oname_v4 "{ $ip }"
    [ "$status" -ne 0 ] || { echo "github.com's address reached the port-unrestricted class"; return 1; }

    # And the property those two sets exist to produce.
    run docker exec "$test_container" timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22"
    [ "$status" -ne 0 ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
}

@test "a configured forge host is exempted from stop-dns-rebind, other allowed domains are not" {
    # Passed as DEJIMA_FORGE_HOSTS, not GITEA_SSH_HOST: the container no longer
    # derives hostnames from any one forge's variables - bin/dejima resolves
    # them host-side from whichever forge is configured and hands the result
    # over under this one name. Feeding the old variable here made the test
    # assert against a hostname the entrypoint never saw.
    local test_container="$(test_container_name rebind)"
    local test_filter="$(test_container_name rebind-filter)"
    start_pair rebind "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e DEJIMA_FORGE_HOSTS=forge.internal.example

    run docker exec "$test_filter" grep -c '^stop-dns-rebind$' /run/egress-policy/resolver.conf
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]

    run docker exec "$test_filter" grep 'rebind-domain-ok=/forge.internal.example/' /run/egress-policy/resolver.conf
    [ "$status" -eq 0 ]

    run docker exec "$test_filter" grep 'rebind-domain-ok=/registry.npmjs.org/' /run/egress-policy/resolver.conf
    [ "$status" -ne 0 ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
}

@test "the code-carrying ~/.claude overlay dirs are read-only inside the container" {
    local test_container="$(test_container_name overlays)"
    local src; src="$(mktemp -d)"
    mkdir -p "$src/skills" "$src/commands" "$src/agents"
    start_pair overlays "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -v "$src/skills:/home/node/.claude/skills:ro" \
        -v "$src/commands:/home/node/.claude/commands:ro" \
        -v "$src/agents:/home/node/.claude/agents:ro"
    for d in skills commands agents; do
        run docker exec -u node "$test_container" bash -c "touch /home/node/.claude/$d/pwned 2>&1"
        [ "$status" -ne 0 ]
        [[ "$output" == *"Read-only file system"* ]]
    done
    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$src"
}

# #104: the whole ~/.claude/projects tree used to be mounted read-write, so a
# session could write another project's transcripts and agent memory. Memory
# is loaded into context at session start, which makes that a write into a
# future session's premises rather than its input.
#
# Three properties, and the second is the one that decides whether scoping is
# viable at all: a slug that is absent has to be creatable, because that is
# what Claude Code does on a first run against a path with no history. If the
# parent were read-only instead, this is where it would hang the way a
# blocked ~/.claude.json write did.
@test "only the mounted project slugs exist in the container, and an unmounted one is still creatable" {
    local test_container="$(test_container_name projects)"
    local src; src="$(mktemp -d)"
    mkdir -p "$src/own" "$src/sibling" "$src/fh-own"
    echo host > "$src/own/existing.jsonl"
    echo secret > "$src/sibling/other.jsonl"
    # file-history holds verbatim copies of edited files, so an unmounted
    # session directory being absent is the whole point of scoping it.
    echo 'other project source' > "$src/fh-own/aaaa@v1"
    chmod -R 777 "$src"
    start_pair projects "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -v "$src/own:/home/node/.claude/projects/own" \
        -v "$src/fh-own:/home/node/.claude/file-history/own-session"

    # the sibling project is absent, not merely unwritable
    run docker exec -u node "$test_container" test -e /home/node/.claude/projects/sibling
    [ "$status" -ne 0 ]
    run docker exec -u node "$test_container" ls /home/node/.claude/projects
    [[ "$output" != *sibling* ]]

    # a slug with no history yet can still be created, and stays in the
    # container: it is not on the host afterwards
    run docker exec -u node "$test_container" \
        bash -c 'mkdir -p /home/node/.claude/projects/fresh && echo x > /home/node/.claude/projects/fresh/a.jsonl'
    [ "$status" -eq 0 ]
    [ ! -e "$src/fresh" ]

    # and the mounted slug is the one that does reach the host
    docker exec -u node "$test_container" \
        bash -c 'echo written > /home/node/.claude/projects/own/new.jsonl'
    [ "$(cat "$src/own/new.jsonl")" = written ]

    # Same three properties for file-history. The middle one is what the
    # image's pre-created directory buys: without it Docker creates
    # file-history/ root-owned while setting up the mount nested in it, and
    # the session cannot record an undo entry for its own id at all.
    run docker exec -u node "$test_container" ls /home/node/.claude/file-history
    [[ "$output" != *other-session* ]]
    run docker exec -u node "$test_container" \
        bash -c 'mkdir -p /home/node/.claude/file-history/fresh-session && echo x > /home/node/.claude/file-history/fresh-session/b@v1'
    [ "$status" -eq 0 ]
    [ ! -e "$src/fresh-session" ]
    docker exec -u node "$test_container" \
        bash -c 'echo written > /home/node/.claude/file-history/own-session/c@v1'
    [ "$(cat "$src/fh-own/c@v1")" = written ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$src"
}

@test "a staged statusline.sh is copied in root-owned, and replacing it never reaches the host" {
    # Companion to the overlay-dirs test above, but for the config
    # bin/dejima stages at /etc/dejima-harness for entrypoint.sh to copy into
    # ~/.claude (see its comment there) rather than mounting at its real
    # path. This test does NOT use bin/dejima or docker-compose.yml directly
    # - it builds the same shape by hand. This shared container isn't reused
    # for it (it has no staging mount at all - see setup_file).
    local test_container="$(test_container_name statusline-regular)"
    local dotclaude; dotclaude="$(mktemp -d)"
    printf '#!/bin/sh\necho original\n' > "$dotclaude/statusline.sh"
    chmod +x "$dotclaude/statusline.sh"
    # mktemp -d is mode 700, which only works because the uid running these
    # tests is usually the same one the container's node maps to. Where it
    # isn't - CI runs as root, node is 1000 - node cannot even traverse this
    # directory. Writable, so that if the container's copy somehow did lead
    # back here the write below would succeed and this test would say so.
    chmod 777 "$dotclaude"

    start_pair statusline-regular "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -v "$dotclaude/statusline.sh:/etc/dejima-harness/.claude/statusline.sh:ro"

    run docker exec -u node "$test_container" cat /home/node/.claude/statusline.sh
    [[ "$output" == *"original"* ]]
    run docker exec -u node "$test_container" stat -c '%U %a' /home/node/.claude/statusline.sh
    [[ "$output" == "root 555" ]]

    # An in-place overwrite fails on the mode alone. Unlinking and replacing
    # it succeeds - ~/.claude belongs to the session - but the copy is the
    # only thing that changes: nothing on the host is reachable from it.
    run docker exec -u node "$test_container" sh -c \
        'echo pwned > /home/node/.claude/statusline.sh'
    [ "$status" -ne 0 ]
    run docker exec -u node "$test_container" sh -c \
        'rm -f /home/node/.claude/statusline.sh && echo pwned > /home/node/.claude/statusline.sh'
    [ "$status" -eq 0 ]

    run cat "$dotclaude/statusline.sh"
    [[ "$output" == *"original"* ]]
    [[ "$output" != *"pwned"* ]]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$dotclaude"
}

@test "staging protects a symlinked statusline.sh, which a read-only mount does not" {
    # Same shape as the plain-regular-file test above, except statusline.sh
    # on the host is a symlink into a separate directory - the common real
    # setup (~/.claude/statusline.sh -> a config checkout elsewhere). That
    # case is the one a :ro mount cannot cover: with statusline.sh mounted
    # read-only back onto its own path inside a read-write ~/.claude mount,
    # the parent mount is established first, so the destination already has
    # the symlink sitting on it, and bind-mount destination resolution
    # (runc's SecureJoin) follows it - the :ro mount lands on the target
    # and the symlink dentry itself stays an ordinary writable entry that a
    # session can unlink and replace, leaving detection (bin/dejima-audit
    # hashing the target string) as the only compensating control.
    #
    # Staging closes it outright, and for the opposite reason: source-side
    # symlink resolution is exactly what's wanted, so what lands at
    # /etc/dejima-harness holds the real content, and entrypoint.sh copies it to
    # a path with no route back to the host at all. This test asserts the
    # replacement no longer reaches either the symlink or its target.
    local test_container="$(test_container_name statusline-symlink)"
    local target_dir dotclaude
    target_dir="$(mktemp -d)"
    printf '#!/bin/sh\necho original\n' > "$target_dir/statusline.sh"
    chmod +x "$target_dir/statusline.sh"
    dotclaude="$(mktemp -d)"
    ln -s "$target_dir/statusline.sh" "$dotclaude/statusline.sh"
    # Both mode 700 from mktemp -d; see the regular-file test above. Left
    # writable for the same reason: a write that did get through must be
    # able to land, or this would pass for reasons unrelated to the gap.
    chmod 777 "$target_dir" "$dotclaude"

    start_pair statusline-symlink "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -v "$dotclaude/statusline.sh:/etc/dejima-harness/.claude/statusline.sh:ro"

    run docker exec -u node "$test_container" sh -c \
        'rm -f /home/node/.claude/statusline.sh && echo pwned > /home/node/.claude/statusline.sh'
    [ "$status" -eq 0 ]

    [ -L "$dotclaude/statusline.sh" ]
    [ "$(readlink "$dotclaude/statusline.sh")" = "$target_dir/statusline.sh" ]
    run cat "$target_dir/statusline.sh"
    [[ "$output" == *"original"* ]]
    [[ "$output" != *"pwned"* ]]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$target_dir" "$dotclaude"
}

@test "root in the session container cannot alter the filter bounding it" {
    # The claim the whole arrangement rests on, and the one that needs a real
    # kernel to settle: capabilities are per PROCESS, not per namespace. This
    # container is inside a namespace whose rules were installed by another
    # container that holds NET_ADMIN, and it declares none - so uid 0 in here
    # is refused, which is what makes an escape to container root stop short of
    # the filter that bounds it.
    #
    # As root, deliberately. `node cannot change the packet filter` below
    # asserts the unprivileged case and would pass on a container that simply
    # had the capability and a user without it.
    run docker exec -u root "$(container_name)" nft flush ruleset
    [ "$status" -ne 0 ] \
        || { echo "root in the session container flushed the filter"; return 1; }
    run docker exec -u root "$(container_name)" nft list table inet egress_policy
    [ "$status" -ne 0 ] \
        || { echo "root in the session container can read the ruleset: $output"; return 1; }

    # And the filter is still there afterwards - the negative above would read
    # the same if there were no rules to flush in the first place.
    run dexec_filter nft list chain inet egress_policy egress
    [ "$status" -eq 0 ]
    [[ "$output" == *"policy drop"* ]] \
        || { echo "the filter is not in the state this test assumed: $output"; return 1; }
}

@test "the compose file parses, and defaults to no network when nothing supplies one" {
    # Nothing in this repo runs `docker compose` against a real daemon: this
    # suite builds with plain `docker build`, and every launch test elsewhere
    # stubs docker entirely. So a compose file that stopped interpolating would
    # reach an operator before it reached a test - and it would present as a
    # failing BUILD, because `build` and `run` both parse the whole file first.
    #
    # That is not hypothetical arithmetic: `docker compose build sandbox` run
    # by hand fails today on four `${VAR:?}` volume entries, which is correct
    # and is why nothing had ever checked this.

    # The compose PLUGIN, not just the docker CLI. The privileged runner has
    # the CLI and a socket and no compose at all, so this skips there - and it
    # skips out loud, because what that absence means is larger than this test:
    # no CI job runs `docker compose`, so no CI job exercises the launch path
    # bin/dejima actually takes. It runs on a host that has the plugin.
    docker compose version >/dev/null 2>&1 \
        || skip "no docker compose plugin here, so the compose file goes unparsed"

    # Not $SANDBOX_DIR: that is assigned in setup_file, which bats runs in a
    # different shell from a test body.
    local compose="$BATS_TEST_DIRNAME/../docker/docker-compose.yml"

    # Every name the file interpolates WITHOUT a default, read out of the file
    # rather than listed here, so one added tomorrow is supplied rather than
    # turning this red against a launcher that sets it properly. Two shapes,
    # and both matter: `${VAR:?}` fails the parse outright, and a bare `${VAR}`
    # resolves to the empty string, which is a volume line with no source.
    #
    # Values only have to exist; `config` validates and starts nothing. HOME is
    # excluded: it is always set, and pointing it elsewhere here would only
    # move where docker looks for its own client config.
    local -a env_args=()
    local v
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        [ "$v" != HOME ] || continue
        env_args+=("$v=/tmp")
    done < <(grep -oE '\$\{[A-Z_]+(:\?|\})' "$compose" \
             | sed 's/^\${//; s/:?$//; s/}$//' | sort -u)
    [ "${#env_args[@]}" -gt 0 ] \
        || { echo "found no undefaulted variables to supply - is the file still interpolated?"; return 1; }

    run env "${env_args[@]}" docker compose -f "$compose" config
    [ "$status" -eq 0 ] || { echo "the compose file does not parse:"; echo "$output"; return 1; }

    # SANDBOX_NETNS_CONTAINER is deliberately NOT supplied above, so this is
    # the default resolving. `none` is a sandbox that visibly cannot work;
    # any real network is one that works and has unfiltered egress.
    grep -qE '^\s*network_mode:\s*"?none"?\s*$' <<< "$output" \
        || { echo "the default network_mode is not none:"; grep -i network <<< "$output"; return 1; }
}

@test "PID 1 can forward a signal to the session, so a resize does not kill it" {
    # The exact failure an operator hits, reproduced: splitting a tmux pane
    # resizes the pty, the kernel sends SIGWINCH to its foreground process
    # group - tini included - and tini forwards it to the session. tini is
    # uid 0; the session's real AND saved uids are the sandbox user's, because
    # the entrypoint changed uid in place before exec'ing it. kill(2) allows
    # that only with CAP_KILL or a uid match, and there is no match.
    #
    # tini treats a failed forward as fatal, so the symptom is not a dropped
    # signal: PID 1 exits and the container goes with it, mid-session.
    #
    # `docker kill --signal` delivers to PID 1, which is the same door the
    # kernel uses - so this asks the question without needing a pty to resize.
    # Its own pair, because the assertion is that a container is still alive
    # and a failure would take every later test in this file with it.
    local c; c="$(test_container_name winch)"
    start_pair winch "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}"

    # PID 1 really is an init here, or this asks nothing: without one the
    # session is PID 1 and signals it early enough never to be forwarded.
    run docker exec "$c" sh -c 'cat /proc/1/comm'
    [ "$status" -eq 0 ]
    [[ "$output" != *sleep* ]] \
        || { echo "PID 1 is the session, so nothing forwards: $output"; return 1; }

    docker kill --signal=WINCH "$c"
    sleep 2
    run docker inspect -f '{{.State.Running}}' "$c"
    [ "$output" = true ] || {
        echo "the container died forwarding a signal to its own session:"
        docker logs "$c" 2>&1 | tail -5
        return 1
    }

    # And the session itself survived it, rather than the container outliving
    # a session the signal killed.
    run docker exec "$c" pgrep -x -f 'sleep infinity'
    [ "$status" -eq 0 ] \
        || { echo "the container is up but the session is gone"; return 1; }
}

@test "the session container inherits the namespace's unprivileged port floor" {
    # docker-compose.yml declares no sysctls: this one is a property of a
    # network namespace, and the session container does not own the one it is
    # in. bin/dejima sets it on the filter container that does.
    #
    # Read from in here rather than from there, because in here is where it has
    # to be true - the credential proxy's TLS terminator binds :443 in this
    # container, as the unprivileged sandbox user.
    run dexec cat /proc/sys/net/ipv4/ip_unprivileged_port_start
    [ "$status" -eq 0 ]
    [ "$output" = "0" ] \
        || { echo "unprivileged binds start at $output, so :443 is out of reach"; return 1; }
}

@test "node cannot change the packet filter" {
    run dexec_node nft list ruleset
    [ "$status" -ne 0 ]
}


@test "node cannot re-run the egress policy to widen the allowlist" {
    run dexec_node /usr/local/sbin/egress-policy apply
    [ "$status" -ne 0 ]
    # And not merely because it is missing: it refuses for the reason that
    # keeps holding after someone puts it back on PATH.
    run dexec_node sh -c '/usr/local/sbin/egress-policy apply 2>&1'
    [[ "$output" == *"must run as root"* ]] \
        || { echo "refused, but not by the check that says why: $output"; return 1; }
}

@test "the permitted set cannot be amended from the session container" {
    # `egress-policy permit` is the documented way to add a destination to a
    # running session, and it is the operator's to run from the host. From
    # inside the session it must do nothing - it is the same binary in the same
    # image, and only the container it runs in differs.
    # What the policy would have CHANGED is re-read after each refusal, not
    # just the exit status checked: an amendment that landed and then failed on
    # something later would exit non-zero with the destination permitted, which
    # is the outcome this test is named for and the one a status cannot see.
    #
    # The entries file and the resolver configuration, because a permit for a
    # NAME writes both - the address sets only ever hold addresses, so grepping
    # those for a hostname is a check that cannot fail.
    local before_entries before_conf after_entries after_conf
    before_entries="$(dexec_filter cat /run/egress-policy/entries)"
    before_conf="$(dexec_filter cat /run/egress-policy/resolver.conf)"
    [ -n "$before_entries" ] && [ -n "$before_conf" ] \
        || { echo "could not read the policy's own record of what is permitted"; return 1; }

    run dexec_node /usr/local/sbin/egress-policy permit evil.example.com
    [ "$status" -ne 0 ]
    run docker exec -u root "$(container_name)" /usr/local/sbin/egress-policy permit evil.example.com
    [ "$status" -ne 0 ] \
        || { echo "root in the session container amended the permitted set"; return 1; }

    after_entries="$(dexec_filter cat /run/egress-policy/entries)"
    after_conf="$(dexec_filter cat /run/egress-policy/resolver.conf)"
    [ "$after_entries" = "$before_entries" ] \
        || { echo "the entries file changed despite both refusals"; return 1; }
    [ "$after_conf" = "$before_conf" ] \
        || { echo "the resolver configuration changed despite both refusals"; return 1; }
    # Named directly as well, so this does not rest on two snapshots matching:
    # an entry already present before the test would make them match anyway.
    grep -q evil.example <<< "$after_entries$after_conf" \
        && { echo "evil.example.com reached the policy's record of what is permitted"; return 1; }
    return 0
}

@test "node has no working sudo" {
    # `run !` rather than checking $status: this fails with 127 (command
    # not found) today since sudo isn't installed at all, not some other
    # nonzero code - both are "no working sudo," and pinning to one exact
    # code would make the test brittle to which specific way that stays true.
    run ! dexec_node sudo -n true
}

@test "the container runs with no path back up to more privilege" {
    # no-new-privileges in docker-compose.yml. gosu drops privilege rather
    # than gaining it, so this does not interfere with the session starting -
    # what it forbids is a setuid binary or a file capability raising
    # privileges on exec, which is the shape any escalation from the session
    # user would have to take.
    #
    # Asserted on PID 1 and on the session user, because the flag is a property
    # of the process tree and both halves of it matter.
    run dexec cat /proc/1/status
    [ "$status" -eq 0 ]
    [[ "$output" == *$'NoNewPrivs:\t1'* ]] \
        || { echo "PID 1 can still gain privileges on exec"; return 1; }
    run dexec_node sh -c 'grep NoNewPrivs /proc/self/status'
    [[ "$output" == *"1"* ]] || { echo "the session user's shell can: $output"; return 1; }
}

@test "the running image holds no setuid binary and no file capability" {
    # no_new_privs above forbids one from taking effect; this asserts there is
    # none to take effect, which is the half a misconfigured runtime cannot
    # undo. Read from the running container rather than the build, because what
    # matters is the image a session is actually handed - including the derived
    # per-project layer, which installs its own packages after the base image
    # is finished and sweeps them at its own end.
    #
    # The image's own sweeper in --check mode, rather than a find and a getcap
    # written out here: the two would then have to agree about which roots to
    # walk, and a check that walks fewer than the sweeper passes for the wrong
    # reason. --check changes nothing, so it is safe against the shared
    # container.
    run dexec /usr/local/sbin/strip-privilege-bits --check
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    # And once more outside those roots. --check walks the directories the
    # sweeper walks, which deliberately exclude /tmp, /run, /mnt and /media -
    # the sweeper has no reason to visit them, but an image that shipped
    # something there would go unnoticed by a check scoped to its own sweep.
    # Cheap because those directories are near-empty in an image.
    run dexec sh -c 'find /tmp /run /mnt /media -xdev -type f -perm /6000 2>/dev/null; getcap -r /tmp /run /mnt /media 2>/dev/null'
    [ -z "$output" ] \
        || { echo "privileged bits outside the swept roots:"; echo "$output"; return 1; }

    # File capabilities over the whole image filesystem, not a directory
    # union: a capability at a top-level path nobody enumerated - /data/bin
    # in some future layer - is asserted by nothing else, while setuid gets
    # the same whole-filesystem walk in the derived-image test below. -xdev
    # keeps this to the image: /proc, /sys and every bind mount are their own
    # filesystems, and a capability in the operator's mounted checkout is not
    # the image's to answer for. A missing getcap prints a marker instead of
    # nothing, because an empty result has to mean "none found", not "nothing
    # asked".
    run dexec sh -c 'command -v getcap >/dev/null || { echo getcap-missing; exit 1; }
        find / -xdev -type f -print0 2>/dev/null | xargs -0 -r getcap 2>/dev/null || true'
    [ -z "$output" ] \
        || { echo "a file capability survived somewhere in the image (or getcap is gone):"; echo "$output"; return 1; }
}

@test "the session shell is bash, configured by the image, with history appended" {
    # A session is killed far more often than it exits, and bash writes history
    # on a clean exit only - so without the per-command append there is no
    # record of what a session did. Asserted in an interactive shell, because
    # that is the only kind the configuration applies to.
    run dexec_node bash -ic 'printf "%s|%s|%s\n" "$SHELL" "$HISTFILE" "$PROMPT_COMMAND"'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"/bin/bash|/var/opt/shell-history/.bash_history|history -a"* ]] \
        || { echo "shell, history file or append is not as configured: $output"; return 1; }
    # The volume is mounted and writable by the session user, so the file the
    # variable names can actually be written.
    run dexec_node sh -c 'touch /var/opt/shell-history/.bash_history && echo writable'
    [[ "$output" == *writable* ]] || { echo "the history volume is not writable: $output"; return 1; }
}

@test "root's shell does not share the session user's history file" {
    # The snippet above is sourced from /etc/bash.bashrc, so it reaches root's
    # interactive shell too - the one an operator gets attaching to debug. The
    # volume belongs to the sandbox user, and `history -a` follows a symlink, so
    # sharing it would let the session choose a file for root to append to and
    # read back whatever the operator typed.
    run dexec bash -ic 'printf "%s" "$HISTFILE"'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"/var/opt/shell-history"* ]] \
        || { echo "root's HISTFILE is on the session user's volume: $output"; return 1; }

    # The directory is the session user's, which is what makes the above
    # necessary rather than merely tidy.
    run dexec stat -c '%U' /var/opt/shell-history
    [[ "$output" != root ]] \
        || { echo "the history volume is root-owned now; this test's premise has changed"; return 1; }
}

@test "the wrapper's directory comes before the npm prefix on the session's PATH" {
    # The wrapper in /usr/local/bin shadows the harness's real binary to pin
    # --dangerously-skip-permissions, --settings and the briefing. That binary
    # is npm-installed, so the order of these two directories decides whether
    # any of those flags reach the session - and getting it wrong costs the
    # sandbox its whole operating mode without erroring.
    #
    # Checked on the real PATH of both a login and a non-login shell, because
    # Debian's /etc/profile rebuilds PATH from scratch for the first and the
    # image's ENV supplies the second.
    local shell_kind path lb np
    for shell_kind in '-lc' '-c'; do
        path=$(dexec_node bash "$shell_kind" 'printf "%s" "$PATH"')
        [ -n "$path" ] || { echo "no PATH from bash $shell_kind"; return 1; }
        lb=$(awk -v p="$path" 'BEGIN{n=split(p,a,":"); for(i=1;i<=n;i++) if(a[i]=="/usr/local/bin") {print i; exit}}')
        np=$(awk -v p="$path" 'BEGIN{n=split(p,a,":"); for(i=1;i<=n;i++) if(a[i]=="/opt/node-tools/bin") {print i; exit}}')
        [ -n "$lb" ] || { echo "bash $shell_kind: /usr/local/bin is not on PATH at all: $path"; return 1; }
        [ -n "$np" ] || { echo "bash $shell_kind: the npm prefix is not on PATH at all: $path"; return 1; }
        [ "$lb" -lt "$np" ] \
            || { echo "bash $shell_kind: the npm prefix precedes /usr/local/bin, so the wrapper is shadowed: $path"; return 1; }
    done
}

@test "the capability bounding set is the declared floor and nothing more" {
    # cap_drop: ALL plus an explicit list, rather than Docker's default set
    # plus two. The entrypoint uses seven capabilities during its root phase and
    # the default carries about fourteen; this asserts the difference is real
    # in the running container rather than only present in the compose file.
    #
    # Read from a fresh `docker exec`, which is where the CONTAINER's declared
    # set is observable. Not from PID 1: what PID 1 holds is whatever the
    # entrypoint left it holding, which since the drop below is nothing at all
    # - a true statement about the session, and no statement about the floor.
    #
    # CapBnd, not CapEff: the effective set is zero for the session user
    # already (the test below), and the bounding set is what says the rest was
    # never available to regain.
    run dexec cat /proc/self/status
    [ "$status" -eq 0 ]
    local bnd; bnd=$(echo "$output" | awk '/^CapBnd:/ {print $2}')
    [ -n "$bnd" ] || { echo "no CapBnd in /proc/self/status"; return 1; }

    # Decoded by name so a failure says which capability, not which bit.
    # Unskippable: libcap2-bin is a declared package and entrypoint.sh refuses
    # to start without capsh, so an image missing it is a failure to report
    # rather than a decode this test can do without.
    local have; have="$(dexec capsh --decode="$bnd" 2>/dev/null)" || have=""
    [ -n "$have" ] || { echo "capsh could not decode $bnd - is libcap2-bin installed?"; return 1; }
    local cap
    for cap in $(compose_cap_add); do
        [[ "$have" == *"cap_$(echo "$cap" | tr '[:upper:]' '[:lower:]')"* ]] \
            || { echo "declared $cap is missing from the bounding set: $have"; return 1; }
    done
    # Not KILL: `dejima-allow --container` signals dnsmasq, which runs as its
    # own user, so root here needs it. That absence is what failed the first
    # privileged run of this change.
    #
    # Not SETPCAP either, and for a reason worth keeping straight: it is
    # declared, and it is declared so that everything in the list can be taken
    # away again from anything the session can reach.
    for cap in mknod setfcap sys_chroot audit_write net_bind_service sys_admin fsetid; do
        [[ "$have" != *"cap_$cap"* ]] \
            || { echo "cap_$cap is in the bounding set and nothing declares it: $have"; return 1; }
    done
}

@test "root can still signal dnsmasq, which is what adding a domain mid-session needs" {
    # Named for the thing rather than left to be caught by the set tests,
    # which is how it WAS caught: the first version of the capability floor
    # dropped KILL, and `dejima-allow --container` failed with "Operation not
    # permitted" because the resolver runs as its own dedicated account and
    # root cannot signal another user's process without CAP_KILL.
    #
    # Adding a domain to a running session is a documented feature that every
    # session briefing tells the agent to ask for, so this asserts the
    # capability by exercising what needs it.
    #
    # In the FILTER container, which is where dnsmasq runs - so the floor this
    # is about is the one bin/dejima gives that container, not the one
    # docker-compose.yml gives the session.
    run dexec_filter sh -c 'kill -HUP "$(cat /run/egress-policy/resolver.pid)"'
    [ "$status" -eq 0 ] \
        || { echo "root cannot signal dnsmasq - is KILL in the filter floor? $output"; return 1; }
}

@test "the session process holds nothing - not effective, and not in the bounding set either" {
    # Two claims, and the second is the one with teeth. An empty effective set
    # is what changing uid gives you for free; it says nothing about what a
    # process that reached uid 0 in this tree would get, because a uid-0 execve
    # recovers its permitted set from the bounding set it inherited.
    #
    # entrypoint.sh empties that too, so the answer is "nothing" rather than
    # "the seven the root phase needed". The declared floor stays what it is -
    # the test above reads it from a fresh exec - and stops being a description
    # of the session's whole life.
    local pid; pid="$(session_pid)"
    [ -n "$pid" ] || { echo "no session process found in the container"; return 1; }

    run dexec cat "/proc/$pid/status"
    [ "$status" -eq 0 ]
    local eff bnd
    eff=$(echo "$output" | awk '/^CapEff:/ {print $2}')
    bnd=$(echo "$output" | awk '/^CapBnd:/ {print $2}')
    [ "$eff" = "0000000000000000" ] \
        || { echo "the session has capabilities in effect: $(dexec capsh --decode="$eff")"; return 1; }
    [ "$bnd" = "0000000000000000" ] \
        || { echo "the session could regain: $(dexec capsh --decode="$bnd")"; return 1; }
}

@test "the entrypoint refuses to start when it cannot take the capabilities away again" {
    # Without CAP_SETPCAP the bounding set cannot be reduced, so the session
    # would run holding every capability the floor declares. The failure that
    # matters is the quiet one: `setpriv --bounding-set` exits 0 having changed
    # nothing in exactly this case, so a container built on it would come up,
    # work, and report success while asserting a floor it did not have.
    #
    # Hence a refusal with a reason, and hence this test: the whole point is
    # that the container does NOT come up.
    # Deliberately NOT start_pair: the point is a floor with one capability
    # missing, and start_pair supplies the declared one to both halves. No
    # filter container either - this container is meant to die in its first few
    # lines, long before anything about a network matters.
    local test_container; test_container="$(test_container_name nosetpcap)"
    local -a caps=()
    while IFS= read -r cap; do
        [ "$cap" != "SETPCAP" ] || continue
        caps+=(--cap-add="$cap")
    done < <(compose_cap_add)

    docker run -d --name "$test_container" \
        --cap-drop=ALL "${caps[@]}" \
        --security-opt=no-new-privileges:true \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$SESSION_IMAGE" >/dev/null

    run docker wait "$test_container"
    [ "$status" -eq 0 ]
    [ "$output" != "0" ] \
        || { echo "the container started anyway, without SETPCAP"; return 1; }

    run docker logs "$test_container"
    [[ "$output" == *"does not hold CAP_SETPCAP"* ]] \
        || { echo "it failed, but said nothing about why: $output"; return 1; }
    [[ "$output" == *"cap_add"* ]] \
        || { echo "the refusal does not name where the floor is declared: $output"; return 1; }
}

@test "the log shipper reads two logs as root and holds no capability while doing it" {
    # It is the one root process that outlives the entrypoint, and what it
    # parses is decided by the session's own traffic - every hostname it
    # resolves and every address it connects to. Root is deliberate (a session
    # must not be able to kill or edit its own oversight log); the capabilities
    # that came with root are not.
    #
    # Its own pair, because the shipper exits immediately without LOKI_URL, so
    # the file-wide fixture never starts one. The URL only has to exist -
    # nothing here asserts delivery, and an unreachable one keeps this test off
    # the network.
    #
    # It runs in the FILTER container, which is where the two records it tails
    # are written - the name lookups and the connection attempts.
    local test_filter; test_filter="$(test_container_name shipper-filter)"

    start_pair shipper "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e LOKI_URL="http://127.0.0.1:1"

    local pid
    pid="$(docker exec "$test_filter" pgrep -f -x '/bin/bash /usr/local/bin/log-shipper.sh' \
        2>/dev/null | head -1)"
    [ -n "$pid" ] || {
        echo "no log-shipper process - LOKI_URL is set, so it should be running"
        docker exec "$test_filter" ps -eo user,args >&2 || true
        return 1
    }

    run docker exec "$test_filter" cat "/proc/$pid/status"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | awk '/^Uid:/ {print $2}')" = "0" ] \
        || { echo "the shipper is no longer root, so a session could signal it"; return 1; }
    local bnd; bnd=$(echo "$output" | awk '/^CapBnd:/ {print $2}')
    [ "$bnd" = "0000000000000000" ] \
        || { echo "the shipper could regain: $(docker exec "$test_filter" capsh --decode="$bnd")"; return 1; }

    # And it can still do its job with nothing: both sources readable on
    # ordinary permissions rather than through DAC_OVERRIDE. The shipper says
    # so itself when they are not, which is the line this looks for the absence
    # of - `tail -F` would otherwise swallow it and ship an empty stream.
    run docker logs "$test_filter"
    [[ "$output" != *"will ship nothing"* ]] \
        || { echo "the shipper cannot read a source it is meant to: $output"; return 1; }
}




@test "both log producers run as their own unprivileged user, not root" {
    # Between them they parse packet headers and resolver log lines, both
    # decided by what the session sends and asks for, so neither should be
    # holding privilege. Each opens what it needs first, so the drop costs it
    # nothing.
    #
    # Read from /proc rather than matched in ps output, because ps truncates
    # in two places that both bite here: `user` to eight characters, which is
    # how an assertion about egress-resolver came to be unsatisfiable, and
    # `comm` to fifteen, which dns-lookup-log fits inside today by one
    # character. The uid in /proc/<pid>/status is neither truncated nor
    # ambiguous, and each process is found by the pid its own producer
    # recorded rather than by matching text.
    local want
    want=$(dexec_filter id -u ulogd)
    [ -n "$want" ] || { echo "the image has no ulogd account"; return 1; }

    local pid uid
    for pid in "$(dexec_filter pgrep -x ulogd)" \
               "$(dexec_filter cat /run/egress-policy/lookup-log.pid)"; do
        [ -n "$pid" ] || { echo "one of the log producers is not running"; return 1; }
        uid=$(dexec_filter awk '/^Uid:/ { print $2 }' "/proc/$pid/status")
        [ "$uid" = "$want" ] \
            || { echo "pid $pid runs as uid $uid, not $want ($(dexec_filter cat "/proc/$pid/cmdline" | tr '\0' ' '))"; return 1; }
    done
}

@test "the resolver runs as the account the upstream rule is keyed to" {
    # The rule permitting anything in this namespace to reach a resolver
    # outside it is a uid match, so the resolver actually running as that
    # account is load-bearing - and it must be an account nothing else uses,
    # because a permission keyed to a shared one is granted to everything that
    # lands there.
    # Compared by uid, not by name. `ps -eo user` pads the column to eight
    # characters and truncates anything longer to "egress-+", which is not a
    # string any assertion about this account can match - and the account is
    # deliberately named for what it is rather than for what fits.
    local want
    want=$(dexec_filter id -u egress-resolver)
    [ -n "$want" ] || { echo "the image has no egress-resolver account"; return 1; }

    run dexec_filter sh -c 'ps -eo uid,comm | awk "\$2 == \"dnsmasq\" { print \$1 }"'
    [ "$status" -eq 0 ]
    [ -n "$output" ] || { echo "no dnsmasq process in the filter container"; return 1; }
    [ "$output" = "$want" ] \
        || { echo "the resolver runs as uid $output, and the rule is keyed to $want"; return 1; }

    # And nothing is running as the account the rule must NOT be keyed to,
    # because a permission keyed to a shared one is granted to everything that
    # lands there.
    run dexec_filter sh -c 'ps -eo uid,comm | awk "\$1 == \"65534\" { print \$2 }"'
    [ -z "$output" ] \
        || { echo "something runs as nobody, which the rule must not be keyed to: $output"; return 1; }
}

@test "every connection attempt is recorded with its verdict" {
    # A refused destination and a permitted one both have to leave a record, or
    # the log a supervisor reads proves nothing about what the session did. And
    # each record's verdict has to be the right one, not merely present: the
    # verdict rides on which NFLOG group the rule named, so the two groups
    # swapped would log every refusal as "allowed" - and a check that only
    # asked for the field would stay green while it did.
    # The permitted half needs a destination nothing has to answer on: the allow
    # record is written when the first packet is accepted, not when a service
    # replies, and a test that waited for a reply would be testing the network.
    # A documentation address permitted as a literal is exactly that - in
    # @literal_v4, on any port, routed nowhere. Added live rather than declared
    # at launch so the file-wide pair keeps the permitted set a real one has.
    local allowed=198.51.100.1
    run dexec_filter /usr/local/sbin/egress-policy permit "$allowed"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    dexec curl -s -o /dev/null --connect-timeout 5 --max-time 8 https://192.0.2.1/ 2>/dev/null || true
    dexec curl -s -o /dev/null --connect-timeout 3 --max-time 5 "http://$allowed:9/" 2>/dev/null || true
    local found="" i
    for i in 1 2 3 4 5 6; do
        if dexec_filter grep -q '192.0.2.1' /var/log/egress-policy/connections.ndjson 2>/dev/null \
            && dexec_filter grep -F "$allowed" /var/log/egress-policy/connections.ndjson 2>/dev/null | grep -q '"allowed"'; then
            found=yes; break
        fi
        sleep 0.5
    done
    [ -n "$found" ] \
        || { echo "a connection left no record with its verdict"; dexec_filter tail -5 /var/log/egress-policy/connections.ndjson; return 1; }
    run dexec_filter sh -c "grep -F '192.0.2.1' /var/log/egress-policy/connections.ndjson | tail -1"
    [[ "$output" == *'"blocked"'* ]] \
        || { echo "a refused connection was not recorded as blocked: $output"; return 1; }
}


@test "the address sets stay in sync with fresh answers, not just the boot-time snapshot" {
    # A permitted name's addresses rotate, and the set has to follow - the
    # resolver writes each answer into the set as it serves it, so a CDN edge
    # moving does not turn into "allowed at startup, blocked minutes later".
    #
    # Any built-in name that resolves to a CDN address will do; this one is
    # here because it is built in, so keep it on a name from fixed-domains.sh
    # rather than one a project happens to have approved.
    local ip
    ip=$(dexec dig +short registry.npmjs.org | head -1)
    [ -n "$ip" ]
    dexec_filter nft delete element inet egress_policy oname_v4 "{ $ip }"
    run dexec_filter nft get element inet egress_policy oname_v4 "{ $ip }"
    [ "$status" -ne 0 ]

    # SIGHUP clears the resolver's answer cache, forcing a genuine upstream
    # re-forward on the next query instead of a cache hit - only a fresh
    # forward writes into the set again.
    dexec_filter bash -c 'kill -HUP "$(cat /run/egress-policy/resolver.pid)"'
    sleep 0.5
    dexec dig +short registry.npmjs.org >/dev/null
    sleep 0.5
    run dexec_filter nft get element inet egress_policy oname_v4 "{ $ip }"
    [ "$status" -eq 0 ]
}

@test "Playwright/Chromium actually launches and renders, not just installs" {
    dexec_node bash -c 'cat > /tmp/pw-launch-test.js <<'"'"'EOF'"'"'
const { chromium } = require("playwright");
(async () => {
  const browser = await chromium.launch({});
  const page = await browser.newPage();
  await page.setContent("<h1>ok</h1>");
  const text = await page.textContent("h1");
  if (text !== "ok") throw new Error("unexpected content: " + text);
  await browser.close();
  console.log("PLAYWRIGHT_LAUNCH_OK");
})();
EOF'
    run dexec_node node /tmp/pw-launch-test.js
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLAYWRIGHT_LAUNCH_OK"* ]]
}

@test "a global package imports as ESM too, from a directory of its own" {
    # The test above proves the browser works, in the module system that
    # already resolved. Both resolvers walk up from the importing file looking
    # for node_modules, and only the symlink at the filesystem root ends that
    # walk somewhere useful; when the image relied on NODE_PATH instead, which
    # feeds the CommonJS resolver alone, the modern form failed everywhere
    # while this suite stayed green. What an agent got was ERR_MODULE_NOT_FOUND,
    # which reads as an image without a browser.
    #
    # Written somewhere with no node_modules of its own, because anywhere
    # inside a project with one would resolve for the wrong reason.
    dexec_node bash -c 'mkdir -p /tmp/esm-probe && cat > /tmp/esm-probe/probe.mjs <<'"'"'EOF'"'"'
import { chromium } from "playwright";
const browser = await chromium.launch({});
await browser.close();
console.log("ESM_IMPORT_OK");
EOF'
    run dexec_node node /tmp/esm-probe/probe.mjs
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"ESM_IMPORT_OK"* ]] || { echo "$output"; return 1; }
}

@test "the firewall applies to Playwright's browser traffic, not just curl/git" {
    # The whole point of pre-baking the browser at build time is that a
    # session never needs new network access for it - confirm the egress
    # allowlist actually governs what the browser itself can reach, the same
    # as every other tool in the container.
    dexec_node bash -c 'cat > /tmp/pw-firewall-test.js <<'"'"'EOF'"'"'
const { chromium } = require("playwright");
(async () => {
  const browser = await chromium.launch({});
  const page = await browser.newPage();
  try {
    await page.goto("http://example.com", { timeout: 5000 });
    console.log("REACHED_BLOCKED_DOMAIN");
  } catch (e) {
    console.log("BLOCKED_AS_EXPECTED");
  }
  await browser.close();
})();
EOF'
    run dexec_node node /tmp/pw-firewall-test.js
    [[ "$output" == *"BLOCKED_AS_EXPECTED"* ]]
    ! [[ "$output" == *"REACHED_BLOCKED_DOMAIN"* ]]
}

@test "empty ANTHROPIC_* env vars are unset before the session command runs" {
    # Compose always sends the pair (possibly empty); entrypoint.sh must
    # unset empties so a disabled proxy is indistinguishable from today.
    # The SESSION's environment, not PID 1's: `init: true` makes PID 1 an init
    # holding the environment Docker gave the container, which still has the
    # empty ANTHROPIC_* pair this is asserting the entrypoint unset.
    # Must read as -u node (matching dexec's convention below): once
    # entrypoint.sh's gosu drops privilege, the kernel clears that
    # process's dumpable flag, and root (docker exec's default, lacking
    # CAP_SYS_PTRACE here) can no longer read another uid's environ at
    # all - reading as the same uid the process actually runs as is what
    # every other environment read in this file already does.
    run docker exec -u node "$(container_name)" sh -c "tr '\0' '\n' < /proc/$(session_pid)/environ | grep -c '^ANTHROPIC' || true"
    [ "$output" = "0" ]
}

@test "loopback transport: 127.0.0.1 -> forwarder -> unix socket -> host proxy injects the real token" {
    TD="$BATS_TEST_TMPDIR"
    python3 "$BATS_TEST_DIRNAME/fixtures/fake-anthropic.py" > "$TD/port" &
    FAKE_PID=$!
    for _ in $(seq 1 50); do [ -s "$TD/port" ] && break; sleep 0.1; done
    cat > "$TD/credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"real-access-token","refreshToken":"r","expiresAt":$((($(date +%s) + 7200) * 1000)),"refreshTokenExpiresAt":$((($(date +%s) + 86400) * 1000)),"scopes":[],"subscriptionType":"max","rateLimitTier":"default"}}
EOF
    start_credential_proxy "$TD/proxy.sock" "$TD/credentials.json" \
        "http://127.0.0.1:$(cat "$TD/port")" \
        "http://127.0.0.1:$(cat "$TD/port")/v1/oauth/token"
    for _ in $(seq 1 50); do [ -S "$TD/proxy.sock" ] && break; sleep 0.1; done
    # UnixStreamServer binds at umask default, so the socket lands 755, and
    # connecting to a unix socket needs *write* permission on it. In the real
    # flow the connecting uid is the one that bound it, so that is fine;
    # under CI it is root binding and node connecting, and the whole chain
    # this test follows fails at its first hop. Widened rather than left to
    # dejima-credential-proxy, which has no such problem in production.
    # Unconditional: if the loop above timed out, "No such file" here says so
    # more clearly than a test that fails on a bare false condition.
    chmod 666 "$TD/proxy.sock"

    container="$(test_container_name proxy)"
    start_pair proxy "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e SANDBOX_CREDENTIAL_PROXY_SOCKET="$TD/proxy.sock" \
        -e SANDBOX_BACKEND_PROXIED_DOMAIN="$(backend_manifest_value proxied_domain)" \
        -e SANDBOX_CREDENTIAL_TRANSPORT=loopback \
        -e ANTHROPIC_AUTH_TOKEN=sandbox-credential-proxy-placeholder \
        -v "$TD:$TD"
    # This test depends on the forwarder having already bound port 18300.
    # start_pair's own wait covers it, since entrypoint.sh waits for the bind
    # before reaching the `sleep infinity` that wait_ready matches on.

    run docker exec "$container" node -e '
        fetch("http://127.0.0.1:18300/v1/messages", {method: "POST",
            headers: {authorization: "Bearer sandbox-credential-proxy-placeholder"},
            body: "{}"})
          .then(r => r.text()).then(t => { console.log(t); })
          .catch(e => { console.error(e); process.exit(1); })'
    status_chain=$status; output_chain=$output

    # the real token never appears in the container environment - read as
    # -u node, matching the test above: root can't see another uid's
    # environ once gosu has dropped privilege (dumpable flag cleared).
    run docker exec -u node "$container" sh -c "tr '\0' '\n' < /proc/$(session_pid "$container")/environ | grep -c real-access-token || true"
    env_hits=$output

    docker rm -f "$container" >/dev/null 2>&1 || true
    kill "$PROXY_PID" "$FAKE_PID" 2>/dev/null || true

    [ "$status_chain" -eq 0 ]
    [[ "$output_chain" == *'"authorization": "Bearer real-access-token"'* ]]
    [[ "$output_chain" != *"sandbox-credential-proxy-placeholder"* ]]
    [ "$env_hits" = "0" ]
}

@test "the real credential never enters the container, and a host-side refresh can't change that (#50)" {
    # Unlike the proxy-chain test above (which hand-builds a docker run to
    # exercise the proxy's HTTP path), this test reuses the mount shape
    # bin/dejima itself launches with: ~/.claude is not mounted, only the
    # enumerated directories inside it are, and .credentials.json is not one
    # of them. Claude Code still finds a credentials file, because
    # entrypoint.sh creates an empty container-local one.
    #
    # The second half is the regression this test previously lacked, and #50
    # is what walked through the gap. The old shape mounted ~/.claude
    # read-write with an empty file layered over .credentials.json, and
    # asserting only at startup made that look airtight. But a single-file
    # bind mount is pinned to the dentry at its mount point: the first
    # host-side atomic replace - which is exactly how the proxy writes a
    # rotated token back, and how host-side Claude Code writes it too -
    # unlinked that dentry, the mask silently detached, and the path fell
    # through to the operator's real, current token. So replace the host
    # file the way a refresh does, and assert again afterwards.
    TD="$BATS_TEST_TMPDIR"
    mkdir -p "$TD/dotclaude/projects" "$TD/dotclaude/plans"
    write_creds() {
        cat > "$1" <<EOF
{"claudeAiOauth":{"accessToken":"real-access-token","refreshToken":"real-refresh-token","expiresAt":$((($(date +%s) + 7200) * 1000)),"refreshTokenExpiresAt":$((($(date +%s) + 86400) * 1000)),"scopes":[],"subscriptionType":"max","rateLimitTier":"default"}}
EOF
    }
    write_creds "$TD/dotclaude/.credentials.json"
    chmod 666 "$TD/dotclaude/.credentials.json"
    chmod -R 777 "$TD/dotclaude"

    container="$(test_container_name proxy-mask)"
    start_pair proxy-mask "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -v "$TD/dotclaude/projects:/home/node/.claude/projects" \
        -v "$TD/dotclaude/plans:/home/node/.claude/plans"

    run docker exec -u node "$container" cat /home/node/.claude/.credentials.json
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run docker exec -u node "$container" grep -rl real-access-token /home/node/.claude
    [ "$status" -ne 0 ]

    # A token refresh, as os.replace() performs it: write a sibling temp file
    # and rename it over the credential.
    write_creds "$TD/dotclaude/.credentials.json.new"
    chmod 666 "$TD/dotclaude/.credentials.json.new"
    mv -f "$TD/dotclaude/.credentials.json.new" "$TD/dotclaude/.credentials.json"

    run docker exec -u node "$container" cat /home/node/.claude/.credentials.json
    status_creds=$status; output_creds=$output
    run docker exec -u node "$container" grep -rl real-access-token /home/node/.claude
    status_grep=$status

    docker rm -f "$container" >/dev/null 2>&1 || true

    [ "$status_creds" -eq 0 ]
    [ -z "$output_creds" ]
    [ "$status_grep" -ne 0 ]
}


@test "a domain added mid-session gets ongoing tracking, not a one-time snapshot" {
    # The container-side half of bin/dejima-allow, run the way it really runs.
    # `permit` records the entry, regenerates the resolver configuration and
    # restarts it, then proves the address reached the set its class uses -
    # so if this returns 0 the wiring held end to end.
    run dexec_filter /usr/local/sbin/egress-policy permit example.org
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    local ip
    ip=$(dexec dig +short A example.org | grep -Em1 '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$ip" ]
    dexec_filter nft get element inet egress_policy oname_v4 "{ $ip }"

    # Simulate a CDN edge rotating away and back: drop the address, clear the
    # resolver's cache, resolve again - it must be re-added with no further
    # dejima-allow involvement. This is exactly the case that used to break
    # ("allowed but blocked again minutes later").
    dexec_filter nft delete element inet egress_policy oname_v4 "{ $ip }"
    dexec_filter bash -c 'kill -HUP "$(cat /run/egress-policy/resolver.pid)"'
    sleep 0.5
    local ip2
    ip2=$(dexec dig +short A example.org | grep -Em1 '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    sleep 0.5
    [ -n "$ip2" ]
    dexec_filter nft get element inet egress_policy oname_v4 "{ $ip2 }"
}

@test "adding a domain twice says so rather than changing its class" {
    # Whatever resolved under the old class stays in the allow-list until it
    # ages out, so a move to a narrower class would leave the wider permission
    # standing - which is worse than refusing, because the command would report
    # a restriction it had not applied.
    dexec_filter /usr/local/sbin/egress-policy permit example.org >/dev/null 2>&1 || true
    run dexec_filter /usr/local/sbin/egress-policy permit example.org
    [ "$status" -eq 0 ]
    [[ "$output" == *"already permitted"* ]]

    run dexec_filter /usr/local/sbin/egress-policy permit example.org --forge
    [ "$status" -ne 0 ] \
        || { echo "the class of a live entry was changed: $output"; return 1; }
    [[ "$output" == *"Restart the session"* ]] \
        || { echo "refused without naming what to do instead: $output"; return 1; }
}


@test "github resolutions land only in the forge class, never the port-unrestricted one" {
    # The resolver writes an answer into the set its entry's CLASS names, and
    # a name under a forge suffix is forge class however it was permitted. That
    # is what keeps GitHub restricted to 443 - read-only, with SSH push
    # physically unreachable - rather than the restriction depending on which
    # code path happened to add the address.
    local ip
    ip=$(dexec dig +short A github.com | grep -Em1 '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$ip" ]
    run dexec_filter nft get element inet egress_policy oname_v4 "{ $ip }"
    [ "$status" -ne 0 ] \
        || { echo "a github address reached the port-unrestricted class"; return 1; }
    dexec_filter nft get element inet egress_policy fname_v4 "{ $ip }"
}

@test "nvim falls back to the sandbox OSC 52 clipboard provider" {
    # nvim 0.11+'s OSC 52 auto-detection needs a DA1/XTGETTCAP terminal
    # handshake that never completes through the docker tty, leaving
    # "clipboard: No provider" for any config without its own provider.
    run dexec_node nvim --headless "+lua io.stdout:write(vim.g.clipboard and vim.g.clipboard.name or 'unset')" "+q"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sandbox-osc52"* ]]
}

@test "a user-configured clipboard provider beats the sandbox fallback" {
    # --cmd runs before plugins, standing in for a user config that sets
    # g:clipboard (e.g. dotfiles' clipboard-copy via SANDBOX_EXTRA_MOUNTS).
    run dexec_node nvim --headless \
        --cmd "lua vim.g.clipboard = {name = 'user-provider', copy = {}, paste = {}}" \
        "+lua io.stdout:write(vim.g.clipboard.name)" "+q"
    [ "$status" -eq 0 ]
    [[ "$output" == *"user-provider"* ]]
    [[ "$output" != *"sandbox-osc52"* ]]
}

@test "session context reports declared-but-missing project requirements" {
    local ws; ws="$(mktemp -d)"
    mkdir -p "$ws/.dejima"
    printf 'apt:definitely-not-installed\n' > "$ws/.dejima/dependencies"
    printf 'declared-not-allowed.example\n' > "$ws/.dejima/allowed-domains"
    chmod -R 755 "$ws"

    # Mounted from a copy, not straight out of the checkout. Whatever daemon
    # starts this container resolves -v sources against its own host, and
    # under CI the checkout lives in a volume that has no host path at all -
    # so the repo copy would mount as an empty directory rather than fail.
    # $BATS_TEST_TMPDIR sits under TMPDIR, which CI points somewhere shared.
    local hook="$BATS_TEST_TMPDIR/sandbox-context.sh"
    cp "$BATS_TEST_DIRNAME/../hooks/sandbox-context.sh" "$hook"

    local test_container="$(test_container_name ctxreq)"
    start_pair ctxreq "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -v "$ws:$ws" \
        -v "$hook:/usr/local/bin/sandbox-context.sh:ro"

    # -w is deliberately an unrelated directory, not "$ws": if cwd extraction
    # from the payload broke and silently fell back to $PWD, running with
    # -w "$ws" would still find the declarations and pass regardless.
    run docker exec -u node -w /tmp "$test_container" \
        bash -c 'printf "{\"session_id\":\"s1\",\"cwd\":\"'"$ws"'\"}" | DEJIMA=1 /usr/local/bin/sandbox-context.sh'
    [ "$status" -eq 0 ]
    [[ "$output" == *"definitely-not-installed"* ]]
    [[ "$output" == *"declared-not-allowed.example"* ]]
    [[ "$output" == *"dejima-project approve"* ]]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$ws"
}

@test "a derived project image gets the package and keeps the base privilege posture" {
    local derived="localhost/dejima-test-derived:$(basename "$BATS_RUN_TMPDIR")"
    local test_container="$(test_container_name derived)"
    local ctx; ctx="$(mktemp -d)"
    local store; store="$(mktemp -d)"
    local df; df="$(mktemp)"
    printf 'apt:cowsay\n' > "$store/dependencies"

    # The positive control, and it is load-bearing: this test proves the
    # derived layer installed cowsay by finding cowsay installed. If the base
    # image already carried it, the assertion below would pass with
    # generate_derived_dockerfile doing nothing at all. Checked here rather
    # than assumed, because "the base image gained a package" is a change
    # nobody would connect to this file.
    run docker run --rm --entrypoint dpkg-query "$IMAGE" -W -f='${Status}' cowsay
    [[ "$output" != *"install ok installed"* ]] || {
        echo "cowsay is in the base image, so this test cannot detect a broken derived build" >&2
        false
    }
    bash -c 'source "$1"; generate_derived_dockerfile "$2" "$3"' \
        _ "$BATS_TEST_DIRNAME/../bin/dejima-project-lib.sh" "$SESSION_IMAGE" "$store" > "$df"
    docker build -q -t "$derived" -f "$df" "$ctx" >&2

    # The image's own config, not the running container: `docker run` below
    # passes --entrypoint explicitly (this file's convention), which would
    # override the image's ENTRYPOINT and mask its absence - so that run
    # succeeding doesn't prove generate_derived_dockerfile's own ENTRYPOINT
    # line survived. Checked here, straight off the build.
    run docker inspect -f '{{json .Config.Entrypoint}}' "$derived"
    [[ "$output" == *"/usr/local/bin/entrypoint.sh"* ]]

    start_pair derived "$derived" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}"

    run docker exec "$test_container" dpkg-query -W -f='${Status}' cowsay
    [[ "$output" == *"install ok installed"* ]]

    # the hardening assertions that matter must hold on a derived image too.
    # `run !` for sudo, matching "node has no working sudo" above: it exits
    # 127 rather than a permission error, since sudo isn't installed at all.
    run ! docker exec -u node "$test_container" sudo -n true
    run docker exec -u node "$test_container" nft list ruleset
    [ "$status" -ne 0 ]
    # And the sweep the base image ends with ran again over what this layer
    # installed: a derived image is where a dependency shipping a setuid
    # binary would land, after the base image had already finished checking.
    run docker exec "$test_container" sh -c 'find / -xdev -type f -perm /6000 2>/dev/null'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "setuid binaries in the derived image:"; echo "$output"; return 1; }

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    docker rmi "$derived" >/dev/null 2>&1 || true
    rm -rf "$ctx" "$store" "$df"
}

@test "live end-to-end: claude -p through the real proxy (RUN_LIVE_API=1 only)" {
    [ "${RUN_LIVE_API:-0}" = "1" ] || skip "set RUN_LIVE_API=1 to hit the real API"
    TD="$BATS_TEST_TMPDIR"
    start_credential_proxy "$TD/proxy.sock" "$HOME/.claude/.credentials.json" \
        "https://api.anthropic.com" \
        "https://platform.claude.com/v1/oauth/token"
    for _ in $(seq 1 50); do [ -S "$TD/proxy.sock" ] && break; sleep 0.1; done
    SANDBOX_CREDENTIAL_PROXY_SOCKET="$TD/proxy.sock" SANDBOX_CREDENTIAL_PROXY_PORT=18399 \
        SANDBOX_CREDENTIAL_TRANSPORT=loopback \
        node "$BATS_TEST_DIRNAME/../docker/credential-proxy-forwarder.js" &
    FWD_PID=$!
    sleep 0.5
    run env ANTHROPIC_BASE_URL=http://127.0.0.1:18399 \
        ANTHROPIC_AUTH_TOKEN=sandbox-credential-proxy-placeholder \
        claude -p 'Reply with exactly: proxy-ok'
    kill "$PROXY_PID" "$FWD_PID" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"proxy-ok"* ]]
}

# Starts a host-side TCP listener bound to $1, waits until it accepts a
# connection, and leaves its port in HOST_LISTENER_PORT. Binding port 0 and
# reading the port back (the same trick fixtures/fake-anthropic.py uses) is
# what keeps the test below honest: the kernel only hands out a port nothing
# else holds, so whatever answers is provably this listener and not some
# unrelated service that happened to own a hardcoded number. The handler has
# no do_* methods, so it serves nothing at all - only the accept() matters,
# and the gateway-bound instance is briefly reachable by every container on
# this host's bridge. Called plainly, never in a command substitution: it has
# to append to HOST_LISTENER_PIDS in the caller's shell for teardown to see it.
start_host_listener() {
    local bind_addr="$1" port_file="$BATS_TEST_TMPDIR/listener-port-$1"
    python3 -c 'import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
s = ThreadingHTTPServer((sys.argv[1], 0), BaseHTTPRequestHandler)
print(s.server_address[1], flush=True)
s.serve_forever()' "$bind_addr" > "$port_file" 2>/dev/null &
    HOST_LISTENER_PIDS="${HOST_LISTENER_PIDS:-} $!"

    for _ in $(seq 1 50); do [ -s "$port_file" ] && break; sleep 0.1; done
    HOST_LISTENER_PORT="$(cat "$port_file")"
    [ -n "$HOST_LISTENER_PORT" ]
    timeout 5 bash -c "cat < /dev/null > /dev/tcp/$bind_addr/$HOST_LISTENER_PORT"
}

@test "the host is unreachable on every port by default, and on exactly the ports EGRESS_HOST_PORTS names" {
    # The regression test for the escape path bin/dejima-ttyd's
    # --interface 127.0.0.1 exists to close, now one layer stronger. The host
    # entry used to be accepted on every port, so a ttyd bound to 0.0.0.0 - and
    # a tmux client attached through ttyd is a host shell, the prefix key opens
    # a window outside the container - was reachable from the session. It now
    # opens only the ports it was told to (#363).
    local container host_ip loopback_port named_port other_port
    local test_container="$(test_container_name hostports)"
    container="$(container_name)"

    # Derived exactly as the egress policy derives the host address, so this is
    # the one host address the container's OUTPUT chain names at all.
    host_ip="$(docker exec "$container" sh -c "ip route | grep default | cut -d' ' -f3")"
    [ -n "$host_ip" ]

    start_host_listener 127.0.0.1
    loopback_port="$HOST_LISTENER_PORT"
    start_host_listener "$host_ip"
    named_port="$HOST_LISTENER_PORT"
    start_host_listener "$host_ip"
    other_port="$HOST_LISTENER_PORT"

    # Setup check, from the host's own vantage point: the loopback listener's
    # port must answer on 127.0.0.1 only. bind(0) on two different addresses
    # can legally return the same port number, and if it had, the container
    # probes below would be hitting a gateway listener and failing for a reason
    # that has nothing to do with containment.
    run timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host_ip/$loopback_port"
    [ "$status" -ne 0 ]

    # The default, on the file-wide pair, which sets no EGRESS_HOST_PORTS: a
    # real listener on the gateway address, and the session cannot reach it.
    run docker exec "$container" timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host_ip/$named_port"
    [ "$status" -ne 0 ]

    # A pair told to open that one port, and nothing else about it changed.
    start_pair hostports "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e EGRESS_HOST_PORTS="$named_port"

    # Positive control, and the reason the negatives mean anything: without it
    # a `status -ne 0` is equally satisfied by docker exec failing (125), bash
    # or timeout missing from the image (127), or a container that can reach
    # nothing at all, none of which say anything about the clamp.
    run docker exec "$test_container" timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host_ip/$named_port"
    [ "$status" -eq 0 ]

    # The clamp itself: same container, same address, same kind of listener,
    # only the port differs from the one above.
    run docker exec "$test_container" timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host_ip/$other_port"
    [ "$status" -ne 0 ]

    # And the original containment property, which the clamp does not replace:
    # a host service bound to loopback is not on the gateway address at all.
    #
    # Deliberately not asserting the exact status on any of the negatives. 1
    # (the host RSTs) is what a refusal should look like, but a drop yields 124
    # from timeout, and that is still containment.
    run docker exec "$test_container" timeout 5 bash -c "cat < /dev/null > /dev/tcp/$host_ip/$loopback_port"
    [ "$status" -ne 0 ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
}



@test "a session port bound to every interface is still unreachable from the bridge" {
    # The other direction, and the one a filter with only an output hook lets
    # through: a session process that binds 0.0.0.0 - by accident, or because a
    # dev server defaults to it - would be reachable from anything sharing the
    # bridge. The launch puts each pair on a network of its own, so today there
    # is nothing else on it; that is a property of the launcher and this is the
    # filter's own answer.
    #
    # Bound in the SESSION container and dialled from a third container on the
    # same network, which is the shape of the exposure - the two share a
    # namespace, so the listener answers at the address the pair holds on that
    # network. Loopback has to keep working throughout, since the resolver and
    # the credential forwarder both listen there, so it is probed on the way
    # past.
    local addr
    addr=$(docker inspect -f \
        '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(filter_name)")
    [ -n "$addr" ] || { echo "could not find the pair's address on its network"; return 1; }

    # Its pid is recorded rather than matched later. `pkill -f "http.server
    # 8099"` matches the command line of the shell running pkill, so it kills
    # itself, the exec comes back 143, and bats stops the test there - which it
    # did, before either assertion below had run.
    dexec_node bash -c \
        'nohup python3 -m http.server 8099 --bind 0.0.0.0 >/dev/null 2>&1 &
         echo $! > /tmp/probe-8099.pid
         sleep 1'

    # Both probes run before anything is asserted, and the listener is stopped
    # before that - a leaked one would sit in the shared container for every
    # test after this, and a cleanup that can fail must not be what decides
    # whether this test passes.
    local from_lo from_bridge
    docker exec -u node "$(container_name)" bash -c 'exec 3<>/dev/tcp/127.0.0.1/8099' \
        >/dev/null 2>&1 && from_lo=0 || from_lo=$?
    docker run --rm \
        --network "$(network_name)" \
        --entrypoint bash "$SESSION_IMAGE" \
        -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$addr/8099'" >/dev/null 2>&1 \
        && from_bridge=0 || from_bridge=$?
    dexec_node bash -c \
        'kill "$(cat /tmp/probe-8099.pid)" 2>/dev/null; rm -f /tmp/probe-8099.pid; true' || true

    # It really was listening, or the refusal below proves nothing.
    [ "$from_lo" -eq 0 ] \
        || { echo "the probe server is not up on loopback, so this test cannot tell"; return 1; }
    [ "$from_bridge" -ne 0 ] \
        || { echo "a session port bound to 0.0.0.0 was reachable from the bridge"; return 1; }

    # And it is actually gone, so the next test does not inherit it.
    run docker exec -u node "$(container_name)" bash -c 'exec 3<>/dev/tcp/127.0.0.1/8099'
    [ "$status" -ne 0 ] \
        || { echo "the probe listener survived the test"; return 1; }
}

@test "tls transport: https://api.anthropic.com from inside the container reaches the host proxy" {
    TD="$BATS_TEST_TMPDIR"
    python3 "$BATS_TEST_DIRNAME/fixtures/fake-anthropic.py" > "$TD/port" &
    FAKE_PID=$!
    for _ in $(seq 1 50); do [ -s "$TD/port" ] && break; sleep 0.1; done
    cat > "$TD/credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"real-access-token","refreshToken":"r","expiresAt":$((($(date +%s) + 7200) * 1000)),"refreshTokenExpiresAt":$((($(date +%s) + 86400) * 1000)),"scopes":[],"subscriptionType":"max","rateLimitTier":"default"}}
EOF
    start_credential_proxy "$TD/proxy.sock" "$TD/credentials.json" \
        "http://127.0.0.1:$(cat "$TD/port")" \
        "http://127.0.0.1:$(cat "$TD/port")/v1/oauth/token"
    for _ in $(seq 1 50); do [ -S "$TD/proxy.sock" ] && break; sleep 0.1; done
    # See the loopback test above for why this chmod is here.
    chmod 666 "$TD/proxy.sock"

    container="$(test_container_name tls)"
    # No ANTHROPIC_* env at all - that absence is the thing under test.
    start_pair tls "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e SANDBOX_CREDENTIAL_PROXY_SOCKET="$TD/proxy.sock" \
        -e SANDBOX_BACKEND_PROXIED_DOMAIN="$(backend_manifest_value proxied_domain)" \
        -v "$TD:$TD"

    # NODE_EXTRA_CA_CERTS has to be passed explicitly: docker exec starts from
    # the image's ENV, not from the entrypoint process's exported environment.
    # The session command itself is a child of the entrypoint and does inherit
    # it - which is what the environment check below confirms.
    run docker exec -e NODE_EXTRA_CA_CERTS=/etc/dejima-credential-tls/cert.pem \
        "$container" node -e '
        fetch("https://api.anthropic.com/v1/messages", {method: "POST", body: "{}"})
          .then(r => r.text()).then(t => { console.log(t); })
          .catch(e => { console.error(e); process.exit(1); })'
    status_tls=$status; output_tls=$output

    run docker exec -u node "$container" sh -c "tr '\0' '\n' < /proc/$(session_pid "$container")/environ | grep -c '^ANTHROPIC' || true"
    env_anthropic=$output
    run docker exec -u node "$container" sh -c "tr '\0' '\n' < /proc/$(session_pid "$container")/environ | grep -c NODE_EXTRA_CA_CERTS || true"
    env_ca=$output
    run docker exec -u node "$container" sh -c "tr '\0' '\n' < /proc/$(session_pid "$container")/environ | grep -c real-access-token || true"
    env_token=$output
    run docker exec "$container" grep -c '127.0.0.1 api.anthropic.com' /etc/hosts
    hosts_hits=$output
    # /etc/hosts resolves the name locally, but that only wins inside
    # getaddrinfo - the DNS proxy itself must still refuse it, same as any
    # other name that isn't on the allowlist (see the DNS-proxy test above),
    # so a bypass of the pin that looks the name up by DNS gets no address.
    # It is not a route check: the API's address stays reachable as an IP
    # literal for as long as allowlisted platform.claude.com resolves to it.
    run docker exec "$container" dig api.anthropic.com
    dig_output=$output

    docker rm -f "$container" >/dev/null 2>&1 || true
    kill "$PROXY_PID" "$FAKE_PID" 2>/dev/null || true

    [ "$status_tls" -eq 0 ]
    # The client sent no Authorization header; the host proxy supplied one.
    [[ "$output_tls" == *'"authorization": "Bearer real-access-token"'* ]]
    # Both fingerprints are gone: no base URL, no placeholder token...
    [ "$env_anthropic" = "0" ]
    # ...while the trust anchor the session actually needs did get inherited.
    [ "$env_ca" = "1" ]
    [ "$env_token" = "0" ]
    [ "$hosts_hits" = "1" ]
    # NXDOMAIN or REFUSED: the resolver answers for permitted names and refuses
    # everything else, and which of the two it says is a property of how the
    # refusal is expressed rather than of whether the name is permitted. What
    # matters here is that a lookup of this name yields no address.
    [[ "$dig_output" == *"status: NXDOMAIN"* || "$dig_output" == *"status: REFUSED"* ]] \
        || { echo "api.anthropic.com resolved despite not being permitted: $dig_output"; return 1; }
}

@test "the kill switch leaves api.anthropic.com unpinned, so the real API stays reachable" {
    # SANDBOX_CREDENTIAL_PROXY=0 mounts the real credential and starts no
    # forwarder. If the hosts entry were unconditional (a compose extra_hosts
    # entry, say), this container would send every API call into a loopback
    # port nothing is listening on.
    container="$(test_container_name nohosts)"
    start_pair nohosts "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}"

    run docker exec "$container" grep -c 'api.anthropic.com' /etc/hosts
    hosts_hits=$output

    docker rm -f "$container" >/dev/null 2>&1 || true

    [ "$hosts_hits" = "0" ]
}

@test "an unrecognised transport aborts the container instead of half-configuring it" {
    # `Loopback` is not `loopback`: bin/dejima would take its tls branch while
    # this container took its loopback one, and every API call in the session
    # would fail with nothing naming the cause.
    container="$(test_container_name badtransport)"
    docker rm -f "$container" >/dev/null 2>&1 || true

    # Run in the FOREGROUND and read the container's own streams, rather than
    # detaching and asking the daemon's log driver for them afterwards.
    #
    # The detached form spent six CI rounds insisting this container aborted
    # partway through the egress policy. It had not. Every line those logs ever
    # contained came from an `echo` to stdout, and not one line written to
    # stderr appeared in any of them - not the policy's ERR trap, not
    # resolve_domain's per-attempt reports, and not the FATAL message this test
    # asserts on, which entrypoint.sh writes to stderr as well. The container
    # was doing the right thing; the stderr half of what it said was not
    # arriving.
    #
    # A foreground `docker run` attaches to the container's streams directly,
    # so nothing is buffered, flushed or dropped by a log driver in between.
    # It is also simply less machinery: one command yields both the output and
    # the exit status, with no wait, no settling and no read-after-exit race.
    #
    # The timeout stays: without the transport check the entrypoint runs on
    # into SANDBOX_TEST_MODE's `sleep infinity` and never exits, and that
    # regression should fail here rather than hang the suite.
    # Deliberately NOT start_pair, and deliberately no filter container: this
    # container is meant to abort at the transport check, which sits well
    # before anything needs a network. Pairing it would only add a second
    # container to wait for and then tear down.
    #
    # SETPCAP is named rather than left to Docker's default set, which happens
    # to include it. The entrypoint refuses to start without it, so leaving it
    # implicit would make a change to those defaults present as this test's
    # subject failing rather than as its precondition being gone.
    run timeout 120 docker run --name "$container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SETPCAP \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e SANDBOX_CREDENTIAL_TRANSPORT=Loopback \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$SESSION_IMAGE"
    exit_code=$status
    logs=$output

    # Still worth capturing: it answers what the output cannot - whether the
    # script exited or the container was killed underneath it.
    state=$(docker inspect \
        --format 'exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{printf "%q" .State.Error}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' \
        "$container" 2>&1 || true)

    docker rm -f "$container" >/dev/null 2>&1 || true

    # Every assertion prints what it was reading. bats prints the failing
    # expression, not the variable, and the container is gone by then - so
    # without this the whole failure is "the container did not say what we
    # expected", which is equally true when the container aborted early, when
    # it was killed, and when its output never reached us. Those took six CI
    # rounds to tell apart (#59); the byte count and the state are what
    # separate them.
    dump() {
        echo "$1" >&2
        echo "exit code: $exit_code" >&2
        echo "container state: $state" >&2
        echo "container output (${#logs} bytes):" >&2
        echo "$logs" >&2
        false
    }

    [ "$exit_code" = "1" ] || dump "expected the container to exit 1"
    [[ "$logs" == *"SANDBOX_CREDENTIAL_TRANSPORT is set to 'Loopback'"* ]] \
        || dump "the transport check never ran - something aborted the entrypoint before it"
    [[ "$logs" == *"'tls'"* ]] || dump "the refusal did not name the valid values"
    [[ "$logs" == *"'loopback'"* ]] || dump "the refusal did not name the valid values"
}

# The three-symptom failure entrypoint.sh's marker-directory check exists to
# name: notifications stop, the session vanishes from dejima-attach, and the
# notify hook reports EACCES - with no obvious moment they started.
#
# It is Docker's answer to a missing bind source that produces it. bin/dejima
# creates the marker directory per launch and removes it on exit, so a
# container that is RESTARTED rather than relaunched has no source left, and
# Docker creates one root-owned rather than refusing. The directory then
# exists, so the hook's own `[ -d ]` guard passes and the write fails instead.
@test "a marker directory the sandbox user cannot write is reported at startup" {
    # Its own container, not container_name() - that one is created in
    # setup_file and used by every dexec test in this file. Starting a second
    # container under that name conflicts, and removing it at the end of this
    # body would take the shared one with it.
    local container="$(test_container_name notifydir)"
    local host_dir; host_dir="$(mktemp -d)"
    # Unwritable by the sandbox user, which is the property the check keys on.
    # Built here rather than by removing a bind source, so the test does not
    # depend on Docker's fallback behaviour to set up a test OF the
    # consequences of that behaviour.
    #
    # chmod rather than mounting :ro. A read-only mount would make the
    # "not repaired" assertion below vacuous - root could not chown it even
    # if entrypoint.sh tried. Mode 555 leaves it repairable by root inside the
    # container and still unwritable by the session user, so that assertion
    # means something.
    chmod 555 "$host_dir"

    start_pair notifydir "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}" \
        -e DEJIMA_NOTIFY_DIR=/run/dejima-notify \
        -v "$host_dir:/run/dejima-notify"

    run settled_logs "$container"
    [[ "$output" == *"not writable by"* ]]
    [[ "$output" == *"RESTARTED rather than"* ]]
    # Reported, not repaired: chowning would restore notifications while the
    # session stayed absent from a registry this container never sees.
    #
    # Asserted as "still not writable by the session user" rather than "still
    # owned by root": ownership depends on who ran the suite, since mktemp -d
    # follows the caller, while writability is the property the check reads
    # and the one repairing it would change.
    run docker exec -u node "$container" test -w /run/dejima-notify
    [ "$status" -ne 0 ]

    rm -rf "$host_dir"
}

# Remote access is opt-in and off by default. The check above must say nothing
# at all for the sessions that never asked for it, which is every session by
# default - a warning about an unconfigured optional feature is noise on every
# start, and noise is what stops warnings being read.
@test "no marker-directory warning when remote access is not enabled" {
    local container="$(test_container_name nonotify)"
    start_pair nonotify "$SESSION_IMAGE" \
        -e SANDBOX_TEST_MODE=1 \
        -e GH_TOKEN="${GH_TOKEN:-}"

    run settled_logs "$container"
    [[ "$output" != *"dejima-notify"* ]]
    [[ "$output" != *"remote access is enabled"* ]]
}

@test "an isolated launch's working directory is a volume the session user owns" {
    # The one thing about --isolated that a confined test cannot decide: that
    # the directory the launcher points a session at is usable. A volume at a
    # path the image created is seeded from it, ownership included, and if
    # that did not hold the session would start in a directory root owns and
    # fail on its first write.
    #
    # The volume is named for the run by bin/dejima and removed in its exit
    # trap, both of which the confined suite checks against the launcher. So
    # this does not re-check the reaping, and deliberately does not count the
    # host's volumes before and after: another job on a shared runner creating
    # one between the two reads would fail a test about something else
    # entirely.
    local vol="dejima-test-work-$(basename "$BATS_RUN_TMPDIR")"
    docker volume create "$vol" >/dev/null

    run docker run --rm -v "$vol:/dejima/work" --entrypoint sh "$SESSION_IMAGE" -c \
        'cd /dejima/work && touch marker && stat -c "%U" /dejima/work'
    if [ "$status" -ne 0 ] || [ "$output" != node ]; then
        docker volume rm "$vol" >/dev/null 2>&1 || true
        echo "the working directory is not writable by the session user: $output"
        return 1
    fi

    # And nothing of the host is behind it, which is the claim the mode rests
    # on: a second volume at the same path starts empty rather than carrying
    # what the first container wrote.
    local other="$vol-second"
    docker volume create "$other" >/dev/null
    run docker run --rm -v "$other:/dejima/work" --entrypoint sh "$SESSION_IMAGE" -c \
        'ls -A /dejima/work'
    local rc="$status" out="$output"
    docker volume rm "$vol" "$other" >/dev/null 2>&1 || true
    [ "$rc" -eq 0 ] || { echo "$out"; return 1; }
    [ -z "$out" ] \
        || { echo "a second session's working directory was not empty: $out"; return 1; }
}

@test "the git shadow loads its policy in the image, and leaves other git commands alone" {
    # The decision lives in a file the Dockerfile copies in
    # (docker/guard-lib.sh), and every git command in a session goes through
    # the shadow that sources it - so a COPY line that stopped matching the
    # path would break git outright, in every session, and nothing in the
    # confined suites would notice: they point the guards at the checkout.
    #
    # The file-wide pair sets no DEJIMA_PUSH_HOSTS, which fails closed, so any
    # push is refused. Which refusal does not matter; that the guard is the one
    # speaking does.
    run dexec bash -c 'cd /tmp && git init -q -b feature r && cd r && git push origin feature'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Blocked by dejima's git guard"* ]] \
        || { echo "the shadow did not reach its policy: $output"; return 1; }
    [[ "$output" != *"No such file"* ]] \
        || { echo "the shadow could not load the policy file: $output"; return 1; }

    # And the pass-through path: everything that is not a push has to reach
    # real git, or the shadow is a broken git rather than a guarded one.
    run dexec git --version
    [ "$status" -eq 0 ]
    [[ "$output" == git\ version* ]] || { echo "$output"; return 1; }
}
