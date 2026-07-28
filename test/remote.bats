#!/usr/bin/env bats
# Host-side tests for the opt-in remote access feature: config parsing, the
# session registry, the attach core, and the notification watcher. The
# watcher is a trust boundary - it consumes a directory a possibly
# compromised session writes into - so most of what's here is about what it
# refuses to do with that input.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/bin/dejima-project-lib.sh"
    CONFIG_DIR="$(mktemp -d)"
    RUNTIME_DIR="$(mktemp -d)"
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR"
    export XDG_RUNTIME_DIR="$RUNTIME_DIR"
}
teardown() {
    # Only ever the private server start_tmux created (its own TMUX_TMPDIR),
    # never the operator's.
    if [ -n "${TMUX_DIR:-}" ]; then
        TMUX_TMPDIR="$TMUX_DIR" tmux kill-server 2>/dev/null || true
    fi
    rm -rf "$CONFIG_DIR" "$RUNTIME_DIR" ${STUB_DIR:+"$STUB_DIR"} ${LAUNCH_DIR:+"$LAUNCH_DIR"} \
        ${TMUX_DIR:+"$TMUX_DIR"}
}

lib() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

@test "remote_enabled is false without remote.conf and true with it" {
    run lib remote_enabled
    [ "$status" -ne 0 ]
    : > "$CONFIG_DIR/remote.conf"
    run lib remote_enabled
    [ "$status" -eq 0 ]
}

@test "remote_conf_get reads values and skips comments and blanks" {
    cat > "$CONFIG_DIR/remote.conf" <<'EOF'
# the topic to push to
NTFY_URL=https://ntfy.example.invalid/dejima

BASE_URL=https://dejima.example.invalid
EOF
    run lib remote_conf_get NTFY_URL
    [ "$status" -eq 0 ]
    [ "$output" = "https://ntfy.example.invalid/dejima" ]
    run lib remote_conf_get BASE_URL
    [ "$output" = "https://dejima.example.invalid" ]
}

@test "remote_conf_get returns empty for a key the file does not set" {
    printf 'NTFY_URL=https://ntfy.example.invalid/t\n' > "$CONFIG_DIR/remote.conf"
    run lib remote_conf_get BASE_URL
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a malformed remote.conf is refused, not silently ignored" {
    # An unparseable config is the operator having got something wrong, and
    # this feature's security properties depend on its values - so every
    # read validates the whole file, not just the requested key.
    printf 'NTFY_URL=https://ntfy.example.invalid/t\nthis is not a setting\n' \
        > "$CONFIG_DIR/remote.conf"
    run lib remote_conf_get NTFY_URL
    [ "$status" -ne 0 ]

    printf 'UNKNOWN_KEY=x\n' > "$CONFIG_DIR/remote.conf"
    run lib remote_conf_get NTFY_URL
    [ "$status" -ne 0 ]
}

@test "remote.conf values reject shell-active input" {
    for bad in 'https://x/$(id)' 'https://x/`id`' 'a;curl evil' 'a b' 'a|b' 'a&b' 'a>b'; do
        printf 'BASE_URL=%s\n' "$bad" > "$CONFIG_DIR/remote.conf"
        run lib remote_conf_get BASE_URL
        [ "$status" -ne 0 ]
    done
}

@test "remote_ttyd_port defaults to 7681 and refuses out-of-range values" {
    : > "$CONFIG_DIR/remote.conf"
    run lib remote_ttyd_port
    [ "$status" -eq 0 ]
    [ "$output" = "7681" ]

    printf 'TTYD_PORT=9999\n' > "$CONFIG_DIR/remote.conf"
    run lib remote_ttyd_port
    [ "$output" = "9999" ]

    printf 'TTYD_PORT=99999\n' > "$CONFIG_DIR/remote.conf"
    run lib remote_ttyd_port
    [ "$status" -ne 0 ]

    printf 'TTYD_PORT=0\n' > "$CONFIG_DIR/remote.conf"
    run lib remote_ttyd_port
    [ "$status" -ne 0 ]
}

@test "valid_run_id accepts what bin/dejima generates and nothing else" {
    run lib valid_run_id 0123456789abcdef
    [ "$status" -eq 0 ]
    for bad in '' 'ABCDEF0123456789' '0123456789abcde' '0123456789abcdef0' \
               '../../etc/passwd' '0123456789abcde;'; do
        run lib valid_run_id "$bad"
        [ "$status" -ne 0 ]
    done
}

@test "remote_state_dir honors XDG_RUNTIME_DIR" {
    run lib remote_state_dir
    [ "$output" = "$RUNTIME_DIR/dejima" ]
}

# A fake `docker` that records its argv, so bin/dejima's launch path can be
# exercised with no daemon. Same approach as test/project.bats.
stub_launch() {
    LAUNCH_DIR="$(mktemp -d)"
    mkdir -p "$LAUNCH_DIR/home/.claude"
    echo '{}' > "$LAUNCH_DIR/home/.claude/settings.json"
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
    : > "$LAUNCH_DIR/sandbox-key"
    chmod 600 "$LAUNCH_DIR/sandbox-key"
    PROJ="$(mktemp -d)"
}

launch() {
    HOME="$LAUNCH_DIR/home" PATH="$LAUNCH_DIR:$PATH" \
        SANDBOX_TEST_DOCKER_LOG="$LAUNCH_DIR/docker-log" \
        SANDBOX_CREDENTIAL_PROXY=0 \
        SANDBOX_SSH_KEY="$LAUNCH_DIR/sandbox-key" \
        SSH_AUTH_SOCK= ALLOWED_DOMAINS= \
        "$REPO_ROOT/bin/dejima" "$@"
}

run_line() { grep -- ' run --rm ' "$LAUNCH_DIR/docker-log" | tail -1; }

@test "with no remote.conf the compose invocation is unchanged" {
    # The opt-in guarantee, tested rather than asserted: an operator who has
    # not configured this feature must get byte-identical behavior.
    stub_launch
    launch "$PROJ"
    baseline="$(run_line)"
    [ -n "$baseline" ]
    case "$baseline" in
        *DEJIMA_RUN_ID*|*dejima-notify*) false ;;
    esac
    [ ! -d "$RUNTIME_DIR/dejima" ]
    rm -rf "$PROJ"
}

@test "with remote.conf a registry entry is written and removed on exit" {
    stub_launch
    : > "$CONFIG_DIR/remote.conf"
    launch "$PROJ"
    # The EXIT trap removes it, so the directory exists but is empty by now.
    [ -d "$RUNTIME_DIR/dejima/sessions" ]
    [ -z "$(ls -A "$RUNTIME_DIR/dejima/sessions")" ]
    [ -z "$(ls -A "$RUNTIME_DIR/dejima/notify")" ]
    rm -rf "$PROJ"
}

@test "the mounted marker directory is this run's own, and the registry is never mounted" {
    stub_launch
    : > "$CONFIG_DIR/remote.conf"
    launch "$PROJ"
    line="$(run_line)"

    # The run ID appears as the LAST path segment of the mount source: the
    # container gets its own directory, never the parent, so it cannot
    # fabricate markers for another session.
    [[ "$line" =~ -v\ [^[:space:]]*/notify/([0-9a-f]{16}):/run/dejima-notify ]]
    [[ "$line" =~ -e\ DEJIMA_RUN_ID=([0-9a-f]{16}) ]]
    [[ "$line" =~ -e\ DEJIMA_NOTIFY_DIR=/run/dejima-notify ]]

    # The registry decides which pane an operator gets attached to. A session
    # able to write it could redirect them, so it is never mounted.
    case "$line" in
        *sessions*) false ;;
    esac
    rm -rf "$PROJ"
}

@test "a sandbox started outside tmux records an empty pane rather than being skipped" {
    stub_launch
    : > "$CONFIG_DIR/remote.conf"
    # The EXIT trap removes the entry, so snapshot it from inside the run:
    # the stub stands in for the container, and runs while it still exists.
    cat > "$LAUNCH_DIR/docker" <<EOF
#!/bin/bash
echo "\$*" >> "\${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
rm -rf "$LAUNCH_DIR/sessions-snapshot"
cp -r "$RUNTIME_DIR/dejima/sessions" "$LAUNCH_DIR/sessions-snapshot" 2>/dev/null || true
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
    TMUX_PANE= launch "$PROJ"
    entry="$(cat "$LAUNCH_DIR"/sessions-snapshot/*)"
    [[ "$entry" == *"workspace=$PROJ"* ]]
    [[ "$entry" == *"pane="* ]]
    [[ "$entry" =~ started=[0-9]+ ]]
    rm -rf "$PROJ"
}

@test "a workspace path containing a newline is refused" {
    # A newline could inject an extra key=value line into the flat registry
    # entry (e.g. a forged pane=), so a path that can't be represented safely
    # is a hard failure, not silently sanitized.
    stub_launch
    : > "$CONFIG_DIR/remote.conf"
    bad_proj="$PROJ"/$'line1\nline2'
    mkdir -p "$bad_proj"
    run launch "$bad_proj"
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$RUNTIME_DIR/dejima/sessions" 2>/dev/null)" ]
    rm -rf "$PROJ"
}

@test "a pre-existing symlink at the state dir is refused, not followed" {
    # /tmp (the fallback parent when XDG_RUNTIME_DIR is unset) is
    # world-writable, and `mkdir -p -m 700` only sets the mode of the leaf it
    # creates - a planted symlink at the state dir itself must be refused,
    # not followed into wherever it points.
    stub_launch
    : > "$CONFIG_DIR/remote.conf"
    elsewhere="$(mktemp -d)"
    ln -s "$elsewhere" "$RUNTIME_DIR/dejima"
    run launch "$PROJ"
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$elsewhere")" ]
    rm -rf "$elsewhere" "$PROJ"
}

@test "an inherited DEJIMA_NOTIFY_DIR is not deleted when remote access is off" {
    # DEJIMA_NOTIFY_DIR is also the name of a container-facing env var; if it
    # happens to be set in the launching shell for any other reason, a run
    # with the feature off must not treat it as its own and delete it.
    stub_launch
    survive_parent="$(mktemp -d)"
    survive="$survive_parent/must-survive"
    mkdir -p "$survive"
    export DEJIMA_NOTIFY_DIR="$survive"
    launch "$PROJ"
    unset DEJIMA_NOTIFY_DIR
    [ -d "$survive" ]
    rm -rf "$survive_parent" "$PROJ"
}

@test "an inherited DEJIMA_NOTIFY_DIR is not deleted on an early exit before remote access is evaluated" {
    # trap cleanup EXIT is installed long before the remote-access block ever
    # runs - several unrelated `exit 1` paths sit in between (a bad
    # SANDBOX_EXTRA_MOUNTS entry is one), and the trap must not delete an
    # inherited DEJIMA_NOTIFY_DIR on any of them either, not just on the
    # ordinary feature-off success path the previous test covers.
    stub_launch
    survive_parent="$(mktemp -d)"
    survive="$survive_parent/must-survive"
    mkdir -p "$survive"
    export DEJIMA_NOTIFY_DIR="$survive"
    export SANDBOX_EXTRA_MOUNTS="$LAUNCH_DIR/does-not-exist"
    run launch "$PROJ"
    unset DEJIMA_NOTIFY_DIR SANDBOX_EXTRA_MOUNTS
    [ "$status" -ne 0 ]
    [ -d "$survive" ]
    rm -rf "$survive_parent" "$PROJ"
}

# A fake `docker` reporting one running sandbox whose DEJIMA_RUN_ID env
# matches $1, so the liveness check can be exercised with no daemon.
stub_docker_run_id() {
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<EOF
#!/bin/bash
case "\$1" in
    ps)      echo dejima-test-container ;;
    inspect) echo "DEJIMA_RUN_ID=$1" ;;
esac
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    PATH="$STUB_DIR:$PATH"
}

write_entry() {
    mkdir -p "$RUNTIME_DIR/dejima/sessions"
    cat > "$RUNTIME_DIR/dejima/sessions/$1" <<EOF
workspace=/home/someone/myproject
pane=$2
label=$3
started=$(date +%s)
EOF
}

@test "dejima-attach refuses an id that is not a run id" {
    : > "$CONFIG_DIR/remote.conf"
    for bad in 'nope' '../../etc/passwd' '$(id)' '0123456789abcdef0'; do
        run "$REPO_ROOT/bin/dejima-attach" "$bad"
        [ "$status" -ne 0 ]
        [[ "$output" == *"Invalid session id"* ]]
    done
}

@test "dejima-attach refuses a well-formed id with no registry entry" {
    : > "$CONFIG_DIR/remote.conf"
    run "$REPO_ROOT/bin/dejima-attach" 0123456789abcdef
    [ "$status" -ne 0 ]
    [[ "$output" == *"No such session"* ]]
}

@test "dejima-attach refuses to run at all without remote.conf" {
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
}

@test "--list prunes entries whose container is gone" {
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id ffffffffffffffff
    write_entry 0123456789abcdef '%1' 'work:2'
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # Pruned from disk, not merely hidden from the listing.
    [ ! -f "$RUNTIME_DIR/dejima/sessions/0123456789abcdef" ]
}

@test "--list marks a session started outside tmux as not attachable" {
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    write_entry 0123456789abcdef '' ''
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"myproject"* ]]
    [[ "$output" == *"no-tmux"* ]]
}

@test "--list marks a session whose pane is gone as stale" {
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    write_entry 0123456789abcdef '%99999' 'work:2'
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}

# A `docker` that can't answer - the daemon restarting, or docker not
# installed at all. Distinct from "no such container", and must stay that way.
stub_docker_broken() {
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock." >&2
exit 1
EOF
    chmod +x "$STUB_DIR/docker"
    PATH="$STUB_DIR:$PATH"
}

# A real tmux server of our own, on a private TMUX_TMPDIR so nothing here can
# touch an operator's sessions. Two windows, so selecting the right one is
# distinguishable from selecting the current one. $TARGET_PANE is in window 1.
start_tmux() {
    TMUX_DIR="$(mktemp -d)"
    export TMUX_TMPDIR="$TMUX_DIR"
    unset TMUX
    tmux -f /dev/null new-session -d -s work -x 80 -y 24 'sleep 300'
    tmux new-window -t work -d 'sleep 300'
    TARGET_PANE="$(tmux list-panes -t work:1 -F '#{pane_id}')"
}

@test "--list shows a live tmux pane as attachable" {
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    start_tmux
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"attachable"* ]]
}

@test "attaching creates a grouped session on the requested window and disposes of it on detach" {
    # The positive direction, which is where every interesting tmux mistake
    # lives: an invalid set-option target, or setting destroy-unattached while
    # the session is still detached, both leave the negative tests green while
    # no one can actually attach.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    start_tmux
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'

    # A pty that is NOT a tmux pane: tmux refuses to nest, and ttyd/ssh give
    # dejima-attach a bare pty too.
    script -qec "$REPO_ROOT/bin/dejima-attach 0123456789abcdef" /dev/null >/dev/null 2>&1 &
    attach_pid=$!
    for _ in $(seq 50); do
        if tmux has-session -t '=dejima-0123456789abcdef' 2>/dev/null; then break; fi
        sleep 0.1
    done
    tmux has-session -t '=dejima-0123456789abcdef'
    [ "$(tmux list-clients -F '#{client_session}')" = "dejima-0123456789abcdef" ]
    # On the requested window - and the operator's own session was not dragged
    # along to it.
    [ "$(tmux display-message -p -t dejima-0123456789abcdef '#{window_index}')" = "1" ]
    [ "$(tmux display-message -p -t work '#{window_index}')" = "0" ]
    [ "$(tmux show-options -t dejima-0123456789abcdef destroy-unattached)" = "destroy-unattached on" ]

    # destroy-unattached actually applied: the throwaway must not outlive the
    # remote client, or every phone detach leaks a session on the host server.
    kill "$attach_pid" 2>/dev/null || true
    for _ in $(seq 50); do
        if ! tmux has-session -t '=dejima-0123456789abcdef' 2>/dev/null; then break; fi
        sleep 0.1
    done
    run tmux has-session -t '=dejima-0123456789abcdef'
    [ "$status" -ne 0 ]
    tmux has-session -t '=work'
}

@test "--list never prunes when docker cannot be asked" {
    # "Couldn't ask" is not "it's gone". bin/dejima stamps the registry only at
    # launch, so pruning here would permanently unregister every running
    # sandbox - and rm -rf the notify dir out from under a live bind mount.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_broken
    write_entry 0123456789abcdef '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/0123456789abcdef"
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [ -f "$RUNTIME_DIR/dejima/sessions/0123456789abcdef" ]
    [ -d "$RUNTIME_DIR/dejima/notify/0123456789abcdef" ]
    [[ "$output" == *"0123456789abcdef"* ]]
}

@test "a registry entry cannot execute anything through the uptime arithmetic" {
    # started= reaches $(( )), where bash evaluates a non-numeric value as a
    # variable name and runs any command substitution in its subscript - and
    # set -u does not catch it when that name is already bound.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    write_entry 0123456789abcdef '%1' 'work:2'
    canary="$RUNTIME_DIR/PWNED"
    printf 'started=now[$(touch %s)]\n' "$canary" >> "$RUNTIME_DIR/dejima/sessions/0123456789abcdef"
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ ! -e "$canary" ]
    run "$REPO_ROOT/bin/dejima-attach" 0123456789abcdef
    [ "$status" -ne 0 ]
    [ ! -e "$canary" ]
}

@test "one unreadable entry does not hide every other live session" {
    # The unreadable entry sorts first, so a fatal read aborts the loop before
    # the live session below it is ever printed - and the picker's process
    # substitution swallows the status, so sandboxes just silently vanish.
    : > "$CONFIG_DIR/remote.conf"
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
case "$1" in
    ps)      echo dejima-test-container ;;
    # Reports both run IDs, so neither entry is pruned for the unrelated
    # reason that its container is gone.
    inspect) echo DEJIMA_RUN_ID=0000000000000000; echo DEJIMA_RUN_ID=0123456789abcdef ;;
esac
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    PATH="$STUB_DIR:$PATH"
    write_entry 0000000000000000 '%1' 'work:1'
    write_entry 0123456789abcdef '%1' 'work:2'
    chmod 000 "$RUNTIME_DIR/dejima/sessions/0000000000000000"
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"0123456789abcdef"* ]]
}

@test "a TMUX_PANE containing a newline is refused" {
    # $TMUX_PANE is taken straight from the launching shell's environment, the
    # one value in the entry that is verbatim rather than derived. An injected
    # line loses the parser's last-match-wins race to the real label= and
    # started= that follow it, but wins outright for a second pane=.
    stub_launch
    : > "$CONFIG_DIR/remote.conf"
    TMUX_PANE=$'%1\nstarted=now[$(id)]' run launch "$PROJ"
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$RUNTIME_DIR/dejima/sessions" 2>/dev/null)" ]
    rm -rf "$PROJ"
}

@test "--list never prunes when docker inspect cannot answer for some container" {
    # The other half of "couldn't ask": inspect failing for an unrelated
    # container must not read as "this isn't the one" for the session being
    # checked. Piping inspect into grep reports only grep's status, and a
    # spurious prune is unrecoverable - bin/dejima stamps at launch only.
    : > "$CONFIG_DIR/remote.conf"
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
case "$1" in
    ps) echo dejima-a; echo dejima-b ;;
    inspect)
        case "$*" in
            *dejima-a*) echo DEJIMA_RUN_ID=aaaaaaaaaaaaaaaa ;;
            *) echo "Error response from daemon: dejima-b" >&2; exit 1 ;;
        esac
        ;;
esac
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    PATH="$STUB_DIR:$PATH"
    write_entry aaaaaaaaaaaaaaaa '%1' 'work:1'
    write_entry bbbbbbbbbbbbbbbb '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/bbbbbbbbbbbbbbbb"
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"aaaaaaaaaaaaaaaa"* ]]
    # B's container could not be examined, so B is unverified, not gone.
    [ -f "$RUNTIME_DIR/dejima/sessions/bbbbbbbbbbbbbbbb" ]
    [ -d "$RUNTIME_DIR/dejima/notify/bbbbbbbbbbbbbbbb" ]
}

@test "a marker directory the sandbox made undeletable does not kill the listing" {
    # /run/dejima-notify is bind-mounted read-write, so a compromised session
    # can chmod its own marker directory on the way out and make the next
    # prune's rm -rf fail. Aborting there would blank the picker - a sandbox
    # must not be able to deny the operator the front door.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    write_entry 0000000000000000 '%1' 'work:1'
    write_entry 0123456789abcdef '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/0000000000000000/waiting-dir"
    chmod 500 "$RUNTIME_DIR/dejima/notify/0000000000000000"
    run "$REPO_ROOT/bin/dejima-attach" --list
    chmod 700 "$RUNTIME_DIR/dejima/notify/0000000000000000"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0123456789abcdef"* ]]
}

# Waits for the grouped session an attach should have created, then prints
# "<name> <group>" for it - empty group means UNGROUPED, i.e. a fresh session
# tmux conjured out of a name rather than a clone of the sandbox's own.
await_group() {
    local i
    for i in $(seq 50); do
        if tmux has-session -t "=dejima-$1" 2>/dev/null; then break; fi
        sleep 0.1
    done
    tmux list-sessions -F '#{session_name} #{session_group}' | grep "^dejima-$1 " || true
}

@test "a recorded session name that no longer exists cannot conjure a session of its own" {
    # tmux does not fail on `new-session -t <nothing-matches>` - it creates a
    # fresh ungrouped session under that name, which for a remote client is a
    # plain host shell with no sandbox in it. The base session must therefore
    # come from the live pane, never from the recorded label.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    start_tmux
    write_entry 0123456789abcdef "$TARGET_PANE" 'nope:0'
    script -qec "$REPO_ROOT/bin/dejima-attach 0123456789abcdef" /dev/null >/dev/null 2>&1 &
    attach_pid=$!
    # Grouped with the session that actually holds the pane, on its window.
    [ "$(await_group 0123456789abcdef)" = "dejima-0123456789abcdef work" ]
    [ "$(tmux display-message -p -t dejima-0123456789abcdef '#{window_index}')" = "1" ]
    kill "$attach_pid" 2>/dev/null || true
}

@test "attaching follows the pane's session across a rename, not the recorded name" {
    # The registry can outlive the shape of the operator's tmux server. If the
    # base came from the label, renaming the real session and letting anything
    # else take the old name would silently attach the remote client to that
    # unrelated session.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    start_tmux
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'
    tmux rename-session -t '=work' old
    tmux new-session -d -s work 'sleep 300'
    script -qec "$REPO_ROOT/bin/dejima-attach 0123456789abcdef" /dev/null >/dev/null 2>&1 &
    attach_pid=$!
    [ "$(await_group 0123456789abcdef)" = "dejima-0123456789abcdef old" ]
    [ "$(tmux display-message -p -t dejima-0123456789abcdef '#{window_index}')" = "1" ]
    kill "$attach_pid" 2>/dev/null || true
}

@test "--list survives a timestamp with a leading zero" {
    # Bash reads a leading zero as octal, so an all-digits "0999999999" is
    # still not a number and $(( )) would abort the whole listing under set -e.
    # The 10# that fixes it is also the second line of defence behind the
    # started validation: "10#now[$(cmd)]" fails to lex before the array
    # subscript is ever evaluated.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    write_entry 0123456789abcdef '%1' 'work:2'
    sed -i 's/^started=.*/started=0999999999/' "$RUNTIME_DIR/dejima/sessions/0123456789abcdef"
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"0123456789abcdef"* ]]
}

# A tmux that reproduces the one behavior a live race produces and no test can
# otherwise force: display-message printing nothing, and still exiting 0, for
# a pane that went away after the liveness check. Everything else passes
# through to the real tmux.
stub_tmux_lost_pane() {
    STUB_DIR="${STUB_DIR:-$(mktemp -d)}"
    cat > "$STUB_DIR/tmux" <<EOF
#!/bin/bash
for arg in "\$@"; do
    [ "\$arg" = '#{session_name}:#{window_index}' ] && exit 0
done
exec $(command -v tmux) "\$@"
EOF
    chmod +x "$STUB_DIR/tmux"
    PATH="$STUB_DIR:$PATH"
}

@test "a pane that vanishes between the liveness check and the attach is refused" {
    # Without the guard, an empty session name and window index are handed
    # straight to tmux, which reads them as "no target given" - a new ungrouped
    # session, and the group's current window rather than the sandbox's.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    start_tmux
    stub_tmux_lost_pane
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'
    run "$REPO_ROOT/bin/dejima-attach" 0123456789abcdef
    [ "$status" -ne 0 ]
    [[ "$output" == *"stale"* ]]
    run tmux has-session -t '=dejima-0123456789abcdef'
    [ "$status" -ne 0 ]
}

# A tmux that reports the sandbox pane as living in a session it destroys on
# the way out. Not hypothetical: display-message names whichever session
# holding the window is most recent, which is typically another remote
# client's grouped throwaway - and those carry destroy-unattached, so that
# client detaching is what makes the name stop resolving.
stub_tmux_doomed_base() {
    STUB_DIR="${STUB_DIR:-$(mktemp -d)}"
    cat > "$STUB_DIR/tmux" <<EOF
#!/bin/bash
real=$(command -v tmux)
for arg in "\$@"; do
    if [ "\$arg" = '#{session_name}:#{window_index}' ]; then
        "\$real" kill-session -t '=doomed' 2>/dev/null
        echo 'doomed:1'
        exit 0
    fi
done
exec "\$real" "\$@"
EOF
    chmod +x "$STUB_DIR/tmux"
    PATH="$STUB_DIR:$PATH"
}

@test "a base session that disappears before the attach yields no session at all" {
    # tmux does not fail on `new-session -t <matches nothing>` - it silently
    # creates a fresh UNGROUPED session, i.e. a plain host shell with no
    # sandbox in it, which is the containment escape. Since the base is
    # routinely another client's throwaway, whoever holds a second connection
    # can drive this race, so the created session must be verified to actually
    # hold the sandbox pane rather than assumed to.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    start_tmux
    # Stands in for that other client's group: really does hold the pane, and
    # really does go away.
    tmux new-session -d -t '=work' -s doomed
    stub_tmux_doomed_base
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'
    run timeout 20 script -qec "$REPO_ROOT/bin/dejima-attach 0123456789abcdef" /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"stale"* ]]
    # Nothing left behind for a client to be sitting in.
    run tmux list-sessions -F '#{session_name}'
    [[ "$output" != *"dejima-0123456789abcdef"* ]]
}

@test "an existing session whose name merely starts with the group name is not attached to" {
    # tmux resolves an unanchored target by prefix, then by fnmatch, so a
    # session named dejima-<id><anything> answers to the group's own name -
    # and "is the group already there?" answering yes about someone else's
    # session hands the remote client that session instead of the sandbox.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    start_tmux
    tmux new-session -d -s 'dejima-0123456789abcdefx' 'sleep 300'
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'

    script -qec "$REPO_ROOT/bin/dejima-attach 0123456789abcdef" /dev/null >/dev/null 2>&1 &
    attach_pid=$!
    for _ in $(seq 50); do
        [ -n "$(tmux list-clients -F '#{client_session}')" ] && break
        sleep 0.1
    done
    [ "$(tmux list-clients -F '#{client_session}')" = "dejima-0123456789abcdef" ]
    # And it is the sandbox's window, not the decoy's shell.
    tmux list-panes -s -t '=dejima-0123456789abcdef' -F '#{pane_id}' | grep -qxF "$TARGET_PANE"
    kill "$attach_pid" 2>/dev/null || true
}
