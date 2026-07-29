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
        ${TMUX_DIR:+"$TMUX_DIR"} ${FAKE_HOME:+"$FAKE_HOME"}
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
    # Seeded with hooks the operator already had, not an empty object: the
    # per-session registration appends to whatever Notification/Stop entries
    # are there, and against `{}` there is nothing to lose, so replacing
    # instead of appending would look identical. Kept as a pristine copy too,
    # to assert the real file is left byte-for-byte alone.
    cat > "$LAUNCH_DIR/settings-seed.json" <<'EOF'
{
  "hooks": {
    "Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "operator-desktop-notify.sh"}]}],
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "operator-tts.sh"}]}]
  }
}
EOF
    cp "$LAUNCH_DIR/settings-seed.json" "$LAUNCH_DIR/home/.claude/settings.json"
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
# Snapshot the generated settings copy while it still exists - bin/dejima's
# EXIT trap deletes it. It has to come from the exported
# $SANDBOX_SETTINGS_FILE rather than from a -v argument, because that mount
# is declared in docker-compose.yml and so never appears in this argv (same
# reason test/project.bats reads the run environment).
for arg in "$@"; do
    [ "$arg" = run ] || continue
    [ -z "${SANDBOX_TEST_SETTINGS_COPY:-}" ] || cp "$SANDBOX_SETTINGS_FILE" "$SANDBOX_TEST_SETTINGS_COPY"
    break
done
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
        SANDBOX_TEST_SETTINGS_COPY="$LAUNCH_DIR/settings-copy.json" \
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
    # The settings copy is off-argv (docker-compose.yml declares that mount),
    # so an unchanged run line alone would not notice a notify hook being
    # registered into it. Assert it was actually captured first - grep on a
    # missing file also "finds nothing".
    [ "$(jq '.sandbox.enabled' "$LAUNCH_DIR/settings-copy.json")" = "false" ]
    run grep -q 'dejima-notify' "$LAUNCH_DIR/settings-copy.json"
    [ "$status" -ne 0 ]
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
    # Same hazard for the settings-rewrite scratch file the remote block
    # uses: cleanup() rm -f's it, so an inherited value must not be believed
    # either.
    survive_file="$survive_parent/must-survive-too"
    : > "$survive_file"
    export SANDBOX_REMOTE_SETTINGS_TMP="$survive_file"
    # The same hazard for every other name cleanup() removes but only assigns
    # inside a conditional block. This run has no nvim config and no approved
    # dependencies, so none of the three is ever set - and one of them is an
    # `rm -rf` argument, which takes a whole tree, not a file.
    survive_lock="$survive_parent/must-survive-lock"
    survive_dockerfile="$survive_parent/must-survive-dockerfile"
    survive_ctx="$survive_parent/must-survive-ctx"
    : > "$survive_lock"
    : > "$survive_dockerfile"
    mkdir -p "$survive_ctx/deep"
    : > "$survive_ctx/deep/canary"
    export SANDBOX_NVIM_LOCKFILE="$survive_lock"
    export SANDBOX_DERIVED_DOCKERFILE="$survive_dockerfile"
    export SANDBOX_DERIVED_CONTEXT="$survive_ctx"
    launch "$PROJ"
    unset DEJIMA_NOTIFY_DIR SANDBOX_REMOTE_SETTINGS_TMP SANDBOX_NVIM_LOCKFILE \
        SANDBOX_DERIVED_DOCKERFILE SANDBOX_DERIVED_CONTEXT
    [ -d "$survive" ]
    [ -f "$survive_file" ]
    [ -f "$survive_lock" ]
    [ -f "$survive_dockerfile" ]
    [ -f "$survive_ctx/deep/canary" ]
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

@test "an attach that cannot open a terminal leaves no session behind" {
    # `restrict,pty` in an authorized_keys entry permits a pty, it doesn't
    # force one, so `ssh -T <host>` runs the forced command with no terminal -
    # and the group is created before tmux ever tries to open one. A leaked
    # group never gets destroy-unattached, and every later attach to that run
    # id joins it instead of creating one, so it stays leaked.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    start_tmux
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'
    run "$REPO_ROOT/bin/dejima-attach" 0123456789abcdef
    [ "$status" -ne 0 ]
    run tmux has-session -t '=dejima-0123456789abcdef'
    [ "$status" -ne 0 ]
    tmux has-session -t '=work'
}

@test "attaching to a group that already exists still sets destroy-unattached" {
    # The option is per-session state, not per-client, so a group that ever
    # came into being without it outlives its client on every later attach.
    : > "$CONFIG_DIR/remote.conf"
    stub_docker_run_id 0123456789abcdef
    start_tmux
    tmux new-session -d -t '=work' -s 'dejima-0123456789abcdef'
    # show-options prints nothing at all for an option left at its default.
    [ -z "$(tmux show-options -t dejima-0123456789abcdef destroy-unattached)" ]
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'

    script -qec "$REPO_ROOT/bin/dejima-attach 0123456789abcdef" /dev/null >/dev/null 2>&1 &
    attach_pid=$!
    for _ in $(seq 50); do
        [ -n "$(tmux list-clients -F '#{client_session}')" ] && break
        sleep 0.1
    done
    [ "$(tmux list-clients -F '#{client_session}')" = "dejima-0123456789abcdef" ]
    [ "$(tmux show-options -t dejima-0123456789abcdef destroy-unattached)" = "destroy-unattached on" ]
    kill "$attach_pid" 2>/dev/null || true
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

@test "the notify hook writes an empty file named for the event and nothing else" {
    NOTIFY="$(mktemp -d)"
    DEJIMA_NOTIFY_DIR="$NOTIFY" run "$REPO_ROOT/hooks/dejima-notify.sh" waiting
    [ "$status" -eq 0 ]
    [ -f "$NOTIFY/waiting" ]
    [ ! -s "$NOTIFY/waiting" ]
    DEJIMA_NOTIFY_DIR="$NOTIFY" run "$REPO_ROOT/hooks/dejima-notify.sh" done
    [ "$status" -eq 0 ]
    [ -f "$NOTIFY/done" ]
    [ ! -s "$NOTIFY/done" ]
    # The marker's name is its entire meaning: the two events it accepts
    # created two files and nothing else. (Stdin is a separate property, and
    # this test does not pin it: `run` does not redirect stdin, so what the
    # hook gets here is whatever the suite was invoked with - normally
    # /dev/null, and normally already drained by an earlier test. See the
    # test below, which supplies stdin itself rather than inheriting it.)
    [ "$(ls -A "$NOTIFY" | sort | tr '\n' ' ')" = "done waiting " ]
    rm -rf "$NOTIFY"
}

@test "the notify hook never reads its stdin" {
    # Stdin is where sandbox-controlled bytes actually arrive: Claude Code
    # hands a hook a JSON payload containing the Notification `message` the
    # session itself wrote, plus transcript_path and cwd. If any of it landed
    # in the marker, the watcher would be composing the operator's phone
    # notification partly from text the sandbox chose.
    #
    # This has to supply stdin itself. The other hook tests run under bats'
    # `run`, which is a plain command substitution with no stdin redirection,
    # so the hook there inherits whatever the suite was invoked with: at
    # /dev/null (the usual case) a hook reading stdin into the marker leaves
    # it empty and passes. Those tests are not stdin-independent, they are
    # stdin-ambient - which is exactly why this property needs its own.
    NOTIFY="$(mktemp -d)"
    payload='{"message":"INJECTED-DEEP-LINK-https://evil.invalid/x","cwd":"/w"}'
    payload_file="$(mktemp)"
    printf '%s' "$payload" > "$payload_file"

    # A regular file behind a shared fd, not a pipe: a pipe could not support
    # this check at all. The hook inherits fd 9's open file description,
    # offset included, so the assertion is the stronger "the bytes were never
    # consumed" rather than "the bytes did not reach the marker" - anything
    # the hook read, even to discard it, would be missing from what is left
    # to read here afterwards.
    exec 9<"$payload_file"
    DEJIMA_NOTIFY_DIR="$NOTIFY" "$REPO_ROOT/hooks/dejima-notify.sh" waiting <&9
    leftover="$(cat <&9)"
    exec 9<&-

    [ "$leftover" = "$payload" ]
    [ -f "$NOTIFY/waiting" ]
    [ ! -s "$NOTIFY/waiting" ]
    rm -rf "$NOTIFY" "$payload_file"
}

@test "the notify hook refuses any event name outside the enum" {
    NOTIFY="$(mktemp -d)"
    for bad in 'error' '../escape' 'waiting done' '' '$(id)' 'waiting;done' '.'; do
        DEJIMA_NOTIFY_DIR="$NOTIFY" run "$REPO_ROOT/hooks/dejima-notify.sh" "$bad"
        [ "$status" -eq 0 ]
    done
    # Nothing at all was created - the enum is a whitelist, not a filter.
    [ -z "$(ls -A "$NOTIFY")" ]
    rm -rf "$NOTIFY"
}

@test "the notify hook is inert when the marker directory is not mounted" {
    # Outside a remote-enabled session the variable is simply absent, and a
    # hook that failed there would surface an error on every notification in
    # an ordinary sandbox. A stale value pointing at nothing is the same
    # case, so it is refused the same way rather than by creating the path.
    run env -u DEJIMA_NOTIFY_DIR "$REPO_ROOT/hooks/dejima-notify.sh" waiting
    [ "$status" -eq 0 ]

    missing="$(mktemp -d)/gone"
    DEJIMA_NOTIFY_DIR="$missing" run "$REPO_ROOT/hooks/dejima-notify.sh" waiting
    [ "$status" -eq 0 ]
    [ ! -e "$missing" ]
}

@test "notify hooks are registered only in the throwaway settings copy" {
    stub_launch
    : > "$CONFIG_DIR/remote.conf"
    launch "$PROJ"
    grep -q 'dejima-notify.sh waiting' "$LAUNCH_DIR/settings-copy.json"
    grep -q 'dejima-notify.sh done' "$LAUNCH_DIR/settings-copy.json"
    # The copy is a throwaway, so the operator's real settings.json - which
    # nothing registers this hook into - is left byte-for-byte alone.
    cmp -s "$LAUNCH_DIR/settings-seed.json" "$LAUNCH_DIR/home/.claude/settings.json"
    # And what the copy carried before is still there: this appends, it does
    # not replace the file bin/dejima generated.
    [ "$(jq '.sandbox.enabled' "$LAUNCH_DIR/settings-copy.json")" = "false" ]
    # Including the operator's OWN Notification and Stop hooks - a desktop
    # notifier, a TTS reader, a logger. Replacing rather than appending would
    # silently disable them in every remote-enabled sandbox. They come first,
    # ahead of the appended dejima entries.
    [ "$(jq '.hooks.Notification | length' "$LAUNCH_DIR/settings-copy.json")" = "2" ]
    [ "$(jq '.hooks.Stop | length' "$LAUNCH_DIR/settings-copy.json")" = "2" ]
    [ "$(jq -r '.hooks.Notification[0].hooks[0].command' "$LAUNCH_DIR/settings-copy.json")" = "operator-desktop-notify.sh" ]
    [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$LAUNCH_DIR/settings-copy.json")" = "operator-tts.sh" ]
    rm -rf "$PROJ"
}

# A fake `curl` that records the ARGUMENT VECTOR it was handed: joined, and
# one argument per line. Deliberately not "what would have been sent" - real
# curl expands @file (in -H and -d), -K and -T, so bytes can reach the wire
# without ever appearing in argv. Confirmed against curl 7.88.1 and a live
# listener: `-H @/path` arrives as the header the file contains. Assertions
# that a secret is ABSENT from this log therefore prove nothing on their own;
# the whitelist below is what makes the log sufficient.
stub_curl() {
    STUB_DIR="${STUB_DIR:-$(mktemp -d)}"
    cat > "$STUB_DIR/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$STUB_DIR/curl-argv"
exit 0
EOF
    chmod +x "$STUB_DIR/curl"
    PATH="$STUB_DIR:$PATH"
}
curl_log() { cat "$STUB_DIR/curl-argv" 2>/dev/null; }

# The EXACT argument vector of one push, one argument per line - a whitelist,
# not a search. Absence assertions cannot do this job: an argument that leaks
# by REFERENCE ("-H @/path/to/secret") contains none of the bytes it sends, so
# every grep for the secret passes while the secret goes out. Compared whole,
# an added argument of any kind fails the test.
#
# $1 title suffix, $2 body, $3 click URL ("" for a config with no BASE_URL).
expect_argv() {
    printf '%s\n' -fsS --max-time 10 --retry 2 \
        -H "Title: dejima: $1" \
        -H "Priority: default"
    [ -z "${3:-}" ] || printf '%s\n' -H "Click: $3"
    printf '%s\n' -d "$2" -- https://ntfy.example.invalid/dejima
}
# Compared as a whole file, so a SECOND push would fail this too. The
# sentinel is what makes "whole" true: both sides are command substitutions,
# which strip trailing newlines, so without it a vector ending in an empty
# argument compares equal to one that does not have it.
assert_argv() {
    [ "$( { cat "$STUB_DIR/curl-argv"; echo .; } )" = "$( { expect_argv "$@"; echo .; } )" ]
}

marker() {
    mkdir -p "$RUNTIME_DIR/dejima/notify/$1"
    : > "$RUNTIME_DIR/dejima/notify/$1/$2"
}

conf_with_ntfy() {
    cat > "$CONFIG_DIR/remote.conf" <<'EOF'
NTFY_URL=https://ntfy.example.invalid/dejima
BASE_URL=https://dejima.example.invalid
EOF
}

@test "a marker produces a push composed entirely from host-side data" {
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    # The click URL is BASE_URL from remote.conf plus the DIRECTORY NAME, and
    # the project name comes from the registry's workspace= (host-written by
    # bin/dejima; write_entry sets it to /home/someone/myproject). Nothing
    # here is sourced from the marker.
    # Every argument, in order, and nothing else. The URL reaches curl as the
    # URL - last, after --, verbatim - and not as an option.
    assert_argv 'myproject needs input' 'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
    # Consumed, so a rerun doesn't re-push.
    [ ! -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]

    # The other half of the enum, which is otherwise never exercised. The log
    # is compared whole, so it starts empty for the second push.
    : > "$STUB_DIR/curl-argv"
    marker 0123456789abcdef done
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    assert_argv 'myproject finished' 'Session has stopped.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
    [ ! -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/done" ]
}

@test "a marker name outside the enum is never acted on" {
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    dir="$RUNTIME_DIR/dejima/notify/0123456789abcdef"
    mkdir -p "$dir"
    # Content is never read, so these are only ever names - and none of them
    # is in the enum. The hook's own enum constrains nothing here: a session
    # owns the contents of its bind-mounted marker directory and can create
    # any name it likes in it, hook or no hook.
    for name in error 'waiting; curl evil' 'X-Actions' 'waiting.' WAITING done2; do
        printf 'PAYLOAD' > "$dir/$name"
    done
    before="$(ls -A "$dir" | sort)"
    [ -n "$before" ]
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    [ -z "$(curl_log)" ]
    # Not merely un-pushed: untouched. An unrecognized name is never stat'd,
    # read, or removed, so the whitelist cannot quietly become a filter.
    [ "$(ls -A "$dir" | sort)" = "$before" ]
}

@test "marker content never reaches the push" {
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/0123456789abcdef"
    # ntfy's X-Actions header makes the phone issue an arbitrary HTTP request
    # or fire an Android intent - one attacker-chosen header is a confused
    # deputy inside the operator's LAN, which is why content is never read.
    printf 'X-Actions: http, pwn, https://evil.example.invalid\n' \
        > "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting"
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    # The whole vector, not a grep for the payload: a watcher that passed the
    # marker on by reference (-H @"$marker", or a copy of it) would send this
    # header verbatim while every absence assertion still passed.
    assert_argv 'myproject needs input' 'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
}

@test "a symlinked marker is removed without its target being read or touched" {
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/0123456789abcdef"
    secret="$RUNTIME_DIR/host-secret"
    printf 'HOSTSECRET' > "$secret"
    ln -s "$secret" "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting"
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    # The link is gone, the host file it aimed at is intact, and nothing from
    # it was sent. rm unlinks a symlink rather than following it; a watcher
    # that opened the marker instead would be reading an operator-chosen file.
    [ ! -L "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]
    [ ! -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]
    [ -f "$secret" ]
    [ "$(cat "$secret")" = "HOSTSECRET" ]
    # Intact is not enough - the target must not have been READ either, and a
    # read that leaves the file alone is invisible from the filesystem. The
    # whole vector says so: no argument names the marker, the link, or the
    # target, so there is nothing for curl to open on their behalf.
    assert_argv 'myproject needs input' 'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
}

@test "a dangling symlinked marker is consumed rather than left in place forever" {
    # [ -e ] follows the link and is FALSE for a dangling one, so without the
    # -L arm a session could leave links a scan never clears - and the target
    # must still not be created on its behalf.
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/0123456789abcdef"
    ln -s "$RUNTIME_DIR/nothing-here" "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting"
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    [ ! -L "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]
    [ ! -e "$RUNTIME_DIR/nothing-here" ]
    [ -n "$(curl_log)" ]
}

@test "a marker directory whose name is not a run id is ignored entirely" {
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    # Beside the marker root, which is where a "../"-shaped name would land if
    # one were ever joined onto the scan path.
    mkdir -p "$RUNTIME_DIR/dejima/escape-attempt"
    : > "$RUNTIME_DIR/dejima/escape-attempt/waiting"
    for bad in NOTARUNID 0123456789ABCDEF 0123456789abcde 0123456789abcdef0; do
        mkdir -p "$RUNTIME_DIR/dejima/notify/$bad"
        : > "$RUNTIME_DIR/dejima/notify/$bad/waiting"
    done
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    [ -z "$(curl_log)" ]
    # And none of them was consumed either.
    [ -f "$RUNTIME_DIR/dejima/notify/NOTARUNID/waiting" ]
    [ -f "$RUNTIME_DIR/dejima/escape-attempt/waiting" ]
}

@test "repeat markers for the same event are debounced" {
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    "$REPO_ROOT/bin/dejima-notify-watch" --once
    assert_argv 'myproject needs input' 'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
    marker 0123456789abcdef waiting
    DEJIMA_DEBOUNCE_SECONDS=3600 run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    # Still that one push and no other: the vector is compared whole, so a
    # second would appear as trailing arguments and fail here.
    assert_argv 'myproject needs input' 'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
    # Debounced means "not pushed", not "not consumed" - a marker left behind
    # would re-push the moment the window expired.
    [ ! -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]
}

@test "the watcher refuses to start without NTFY_URL" {
    : > "$CONFIG_DIR/remote.conf"
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_URL"* ]]
}

@test "the watcher refuses to start at all without remote.conf" {
    # The opt-in guarantee: with the feature unconfigured nothing here runs,
    # and in particular no state directory is created.
    stub_curl
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
    [ ! -d "$RUNTIME_DIR/dejima" ]
    [ -z "$(curl_log)" ]
}

@test "a config value curl would read as an option is refused, not passed on" {
    # valid_remote_value permits a leading '-', which is harmless in a config
    # file and not harmless in curl's argument list: curl reads "-K/path" as
    # an OPTION, and -K takes the request's URL (and its output file) from
    # that path instead - verified against the real curl, which duly connected
    # to the config file's URL rather than to the one in remote.conf. So a
    # value that isn't a URL sends the push somewhere the operator never
    # named. remote.conf is operator-written, which is a reason to refuse a
    # bad value loudly rather than to assume a good one.
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    printf 'NTFY_URL=-K/tmp/dejima-test-curl-config\n' > "$CONFIG_DIR/remote.conf"
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"NTFY_URL"* ]]
    [ -z "$(curl_log)" ]

    # BASE_URL reaches the phone as the Click: target rather than curl's argv,
    # but it is the same class of value and the same refusal.
    printf 'NTFY_URL=https://ntfy.example.invalid/t\nBASE_URL=-o/tmp/dejima-test-out\n' \
        > "$CONFIG_DIR/remote.conf"
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"BASE_URL"* ]]
    [ -z "$(curl_log)" ]
    # Refused before anything was consumed, so a real marker is still there.
    [ -f "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]
}

@test "the debounce store cannot execute anything through the age arithmetic" {
    # Same shape as the registry's started=: bash evaluates a non-numeric
    # value in $(( )) as a VARIABLE NAME and runs any command substitution in
    # its subscript, and set -u does not catch it because `now` is bound right
    # there. The debounce directory is host-owned and never mounted, so this
    # is about not leaving the pattern in the repo - it shipped as a Critical
    # once already, in bin/dejima-attach.
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    mkdir -p "$RUNTIME_DIR/dejima/debounce"
    canary="$RUNTIME_DIR/PWNED"
    printf 'now[$(touch %s)]' "$canary" \
        > "$RUNTIME_DIR/dejima/debounce/0123456789abcdef-waiting"
    # Bounded because this is the probe most likely to reach an arithmetic
    # error, and such an error unwinds to the top level, discarding the rest
    # of the enclosing command - the script keeps its --once exit OUT of that
    # command for exactly this reason, and if that ever regresses a bounded
    # test fails where an unbounded one hangs the whole file.
    run timeout 30 "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    [ ! -e "$canary" ]
    # An unparseable stamp reads as "not sent recently": failing the other way
    # would let one junk file silence a session's notifications for good.
    [ -n "$(curl_log)" ]
}

@test "a marker the watcher cannot consume does not silence every other session" {
    # /run/dejima-notify is bind-mounted read-write, so a session can make its
    # own marker undeletable - a directory named `waiting` is enough. One scan
    # covers every run directory, so an rm that is fatal under set -e lets one
    # compromised sandbox suppress all the others' notifications. The
    # undeletable one sorts first, so it is reached first.
    conf_with_ntfy
    stub_curl
    write_entry 0000000000000000 '%1' 'work:1'
    write_entry 0123456789abcdef '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/0000000000000000/waiting/not-empty"
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    [[ "$(curl_log)" == *"?arg=0123456789abcdef"* ]]
    [[ "$output" == *"warning"* ]]
    # And the one it could not consume was not pushed either: a marker that
    # survives would otherwise re-push on every single scan.
    [[ "$(curl_log)" != *"?arg=0000000000000000"* ]]
}

@test "an unreadable registry entry does not abort the scan" {
    # project_of reads the registry with `done < "$file"`, which is fatal
    # under set -e when the file cannot be opened - and again, one scan covers
    # every run directory.
    conf_with_ntfy
    stub_curl
    write_entry 0000000000000000 '%1' 'work:1'
    write_entry 0123456789abcdef '%1' 'work:2'
    chmod 000 "$RUNTIME_DIR/dejima/sessions/0000000000000000"
    marker 0000000000000000 waiting
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    [[ "$(curl_log)" == *"?arg=0123456789abcdef"* ]]
    # The entry it could not read still gets a push, just without a name.
    [[ "$(curl_log)" == *"?arg=0000000000000000"* ]]
}

@test "the watcher refuses a state directory that is a symlink" {
    # Same hazard bin/dejima already refuses: /tmp is the fallback parent when
    # XDG_RUNTIME_DIR is unset, and `mkdir -p -m 700` only sets the mode of
    # the leaf it creates, so a planted symlink here would send every mkdir
    # and every rm below it into someone else's tree.
    conf_with_ntfy
    stub_curl
    elsewhere="$(mktemp -d)"
    mkdir -p "$elsewhere/notify/0123456789abcdef"
    : > "$elsewhere/notify/0123456789abcdef/waiting"
    ln -s "$elsewhere" "$RUNTIME_DIR/dejima"
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
    [ -z "$(curl_log)" ]
    [ -f "$elsewhere/notify/0123456789abcdef/waiting" ]
    rm -rf "$elsewhere"
}

@test "a push still goes out when BASE_URL is not configured" {
    # BASE_URL is optional - ntfy alone is a complete setup, and it is the
    # only half that needs to be reachable from the phone. This pins the
    # otherwise-unexercised branch that composes no Click header at all,
    # including the empty-array expansion it hands to curl under set -u.
    printf 'NTFY_URL=https://ntfy.example.invalid/dejima\n' > "$CONFIG_DIR/remote.conf"
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    # No Click argument at all, rather than an empty one.
    assert_argv 'myproject needs input' 'Session is waiting for you.' ''
    [ ! -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]
}

@test "an argument that is not --once is refused rather than watched forever" {
    # Anything unrecognized - a typo, --help - used to fall into the watch
    # loop, which for an interactive invocation looks like a hang.
    conf_with_ntfy
    stub_curl
    for bad in --help --onces -x once; do
        run timeout 10 "$REPO_ROOT/bin/dejima-notify-watch" "$bad"
        [ "$status" -eq 2 ]
        [[ "$output" == *"usage:"* ]]
    done
    [ -z "$(curl_log)" ]
}

@test "the watcher refuses a state directory it does not own or that is not a directory" {
    # The other two arms of the same guard. The ownership arm is the one that
    # matters for the /tmp fallback - another local user pre-creating
    # /tmp/dejima as a real directory of their own - and it cannot be set up
    # for real without root, so the ownership PROBE is stubbed instead: the
    # script asks `stat -c %u`, and here it gets an answer that is not us.
    conf_with_ntfy
    stub_curl
    cat > "$STUB_DIR/stat" <<EOF
#!/bin/bash
[ "\$1" = "-c" ] && [ "\$2" = "%u" ] && { printf '4242\n'; exit 0; }
exec $(command -v stat) "\$@"
EOF
    chmod +x "$STUB_DIR/stat"
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"owned"* ]]
    [ -z "$(curl_log)" ]
    # Refused, not cleaned up: it is not ours to touch.
    [ -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]

    # And the arm for a state path that is not a directory at all.
    rm -f "$STUB_DIR/stat"
    rm -rf "$RUNTIME_DIR/dejima"
    printf 'not a directory' > "$RUNTIME_DIR/dejima"
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [ -z "$(curl_log)" ]
    [ "$(cat "$RUNTIME_DIR/dejima")" = "not a directory" ]
}

@test "a workspace path that would split a header is reduced before it is sent" {
    # The registry is host-written, so this is not a sandbox escape - it is an
    # operator whose directory name contains a CR, which would end the Title
    # header and start one of the reader's choosing.
    conf_with_ntfy
    stub_curl
    mkdir -p "$RUNTIME_DIR/dejima/sessions"
    # No slash in the payload: basename would eat everything before the last
    # one, which would hide what this test is about.
    printf 'workspace=/home/someone/my%sX-Actions: pwn\npane=%%1\n' \
        "$(printf '\r')" > "$RUNTIME_DIR/dejima/sessions/0123456789abcdef"
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    # One Title argument, on one line, with the CR, the space and the colon
    # gone - so there is no second header and no header value to control.
    assert_argv 'myX-Actionspwn needs input' \
        'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
}

@test "a workspace name longer than the header allowance is truncated" {
    conf_with_ntfy
    stub_curl
    mkdir -p "$RUNTIME_DIR/dejima/sessions"
    long="$(printf 'a%.0s' $(seq 1 200))"
    printf 'workspace=/home/someone/%s\npane=%%1\n' "$long" \
        > "$RUNTIME_DIR/dejima/sessions/0123456789abcdef"
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    assert_argv "$(printf 'a%.0s' $(seq 1 64)) needs input" \
        'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
}

@test "a debounce window that is not a number is refused" {
    # It reaches an arithmetic context, and it is the one input to this script
    # that comes from the unit file's environment rather than from a file.
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    # Not the empty string: unset and empty both mean "use the default".
    for bad in 'x[$(touch '"$RUNTIME_DIR"'/PWNED)]' '60s' '-1' '6 0'; do
        DEJIMA_DEBOUNCE_SECONDS="$bad" run "$REPO_ROOT/bin/dejima-notify-watch" --once
        [ "$status" -ne 0 ]
        [[ "$output" == *"DEJIMA_DEBOUNCE_SECONDS"* ]]
    done
    [ ! -e "$RUNTIME_DIR/PWNED" ]
    [ -z "$(curl_log)" ]
    # Refused before the scan, so the marker is still there to push later.
    [ -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]
}

@test "an inotifywait that returns immediately does not spin the watcher" {
    # Both ways a sandbox can make the wait stop waiting, and they need
    # different guards:
    #   exit 1 - the wait FAILS. Reachable from inside: -r takes one inotify
    #     watch per directory under the marker root, and a session owns its
    #     own marker directory, so it can mkdir enough of them to exhaust this
    #     uid's max_user_watches. Bounded by the fallback sleep.
    #   exit 0 - the wait SUCCEEDS, over and over. Needs no exhaustion at all:
    #     the enum does not gate the wake path, so any file the session
    #     creates is an event. Bounded by the floor under the loop.
    conf_with_ntfy
    stub_curl
    for rc in 1 0; do
        # Thresholds differ because the two guards bound different rates, and
        # a threshold the floor alone can meet would leave the other unpinned:
        #   rc=1 - floor then a five second fallback, so one call in three
        #     seconds. Two or more means only the floor is left.
        #   rc=0 - the floor alone, about one a second. Unbounded, this is in
        #     the hundreds (571 in five seconds, measured).
        case "$rc" in
            1) max=2 ;;
            0) max=10 ;;
        esac
        : > "$STUB_DIR/inotify-calls"
        cat > "$STUB_DIR/inotifywait" <<EOF
#!/bin/bash
printf 'x' >> "$STUB_DIR/inotify-calls"
exit $rc
EOF
        chmod +x "$STUB_DIR/inotifywait"
        "$REPO_ROOT/bin/dejima-notify-watch" >/dev/null 2>&1 &
        watcher=$!
        sleep 3
        kill "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
        [ "$(wc -c < "$STUB_DIR/inotify-calls")" -lt "$max" ]
    done
}

@test "a marker that cannot be consumed is warned about once, not once per scan" {
    # The warning is on the path a session controls - it makes its own marker
    # undeletable - and the loop revisits it on every scan, so undeduplicated
    # this is the journal-growth half of the same denial of service.
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting/not-empty"
    # Scans have to actually repeat for this to mean anything, and this host
    # has no inotifywait, which would leave the loop sleeping 5s and the test
    # vacuous. A stub that returns at once puts it at the floor: ~3 scans.
    cat > "$STUB_DIR/inotifywait" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$STUB_DIR/inotifywait"
    "$REPO_ROOT/bin/dejima-notify-watch" > /dev/null 2> "$STUB_DIR/watch-err" &
    watcher=$!
    sleep 3
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    [ "$(grep -c 'could not consume marker' "$STUB_DIR/watch-err")" -eq 1 ]
}

@test "the state directory is tightened even when another process created it" {
    # -m 700 applies only to the process that creates the directory, and by
    # this script's own design either side may get there first.
    conf_with_ntfy
    stub_curl
    mkdir -p -m 755 "$RUNTIME_DIR/dejima"
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$RUNTIME_DIR/dejima")" = "700" ]
}

# ---------------------------------------------------------------------------
# The front doors: bin/dejima-ttyd, the systemd units that run it and the
# watcher, the nginx example that fronts it, and the install.sh wiring that
# puts all of it where those units expect to find it.
#
# Most of what follows is necessarily static - there is no ttyd, no systemd
# and no nginx on the machines this suite runs on. Two things guard against
# the vacuous pass that invites: every negative grep is preceded by a check
# that its files exist (a grep against a missing file "finds nothing" too),
# and the two properties that actually matter - what ttyd is launched with,
# and what environment the units give the scripts - are executed rather than
# grepped.
# ---------------------------------------------------------------------------

# A fake ttyd that records the argv it was exec'd with. ttyd is not installed
# here, which is exactly why it is stubbed rather than skipped: without it
# every "dejima-ttyd fails" assertion below is true for the wrong reason.
stub_ttyd() {
    STUB_DIR="${STUB_DIR:-$(mktemp -d)}"
    cat > "$STUB_DIR/ttyd" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$STUB_DIR/ttyd-argv"
exit 0
EOF
    chmod +x "$STUB_DIR/ttyd"
    PATH="$STUB_DIR:$PATH"
}
ttyd_log() { cat "$STUB_DIR/ttyd-argv" 2>/dev/null; }

# The EXACT argument vector, one argument per line - a whitelist, for the same
# reason expect_argv above is one. The bind address is the security property
# of this whole task, and an absence grep cannot see a SECOND --interface, a
# --credential that turns nginx's auth into a duplicate, or a dropped flag.
# $1 is the expected port. The command must be this repo's dejima-attach,
# resolved the way the script resolves it (readlink -f, so a $BATS_TEST_DIRNAME
# with a ".." in it does not make this a comparison of two spellings).
expect_ttyd_argv() {
    printf '%s\n' --interface 127.0.0.1 --port "$1" --url-arg --writable \
        "$(readlink -f "$REPO_ROOT/bin")/dejima-attach"
}
# Sentinel on both sides: both are command substitutions, which strip trailing
# newlines, so without it a vector ending in an empty argument compares equal
# to one that does not have it.
assert_ttyd_argv() {
    [ "$( { cat "$STUB_DIR/ttyd-argv"; echo .; } )" = "$( { expect_ttyd_argv "$@"; echo .; } )" ]
}

# ExecStart= with %h expanded, i.e. what systemd would actually run. Read out
# of the unit rather than repeated here, so a unit that points somewhere else
# fails these tests instead of quietly testing a path nothing uses.
unit_exec_start() {
    local line
    line="$(grep -m1 '^ExecStart=' "$REPO_ROOT/systemd/$1")"
    line="${line#ExecStart=}"
    printf '%s' "${line//%h/$2}"
}

@test "dejima-ttyd binds ttyd to loopback and takes its port from remote.conf" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    printf 'TTYD_PORT=12345\n' > "$CONFIG_DIR/remote.conf"
    stub_ttyd
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 12345

    # The default is the library's, not a second copy of it in this script.
    : > "$STUB_DIR/ttyd-argv"
    : > "$CONFIG_DIR/remote.conf"
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 7681
}

@test "dejima-ttyd refuses to start without remote.conf, before ttyd is reached" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    stub_ttyd
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
    # The reason matters: on a machine with no ttyd this test passes for free.
    [ -z "$(ttyd_log)" ]
}

@test "dejima-ttyd reports a missing ttyd instead of exec-ing into nothing" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    : > "$CONFIG_DIR/remote.conf"
    # A PATH holding only what the script itself needs, so the absence of ttyd
    # is a property of this test rather than of whoever runs it.
    STUB_DIR="$(mktemp -d)"
    for tool in readlink dirname; do
        ln -s "$(command -v "$tool")" "$STUB_DIR/$tool"
    done
    run env PATH="$STUB_DIR" "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    # The exact message, not just a failure: an unwritten script is "not
    # found" too, and `exec ttyd` with no ttyd says so in bash's words rather
    # than in words that tell an operator what to install.
    [[ "$output" == *"ttyd is not installed"* ]]
}

@test "dejima-ttyd refuses an out-of-range TTYD_PORT rather than launching without one" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    printf 'TTYD_PORT=99999\n' > "$CONFIG_DIR/remote.conf"
    stub_ttyd
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    # Named, so this cannot pass because ttyd was missing or the config was.
    [[ "$output" == *"TTYD_PORT out of range"* ]]
    [ -z "$(ttyd_log)" ]
}

@test "nothing shipped by the front doors binds a routable address" {
    # Load-bearing, not stylistic. docker/init-firewall.sh:187 accepts
    # container OUTPUT to the default-route address, which is the Docker
    # bridge gateway - the host - and attaching tmux gives a host shell. A
    # listener on any address the container can route to is the sandbox's own
    # escape hatch. Loopback is not one of those addresses.
    local f
    for f in bin/dejima-ttyd systemd/dejima-ttyd.service \
             systemd/dejima-notify-watch.service docs/nginx-dejima.conf.example; do
        # Without this, every negative grep below passes on a missing file.
        [ -f "$REPO_ROOT/$f" ]
    done
    grep -q -- '--interface 127\.0\.0\.1' "$REPO_ROOT/bin/dejima-ttyd"
    # Not just "no 0.0.0.0": the only address any of these files may name is
    # the loopback one dejima-ttyd binds and nginx proxies to.
    run bash -c 'grep -rhoE "([0-9]{1,3}\.){3}[0-9]{1,3}" "$@" | sort -u' _ \
        "$REPO_ROOT/bin/dejima-ttyd" "$REPO_ROOT/systemd" \
        "$REPO_ROOT/docs/nginx-dejima.conf.example"
    [ "$status" -eq 0 ]
    [ "$output" = "127.0.0.1" ]
}

@test "the shipped front-door artifacts carry no real network details" {
    # This repo is public. No operator's hostnames, LAN addresses or ntfy
    # topics belong in it - not even in a comment. Every host in these files
    # is an <angle-bracket> placeholder, so anything that could resolve to a
    # real machine is a mistake.
    local files=("$REPO_ROOT/bin/dejima-ttyd" "$REPO_ROOT/systemd"
                 "$REPO_ROOT/docs/nginx-dejima.conf.example") f
    for f in "${files[@]}"; do
        # Without this, both greps below "find nothing" in a missing file.
        [ -e "$f" ]
    done
    # Every absolute URL has to be a name that cannot belong to anyone: the
    # loopback address, or an RFC 2606 documentation name. This is the rule
    # that catches an ntfy topic, which is always a URL.
    run bash -c 'grep -rhoiE "https?://[a-z0-9.:@_-]+" "$@" \
        | grep -viE "^https?://(127\.0\.0\.1(:[0-9]+)?|(www\.)?example\.(com|net|org)|[a-z0-9-]+\.invalid)"' \
        _ "${files[@]}"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    # And no private-network or mDNS suffix in any form, URL or not. The
    # leading host character is what keeps this off ~/.local/bin, which is
    # where these units point.
    run grep -rniE '[a-z0-9-]\.(localdomain|lan|local|home|internal|arpa)([^a-z0-9/-]|$)' "${files[@]}"
    [ "$status" -ne 0 ]
    # And the placeholders really are placeholders.
    grep -q '<LAN-IP>' "$REPO_ROOT/docs/nginx-dejima.conf.example"
    grep -q '<hostname>' "$REPO_ROOT/docs/nginx-dejima.conf.example"
}

@test "the nginx example cannot be loaded as-is and never binds every interface" {
    local ex="$REPO_ROOT/docs/nginx-dejima.conf.example"
    [ -f "$ex" ]
    grep -q '/path/to/' "$ex"
    # At least one listen, and no listen line that omits the placeholder
    # address: a bare `listen 443 ssl;` binds every interface, including the
    # bridge address the container can reach.
    run grep -cE '^[[:space:]]*listen[[:space:]]+<LAN-IP>:' "$ex"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    run bash -c 'grep -hE "^[[:space:]]*listen[[:space:]]" "$1" | grep -v "<LAN-IP>:"' _ "$ex"
    [ "$status" -ne 0 ]
}

@test "the nginx example proxies to the port dejima-ttyd defaults to, over a connection that can idle" {
    local ex="$REPO_ROOT/docs/nginx-dejima.conf.example" port
    [ -f "$ex" ]
    # Taken from the library rather than hardcoded, so the example and the
    # default can never drift apart without this failing.
    : > "$CONFIG_DIR/remote.conf"
    run lib remote_ttyd_port
    [ "$status" -eq 0 ]
    port="$output"
    [ -n "$port" ]
    grep -qF "proxy_pass http://127.0.0.1:$port;" "$ex"
    grep -qE '^[[:space:]]*proxy_http_version[[:space:]]+1\.1;' "$ex"
    grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+Upgrade[[:space:]]+\$http_upgrade;' "$ex"
    grep -qiE '^[[:space:]]*proxy_set_header[[:space:]]+Connection[[:space:]]+"upgrade";' "$ex"
    # An attached terminal can sit idle for hours, so the read timeout has to
    # be measured in hours or days - nginx's own default is 60 seconds.
    run grep -hoE 'proxy_read_timeout[[:space:]]+[0-9]+[smhd]?' "$ex"
    [ "$status" -eq 0 ]
    [[ "$output" =~ [0-9]+[hd]$ ]]
}

@test "the nginx example carries the only authentication there is" {
    local ex="$REPO_ROOT/docs/nginx-dejima.conf.example"
    [ -f "$ex" ]
    grep -qE '^[[:space:]]*auth_basic[[:space:]]' "$ex"
    grep -qE '^[[:space:]]*auth_basic_user_file[[:space:]]' "$ex"
    grep -qE '^[[:space:]]*ssl_certificate[[:space:]]' "$ex"
    # ttyd is started --writable and with no credential of its own, so nginx
    # is the whole gate. If that ever changes, both halves have to change
    # together rather than one of them drifting.
    grep -q -- '--writable' "$REPO_ROOT/bin/dejima-ttyd"
    run grep -nE -- '--credential|[[:space:]]-c[[:space:]]' "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
}

@test "install.sh links the remote scripts and the notify hook, registers neither, and enables nothing" {
    grep -q '^link_hook dejima-notify.sh$' "$REPO_ROOT/install.sh"
    grep -q '^link_bin dejima-attach$' "$REPO_ROOT/install.sh"
    grep -q '^link_bin dejima-ttyd$' "$REPO_ROOT/install.sh"
    grep -q '^link_bin dejima-notify-watch$' "$REPO_ROOT/install.sh"
    # The notify hook is registered per session by bin/dejima, into a
    # throwaway settings copy. Registered here it would fire for every
    # unsandboxed host session too.
    run grep -nE 'register_hook.*dejima-notify' "$REPO_ROOT/install.sh"
    [ "$status" -ne 0 ]
    # Standing up a front door is an explicit operator decision. Nothing in
    # the installer may start, enable or even copy a unit. Code only - the
    # comment that says the script never touches systemd is not a violation
    # of itself.
    run bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -nE "systemctl|loginctl|systemd"' \
        _ "$REPO_ROOT/install.sh"
    [ "$status" -ne 0 ]
}

@test "install.sh puts the notify hook and the remote scripts where the container and the units expect them" {
    FAKE_HOME="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    # install.sh checks for docker and `docker compose version`; jq and
    # python3 are real, and it needs them to be.
    printf '#!/bin/bash\nexit 0\n' > "$STUB_DIR/docker"
    chmod +x "$STUB_DIR/docker"

    run env HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]

    # bin/dejima registers $HOME/.claude/hooks/dejima-notify.sh per session,
    # and ~/.claude/hooks is what gets mounted read-only into the container.
    # Without this link every Notification and Stop is an exit-127.
    [ -L "$FAKE_HOME/.claude/hooks/dejima-notify.sh" ]
    [ "$(readlink -f "$FAKE_HOME/.claude/hooks/dejima-notify.sh")" \
      = "$(readlink -f "$REPO_ROOT/hooks/dejima-notify.sh")" ]
    [ -x "$FAKE_HOME/.claude/hooks/dejima-notify.sh" ]
    local b
    for b in dejima-attach dejima-ttyd dejima-notify-watch; do
        [ -L "$FAKE_HOME/.local/bin/$b" ]
        [ "$(readlink -f "$FAKE_HOME/.local/bin/$b")" = "$(readlink -f "$REPO_ROOT/bin/$b")" ]
        [ -x "$FAKE_HOME/.local/bin/$b" ]
    done

    # Positive first: an absence assertion against a settings.json that did
    # not get written would pass on its own.
    run jq -e '[.hooks[]?[]?.hooks[]?.command] | any(test("sandbox-context.sh"))' \
        "$FAKE_HOME/.claude/settings.json"
    [ "$status" -eq 0 ]
    run jq -e '[.hooks[]?[]?.hooks[]?.command] | any(test("dejima-notify"))' \
        "$FAKE_HOME/.claude/settings.json"
    [ "$status" -ne 0 ]

    # Nothing was enabled, and nothing under the runtime dir was created: the
    # feature stays off until the operator writes remote.conf.
    [ ! -e "$RUNTIME_DIR/dejima" ]
    [ ! -e "$FAKE_HOME/.config/systemd" ]

    # Re-runnable: the second pass displaces nothing into the backup dir.
    run env HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$FAKE_HOME/.dejima-backup" ]
    [ -L "$FAKE_HOME/.claude/hooks/dejima-notify.sh" ]
}

@test "the systemd units are user units that run the installed scripts and duplicate no configuration" {
    local u f
    for u in dejima-ttyd dejima-notify-watch; do
        f="$REPO_ROOT/systemd/$u.service"
        [ -f "$f" ]
        grep -q "^ExecStart=%h/\.local/bin/$u\$" "$f"
        grep -q '^WantedBy=default\.target$' "$f"
        # Directives only, from here down: these files carry comments that
        # name the very things a directive may not set ("do not repeat
        # NTFY_URL here"), and a grep that could not tell the two apart would
        # force those comments out of the file to stay green.
        run bash -c 'grep -vE "^[[:space:]]*[#;]" "$1" | grep -nE "^(User|Group)="' _ "$f"
        [ "$status" -ne 0 ]
        # No absolute home - %h is what makes these units the same file for
        # every operator.
        run bash -c 'grep -vE "^[[:space:]]*[#;]" "$1" | grep -nE "/home/|/root/|/Users/"' _ "$f"
        [ "$status" -ne 0 ]
        # remote.conf is the single source of truth for all of these. A unit
        # that repeated one would drift from the script that reads it.
        run bash -c 'grep -vE "^[[:space:]]*[#;]" "$1" | grep -nE "TTYD_PORT|NTFY_URL|BASE_URL|--port|--interface"' _ "$f"
        [ "$status" -ne 0 ]
        # No environment of their own either. The two tests below run
        # ExecStart under an environment they build themselves, so an
        # Environment= line here - an XDG_RUNTIME_DIR pointing somewhere the
        # markers are not, say - would be invisible to them.
        run bash -c 'grep -vE "^[[:space:]]*[#;]" "$1" | grep -nE "^(Environment|EnvironmentFile)="' _ "$f"
        [ "$status" -ne 0 ]
    done
}

@test "the ttyd unit's ExecStart launches ttyd with nothing but what systemd gives a user unit" {
    # systemd starts a user unit with the user manager's environment, not the
    # operator's shell's. env -i with the floor systemd guarantees (HOME,
    # PATH, XDG_RUNTIME_DIR) is what makes this test worth having: a script
    # that works only because some interactive-shell variable happened to be
    # set fails here rather than on the operator's phone.
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.local/bin" "$FAKE_HOME/.config/dejima"
    ln -s "$REPO_ROOT/bin/dejima-ttyd" "$FAKE_HOME/.local/bin/dejima-ttyd"
    printf 'TTYD_PORT=12345\n' > "$FAKE_HOME/.config/dejima/remote.conf"
    stub_ttyd

    local exec_start
    exec_start="$(unit_exec_start dejima-ttyd.service "$FAKE_HOME")"
    [ "$exec_start" = "$FAKE_HOME/.local/bin/dejima-ttyd" ]
    run env -i HOME="$FAKE_HOME" PATH="$STUB_DIR:/usr/bin:/bin" \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" "$exec_start"
    [ "$status" -eq 0 ]
    # %h resolved to the install destination, the symlink resolved back to
    # this repo (the command below is the repo's dejima-attach, not the
    # link), and remote.conf was found at the default config path with no
    # DEJIMA_CONFIG_DIR in the environment to point at it.
    assert_ttyd_argv 12345
}

@test "the notify-watch unit's ExecStart finds the markers in the runtime dir systemd gives it" {
    # The highest-risk integration point in the feature. bin/dejima resolves
    # ${XDG_RUNTIME_DIR:-/tmp}/dejima from the operator's shell; this unit
    # resolves it from the user manager's environment. If those ever disagree
    # the watcher watches an empty directory and no notification is ever
    # pushed - with no error anywhere to say so.
    conf_with_ntfy
    stub_curl
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.local/bin" "$FAKE_HOME/.config/dejima"
    ln -s "$REPO_ROOT/bin/dejima-notify-watch" "$FAKE_HOME/.local/bin/dejima-notify-watch"
    cp "$CONFIG_DIR/remote.conf" "$FAKE_HOME/.config/dejima/remote.conf"
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting

    local exec_start
    exec_start="$(unit_exec_start dejima-notify-watch.service "$FAKE_HOME")"
    [ "$exec_start" = "$FAKE_HOME/.local/bin/dejima-notify-watch" ]
    # --once bounds the scan; the unit's own argv is the line asserted above.
    run env -i HOME="$FAKE_HOME" PATH="$STUB_DIR:/usr/bin:/bin" \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" "$exec_start" --once
    [ "$status" -eq 0 ]
    assert_argv 'myproject needs input' 'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
    [ ! -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]
}
