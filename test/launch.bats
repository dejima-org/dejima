#!/usr/bin/env bats
# How a launch is arranged: the containers it starts, in what order, on what
# network, and what it takes down again.
#
# The subject is bin/dejima's side of the filter container - the extra
# container per launch that owns the network namespace and the packet filter,
# which the sandbox joins and has no capability to alter. Whether the filter
# actually filters is runtime.bats's question and needs a real Docker; whether
# the launcher builds the arrangement that puts one there is this file's, and
# needs only a stub.
#
# Everything here runs against a `docker` that records its argv and exits 0, so
# a launch completes without a daemon. That makes the ORDER of the calls, and
# the flags on each, the thing being asserted.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    SANDBOX_DIR="$REPO_ROOT/docker"
    LIB="$REPO_ROOT/bin/dejima-project-lib.sh"
    CONFIG_DIR="$(mktemp -d)"
    RUNTIME_DIR="$(mktemp -d)"
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR"
    export XDG_RUNTIME_DIR="$RUNTIME_DIR"
}

teardown() {
    rm -rf "$CONFIG_DIR" "$RUNTIME_DIR" ${LAUNCH_DIR:+"$LAUNCH_DIR"} ${PROJ:+"$PROJ"}
}

# A `docker` that logs one line per invocation and succeeds at everything,
# including the readiness probe. Tests that need a failure override it.
stub_launch() {
    LAUNCH_DIR="$(mktemp -d)"
    mkdir -p "$LAUNCH_DIR/home/.claude"
    echo '{}' > "$LAUNCH_DIR/home/.claude/settings.json"
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
# `docker run -e NAME` carries the value in the environment rather than on the
# command line, so the log above cannot show whether a flag had anything behind
# it. Record what this process inherited, which is the same thing the flag
# would forward. GH_TOKEN is deliberately not among them: it is a real
# credential on a developer's machine and there is no reason to write one to
# disk to test an unrelated variable.
case "$*" in
    "run -d --init"*)
        env | grep -E '^(DEJIMA_|ALLOWED_DOMAINS=|ENABLE_FIREWALL=|ALLOW_GITHUB_PUSH=|LOKI_URL=|SANDBOX_)' \
            > "${SANDBOX_TEST_FILTER_ENV:-/dev/null}" || true
        ;;
esac
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
    : > "$LAUNCH_DIR/sandbox-key"
    chmod 600 "$LAUNCH_DIR/sandbox-key"
    PROJ="$(mktemp -d)"
}

launch() {
    local conf
    conf="$(bash -c 'source "$1"; config_path' _ "$LIB")"
    mkdir -p "$(dirname "$conf")"
    printf '[core]\nharness = claude-code\nupdate_check = off\nssh_key = %s\n' \
        "$LAUNCH_DIR/sandbox-key" >> "$conf"
    HOME="$LAUNCH_DIR/home" PATH="$LAUNCH_DIR:$PATH" \
        SANDBOX_TEST_DOCKER_LOG="$LAUNCH_DIR/docker-log" \
        SANDBOX_TEST_FILTER_ENV="$LAUNCH_DIR/filter-env" \
        SSH_AUTH_SOCK= ALLOWED_DOMAINS= \
        "${DEJIMA_BIN:-$REPO_ROOT/bin/dejima}" "$@"
}

log_line() { grep -- "$1" "$LAUNCH_DIR/docker-log" | tail -1; }
# 1-indexed position of the last line matching a pattern, for ordering claims.
log_pos() { grep -n -- "$1" "$LAUNCH_DIR/docker-log" | tail -1 | cut -d: -f1; }

@test "a launch creates a network of its own and a filter container on it" {
    stub_launch
    launch "$PROJ"

    local net; net="$(log_line 'network create')"
    [ -n "$net" ] || { echo "no network was created"; return 1; }
    [[ "$net" =~ dejima-run-[0-9a-f]{16} ]] \
        || { echo "the network is not named for this run: $net"; return 1; }
    [[ "$net" == *"--label dejima.run="* ]] \
        || { echo "the network carries no run label, so nothing can reconcile it: $net"; return 1; }

    local run; run="$(log_line 'run -d --init')"
    [ -n "$run" ] || { echo "no filter container was started"; return 1; }
    [[ "$run" =~ --name\ dejima-filter-[0-9a-f]{16} ]] \
        || { echo "the filter container is not named for this run: $run"; return 1; }
    [[ "$run" == *"--entrypoint /usr/local/bin/filter-entrypoint.sh"* ]] \
        || { echo "the filter container does not run the filter entrypoint: $run"; return 1; }

    # One network per launch, and the filter container on that one - not on
    # whatever bridge Docker would have picked. The restricted resolver forwards to the
    # embedded resolver at 127.0.0.11, which only exists on a user-defined
    # network, so this is load-bearing rather than tidiness.
    local id; id="$(sed -E 's/.*dejima-run-([0-9a-f]{16}).*/\1/' <<< "$net")"
    [[ "$run" == *"--network dejima-run-$id"* ]] \
        || { echo "the filter container is not on this launch's network: $run"; return 1; }
}

@test "the sandbox joins the filter container's namespace rather than getting one" {
    stub_launch
    launch "$PROJ"

    # The compose file is what carries it, from an environment variable the
    # launcher exports - so both halves are asserted. Either alone passes on an
    # arrangement where the session still has a network of its own.
    grep -qE '^\s*network_mode: \$\{SANDBOX_NETNS_CONTAINER' "$SANDBOX_DIR/docker-compose.yml" \
        || { echo "the compose file does not join a namespace"; return 1; }

    # And what it falls back to when nothing supplies one. Only a `docker
    # compose` invocation by hand reaches this, but a default naming a real
    # network is a sandbox that comes up working with unfiltered egress, and
    # nothing about it looks wrong. `none` fails the same case visibly.
    grep -qE '^\s*network_mode: \$\{SANDBOX_NETNS_CONTAINER:-none\}\s*$' \
        "$SANDBOX_DIR/docker-compose.yml" \
        || { echo "the network_mode default is not fail-closed"; return 1; }

    local run; run="$(log_line 'run -d --init')"
    local id; id="$(sed -E 's/.*--name dejima-filter-([0-9a-f]{16}).*/\1/' <<< "$run")"
    [ -n "$id" ]
    run grep -c "SANDBOX_NETNS_CONTAINER" "$REPO_ROOT/bin/dejima"
    [ "$status" -eq 0 ]
    grep -q 'export SANDBOX_NETNS_CONTAINER="container:\$SANDBOX_FILTER_CONTAINER"' \
        "$REPO_ROOT/bin/dejima" \
        || { echo "the launcher does not point the sandbox at the filter container"; return 1; }
}

@test "the filter container comes up before the session, not beside it" {
    # The ordering IS the control. A namespace that gets its rules after
    # something is already running in it has a window where a session holds an
    # interface and no filter, which is what this arrangement exists to remove
    # by construction rather than to bound by argument.
    stub_launch
    launch "$PROJ"

    local net_at filter_at ready_at session_at
    net_at="$(log_pos 'network create')"
    filter_at="$(log_pos 'run -d --init')"
    ready_at="$(log_pos 'dejima-firewall-ready')"
    session_at="$(log_pos ' run --rm ')"
    [ -n "$net_at" ] && [ -n "$filter_at" ] && [ -n "$ready_at" ] && [ -n "$session_at" ] \
        || { echo "one of the four steps never happened"; cat "$LAUNCH_DIR/docker-log"; return 1; }

    [ "$net_at" -lt "$filter_at" ] \
        || { echo "the filter container started before its network existed"; return 1; }
    [ "$filter_at" -lt "$ready_at" ] \
        || { echo "readiness was probed before the filter container was started"; return 1; }
    [ "$ready_at" -lt "$session_at" ] \
        || { echo "the session started before the filter was confirmed up"; return 1; }
}

@test "a filter container that never comes up refuses the launch" {
    # The failure this is really about is the quiet one: a launcher that waited,
    # gave up, and started the session anyway would produce a working sandbox
    # with no egress control, and nothing downstream would notice.
    stub_launch
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
case "$*" in
    # The marker never appears, and the container is reported gone - which is
    # what a firewall that refused to start leaves behind.
    *dejima-firewall-ready*) exit 1 ;;
    *inspect*State.Running*) echo false; exit 0 ;;
    *logs*) echo "[egress-policy] FAILED: registry.npmjs.org did not resolve"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"

    run launch "$PROJ"
    [ "$status" -ne 0 ] \
        || { echo "the launch succeeded with no egress control"; return 1; }
    [[ "$output" == *"did not come up"* ]] \
        || { echo "it refused without saying why: $output"; return 1; }
    # And it hands over what the filter container said, or the operator is left
    # with a refusal and nowhere to look.
    [[ "$output" == *"registry.npmjs.org"* ]] \
        || { echo "the refusal does not carry the filter container's own output: $output"; return 1; }

    run grep -c -- ' run --rm ' "$LAUNCH_DIR/docker-log"
    [ "$output" = "0" ] \
        || { echo "the session was started anyway"; return 1; }
}

@test "the launch takes its own container and network down again" {
    stub_launch
    launch "$PROJ"

    local run id
    run="$(log_line 'run -d --init')"
    id="$(sed -E 's/.*--name dejima-filter-([0-9a-f]{16}).*/\1/' <<< "$run")"
    [ -n "$id" ]

    grep -q -- "rm -f dejima-filter-$id" "$LAUNCH_DIR/docker-log" \
        || { echo "the filter container was left running"; return 1; }
    grep -q -- "network rm dejima-run-$id" "$LAUNCH_DIR/docker-log" \
        || { echo "the network was left behind"; return 1; }

    # After the session, not before it. Docker permits removing a namespace
    # owner from under a live joiner, so this order is the launcher's to keep.
    local session_at rm_at
    session_at="$(log_pos ' run --rm ')"
    rm_at="$(log_pos "rm -f dejima-filter-$id")"
    [ "$session_at" -lt "$rm_at" ] \
        || { echo "the filter container was removed before the session ran"; return 1; }
}

@test "the filter container runs the base image, never a project's derived one" {
    # It is the privileged half of the pair. A project's declared dependencies
    # are installed into the derived image for the session to use, and there is
    # no reason for any of them to be present in the container holding
    # NET_ADMIN.
    stub_launch
    launch "$PROJ"

    local run; run="$(log_line 'run -d --init')"
    [[ "$run" =~ localhost/dejima:[^[:space:]-]+$ ]] \
        || { echo "the filter container's image is not the plain base tag: $run"; return 1; }
}

@test "the filter container declares the network capabilities and drops the rest" {
    stub_launch
    launch "$PROJ"

    local run; run="$(log_line 'run -d --init')"
    [[ "$run" == *"--cap-drop ALL"* ]] \
        || { echo "the filter container keeps Docker's default set: $run"; return 1; }
    [[ "$run" == *"--security-opt no-new-privileges:true"* ]] \
        || { echo "no-new-privileges is missing from the filter container: $run"; return 1; }
    local cap
    for cap in NET_ADMIN NET_RAW KILL SETPCAP; do
        [[ "$run" == *"--cap-add $cap"* ]] \
            || { echo "the filter container cannot do its job without $cap: $run"; return 1; }
    done
}


@test "every variable the firewall path reads is passed to the filter container" {
    # The drift guard this arrangement needs most. The sandbox gets its
    # environment from docker-compose.yml; the filter container is started with
    # `docker run` and gets nothing that is not named on that command line.
    #
    # So a firewall script that starts reading a new variable does not fail - it
    # reads an empty one, and permits less than it was told to, which presents
    # as a domain the operator approved being unreachable rather than as
    # anything about this. Derived from the scripts rather than listed here, so
    # the test cannot drift from them either.
    stub_launch
    launch "$PROJ"
    local run; run="$(log_line 'run -d --init')"
    [ -n "$run" ]

    # A name these files ORIGINATE is their own working value, not something
    # the launcher supplies, so only names they read without originating have
    # to be passed in. Derived rather than listed, because a hand-kept
    # exclusion list is the same drift this test exists to catch, one level up.
    #
    # `X="${X:-}"` does not count as originating X: it reads the launcher's
    # value and supplies a default for its absence, which is the shape every
    # variable here is consumed with. Counting it would have quietly dropped
    # LOKI_URL out of the required set.
    local scripts=("$SANDBOX_DIR/firewall-up.sh" "$SANDBOX_DIR/egress-policy"
                   "$SANDBOX_DIR/fixed-domains.sh" "$SANDBOX_DIR/log-shipper.sh")
    # The awk program is held in a variable rather than written inline: it
    # contains a double quote, and bash mis-nests one inside a single-quoted
    # program inside "$( )" - the whole file then fails to parse, as a syntax
    # error pointing at an unrelated line much further down.
    local prog assigned
    prog=$(cat <<'AWK'
match($0, /^[[:space:]]*(export |readonly |local )?[A-Z][A-Z0-9_]*\+?=/) {
    decl = substr($0, RSTART, RLENGTH)
    rest = substr($0, RSTART + RLENGTH)
    gsub(/^[[:space:]]*(export|readonly|local)[[:space:]]+/, "", decl)
    sub(/\+?=$/, "", decl)
    if (rest ~ ("[$]{?" decl)) next
    print decl
}

AWK
)
    assigned="$(cat "${scripts[@]}" | awk "$prog" | sort -u)"
    local v missing=""
    while read -r v; do
        [ -n "$v" ] || continue
        grep -qxF "$v" <<< "$assigned" && continue
        [[ "$run" == *"-e $v"* ]] || missing="$missing $v"
    done < <(cat "${scripts[@]}" \
             | grep -oE '\$\{?(ALLOW[A-Z_]*|DEJIMA_[A-Z_]*|ENABLE_[A-Z_]*|GH_TOKEN|LOKI_URL|SANDBOX_[A-Z_]*)' \
             | tr -d '${' | sort -u \
             | grep -vE '^(SANDBOX_TEST.*)$')

    [ -z "$missing" ] \
        || { echo "the firewall path reads these, and the filter container is not given them:$missing"; return 1; }

    # And the other half of the same failure, which the flag alone cannot show.
    # `docker run -e NAME` takes the value from the launcher's environment, so
    # a name that is assigned but never exported passes an empty one - the
    # filter container then permits less than it was told to, and what an
    # operator sees is a domain they approved being unreachable, with nothing
    # pointing here.
    #
    # Not hypothetical: `export DEJIMA_FORGE_HOSTS` is a line that had to be
    # added by hand when the filter container was introduced, because until
    # then that variable had only ever needed to reach the sandbox as
    # `-e NAME=value`, which carries its own value.
    #
    # Continuations are flattened first, because the exports here run to
    # several lines; and `export` is matched anywhere on a line rather than at
    # its start, because two of these are exported after a `;` on the line that
    # assigns them.
    local exported unexported=""
    exported="$(sed -z 's/\\\n[[:space:]]*/ /g' "$REPO_ROOT/bin/dejima" \
        | grep -oE 'export [A-Za-z_][A-Za-z0-9_ ]*')"
    [ -n "$exported" ] || { echo "found no exports in bin/dejima at all"; return 1; }

    while read -r v; do
        [ -n "$v" ] || continue
        grep -qE "(^|[[:space:]])$v([[:space:]]|\$)" <<< "$exported" \
            || unexported="$unexported $v"
    done < <(grep -oE '^\s+-e [A-Z_]+' "$REPO_ROOT/bin/dejima" | awk '{print $2}' | sort -u)

    [ -z "$unexported" ] \
        || { echo "passed as -e NAME but never exported, so the value is empty:$unexported"; return 1; }
}
@test "a declared internal domain reaches the filter container as a value, not just a name" {
    # The test above proves the flag is on the command line. `docker run -e
    # NAME` takes the value from the launcher's environment, so a flag with
    # nothing behind it passes an empty string - and this key decides whether a
    # security check applies to a name, so an empty one silently applies it to
    # every name the operator declared internal.
    #
    # Colon-separated in the file, space-separated in the environment, which is
    # what firewall-up.sh splits on.
    stub_launch
    local conf
    conf="$(bash -c 'source "$1"; config_path' _ "$LIB")"
    mkdir -p "$(dirname "$conf")"
    printf '[core]\ninternal_domains = mirror.example:logs.example\n' >> "$conf"
    launch "$PROJ"

    local run; run="$(log_line 'run -d --init')"
    [ -n "$run" ]
    [[ "$run" == *"-e DEJIMA_INTERNAL_DOMAINS"* ]] \
        || { echo "the flag is not on the filter container's command line"; return 1; }

    # The value itself, read out of the environment the launcher handed over.
    # The stub records it, because `-e NAME` puts the value nowhere the command
    # line can show it - which is the whole reason this can go wrong quietly.
    local seen; seen="$(cat "$LAUNCH_DIR/filter-env" 2>/dev/null || true)"
    [[ "$seen" == *"DEJIMA_INTERNAL_DOMAINS=mirror.example logs.example"* ]] \
        || { echo "the filter container was given: '$seen'"; return 1; }
}

# A `docker` that reports one filter container and one network, with whatever
# age, joiner and identity a test needs, and records every removal.
#
# Each of these tests is about a branch that decides NOT to remove something,
# and a reconciler that removed nothing at all would pass every one of them -
# so the first test here is the one that proves the mechanism fires.
stub_orphan() {  # <age-seconds> <joined-by|"">
    local age="$1" joiner="$2"
    stub_launch
    # Each query answers in the format Docker really answers it in, and the two
    # differ: `Created` is a string field on a container and a time.Time on a
    # network, so a template prints the second through String() and appends a
    # timezone NAME. One format for both is what let the network half of the
    # reconciler pass a test while reaping nothing.
    cat > "$LAUNCH_DIR/docker" <<EOF
#!/bin/bash
echo "\$*" >> "\${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
epoch=\$(( \$(date +%s) - $age ))
made=\$(date -u -d "@\$epoch" +%Y-%m-%dT%H:%M:%S.000000000Z)
made_go=\$(date -u -d "@\$epoch" '+%Y-%m-%d %H:%M:%S.000000000 +0000 UTC')
case "\$*" in
    # The running containers, and what namespace each is in.
    "ps -q")                       [ -n "$joiner" ] && echo j0 ; exit 0 ;;
    *HostConfig.NetworkMode*)      [ -n "$joiner" ] && echo "container:$joiner" ; exit 0 ;;
    # The candidates.
    *"ps -aq --filter label=dejima.filter"*) echo orphan0 ; exit 0 ;;
    *"{{.Id}} {{.Name}} {{.Created}}"*)     echo "orphan0 /dejima-filter-old \$made" ; exit 0 ;;
    *"network ls -q --filter label=dejima.run"*) echo net0 ; exit 0 ;;
    *"{{.Name}} {{.Created}}"*)             echo "dejima-run-old \$made_go" ; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
}

@test "a filter container nothing is joined to, left over from before, is removed" {
    stub_orphan 6000 ""
    launch "$PROJ"
    grep -q -- 'rm -f orphan0' "$LAUNCH_DIR/docker-log" \
        || { echo "the orphaned filter container was left running"; return 1; }
    grep -q -- 'network rm dejima-run-old' "$LAUNCH_DIR/docker-log" \
        || { echo "its network was left behind"; return 1; }
}

@test "the reconcile says what it removed, so a leak is not silently routine" {
    stub_orphan 6000 ""
    run launch "$PROJ"
    [[ "$output" == *"left behind"* ]] \
        || { echo "an orphan was removed with nothing said about it: $output"; return 1; }
}

@test "a filter container with a session still in its namespace is left alone" {
    # The one that matters on a host running several sessions: reaping this is
    # taking the network out from under somebody's running agent.
    stub_orphan 6000 orphan0
    launch "$PROJ"
    run grep -c -- 'rm -f orphan0' "$LAUNCH_DIR/docker-log"
    [ "$output" = "0" ] \
        || { echo "a filter container with a live session was removed"; return 1; }
}

@test "a filter container younger than the grace is left alone" {
    # A pair being built right now by a concurrent launch: between `docker run`
    # for the filter and `docker compose run` for the session, a healthy filter
    # container has no joiner. Age is what tells that apart from abandonment.
    stub_orphan 5 ""
    launch "$PROJ"
    run grep -c -- 'rm -f orphan0' "$LAUNCH_DIR/docker-log"
    [ "$output" = "0" ] \
        || { echo "a filter container still being paired was removed"; return 1; }
    run grep -c -- 'network rm dejima-run-old' "$LAUNCH_DIR/docker-log"
    [ "$output" = "0" ] \
        || { echo "a network still being attached to was removed"; return 1; }
}

@test "a docker that cannot answer the reconcile does not fail the launch" {
    # It runs before the launch's own network and container, so an error here
    # would refuse a session over tidying up. The launch that follows reports
    # its own failures.
    stub_launch
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
case "$*" in
    ps*|*inspect*|*network\ ls*) echo "Cannot connect to the Docker daemon" >&2; exit 1 ;;
esac
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
    run launch "$PROJ"
    [ "$status" -eq 0 ] \
        || { echo "a failing reconcile refused the launch: $output"; return 1; }
    grep -q -- ' run --rm ' "$LAUNCH_DIR/docker-log" \
        || { echo "the session never started"; return 1; }
}

@test "a single-label host in a firewall-facing key stops the launch, naming the key" {
    # The policy refuses a dotless permitted entry at container start. Meeting
    # that as a sandbox that will not boot, on a value every check on the way in
    # accepted, is the failure this check exists to move: it happens here, on
    # the host, before anything starts, and says which key it came from.
    stub_launch
    local conf
    conf="$(bash -c 'source "$1"; config_path' _ "$LIB")"
    mkdir -p "$(dirname "$conf")"
    printf '[logging]\nloki_url = http://loki:3100\n' >> "$conf"

    run launch "$PROJ"
    [ "$status" -ne 0 ] || { echo "the launch proceeded with a dotless host"; return 1; }
    [[ "$output" == *"loki_url"* ]] \
        || { echo "the error does not name the key it came from: $output"; return 1; }
    [[ "$output" == *"single label"* ]] \
        || { echo "the error does not say what is wrong: $output"; return 1; }

    # And nothing was started, rather than started and then torn down.
    [ ! -s "$LAUNCH_DIR/docker-log" ] || {
        echo "docker was invoked before the check refused:"; cat "$LAUNCH_DIR/docker-log"; return 1; }
}

@test "a fully qualified host in the same key launches" {
    # The control for the test above: same key, same shape, one dot more.
    stub_launch
    local conf
    conf="$(bash -c 'source "$1"; config_path' _ "$LIB")"
    mkdir -p "$(dirname "$conf")"
    printf '[logging]\nloki_url = http://loki.example.com:3100\n' >> "$conf"

    run launch "$PROJ"
    [ "$status" -eq 0 ] || { echo "a fully qualified loki_url was refused: $output"; return 1; }
}
