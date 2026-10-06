#!/usr/bin/env bats
# Host-side tests for the opt-in remote access feature: config parsing, the
# session registry, the attach core, and the notification watcher. The
# watcher is a trust boundary - it consumes a directory a possibly
# compromised session writes into - so most of what's here is about what it
# refuses to do with that input.

# No test in this file may modify the repository's own CLIs. Two of them need
# an exit-time audit that fails, and they get it from a temp shadow of bin/
# (see shadow_repo) rather than by overwriting the real one. This is what
# proves it stayed that way even if a test aborts partway through, and it is
# checked against a hash rather than against `git status` so that it holds
# while someone has uncommitted edits to that file.
setup_file() {
    REMOTE_AUDIT_SUM="$(sha256sum "$BATS_TEST_DIRNAME/../bin/dejima-audit" | cut -d' ' -f1)"
    export REMOTE_AUDIT_SUM
}
teardown_file() {
    local now
    now="$(sha256sum "$BATS_TEST_DIRNAME/../bin/dejima-audit" | cut -d' ' -f1)"
    [ "$now" = "$REMOTE_AUDIT_SUM" ] || {
        echo "test/remote.bats modified bin/dejima-audit in the repository" >&2
        return 1
    }
}

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

# Writes a [remote-access] config with enabled = on and base_url set (so
# remote_enabled is true) plus whatever extra key = value lines a test needs.
write_remote_config() {
    { printf '[remote-access]\n'; printf 'enabled = on\n'; printf 'base_url = https://d.example\n'; printf '%s\n' "$@"; } \
        > "$CONFIG_DIR/config"
}

@test "remote_enabled is false until enabled is on, independent of base_url" {
    printf '[core]\nfirewall = on\n' > "$CONFIG_DIR/config"
    run lib remote_enabled
    [ "$status" -ne 0 ]
    # base_url alone is not the switch - it never was, and consolidation must
    # not make it one.
    printf '[remote-access]\nbase_url = https://d.example\n' > "$CONFIG_DIR/config"
    run lib remote_enabled
    [ "$status" -ne 0 ]
    printf '[remote-access]\nenabled = on\n' > "$CONFIG_DIR/config"
    run lib remote_enabled
    [ "$status" -eq 0 ]
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

# A throwaway copy of the repository whose bin/dejima-audit a test may
# replace or delete. Everything else is a symlink to the real thing, so this
# costs one directory of links.
#
# bin/ is copied rather than linked, and both reasons matter. bin/dejima
# resolves its own location with `readlink -f`, so a symlinked copy would
# point SCRIPT_DIR back at the repository and the stub would never be the one
# it calls. And a symlink is actively dangerous here: `cat > $SHADOW/bin/
# dejima-audit` follows it and truncates the real script, which is precisely
# what this helper exists to stop. Copying removes the whole class rather
# than one instance of it.
#
# Two tests here need an audit binary that fails, and they used to get one by
# overwriting `$REPO_ROOT/bin/dejima-audit` and restoring it afterwards. That
# left the working tree holding a two-line stub for the length of the test,
# which is a poor thing to do to a security tool: a run killed partway, or
# two runs of this file at once, restores the stub permanently instead of the
# script, and a suite that passes while silently disabling the exit-time
# audit is the exact failure this file exists to prevent. It also, reasonably
# enough, reads like an attack to anything watching the repository for
# changes.
shadow_repo() {
    local root entry
    root="$(cd "$REPO_ROOT" && pwd)"
    SHADOW="$BATS_TEST_TMPDIR/shadow"
    mkdir -p "$SHADOW"
    for entry in "$root"/*; do
        [ "$(basename "$entry")" = bin ] && continue
        ln -sfn "$entry" "$SHADOW/$(basename "$entry")"
    done
    cp -a "$root/bin" "$SHADOW/bin"
    DEJIMA_BIN="$SHADOW/bin/dejima"
}

# Stands in for the real audit and does nothing but fail. Self-describing
# because a file watcher can surface it mid-test, and a bare `exit 3` sitting
# where a security tool belongs is alarming without this comment on it.
shadow_failing_audit() {
    cat > "$SHADOW/bin/dejima-audit" <<'EOF'
#!/bin/bash
# Test fixture for test/remote.bats, living in that test's temp directory
# and never in the repository. Fails on purpose: bin/dejima must still
# report the container's exit code and not this one.
exit 3
EOF
    chmod +x "$SHADOW/bin/dejima-audit"
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

# ssh_key is written into whatever config file config_root() currently
# resolves to and appended rather than written, so it layers over whatever
# write_remote_config already put there instead of clobbering it - and so it
# still creates the file at all when a test calls launch() with no
# write_remote_config call.
launch() {
    local conf
    conf="$(bash -c 'source "$1"; config_path' _ "$LIB")"
    mkdir -p "$(dirname "$conf")"
    # No default, so a config that launches must select one.
    # A launch runs dejima-update-check, which would ls-remote this checkout's
    # own origin. Off here rather than in each fixture's config, because the
    # launch is what triggers it. Its cache needs nothing further: it lands
    # under $HOME, which every launch fixture already points somewhere of its
    # own.
    printf '[core]\nharness = claude-code\nupdate_check = off\nssh_key = %s\n' \
        "$LAUNCH_DIR/sandbox-key" >> "$conf"
    HOME="$LAUNCH_DIR/home" PATH="$LAUNCH_DIR:$PATH" \
        SANDBOX_TEST_DOCKER_LOG="$LAUNCH_DIR/docker-log" \
        SANDBOX_TEST_SETTINGS_COPY="$LAUNCH_DIR/settings-copy.json" \
        SSH_AUTH_SOCK= ALLOWED_DOMAINS= \
        "${DEJIMA_BIN:-$REPO_ROOT/bin/dejima}" "$@"
}

run_line() { grep -- ' run --rm ' "$LAUNCH_DIR/docker-log" | tail -1; }

@test "with remote access unconfigured the compose invocation is unchanged" {
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

@test "an inherited state dir and run id are not what the exit trap deletes" {
    # cleanup() removes "$DEJIMA_STATE_DIR/debounce/$DEJIMA_RUN_ID-{waiting,done}".
    # With remote access off nothing used to assign either name, so both came
    # from the caller's environment if it had them - and the trap then removed
    # a path of the environment's choosing. Both are bound by dejima before the
    # trap is installed now, so the join can only ever name a path it made.
    #
    # Two canaries, because either name alone being dejima's is enough to miss
    # the path: the removal needs both halves to come from the environment.
    stub_launch
    local canary="$LAUNCH_DIR/canary"
    mkdir -p "$canary/debounce"
    : > "$canary/debounce/deadbeefdeadbeef-waiting"
    : > "$canary/debounce/deadbeefdeadbeef-done"

    DEJIMA_STATE_DIR="$canary" DEJIMA_RUN_ID=deadbeefdeadbeef launch "$PROJ"

    [ -f "$canary/debounce/deadbeefdeadbeef-waiting" ] \
        || { echo "the trap removed a file named by the environment"; return 1; }
    [ -f "$canary/debounce/deadbeefdeadbeef-done" ] \
        || { echo "the trap removed a file named by the environment"; return 1; }
    rm -rf "$PROJ"
}

@test "with remote access configured a registry entry is written and removed on exit" {
    stub_launch
    write_remote_config
    launch "$PROJ"
    # The EXIT trap removes it, so the directory exists but is empty by now.
    [ -d "$RUNTIME_DIR/dejima/sessions" ]
    [ -z "$(ls -A "$RUNTIME_DIR/dejima/sessions")" ]
    [ -z "$(ls -A "$RUNTIME_DIR/dejima/notify")" ]
    rm -rf "$PROJ"
}

@test "the mounted marker directory is this run's own, and the registry is never mounted" {
    stub_launch
    write_remote_config
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
    #
    # Matched on the registry's own path, not on the bare word "sessions":
    # the harness has a ~/.claude/sessions of its own, and once that mount
    # moved from docker-compose.yml onto the command line this read as the
    # registry being mounted when it was not.
    case "$line" in
        */dejima/sessions*) false ;;
    esac
    rm -rf "$PROJ"
}

@test "a session cannot rewrite Claude Code's exit code through its marker directory" {
    # /run/dejima-notify is bind-mounted read-write, so a session can leave it
    # undeletable, and that rm -rf is the LAST command of bin/dejima's EXIT
    # trap - where under set -e a failure replaces the shell's exit status
    # with 1. Both halves are the session's to control, so without the guard a
    # compromised sandbox reports its own status in place of the real one.
    stub_launch
    write_remote_config
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        *:/run/dejima-notify)
            dir="${arg%:/run/dejima-notify}"
            mkdir -p "$dir/undeletable"
            : > "$dir/undeletable/file"
            chmod 500 "$dir/undeletable"
            exit 3
            ;;
    esac
done
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
    run launch "$PROJ"
    [ "$status" -eq 3 ]
    # Left behind rather than deleted, and said so out loud.
    [[ "$output" == *"could not remove the marker directory"* ]]
    # teardown's rm -rf would inherit the same refusal.
    chmod -R u+rwX "$RUNTIME_DIR"
    rm -rf "$PROJ"
}

@test "the exit-time audit still fires and prints after a forced marker-directory removal failure, without eating the real exit code" {
    # Task 10: cleanup() now runs the exit-time audit after the marker-
    # directory removal, structurally, so the operator's bottom-up read of
    # the terminal always lands on the verdict. Stack this session's own
    # provokable print (the marker-directory warning above) with a real
    # workspace change and a distinct container exit code, and check all
    # three survive together: the warning prints, the audit's report prints
    # strictly after it, and the container's own exit code (not 1, not the
    # audit's own status) is what bin/dejima reports.
    stub_launch
    write_remote_config
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in
        *:/run/dejima-notify)
            dir="${arg%:/run/dejima-notify}"
            mkdir -p "$dir/undeletable"
            : > "$dir/undeletable/file"
            chmod 500 "$dir/undeletable"
            echo '{}' > "$SANDBOX_TEST_WS/.mcp.json"
            exit 5
            ;;
    esac
done
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
    export SANDBOX_TEST_WS="$PROJ"
    run launch "$PROJ"
    unset SANDBOX_TEST_WS
    [ "$status" -eq 5 ]
    marker_line=$(printf '%s\n' "$output" | grep -n 'could not remove the marker directory' | head -1 | cut -d: -f1)
    audit_line=$(printf '%s\n' "$output" | grep -n 'HOST-CODE-EXECUTION workspace file: \.mcp\.json' | head -1 | cut -d: -f1)
    verdict_line=$(printf '%s\n' "$output" | grep -n 'CRITICAL - code that will run on your host' | head -1 | cut -d: -f1)
    [ -n "$marker_line" ]
    [ -n "$audit_line" ]
    [ -n "$verdict_line" ]
    [ "$marker_line" -lt "$audit_line" ]
    # The verdict is the true last line of everything bin/dejima printed -
    # not just after the marker warning, but after every other line too.
    total_lines=$(printf '%s\n' "$output" | wc -l)
    [ "$verdict_line" -eq "$total_lines" ]
    chmod -R u+rwX "$RUNTIME_DIR"
    rm -rf "$PROJ"
}

@test "the container's real exit code survives an exit-time audit invocation that itself fails" {
    # The brief's central question: cleanup() now calls dejima-audit compare
    # from the EXIT trap tail, guarded with || true specifically so that a
    # failing audit invocation cannot replace the shell's own exit status
    # under set -e. Prove it directly rather than by reasoning alone: swap
    # in an audit binary that exits nonzero, and confirm bin/dejima still
    # reports the container's own distinctive exit code (5 - neither 0, nor
    # 1, nor the audit stub's own failure code of 3).
    stub_launch
    write_remote_config
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    [ "$arg" = run ] && exit 5
done
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
    shadow_repo
    shadow_failing_audit
    run launch "$PROJ"
    [ "$status" -eq 5 ]
    rm -rf "$PROJ"
}

@test "the container's real exit code survives an exit-time audit invocation that does not exist" {
    # Same guarantee, second failure mode named by the brief: the audit
    # binary missing entirely (a broken install, a bad upgrade) makes the
    # shell's own exec fail with 127 at that point in cleanup() - still
    # guarded by the same || true, so it must not surface as bin/dejima's
    # reported exit code either.
    stub_launch
    write_remote_config
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    [ "$arg" = run ] && exit 5
done
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
    shadow_repo
    rm -f "$SHADOW/bin/dejima-audit"
    run launch "$PROJ"
    [ "$status" -eq 5 ]
    rm -rf "$PROJ"
}

@test "an undeletable entry in SANDBOX_GITCONFIG_DIR does not abort the exit trap or eat the real exit code" {
    # CRITICAL 2: SANDBOX_GITCONFIG_DIR is bind-mounted read-write into the
    # container (docker-compose.yml, no :ro), unconditionally for every
    # session - unlike the notify marker directory above, this one exists
    # whether or not remote access is even configured. A session can leave
    # an undeletable subdirectory in it, making the host-side `rm -rf` fail;
    # before the `|| true` guard, that failure would abort cleanup()'s EXIT
    # trap right there under set -e, so dejima-audit compare never runs and
    # bin/dejima would report 1 in place of the container's real exit code.
    # Prove both halves survive together: the audit still runs (a workspace
    # change it plants is still reported) and the container's own
    # distinctive exit code (7 - neither 0 nor 1) comes through unchanged.
    stub_launch
    cat > "$LAUNCH_DIR/docker" <<EOF
#!/bin/bash
echo "\$SANDBOX_GITCONFIG_DIR" > "$LAUNCH_DIR/gitconfig-dir-path"
mkdir -p "\$SANDBOX_GITCONFIG_DIR/undeletable"
: > "\$SANDBOX_GITCONFIG_DIR/undeletable/file"
chmod 500 "\$SANDBOX_GITCONFIG_DIR/undeletable"
echo '{}' > "\$SANDBOX_TEST_WS/.mcp.json"
exit 7
EOF
    chmod +x "$LAUNCH_DIR/docker"
    export SANDBOX_TEST_WS="$PROJ"
    run launch "$PROJ"
    unset SANDBOX_TEST_WS
    [ "$status" -eq 7 ]
    [[ "$output" == *"HOST-CODE-EXECUTION workspace file: .mcp.json"* ]]
    gitconfig_dir="$(cat "$LAUNCH_DIR/gitconfig-dir-path")"
    [ -n "$gitconfig_dir" ]
    [ -d "$gitconfig_dir" ]   # left behind, not removed - the guard doesn't pretend it succeeded
    chmod -R u+rwX "$gitconfig_dir"
    rm -rf "$gitconfig_dir" "$PROJ"
}

@test "a sandbox started outside tmux records an empty pane rather than being skipped" {
    stub_launch
    write_remote_config
    # The EXIT trap removes the entry, so snapshot it from inside the run:
    # the stub stands in for the container, and runs while it still exists.
    #
    # Matched on the session's own compose run rather than on every docker
    # call. A launch makes several - a build, this launch's filter container,
    # and two removals from the exit trap - and snapshotting on each meant the
    # last one won. Those two removals run after the entry is gone, so what
    # this read was an empty directory.
    cat > "$LAUNCH_DIR/docker" <<EOF
#!/bin/bash
echo "\$*" >> "\${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
case "\$*" in
    *" run --rm "*)
        rm -rf "$LAUNCH_DIR/sessions-snapshot"
        cp -r "$RUNTIME_DIR/dejima/sessions" "$LAUNCH_DIR/sessions-snapshot" 2>/dev/null || true
        ;;
esac
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
    write_remote_config
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
    write_remote_config
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
    # mounts.readonly entry is one), and the trap must not delete an
    # inherited DEJIMA_NOTIFY_DIR on any of them either, not just on the
    # ordinary feature-off success path the previous test covers.
    stub_launch
    survive_parent="$(mktemp -d)"
    survive="$survive_parent/must-survive"
    mkdir -p "$survive"
    export DEJIMA_NOTIFY_DIR="$survive"
    printf '[mounts]\nreadonly = %s\n' "$LAUNCH_DIR/does-not-exist" > "$CONFIG_DIR/config"
    run launch "$PROJ"
    unset DEJIMA_NOTIFY_DIR
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

# $4 is the launch timestamp, defaulting to now. It matters to anything that
# prunes: dejima-attach holds off on an entry too young to have a container
# yet, so a test about pruning has to write one that is old enough.
# $5 is the launcher pid. Omitted by default, which writes the pre-pid entry
# shape - so every existing caller keeps exercising the upgrade fallback, and
# a test that means to exercise the liveness check says which pid it means.
write_entry() {
    mkdir -p "$RUNTIME_DIR/dejima/sessions"
    cat > "$RUNTIME_DIR/dejima/sessions/$1" <<EOF
workspace=/home/someone/myproject
pane=$2
label=$3
started=${4:-$(date +%s)}
EOF
    [ -z "${5:-}" ] || printf 'pid=%s\n' "$5" >> "$RUNTIME_DIR/dejima/sessions/$1"
}

# A pid that is certain to be dead: spawn a process and reap it, so the number
# is one the kernel has genuinely finished with rather than one picked out of
# the air and hoped to be free.
dead_pid() {
    local p
    ( exit 0 ) &
    p=$!
    wait "$p" 2>/dev/null || true
    printf '%s' "$p"
}

@test "dejima-attach refuses an id that is not a run id" {
    write_remote_config
    for bad in 'nope' '../../etc/passwd' '$(id)' '0123456789abcdef0'; do
        run "$REPO_ROOT/bin/dejima-attach" "$bad"
        [ "$status" -ne 0 ]
        [[ "$output" == *"Invalid session id"* ]]
    done
}

@test "dejima-attach refuses a well-formed id with no registry entry" {
    write_remote_config
    run "$REPO_ROOT/bin/dejima-attach" 0123456789abcdef
    [ "$status" -ne 0 ]
    [[ "$output" == *"No such session"* ]]
}

@test "dejima-attach refuses to run at all when remote access is unconfigured" {
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
}

@test "--list prunes entries whose container is gone" {
    write_remote_config
    stub_docker_run_id ffffffffffffffff
    # Old enough to be past the startup grace - a container that never existed
    # and a container that has not been created yet look identical to `docker
    # ps`, and only the age tells them apart.
    write_entry 0123456789abcdef '%1' 'work:2' $(( $(date +%s) - 86400 ))
    # Keyed by run id and written by the watcher, which never removes them:
    # unless the prune takes them too, they outlive every session.
    mkdir -p "$RUNTIME_DIR/dejima/debounce"
    : > "$RUNTIME_DIR/dejima/debounce/0123456789abcdef-waiting"
    : > "$RUNTIME_DIR/dejima/debounce/0123456789abcdef-done"
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # Pruned from disk, not merely hidden from the listing.
    [ ! -f "$RUNTIME_DIR/dejima/sessions/0123456789abcdef" ]
    [ -z "$(ls -A "$RUNTIME_DIR/dejima/debounce")" ]
}

@test "a session whose container has not started yet is not unregistered" {
    # bin/dejima registers the session and then builds - an unconditional
    # `docker compose build claude` plus up to two derived images - before it
    # ever runs a container, so for that whole span `docker ps` answers "no
    # such container" for a session that is perfectly alive. Pruning on that
    # answer removes the entry for good (bin/dejima never rewrites it), which
    # takes the session out of BOTH front doors, and deletes the marker
    # directory that the imminent `docker compose run` bind-mounts.
    write_remote_config
    stub_docker_run_id ffffffffffffffff
    write_entry 0123456789abcdef '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/0123456789abcdef"
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"0123456789abcdef"* ]]
    [[ "$output" == *"starting"* ]]
    [ -f "$RUNTIME_DIR/dejima/sessions/0123456789abcdef" ]
    [ -d "$RUNTIME_DIR/dejima/notify/0123456789abcdef" ]
}

@test "--list marks a session started outside tmux as not attachable" {
    write_remote_config
    stub_docker_run_id 0123456789abcdef
    write_entry 0123456789abcdef '' ''
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"myproject"* ]]
    [[ "$output" == *"no-tmux"* ]]
}

@test "--list marks a session whose pane is gone as stale" {
    write_remote_config
    stub_docker_run_id 0123456789abcdef
    write_entry 0123456789abcdef '%99999' 'work:2'
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
}

# A `docker` that reports one running container per registry entry, so a
# listing of N sessions can be built without N containers.
stub_docker_sessions() {
    STUB_DIR="${STUB_DIR:-$(mktemp -d)}"
    cat > "$STUB_DIR/docker" <<EOF
#!/bin/bash
case "\$1" in
    ps)      ls "$RUNTIME_DIR/dejima/sessions" | sed 's/^/c-/' ;;
    inspect) name="\${!#}"; echo "DEJIMA_RUN_ID=\${name#c-}" ;;
esac
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    PATH="$STUB_DIR:$PATH"
}

@test "the picker reads the operator's choice in base 10, not base 8" {
    # The range check is `[`, which is decimal-only, and the subscript is
    # $(( )), which reads a leading zero as OCTAL. They therefore disagree
    # about "010": in range as 10, indexed as 8, and the caller is attached to
    # a session they did not pick with nothing printed to say so. A leading
    # zero is not exotic on the front door this exists for - it is one stray
    # keypress on a phone keyboard.
    write_remote_config
    stub_docker_sessions
    local i
    for i in $(seq 11); do write_entry "$(printf '%016d' "$i")" '' ''; done
    # Every entry is pane-less, so attach() refuses by name - which is what
    # makes the session that was actually picked visible at all.
    run "$REPO_ROOT/bin/dejima-attach" <<< '010'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Session 0000000000000010 was not started from tmux"* ]]
    # "09" is not an octal number at all, so the same subscript aborts the
    # script outright under set -e.
    run "$REPO_ROOT/bin/dejima-attach" <<< '09'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Session 0000000000000009 was not started from tmux"* ]]
    # And a number `[` cannot compare: both comparisons exit 2, which makes
    # the `if` false, so the range is never reported as the problem and the
    # subscript dies on an unbound element instead.
    run "$REPO_ROOT/bin/dejima-attach" <<< '99999999999999999999999'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Out of range."* ]]
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
    write_remote_config
    stub_docker_run_id 0123456789abcdef
    start_tmux
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"attachable"* ]]
}

# The picker is a human view; --list is a machine interface, and three things
# read it that way at once - the picker itself splits those rows on tabs to
# build its columns, ttyd feeds a run id from them back in through --url-arg,
# and the README documents them as scriptable. Colour in list_sessions would
# break all three, and no other test here can see it: bats never gives the
# script a terminal, which is the condition the colour is gated on. `script`
# supplies one.
@test "colour reaches the picker but never --list" {
    write_remote_config
    stub_docker_run_id 0123456789abcdef
    start_tmux
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'

    run script -qec "'$REPO_ROOT/bin/dejima-attach' --list" /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\033'* ]]
    # Still tab-separated, so the shape the other readers rely on is intact
    # rather than merely uncoloured.
    [[ "$output" == *$'\t'"work:1"$'\t'* ]]

    run script -qec "echo q | '$REPO_ROOT/bin/dejima-attach'" /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033'* ]]
    [[ "$output" == *"dejima"* ]]

    # NO_COLOR is honoured on that same terminal, and the box-drawing glyphs
    # ride the same switch - so the fallback is plain in both senses.
    run script -qec "NO_COLOR=1 sh -c 'echo q | \"$REPO_ROOT/bin/dejima-attach\"'" /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\033'* ]]
    [[ "$output" == *"dejima | live sessions"* ]]
}

# Provenance, pinned offline. Upstream's color.table is the authority, but a
# The terminal palette carries no hexes at all any more, and that is the
# property worth pinning. It used to hardcode gruvbox in 24-bit, which is the
# brand but assumes a background dejima does not own: measured against a light
# one, light1 came out at 1.21:1 and bright yellow at 1.49:1. Indexed colours
# cannot have that problem, because the theme's author picked them against
# their own background - and on a gruvbox terminal they ARE those hexes.
@test "the terminal palette is the terminal's own, not hardcoded" {
    local lib="$REPO_ROOT/bin/dejima-color-lib.sh"
    run grep -n '38;2;' "$lib" "$REPO_ROOT/bin/dejima-tui-lib.sh"
    [ "$status" -ne 0 ] \
        || { echo "24-bit colour is back in a terminal palette:"; echo "$output"; return 1; }
    # And it is one palette: a second definition is how C_OK and C_WARN came
    # to mean two different things depending on which file a caller sourced.
    run grep -c '^\s*C_OK=' "$REPO_ROOT/bin/dejima-tui-lib.sh"
    [ "$output" -eq 0 ] \
        || { echo "dejima-tui-lib.sh defines its own palette again"; return 1; }
    # The colours it does use are the semantic slots, so a gruvbox terminal
    # fills them with gruvbox.
    local slot
    for slot in '92m' '93m' '91m' '94m' '90m'; do
        grep -q "$slot" "$lib" || { echo "the palette lost slot $slot"; return 1; }
    done
}

@test "attaching creates a grouped session on the requested window and disposes of it on detach" {
    # The positive direction, which is where every interesting tmux mistake
    # lives: an invalid set-option target, or setting destroy-unattached while
    # the session is still detached, both leave the negative tests green while
    # no one can actually attach.
    write_remote_config
    stub_docker_run_id 0123456789abcdef
    start_tmux
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'

    # A pty that is NOT a tmux pane: tmux refuses to nest, and ttyd/ssh give
    # dejima-attach a bare pty too.
    script -qec "$REPO_ROOT/bin/dejima-attach 0123456789abcdef" /dev/null >/dev/null 2>&1 &
    attach_pid=$!
    # Waits for the CLIENT, not just the session. dejima-attach creates the
    # session and then attaches to it, so has-session goes true first and
    # list-clients stays empty for a moment after - and the assertion below
    # used to run inside that window. On an unloaded machine it lost the race
    # rarely enough to look like noise; under load it failed 5 times in 12.
    # Polling for the state being asserted on closes the window instead of
    # widening it, and the assertions themselves are unchanged, so a genuine
    # regression still fails here rather than timing out into a pass.
    for _ in $(seq 100); do
        [ "$(tmux list-clients -F '#{client_session}' 2>/dev/null)" = "dejima-0123456789abcdef" ] && break
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
    write_remote_config
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
    write_remote_config
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
    write_remote_config
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
    write_remote_config
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
    write_remote_config
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
    # can chmod its own marker directory on the way out. Nothing in the prune
    # tries to remove it, but a sandbox must not be able to deny the operator
    # the front door by making a directory awkward, so this stays pinned.
    write_remote_config
    stub_docker_run_id 0123456789abcdef
    write_entry 0000000000000000 '%1' 'work:1' 0999999999
    write_entry 0123456789abcdef '%1' 'work:2'
    mkdir -p "$RUNTIME_DIR/dejima/notify/0000000000000000/waiting-dir"
    chmod 500 "$RUNTIME_DIR/dejima/notify/0000000000000000"
    run "$REPO_ROOT/bin/dejima-attach" --list
    chmod 700 "$RUNTIME_DIR/dejima/notify/0000000000000000"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0123456789abcdef"* ]]
}

# The marker directory is the bind source of a mount bin/dejima declares, and
# its lifetime belongs to that process's EXIT trap. A second owner in the
# prune can only race it, and losing that race does not leave a tidy host: it
# leaves Docker recreating the bind source root-owned, dejima-notify.sh
# failing on every Notification and Stop for the rest of the run, and no code
# anywhere that rewrites the registry entry to make the session visible again.
@test "pruning a dead entry leaves the marker directory alone" {
    write_remote_config
    stub_docker_run_id ffffffffffffffff
    write_entry 0123456789abcdef '%1' 'work:2' 0999999999 "$(dead_pid)"
    mkdir -p "$RUNTIME_DIR/dejima/notify/0123456789abcdef"
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [ ! -f "$RUNTIME_DIR/dejima/sessions/0123456789abcdef" ] \
        || { echo "the registry entry survived a dead launcher"; return 1; }
    [ -d "$RUNTIME_DIR/dejima/notify/0123456789abcdef" ] \
        || { echo "the prune deleted a marker directory it does not own"; return 1; }
}

# The failure this replaced: a cold first build outran STARTUP_GRACE, the
# operator opened the front door to check on it, and the session was
# unregistered mid-launch. A build takes as long as it takes; whether the
# process that registered the entry is still running does not.
@test "a launch still building is not pruned however long it has taken" {
    write_remote_config
    stub_docker_run_id ffffffffffffffff
    # started= far enough back that any guessed window has long since passed.
    write_entry 0123456789abcdef '%1' 'work:2' 0999999999 $$
    mkdir -p "$RUNTIME_DIR/dejima/notify/0123456789abcdef"
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"0123456789abcdef"* ]]
    [[ "$output" == *"starting"* ]]
    [ -f "$RUNTIME_DIR/dejima/sessions/0123456789abcdef" ]
    [ -d "$RUNTIME_DIR/dejima/notify/0123456789abcdef" ]
}

@test "an entry whose pid is not a plain number is refused, not signalled" {
    # pid reaches `kill`, which accepts a job spec and a negative pgid as well
    # as a process. Neither may be reachable from a state file.
    write_remote_config
    stub_docker_run_id ffffffffffffffff
    for bad in '%1' '-1' 'x[$(id)]' ' 1'; do
        write_entry 0123456789abcdef '%1' 'work:2' 0999999999 "$bad"
        run "$REPO_ROOT/bin/dejima-attach" --list
        [ "$status" -eq 0 ] || { echo "pid '$bad' broke the listing: $output"; return 1; }
        [ ! -f "$RUNTIME_DIR/dejima/sessions/0123456789abcdef" ] \
            || { echo "pid '$bad' was treated as a live launcher"; return 1; }
    done
}

# Waits for the grouped session an attach should have created, then prints
# "<name> <group>" for it - empty group means UNGROUPED, i.e. a fresh session
# tmux conjured out of a name rather than a clone of the sandbox's own.
#
# Waits for the CLIENT rather than the session, like the earlier attach test
# does. dejima-attach creates the session detached, checks it holds the pane,
# selects the window and only then attaches - so has-session goes true while
# the session is still on whatever window the group started on. A caller that
# goes on to assert the window index reads it inside that gap. That is how
# this failed in CI, with the group assertion on the line before it passing:
# the group is set at creation, the window is not.
await_group() {
    local i
    for i in $(seq 100); do
        [ "$(tmux list-clients -F '#{client_session}' 2>/dev/null)" = "dejima-$1" ] && break
        sleep 0.1
    done
    tmux list-sessions -F '#{session_name} #{session_group}' | grep "^dejima-$1 " || true
}

@test "a recorded session name that no longer exists cannot conjure a session of its own" {
    # tmux does not fail on `new-session -t <nothing-matches>` - it creates a
    # fresh ungrouped session under that name, which for a remote client is a
    # plain host shell with no sandbox in it. The base session must therefore
    # come from the live pane, never from the recorded label.
    write_remote_config
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
    write_remote_config
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
    write_remote_config
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
    write_remote_config
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
    write_remote_config
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
    write_remote_config
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
    write_remote_config
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

@test "an existing group that no longer holds the sandbox's pane is not attached to" {
    # The has-session branch hands the client whatever carries the name, and
    # nothing in this script created it. Only reachable as debris - a
    # dejima-<run-id> that exists but shares no window with the sandbox - and
    # anyone who can create that name already has a host shell, so the stake
    # is landing in the right window rather than containment. The session
    # created twenty lines below is verified for exactly this; this one was
    # not.
    write_remote_config
    stub_docker_run_id 0123456789abcdef
    start_tmux
    tmux new-session -d -s 'dejima-0123456789abcdef' 'sleep 300'
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'

    run "$REPO_ROOT/bin/dejima-attach" 0123456789abcdef
    [ "$status" -ne 0 ]
    # The message, not just the failure: with no pty this attach cannot
    # succeed either way, and "open terminal failed" would pass a bare status
    # check while still having tried to hand over the wrong session.
    [[ "$output" == *"does not hold its pane"* ]]
    [ -z "$(tmux list-clients -F '#{client_session}')" ]
}

@test "an existing session whose name merely starts with the group name is not attached to" {
    # tmux resolves an unanchored target by prefix, then by fnmatch, so a
    # session named dejima-<id><anything> answers to the group's own name -
    # and "is the group already there?" answering yes about someone else's
    # session hands the remote client that session instead of the sandbox.
    write_remote_config
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

@test "notify hooks are registered only in the throwaway override layer" {
    stub_launch
    write_remote_config
    launch "$PROJ"
    grep -q 'dejima-notify.sh done' "$LAUNCH_DIR/settings-copy.json"
    # The layer is a throwaway, so the operator's real settings.json - which
    # nothing registers this hook into - is left byte-for-byte alone.
    cmp -s "$LAUNCH_DIR/settings-seed.json" "$LAUNCH_DIR/home/.claude/settings.json"
    # And what the layer carried before is still there: this appends, it does
    # not replace the file bin/dejima generated.
    [ "$(jq '.sandbox.enabled' "$LAUNCH_DIR/settings-copy.json")" = "false" ]
    # The operator's OWN Notification and Stop hooks - a desktop notifier, a
    # TTS reader - are deliberately NOT copied in here. They keep applying
    # from their own settings.json, which Claude Code loads as the lower
    # layer and merges hooks from rather than letting this one replace it.
    # Copying them would run each of them twice. Verified against Claude Code
    # 2.1.220: a SessionStart hook in a --settings file and one in
    # ~/.claude/settings.json both fire.
    [ "$(jq '.hooks.Stop | length' "$LAUNCH_DIR/settings-copy.json")" = "1" ]
    [ "$(jq '.hooks.Notification // [] | length' "$LAUNCH_DIR/settings-copy.json")" = "0" ]
    run jq -r '[.hooks[][].hooks[].command] | join(" ")' "$LAUNCH_DIR/settings-copy.json"
    [[ "$output" != *operator-desktop-notify.sh* ]]
    [[ "$output" != *operator-tts.sh* ]]
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
    # stdin as well as argv, because the request URL now arrives that way and
    # a stub that only saw argv would report the push as carrying no
    # destination at all - which reads like the value being dropped.
    #
    # Drained only when `--config -` asked for it, exactly as the real curl
    # does. A stub that reads stdin unconditionally HANGS when the caller
    # sends none, so a change that stopped redirecting would fail this suite
    # by timing out rather than by failing an assertion.
    cat > "$STUB_DIR/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$STUB_DIR/curl-argv"
_want_stdin=
for _a in "\$@"; do
    [ "\$_a" = --config ] && _want_stdin=1
done
[ -z "\$_want_stdin" ] || cat >> "$STUB_DIR/curl-stdin"
exit 0
EOF
    chmod +x "$STUB_DIR/curl"
    PATH="$STUB_DIR:$PATH"
}
curl_log() { cat "$STUB_DIR/curl-argv" 2>/dev/null; }
curl_stdin() { cat "$STUB_DIR/curl-stdin" 2>/dev/null; }

# The EXACT argument vector of one push, one argument per line - a whitelist,
# not a search. Absence assertions cannot do this job: an argument that leaks
# by REFERENCE ("-H @/path/to/secret") contains none of the bytes it sends, so
# every grep for the secret passes while the secret goes out. Compared whole,
# an added argument of any kind fails the test.
#
# $1 title suffix, $2 body, $3 click URL.
expect_argv() {
    printf '%s\n' -fsS --max-time 10 --retry 2 \
        -H "Title: dejima: $1" \
        -H "Priority: default"
    [ -z "${3:-}" ] || printf '%s\n' -H "Click: $3"
    printf '%s\n' -d "$2" --config -
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
    cat > "$CONFIG_DIR/config" <<'EOF'
[remote-access]
enabled = on
ntfy_url = https://ntfy.example.invalid/dejima
base_url = https://dejima.example.invalid
EOF
}

@test "a marker produces a push composed entirely from host-side data" {
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    # The click URL is base_url from the config plus the DIRECTORY NAME, and
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
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    # Still that one push and no other: the vector is compared whole, so a
    # second would appear as trailing arguments and fail here.
    assert_argv 'myproject needs input' 'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
    # Debounced means "not pushed", not "not consumed" - a marker left behind
    # would re-push the moment the window expired.
    [ ! -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ]
}

@test "the watcher refuses to start without ntfy_url" {
    write_remote_config
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"ntfy_url"* ]]
}

@test "the watcher refuses to start at all when remote access is unconfigured" {
    # The opt-in guarantee: with the feature unconfigured nothing here runs,
    # and in particular no state directory is created.
    stub_curl
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
    [ ! -d "$RUNTIME_DIR/dejima" ]
    [ -z "$(curl_log)" ]
}

@test "the ntfy URL never reaches curl's argv, because it can carry a token" {
    # An ntfy server that wants credentials takes them in the URL, and
    # docs/remote-access.md documents that form. Every argument of every
    # process on this host is readable by any local account through
    # /proc/<pid>/cmdline, so a URL in argv is a token published to the
    # machine for as long as the request runs - `ps` is enough.
    #
    # Both halves are asserted. Absent from argv is the fix; present on stdin
    # is what stops the fix from being "the push lost its destination", which
    # would pass an absence check just as well.
    stub_curl
    conf_with_ntfy
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [[ "$(curl_log)" != *ntfy.example.invalid* ]] \
        || { echo "the URL is in argv:"; curl_log; return 1; }
    [[ "$(curl_stdin)" == *'url = "https://ntfy.example.invalid/dejima"'* ]] \
        || { echo "the URL did not reach curl at all:"; curl_stdin; return 1; }

    # The click URL is not secret and stays where it is: it is composed from
    # base_url, which is the address of the operator's own front door.
    [[ "$(curl_log)" == *"Click: https://dejima.example.invalid/?arg=0123456789abcdef"* ]] \
        || { echo "the click target moved:"; curl_log; return 1; }
}

@test "a misconfigured ntfy URL is not echoed back with its credentials" {
    # The refusal path prints the offending value, and the journal is where
    # that lands under a systemd user unit. A token that survives a
    # misconfiguration by being written to the journal is a token that
    # outlives the mistake.
    stub_curl
    write_remote_config 'ntfy_url = https://someone:hunter2@ntfy.example.invalid/t{}'
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ] || { echo "a bad URL was accepted: $output"; return 1; }
    [[ "$output" != *hunter2* ]] \
        || { echo "the credential was echoed back: $output"; return 1; }
    [[ "$output" == *"ntfy_url"* ]] || { echo "$output"; return 1; }
    [ -z "$(curl_log)" ]
}

@test "a config value curl would read as an option is refused, not passed on" {
    # The url schema type requires an http(s) scheme, which "-K/path" is not -
    # verified against the real curl, which would otherwise read "-K/path" as
    # an OPTION and take the request's URL (and its output file) from that
    # path instead. A value that isn't a URL is refused at parse time, before
    # anything is pushed. The config is operator-written, which is a reason
    # to refuse a bad value loudly rather than to assume a good one.
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    write_remote_config 'ntfy_url = -K/tmp/dejima-test-curl-config'
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"ntfy_url"* ]]
    [ -z "$(curl_log)" ]

    # base_url reaches the phone as the Click: target rather than curl's argv,
    # but it is the same class of value and the same refusal.
    write_remote_config 'ntfy_url = https://ntfy.example.invalid/t' \
                         'base_url = -o/tmp/dejima-test-out'
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"base_url"* ]]
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

@test "a push still goes out when base_url is not configured" {
    # base_url is optional - ntfy alone is a complete setup, and it is the
    # only half that needs to be reachable from the phone. This pins the
    # otherwise-unexercised branch that composes no Click header at all,
    # including the empty-array expansion it hands to curl under set -u.
    printf '[remote-access]\nenabled = on\nntfy_url = https://ntfy.example.invalid/dejima\n' \
        > "$CONFIG_DIR/config"
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
    # Anything unrecognized - a typo - used to fall into the watch loop, which
    # for an interactive invocation looks like a hang.
    #
    # --help was on this list until #64, which asked every tool to explain
    # itself. It is now a recognized argument that prints and exits 0, so it
    # belongs to the --help test rather than here. The property this one is
    # about is unchanged: an argument the tool does not know is refused.
    conf_with_ntfy
    stub_curl
    for bad in --onces -x once; do
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
    # debounce used to reach an arithmetic context straight from
    # DEJIMA_DEBOUNCE_SECONDS; it now goes through the schema's int:0:86400
    # at config parse time instead, before this script ever sees it.
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    for bad in 'x[$(touch '"$RUNTIME_DIR"'/PWNED)]' '60s' '-1' '6 0'; do
        write_remote_config 'ntfy_url = https://ntfy.example.invalid/t' "debounce = $bad"
        run "$REPO_ROOT/bin/dejima-notify-watch" --once
        [ "$status" -ne 0 ]
        [[ "$output" == *"invalid value"* ]]
        [[ "$output" == *"debounce"* ]]
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

# Reports no listener, whatever the host is actually running. Called beside
# stub_ttyd by every ttyd test but one, and deliberately not folded into it:
# the port-in-use refusal binds a real socket and needs the real ss to see it.
#
# For every OTHER ttyd test the port being free is a precondition, not the
# subject - and one that was being inherited from the machine rather than
# stated. The default-port case asserts against 7681, which is exactly the
# port a real dejima-ttyd front door holds, so it failed on any host running
# the feature: the machine a developer is most likely to run this suite on.
# The rest name 12345, which is free on most machines and on none reliably.
# Same shape as #56 - a test reading its environment instead of setting it.
stub_ss_no_listeners() {
    STUB_DIR="${STUB_DIR:-$(mktemp -d)}"
    printf '#!/bin/bash\nexit 0\n' > "$STUB_DIR/ss"
    chmod +x "$STUB_DIR/ss"
    PATH="$STUB_DIR:$PATH"
}

# The EXACT argument vector, one argument per line - a whitelist, for the same
# reason expect_argv above is one. The bind address is the security property
# of this whole task, and an absence grep cannot see a SECOND --interface, a
# --credential that turns nginx's auth into a duplicate, or a dropped flag.
# $1 is the expected port. The command must be this repo's dejima-attach,
# resolved the way the script resolves it (readlink -f, so a $BATS_TEST_DIRNAME
# with a ".." in it does not make this a comparison of two spellings).
# $2 is the expected TTYD_FONT_SIZE, empty or absent for "no -t at all" - the
# unset default, which has to stay a genuine absence rather than a value that
# happens to match ttyd's own, or the option is no longer optional. $3 is the
# expected TTYD_TMUX_PREFIX, on the same terms.
#
# --index is unconditional: it is what replaces ttyd's stock frontend with the
# touch-capable page in web/, and it is the whole feature rather than an
# option, so an invocation without it is a regression and not a configuration.
expect_ttyd_argv() {
    printf '%s\n' --interface 127.0.0.1 --port "$1" --check-origin --url-arg --writable
    printf '%s\n' --index "$(dirname "$(readlink -f "$REPO_ROOT/bin")")/web/index.html"
    [ -z "${2:-}" ] || printf '%s\n' -t "fontSize=$2"
    [ -z "${3:-}" ] || printf '%s\n' -t "tmuxPrefix=$3"
    [ -z "${4:-}" ] || printf '%s\n' -t "focusOnTap=$4"
    [ -z "${5:-}" ] || printf '%s\n' -t "buttonColors=$5"
    # Always sent, unlike the four above: a browser has no theme to inherit,
    # so this is not an option an operator turns on. Read out of the script
    # rather than transcribed - this file asserts that ttyd is given a theme
    # and that its values match the page (static.bats), not what they are.
    printf '%s\n' -t "$(sed -n "/^theme_opt=(-t '/,/^}')$/p" \
        "$REPO_ROOT/bin/dejima-ttyd" | sed "1s/^theme_opt=(-t '//; \$s/')$//")"
    printf '%s\n' "$(readlink -f "$REPO_ROOT/bin")/dejima-attach"
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

@test "dejima-ttyd binds ttyd to loopback and takes its port from the config" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    write_remote_config 'ttyd_port = 12345'
    stub_ttyd
    stub_ss_no_listeners
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 12345

    # The default is the library's, not a second copy of it in this script.
    : > "$STUB_DIR/ttyd-argv"
    write_remote_config
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 7681
}

@test "dejima-ttyd refuses to start when something else already holds its port" {
    command -v ss >/dev/null 2>&1 || skip "ss is not available"
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    # The one ttyd test with no stub_ss_no_listeners beside stub_ttyd: ss
    # seeing the socket bound below is the subject here, not a precondition.
    stub_ttyd

    # The distro's ttyd package ships an enabled service that binds every
    # interface on this same default port. When it wins the port, this unit
    # dies at every start and the reverse proxy in front of it serves THAT -
    # a host login prompt - behind the operator's own password. Nothing in
    # that path looks broken, so the refusal here is the only thing that says
    # what happened.
    #
    # Driven from python so the listener cannot outlive the test: the socket
    # dies with the interpreter no matter how the assertions below go. A
    # background process holding it would leak on the first failure, since
    # bats runs test bodies under errexit.
    #
    # Both halves in one run, against ONE port: bound, then closed. Without
    # the second half a script that refused unconditionally would pass.
    run python3 - "$REPO_ROOT/bin/dejima-ttyd" "$CONFIG_DIR" <<'PY'
import os, socket, subprocess, sys

script, config_dir = sys.argv[1], sys.argv[2]
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
port = s.getsockname()[1]
with open(os.path.join(config_dir, "config"), "w") as f:
    f.write("[remote-access]\nenabled = on\nbase_url = https://d.example\nttyd_port = %d\n" % port)

held = subprocess.run([script], capture_output=True, text=True)
s.close()
free = subprocess.run([script], capture_output=True, text=True)

print("PORT", port)
print("HELD_RC", held.returncode)
print("FREE_RC", free.returncode)
print("HELD_ERR", held.stderr.replace("\n", " "))
PY
    [ "$status" -eq 0 ]
    local port
    port="$(printf '%s\n' "$output" | sed -n 's/^PORT //p')"
    [ -n "$port" ]
    printf '%s\n' "$output" | grep -qx 'HELD_RC 1'
    printf '%s\n' "$output" | grep -qx 'FREE_RC 0'
    # Names the port, and names the service that is usually holding it - a
    # bare "address in use" is what this exists to replace.
    printf '%s\n' "$output" | grep -q "HELD_ERR .*$port"
    printf '%s\n' "$output" | grep -q 'HELD_ERR .*ttyd\.service'

    # And it refused rather than proceeding: exactly one ttyd launch reached
    # the stub, the one made after the port was released. A check that printed
    # a warning and exec'd anyway would leave two.
    [ "$(ttyd_log | grep -c -- '--interface')" -eq 1 ]
}

@test "dejima-ttyd refuses to start when remote access is unconfigured, before ttyd is reached" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    stub_ttyd
    stub_ss_no_listeners
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not configured"* ]]
    # The reason matters: on a machine with no ttyd this test passes for free.
    [ -z "$(ttyd_log)" ]
}

@test "dejima-ttyd reports a missing ttyd instead of exec-ing into nothing" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    write_remote_config
    # A PATH holding only what the script itself needs, so the absence of ttyd
    # is a property of this test rather than of whoever runs it.
    STUB_DIR="$(mktemp -d)"
    for tool in readlink dirname cat; do
        ln -s "$(command -v "$tool")" "$STUB_DIR/$tool"
    done
    run env PATH="$STUB_DIR" "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    # The exact message, not just a failure: an unwritten script is "not
    # found" too, and `exec ttyd` with no ttyd says so in bash's words rather
    # than in words that tell an operator what to install.
    [[ "$output" == *"ttyd is not installed"* ]]
    # And which ttyd: -W/--writable does not exist before 1.7.4 (1.7.3 and
    # earlier have --readonly and are writable by default), so an older
    # package makes every start a getopt usage error. An operator reading
    # "install ttyd" would install exactly that. Anchored to the headline
    # rather than matched anywhere in the output: the version is named twice,
    # so a loose match lets the line an operator actually reads say 1.6.0.
    [[ "$output" == *"needs it, 1.7.4 or newer"* ]]
}

@test "dejima-ttyd reports a broken config before it reports a missing ttyd" {
    # An operator missing both pieces is otherwise sent to install a package,
    # after which they hit the identical failure having never been told that
    # their config is the other half of it. The config error is also the one
    # they cannot work out for themselves.
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    write_remote_config 'ttyd_port = 99999'
    # The same isolated PATH the missing-ttyd test uses, so the absence is a
    # property of this test rather than of whoever runs it.
    STUB_DIR="$(mktemp -d)"
    for tool in readlink dirname cat; do
        ln -s "$(command -v "$tool")" "$STUB_DIR/$tool"
    done
    run env PATH="$STUB_DIR" "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid value"* ]]
    [[ "$output" == *"ttyd_port"* ]]
    [[ "$output" != *"ttyd is not installed"* ]]
}

@test "dejima-ttyd starts against a config containing a [forge.<name>] section" {
    # Regression test: dejima-project-lib.sh used to source only
    # dejima-config-lib.sh, leaving _config_extra_section_known's refuse-
    # everything stub in place, so any config with a [forge.*]/[harness.*]
    # section - including the one install.sh itself generates - died with
    # "unknown section [forge.gitea]" in every remote-access CLI. Confirmed
    # directly against the unpatched source before this fix.
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    write_remote_config '[forge.gitea]' 'ssh_host = git.example' \
        'api = https://api.example/v1'
    STUB_DIR="$(mktemp -d)"
    for tool in readlink dirname cat; do
        ln -s "$(command -v "$tool")" "$STUB_DIR/$tool"
    done
    run env PATH="$STUB_DIR" "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    [[ "$output" != *"unknown section"* ]]
    # Got past config validation to the next check, same as the missing-ttyd
    # test above - proof the section itself was accepted, not that this
    # particular failure mode is silent about it.
    [[ "$output" == *"ttyd is not installed"* ]]
}

@test "dejima-notify-watch starts against a config containing a [forge.<name>] section" {
    conf_with_ntfy
    printf '[forge.gitea]\nssh_host = git.example\napi = https://api.example/v1\n' \
        >> "$CONFIG_DIR/config"
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    [[ "$output" != *"unknown section"* ]]
}

@test "a malformed config takes down the scripts that read a value, not dejima-attach" {
    # dejima-attach reads no VALUE out of the config - remote_enabled only
    # asks whether [remote-access] enabled is on, through its own parser
    # rather than config_get, so a bad line elsewhere cannot take away the
    # terminal an operator would fix that typo from. Everything that DOES
    # read a value still goes through config_get, which validates the WHOLE
    # file, so it still refuses - that contrast is the point of keeping
    # remote_enabled off config_get.
    write_remote_config 'this is not an assignment'
    stub_docker_run_id 0123456789abcdef
    write_entry 0123456789abcdef '' ''
    run "$REPO_ROOT/bin/dejima-attach" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"0123456789abcdef"* ]]

    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"malformed"* ]]

    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -ne 0 ]
    [[ "$output" == *"malformed"* ]]
}

@test "dejima-ttyd refuses an out-of-range ttyd_port rather than launching without one" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    write_remote_config 'ttyd_port = 99999'
    stub_ttyd
    stub_ss_no_listeners
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    # Named, so this cannot pass because ttyd was missing or the config was.
    [[ "$output" == *"invalid value"* ]]
    [[ "$output" == *"ttyd_port"* ]]
    [ -z "$(ttyd_log)" ]
}

@test "ttyd_font_size reaches ttyd as an option, and its absence sends none at all" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]

    # Unset first. The point of the default is that no -t is sent, leaving
    # ttyd on whatever its own default is - not that we send a number that
    # currently happens to agree with it.
    write_remote_config 'ttyd_port = 12345'
    stub_ttyd
    stub_ss_no_listeners
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 12345
    # No fontSize reaches ttyd, rather than no -t at all: the theme is sent on
    # every launch (a browser has no palette to inherit), so counting -t stopped
    # measuring what this is about, which is that an unset option sends nothing.
    run grep -c 'fontSize' "$STUB_DIR/ttyd-argv"
    [ "$output" = "0" ]

    # Set. Checked through the exact vector, not a substring: "fontSize=20
    # arrived somewhere" would also pass if it were welded onto another
    # argument, and this is a value from a config file reaching an exec.
    : > "$STUB_DIR/ttyd-argv"
    write_remote_config 'ttyd_port = 12345' 'ttyd_font_size = 20'
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 12345 20
}

@test "dejima-ttyd refuses a ttyd_font_size outside its range rather than launching with one" {
    # A size large enough to make a single glyph wider than the viewport
    # renders a terminal that displays nothing, which an operator reads as a
    # broken front door rather than as a typo in a file three steps back. Same
    # treatment ttyd_port gets, and for the same reason: refuse at the config,
    # where the message can name the key.
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    local bad
    for bad in 0 7 73 999 abc 1e2 -20; do
        stub_ttyd
        stub_ss_no_listeners
        : > "$STUB_DIR/ttyd-argv"
        write_remote_config 'ttyd_port = 12345' "ttyd_font_size = $bad"
        run "$REPO_ROOT/bin/dejima-ttyd"
        [ "$status" -ne 0 ] || { echo "accepted ttyd_font_size=$bad" >&2; false; }
        # Named, so this cannot pass because ttyd was missing or the port was
        # bad - what must not happen is a launch.
        [[ "$output" == *"ttyd_font_size"* ]] \
            || { echo "refused ttyd_font_size=$bad without naming it: $output" >&2; false; }
        [ -z "$(ttyd_log)" ] || { echo "launched ttyd despite ttyd_font_size=$bad" >&2; false; }
    done
}

@test "ttyd_tmux_prefix reaches ttyd as an option, and its absence sends none at all" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]

    # Unset means the page falls back to stock tmux's C-b on its own. Sending
    # "tmuxPrefix=C-b" here instead would look identical today and diverge the
    # moment either default moves.
    write_remote_config 'ttyd_port = 12345'
    stub_ttyd
    stub_ss_no_listeners
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 12345
    run grep -c 'tmuxPrefix' "$STUB_DIR/ttyd-argv"
    [ "$output" = "0" ]

    : > "$STUB_DIR/ttyd-argv"
    write_remote_config 'ttyd_port = 12345' 'ttyd_tmux_prefix = C-a'
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 12345 '' C-a

    # Both knobs at once, since they share the -t mechanism and an array
    # spliced in the wrong order would still "contain" each of them.
    : > "$STUB_DIR/ttyd-argv"
    write_remote_config 'ttyd_port = 12345' 'ttyd_font_size = 20' 'ttyd_tmux_prefix = C-Space'
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 12345 20 C-Space
}

@test "ttyd_button_colors reaches ttyd, and unset sends nothing so the page decides" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]

    # Unset is not "off": the page colours the toolbar unless told not to, and
    # a host-wide "off" written here would be a different thing from silence.
    write_remote_config 'ttyd_port = 12345'
    stub_ttyd
    stub_ss_no_listeners
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    run grep -c 'buttonColors' "$STUB_DIR/ttyd-argv"
    [ "$output" = "0" ]

    local value
    for value in on off; do
        : > "$STUB_DIR/ttyd-argv"
        write_remote_config 'ttyd_port = 12345' "ttyd_button_colors = $value"
        run "$REPO_ROOT/bin/dejima-ttyd"
        [ "$status" -eq 0 ]
        assert_ttyd_argv 12345 '' '' '' "$value"
    done

    # Alongside every other -t knob, since they share one splice.
    : > "$STUB_DIR/ttyd-argv"
    write_remote_config 'ttyd_port = 12345' 'ttyd_font_size = 20' \
        'ttyd_tmux_prefix = C-a' 'ttyd_focus_on_tap = on' 'ttyd_button_colors = off'
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 12345 20 C-a on off
}

@test "ttyd_focus_on_tap reaches ttyd, and unset sends nothing so the page decides" {
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]

    # Unset is not "off". The page picks from the pointer type, which is a
    # property of the client and not of the host, so a host-wide default here
    # would be wrong for whichever half of the clients it did not match.
    write_remote_config 'ttyd_port = 12345'
    stub_ttyd
    stub_ss_no_listeners
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    run grep -c 'focusOnTap' "$STUB_DIR/ttyd-argv"
    [ "$output" = "0" ]

    # Both settings, spelled the way the config's bool type produces them -
    # "off" has to survive the trip, and an is-it-empty test would drop it.
    local value
    for value in on off; do
        : > "$STUB_DIR/ttyd-argv"
        write_remote_config 'ttyd_port = 12345' "ttyd_focus_on_tap = $value"
        run "$REPO_ROOT/bin/dejima-ttyd"
        [ "$status" -eq 0 ]
        assert_ttyd_argv 12345 '' '' "$value"
    done

    # Alongside the other -t knobs, since they share one splice and the wrong
    # order would still leave each of them present.
    : > "$STUB_DIR/ttyd-argv"
    write_remote_config 'ttyd_port = 12345' 'ttyd_font_size = 20' \
        'ttyd_tmux_prefix = C-a' 'ttyd_focus_on_tap = on'
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    assert_ttyd_argv 12345 20 C-a on
}

@test "dejima-ttyd refuses a ttyd_tmux_prefix it cannot parse rather than launching with one" {
    # The page refuses an unparseable prefix too, and says so - but it says so
    # on the phone, hours later, to whoever happens to press PREFIX. Refusing
    # here names the key and the file while the operator is still looking at
    # them.
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    local bad
    for bad in b M-b C-ab C- ctrl-a 2 'C-\' ; do
        stub_ttyd
        stub_ss_no_listeners
        : > "$STUB_DIR/ttyd-argv"
        write_remote_config 'ttyd_port = 12345' "ttyd_tmux_prefix = $bad"
        run "$REPO_ROOT/bin/dejima-ttyd"
        [ "$status" -ne 0 ] || { echo "accepted ttyd_tmux_prefix=$bad" >&2; false; }
        [[ "$output" == *"ttyd_tmux_prefix"* ]] \
            || { echo "refused ttyd_tmux_prefix=$bad without naming it: $output" >&2; false; }
        [ -z "$(ttyd_log)" ] || { echo "launched ttyd despite ttyd_tmux_prefix=$bad" >&2; false; }
    done
}

@test "dejima-ttyd refuses to launch without the terminal page rather than falling back to ttyd's" {
    # ttyd serves its own frontend when --index is absent, which would leave a
    # front door that works and a phone that has silently lost every gesture,
    # the toolbar and pane resizing - with nothing anywhere saying why. So the
    # missing file has to be a refusal that names it.
    #
    # Run from a copy of bin/ with no web/ beside it, which is what an
    # incomplete checkout looks like from the script's point of view: it
    # resolves the page relative to its own resolved location.
    local fake="$BATS_TEST_TMPDIR/incomplete"
    mkdir -p "$fake/bin"
    # Every library the launcher sources, so the copy fails on the missing
    # page rather than on a missing lib - which would pass the status check
    # below while proving nothing.
    cp "$REPO_ROOT/bin/dejima-ttyd" "$REPO_ROOT/bin/dejima-project-lib.sh" \
       "$REPO_ROOT/bin/dejima-attach" "$REPO_ROOT/bin/dejima-config-lib.sh" \
       "$REPO_ROOT/bin/dejima-provider-lib.sh" "$fake/bin/"
    write_remote_config 'ttyd_port = 12345'
    stub_ttyd
    stub_ss_no_listeners
    run "$fake/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$fake/web/index.html"* ]]
    [[ "$output" == *"build.mjs"* ]]
    [ -z "$(ttyd_log)" ]
}

@test "web/index.html is regenerated whenever the sources it is built from change" {
    # The page is a build artifact that is COMMITTED, so that a checkout is
    # usable by copy alone and nobody needs npm to run the front door. The cost
    # of that is the one failure mode a generated-and-ignored file cannot have:
    # editing web/src and shipping the stale artifact, which looks like the
    # edit silently not working. build.mjs writes this manifest beside the page
    # from the same inputs, so a mismatch means one was not rebuilt.
    local web="$REPO_ROOT/web"
    [ -f "$web/index.html" ]
    [ -f "$web/sources.sha256" ]
    run bash -c "cd '$web' && sha256sum src/* package-lock.json | LC_ALL=C sort -k2"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$web/sources.sha256")" ] || {
        echo "web/sources.sha256 is stale. Rebuild it:" >&2
        echo "  cd web && npm ci && node build.mjs" >&2
        diff <(printf '%s\n' "$output") "$web/sources.sha256" >&2 || true
        false
    }

    # The manifest agreeing with the sources says the MANIFEST was rebuilt. It
    # says nothing about the page, and a commit that stages web/src and
    # web/sources.sha256 while leaving index.html behind is exactly the shape
    # this test exists to catch - it would pass everything above.
    #
    # build.mjs stamps the page with sha256sum of the manifest it wrote in the
    # same run, so the page carrying that hash is the page having been built
    # from that manifest. Two comparisons, and the pair is what closes it.
    local stamp expected
    stamp="$(grep -oE 'Sources: [a-f0-9]{64}' "$web/index.html" | head -1)"
    stamp="${stamp#Sources: }"
    expected="$(sha256sum "$web/sources.sha256" | cut -d' ' -f1)"
    [ -n "$stamp" ] || { echo "web/index.html carries no Sources stamp" >&2; false; }
    [ "$stamp" = "$expected" ] || {
        echo "web/index.html is stale: it was built from a different manifest." >&2
        echo "  page stamp:  $stamp" >&2
        echo "  manifest is: $expected" >&2
        echo "Rebuild it:  cd web && npm ci && node build.mjs" >&2
        false
    }
}

@test "the terminal page fetches nothing at page load" {
    # Two reasons, either sufficient. ttyd serves exactly one file - its HTTP
    # handler answers a token endpoint, a redirect and the index, and nothing
    # else - so a second asset would 404 rather than load. And the sandbox
    # restricts outbound traffic to an allowlist, so a CDN reference would not
    # resolve even from a browser outside it if the operator is on the same
    # restricted network.
    #
    # A `data:` URI is exempt and only that: it carries its bytes in the
    # attribute, so it fetches nothing and neither reason above applies to it.
    # The favicon is one. Matched per attribute rather than per line, so a data
    # URI on a line cannot carry a real reference past this beside it.
    local page="$REPO_ROOT/web/index.html"
    [ -f "$page" ]
    run bash -c "grep -oEi '<(script|link|img|iframe)[^>]+(src|href)=\"[^\"]*\"' '$page' \
                 | grep -vEi '(src|href)=\"data:'"
    [ "$status" -ne 0 ] || { echo "the page references an external asset: $output" >&2; false; }

    # And the exemption is not a hole: anything that is not a data URI still
    # fails, checked against a copy rather than trusted.
    local probe="$BATS_TEST_TMPDIR/probe.html"
    sed 's|<link rel="icon"|<link rel="stylesheet" href="https://cdn.example.com/x.css"><link rel="icon"|' \
        "$page" > "$probe"
    run bash -c "grep -oEi '<(script|link|img|iframe)[^>]+(src|href)=\"[^\"]*\"' '$probe' \
                 | grep -vEi '(src|href)=\"data:'"
    [ "$status" -eq 0 ] \
        || { echo "the check no longer catches a real external reference" >&2; false; }
}

@test "the terminal page's own unit tests pass" {
    # The pure parts - mouse report encoding, the private-mode tracker, sticky
    # Ctrl, OSC 52 decoding, prefix parsing - are the parts a browser test
    # could only reach through a gesture, so they are written to be checkable
    # without one. Run from here rather than from a second CI job, so they
    # cannot quietly stop running.
    command -v node >/dev/null 2>&1 || skip "node is not installed"
    run node --test "$REPO_ROOT"/web/test/*.test.js
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "ttyd validates the WebSocket origin, and the proxy passes the Host it compares against" {
    # Without --check-origin ttyd does no origin validation at all (its
    # protocol.c only calls check_host_origin when the flag is set), and
    # browsers do not apply the same-origin policy to WebSockets: any page in
    # the operator's browser could open wss://<front-door>/ws, have the
    # browser attach the cached Basic credential for that origin, and get the
    # host shell - no operator interaction beyond visiting the page. auth_basic
    # cannot stop that, because it is satisfied by the victim's own browser.
    [ -x "$REPO_ROOT/bin/dejima-ttyd" ]
    write_remote_config 'ttyd_port = 12345'
    stub_ttyd
    stub_ss_no_listeners
    run "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -eq 0 ]
    # Executed, not grepped: the flag has to reach ttyd's argv.
    printf '%s\n' "$(ttyd_log)" | grep -qx -- '--check-origin'

    # ttyd compares the Origin authority against the HOST HEADER, so the flag
    # is only a guard if the proxy passes the client's Host through. Deleting
    # this one line would leave --check-origin comparing against 127.0.0.1:port
    # and refusing every real client - or, worse, quietly changing what is
    # being compared. The two ship together or not at all.
    local ex="$REPO_ROOT/docs/nginx-dejima.conf.example"
    [ -f "$ex" ]
    # $http_host, not $host: nginx's $host has the PORT STRIPPED, and ttyd
    # keeps the port in what it compares whenever it is not 80 or 443. A front
    # door on 8443 - the common case, when 443 is already taken - would then
    # compare "host:8443" against "host" and refuse every WebSocket, with the
    # page loading fine and nothing but an lwsl_warn in the journal to say why.
    grep -qE '^[[:space:]]*proxy_set_header[[:space:]]+Host[[:space:]]+\$http_host;' "$ex"
    run grep -nE '\$host;' "$ex"
    [ "$status" -ne 0 ]
}

@test "nothing shipped by the front doors binds a routable address" {
    # Load-bearing, not stylistic. The egress policy permits traffic to
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

# One line per server block in the example: its listen line and whether the
# block authenticates, proxies, refuses, and is the default for its address.
#
# Per BLOCK rather than per file, because every property these tests care
# about is a per-block directive. A file-wide `grep -q auth_basic` passes on a
# file whose second block has none, and that block is the open door. Braces
# are counted rather than matched on indentation, so the `location` block
# nested inside a server doesn't end it early.
nginx_blocks() {
    awk '
        function count(s, ch,   n, i) {
            n = 0
            for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++
            return n
        }
        !inb && /^[[:space:]]*server[[:space:]]*\{/ {
            inb = 1; depth = 0
            listen = "NONE"; auth = 0; pass = 0; reject = 0; def = 0; subf = 0
        }
        inb {
            if ($0 ~ /^[[:space:]]*listen[[:space:]]/)          listen = $0
            if ($0 ~ /^[[:space:]]*auth_basic[[:space:]]+"/)    auth = 1
            if ($0 ~ /^[[:space:]]*proxy_pass[[:space:]]/)      pass = 1
            if ($0 ~ /^[[:space:]]*ssl_reject_handshake[[:space:]]+on;/ ||
                $0 ~ /^[[:space:]]*return[[:space:]]+444;/)     reject = 1
            if ($0 ~ /default_server/)                          def = 1
            if ($0 ~ /^[[:space:]]*sub_filter[[:space:]]/)      subf = 1
            depth += count($0, "{") - count($0, "}")
            if (depth <= 0) {
                printf "auth=%d pass=%d reject=%d def=%d sub=%d listen=<%s>\n", \
                    auth, pass, reject, def, subf, listen
                inb = 0
            }
        }
    ' "$1"
}

@test "the nginx example cannot be loaded as-is and never binds every interface" {
    local ex="$REPO_ROOT/docs/nginx-dejima.conf.example" block n=0
    [ -f "$ex" ]
    grep -q '/path/to/' "$ex"
    while IFS= read -r block; do
        n=$((n + 1))
        # Every block, every listen. A bare `listen 443 ssl;` binds every
        # interface including the bridge address a container can reach, and a
        # block with NO listen at all is not caught by grepping listen lines -
        # nginx defaults it to *:80, the same wildcard bind in the clear.
        [[ "$block" == *"listen=<"*"<LAN-IP>:"* ]] \
            || { echo "block $n does not listen on the placeholder address: $block" >&2; false; }
        [[ "$block" == *" ssl"* || "$block" == *" ssl;"* ]] \
            || { echo "block $n listens without ssl: $block" >&2; false; }
    done < <(nginx_blocks "$ex")
    [ "$n" -ge 2 ]
}

@test "the nginx example refuses every hostname but its own" {
    local ex="$REPO_ROOT/docs/nginx-dejima.conf.example" block defaults=0
    [ -f "$ex" ]
    # nginx serves the DEFAULT server for a listen address whenever the Host
    # matches no server_name, and with a single block that default IS the
    # front door - so it answers to every name resolving to that address, the
    # box's own included, and server_name isolates nothing. The example has to
    # ship a default that refuses, or the isolation it appears to describe
    # does not exist.
    while IFS= read -r block; do
        case "$block" in
            *"def=1"*)
                defaults=$((defaults + 1))
                # The default block must be the one that serves NOTHING.
                [[ "$block" == *"reject=1"* ]] \
                    || { echo "the default server does not refuse: $block" >&2; false; }
                [[ "$block" == *"pass=0"* ]] \
                    || { echo "the default server proxies to ttyd: $block" >&2; false; }
                ;;
        esac
    done < <(nginx_blocks "$ex")
    [ "$defaults" -eq 1 ]
    grep -qE '^[[:space:]]*server_name[[:space:]]+<hostname>;' "$ex"
}

@test "the nginx example proxies to the port dejima-ttyd defaults to, over a connection that can idle" {
    local ex="$REPO_ROOT/docs/nginx-dejima.conf.example" port
    [ -f "$ex" ]
    # Taken from the library rather than hardcoded, so the example and the
    # default can never drift apart without this failing.
    write_remote_config
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

@test "the terminal page ships its own viewport meta" {
    # ttyd serves no <meta name="viewport"> - not in 1.7.7, not on main - so a
    # phone lays the page out at a virtual desktop width and scales it down,
    # which no font size can undo and which zooming cannot reflow. The page
    # supplies the tag itself, so the layout does not depend on the reverse
    # proxy in front of it rewriting the body.
    local page="$REPO_ROOT/web/index.html"
    [ -f "$page" ]
    grep -qE '<meta name="viewport"[^>]*width=device-width' "$page"
    # user-scalable=no is not tidiness: a two-finger drag is this page's scroll
    # gesture, and pinch-zoom would consume it.
    grep -qE '<meta name="viewport"[^>]*user-scalable=no' "$page"

    # And the example no longer injects one. Two tags would not conflict, but
    # the sub_filter would silently reintroduce its own requirements - an nginx
    # built with the sub module, and Accept-Encoding cleared toward the
    # upstream - whose only symptom when unmet is the tag appearing not to work.
    local ex="$REPO_ROOT/docs/nginx-dejima.conf.example"
    [ -f "$ex" ]
    run grep -nE '^[[:space:]]*sub_filter' "$ex"
    [ "$status" -ne 0 ]

    # The cache header stays, for a reason that survived the change and got
    # stronger: ttyd sends the page with no Cache-Control, no ETag and no
    # Last-Modified, so a browser may cache it indefinitely - and the page is
    # now a build artifact that moves with this repo, so a phone that has been
    # here before renders whatever it first saw.
    grep -qE '^[[:space:]]*add_header[[:space:]]+Cache-Control[[:space:]]+"no-store"' "$ex"
}

@test "the nginx example carries the only authentication there is" {
    local ex="$REPO_ROOT/docs/nginx-dejima.conf.example"
    [ -f "$ex" ]
    grep -qE '^[[:space:]]*auth_basic[[:space:]]' "$ex"
    grep -qE '^[[:space:]]*auth_basic_user_file[[:space:]]' "$ex"
    grep -qE '^[[:space:]]*ssl_certificate[[:space:]]' "$ex"
    # Judged per block, because auth is a per-block directive: one block with
    # it and one without passes every "is it present" grep and still leaves an
    # open door. The rule is about what a block SERVES - anything that can
    # reach ttyd needs authentication, and a block with none is only allowed
    # if it serves nothing at all.
    # A realm, not just the directive: `auth_basic off;` IS an auth_basic line
    # and turns authentication off for the block it is in.
    local block proxies=0
    while IFS= read -r block; do
        case "$block" in
            *"pass=1"*)
                proxies=$((proxies + 1))
                [[ "$block" == *"auth=1"* ]] \
                    || { echo "a block proxies to ttyd without authentication: $block" >&2; false; }
                ;;
            *"auth=0"*)
                [[ "$block" == *"reject=1"* ]] \
                    || { echo "a block without authentication serves something: $block" >&2; false; }
                ;;
        esac
    done < <(nginx_blocks "$ex")
    [ "$proxies" -ge 1 ]
    run grep -nE '^[[:space:]]*auth_basic[[:space:]]+off' "$ex"
    [ "$status" -ne 0 ]
    # ttyd is started --writable and with no credential of its own, so nginx
    # is the whole gate. If that ever changes, both halves have to change
    # together rather than one of them drifting.
    grep -q -- '--writable' "$REPO_ROOT/bin/dejima-ttyd"
    run grep -nE -- '--credential|[[:space:]]-c[[:space:]]' "$REPO_ROOT/bin/dejima-ttyd"
    [ "$status" -ne 0 ]
}

@test "install.sh links the remote scripts and the notify hook, registers neither, and enables nothing" {
    # The hook is baked into the image and registered by absolute path, so
    # install.sh puts nothing of it on the host - which file it is, and where
    # a session reads it from, is the harness plugin's business. The CLIs stay
    # install.sh's, being dejima's own.
    grep -q 'COPY hooks/dejima-notify.sh /usr/local/lib/dejima/hooks/dejima-notify.sh' \
        "$REPO_ROOT/docker/Dockerfile"
    grep -q '_link_hook' "$REPO_ROOT/bin/harness/claude-code.sh" \
        && { echo "install.sh still links hooks into ~/.claude/hooks"; return 1; }
    grep -q '^link_bin dejima-attach$' "$REPO_ROOT/install.sh"
    grep -q '^link_bin dejima-ttyd$' "$REPO_ROOT/install.sh"
    grep -q '^link_bin dejima-notify-watch$' "$REPO_ROOT/install.sh"
    # The notify hook is registered per session by bin/dejima, into a
    # throwaway settings copy. Registered here it would fire for every
    # unsandboxed host session too.
    run grep -nE '_register .*dejima-notify' "$REPO_ROOT/bin/harness/claude-code.sh"
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
    # Asserted here rather than further down: every `run` below replaces
    # $output, and this is a statement about what THIS run printed.
    [[ "$output" == *"nothing is listening"* ]]

    # The notify hook is baked into the image and registered per session by
    # its absolute path there, so nothing about it lands on the host. Without
    # the baked copy every notification hook would be an exit-127.
    [ ! -e "$FAKE_HOME/.claude/hooks/dejima-notify.sh" ] \
        || { echo "install.sh still puts the notify hook on the host"; return 1; }
    # Asserted on what the registration PRODUCES rather than on the source
    # text: the path is a variable there, and a grep for the literal passes or
    # fails on how it happens to be spelled rather than on where it points.
    local st; st="$(mktemp)"; echo '{}' > "$st"
    bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        harness_plugin_load claude-code
        harness_hook harness_register_notify "$1"
    ' _ "$st" >/dev/null 2>&1
    [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$st")" \
        = "/usr/local/lib/dejima/hooks/dejima-notify.sh done" ] \
        || { echo "notify is not registered at its baked path: $(cat "$st")"; rm -f "$st"; return 1; }
    rm -f "$st"
    local b
    for b in dejima-attach dejima-ttyd dejima-notify-watch; do
        [ -L "$FAKE_HOME/.local/bin/$b" ]
        [ "$(readlink -f "$FAKE_HOME/.local/bin/$b")" = "$(readlink -f "$REPO_ROOT/bin/$b")" ]
        [ -x "$FAKE_HOME/.local/bin/$b" ]
    done

    # install.sh registers nothing in the harness's config now, so there is
    # nothing positive to check there - the settings file may not exist at
    # all. The positive assertion that matters moved above: the notify hook IS
    # registered, at its baked path, in the sandbox's own overlay.
    if [ -f "$FAKE_HOME/.claude/settings.json" ]; then
        run jq -e '[.hooks[]?[]?.hooks[]?.command] | any(test("dejima-notify"))' \
            "$FAKE_HOME/.claude/settings.json"
        [ "$status" -ne 0 ]
    fi

    # Nothing was enabled, and nothing under the runtime dir was created: the
    # feature stays off until the operator sets [remote-access] enabled = on.
    [ ! -e "$RUNTIME_DIR/dejima" ]
    [ ! -e "$FAKE_HOME/.config/systemd" ]

    # Re-runnable: the second pass displaces nothing into the backup dir.
    run env HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$FAKE_HOME/.dejima-backup" ]
    [ ! -e "$FAKE_HOME/.claude/hooks/dejima-notify.sh" ]

    # And with one, it may not: re-running the installer after a git pull is
    # exactly what an operator with a front door already up does, and telling
    # them nothing is listening is a false statement about their own machine.
    write_remote_config
    run env HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"nothing is listening"* ]]
    [[ "$output" == *"$CONFIG_DIR/config"* ]]

    # With DEJIMA_CONFIG_DIR unset, which is how every operator runs it: the
    # installer has to look where the library looks. Everything above runs
    # with the variable exported, so the default path is otherwise never
    # exercised and could point anywhere.
    mkdir -p "$FAKE_HOME/.config/dejima"
    printf '[remote-access]\nenabled = on\nbase_url = https://d.example\n' > "$FAKE_HOME/.config/dejima/config"
    run env -u DEJIMA_CONFIG_DIR HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" \
        "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"nothing is listening"* ]]
    [[ "$output" == *"$FAKE_HOME/.config/dejima/config"* ]]
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
        # Restarting on failure, not always: these units exist to be given up
        # on when base_url is unset or the config is invalid, which is a
        # clean-ish exit away from Restart=always.
        grep -q '^Restart=on-failure$' "$f"
        # A WHITELIST of directive names, not a list of banned ones: a denylist
        # only ever catches the directives someone thought of, and these units
        # run a host shell - StandardOutput=file:..., User=, Environment=,
        # ExecStartPre= are all things that change what runs or where its
        # output goes. Anything not on this line has to be added deliberately -
        # including a systemd line continuation, whose second line carries no
        # "=" and so fails this. That is the intended trade: these units are
        # five directives long and none of them needs one.
        run bash -c 'grep -vE "^[[:space:]]*([#;]|$)" "$1" \
            | grep -vxE "\[(Unit|Service|Install)\]" | sed "s/=.*//" | sort -u \
            | grep -vxE "Description|StartLimitIntervalSec|StartLimitBurst|ExecStart|Restart|RestartSec|WantedBy"' \
            _ "$f"
        [ "$status" -ne 0 ]
        # The whitelist covers directive NAMES; the rest of this test is about
        # their VALUES. No absolute home - %h is what makes these units the
        # same file for every operator.
        run bash -c 'grep -vE "^[[:space:]]*[#;]" "$1" | grep -nE "/home/|/root/|/Users/"' _ "$f"
        [ "$status" -ne 0 ]
        # remote.conf is the single source of truth for all of these. A unit
        # that repeated one would drift from the script that reads it.
        run bash -c 'grep -vE "^[[:space:]]*[#;]" "$1" | grep -nE "TTYD_PORT|NTFY_URL|BASE_URL|--port|--interface"' _ "$f"
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
    printf '[remote-access]\nenabled = on\nbase_url = https://d.example\nttyd_port = 12345\n' \
        > "$FAKE_HOME/.config/dejima/config"
    stub_ttyd
    stub_ss_no_listeners

    local exec_start
    exec_start="$(unit_exec_start dejima-ttyd.service "$FAKE_HOME")"
    [ "$exec_start" = "$FAKE_HOME/.local/bin/dejima-ttyd" ]
    run env -i HOME="$FAKE_HOME" PATH="$STUB_DIR:/usr/bin:/bin" \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" "$exec_start"
    [ "$status" -eq 0 ]
    # %h resolved to the install destination, the symlink resolved back to
    # this repo (the command below is the repo's dejima-attach, not the
    # link), and the config was found at the default config path with no
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
    cp "$CONFIG_DIR/config" "$FAKE_HOME/.config/dejima/config"
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

# The whole doc this feature is documented in. It used to be one "## Remote
# access" section awk'd out of the README, and the carving was the point: a
# string that only has to appear *somewhere* in a 900-line README is satisfied
# by an unrelated section. Its own file gives that for free.
remote_doc() {
    cat "$REPO_ROOT/docs/remote-access.md"
}

@test "the doc the front doors point readers at exists at the path they name" {
    # bin/dejima-ttyd, install.sh and five more end their diagnostics with
    # `See docs/remote-access.md`. Nothing else in the repo notices when one
    # side of that moves: the scripts still run, the doc still reads fine, and
    # the operator who most needs it is sent nowhere. The path is READ OUT of
    # the script rather than written here twice, so a rename on the code side
    # fails this test instead of quietly passing it.
    #
    # Normalized before matching, because the reference is not written the same
    # way twice: dejima-ttyd carries it on one comment line, while
    # dejima-attach's and the notify hook's wrap across two. Joining lines and
    # squashing '#' and runs of spaces makes all three the same string without
    # making the pattern itself lax.
    ref() { tr '\n' ' ' < "$1" | sed 's/#/ /g; s/  */ /g'; }
    local doc
    # head -n1 rather than grep -m1: the ref() above joins the file into a
    # single line, so -m1 stops after the first matching LINE and still prints
    # every match on it. A script that names the doc twice would otherwise
    # produce a two-line "path" and fail this on the wrong thing entirely.
    doc="$(ref "$REPO_ROOT/bin/dejima-ttyd" | grep -oE 'docs/[a-z-]+\.md' | head -n1)"
    [ -n "$doc" ]
    [ -f "$REPO_ROOT/$doc" ]
    # Reachable from the README too, not only from the scripts: the section it
    # was extracted from is now a stub whose one job is to link here.
    grep -qF "($doc)" "$REPO_ROOT/README.md"

    # And every other file that points at this feature points at the SAME
    # path - one stale pointer is as dangling as one moved file.
    local f
    for f in bin/dejima-attach bin/dejima-ttyd bin/dejima-notify-watch \
             bin/dejima bin/dejima-project-lib.sh hooks/dejima-notify.sh install.sh; do
        ref "$REPO_ROOT/$f" | grep -qF "$doc" || {
            echo "$f does not point at $doc" >&2
            false
        }
    done
}

@test "docs/remote-access.md documents every remote access setup step" {
    local section
    section="$(remote_doc)"
    [ -n "$section" ]
    # has <-F|-E> <pattern>. Fails the test on the first missing item, naming
    # it - a bare grep chain reports only a line number. The pattern goes
    # through -e because half of what's looked for below is a command-line
    # flag, which grep would otherwise try to interpret as its own.
    has() {
        printf '%s\n' "$section" | grep -q "$1" -e "$2" || {
            echo "docs/remote-access.md is missing: $2" >&2
            return 1
        }
    }

    # Opt-in, and the config key whose value is the switch.
    has -F '[remote-access]'
    has -F 'enabled = on'
    has -F '~/.config/dejima/config'

    # Every key the [remote-access] section accepts. This list used to be
    # derived from valid_remote_key(); that function and remote.conf are both
    # gone (see bin/dejima-project-lib.sh), and the keys now live in the
    # config schema (_config_table in bin/dejima-config-lib.sh). Pinned here
    # rather than derived so this still catches the doc losing one of them.
    local keys key
    keys='enabled ntfy_url base_url ttyd_port ttyd_font_size ttyd_tmux_prefix
           ttyd_focus_on_tap ttyd_button_colors'
    for key in $keys; do has -F "\`$key\`"; done

    # The port default, taken from the library so the two cannot drift.
    write_remote_config
    run lib remote_ttyd_port
    [ "$status" -eq 0 ]
    has -F "$output"

    # The binding requirement, which is the whole security of the feature:
    # ttyd on loopback, the proxy on one specific address, and the reason -
    # the container can route to the bridge gateway, and a tmux client is a
    # host shell.
    has -F '127.0.0.1'
    has -F '0.0.0.0'
    has -E 'bridge gateway'
    has -E 'host shell'
    # As a step the operator performs, not only as prose: a probe run from
    # inside a live sandbox at the host's own default-route address. Matched
    # loosely on purpose - that some runnable check is there is the point,
    # not which tool it reaches for.
    has -E 'ip route|default route'
    has -E '/dev/tcp|\bnc |ncat|curl '

    # Both front doors, the pieces each one needs, and the hook and watcher
    # behind the notification.
    has -F 'authorized_keys'
    has -F 'restrict,pty,command='
    has -F 'dejima-attach'
    has -F 'hooks/dejima-notify.sh'
    has -F 'docs/nginx-dejima.conf.example'
    has -F 'systemctl --user enable'
    # The step that keeps those user units - and the session registry that
    # lives in the runtime directory they read - alive across a logout. An
    # operator who skips it has a front door that works only while they hold
    # an interactive session on the host, which is the case the feature
    # exists for.
    has -F 'enable-linger'
    # Derived from what the repo ships: a third unit cannot be added and left
    # undocumented. (Full names, so "dejima-ttyd" alone does not satisfy it.)
    local unit
    for unit in "$REPO_ROOT"/systemd/*; do has -F "$(basename "$unit")"; done

    # ttyd's two load-bearing flags, and the version floor --writable needs.
    # An operator who installs an older ttyd gets a unit that fails at every
    # start, or - worse, before 1.7.4 inverted the default - a front door
    # whose only gate is the proxy.
    has -F '--check-origin'
    has -F '--writable'
    has -F '1.7.4'
    # The header --check-origin compares against, in the form that keeps the
    # port. The negative test next door forbids the other form; this one
    # makes sure the right one is actually named.
    has -F '$http_host'

    # The notification: what it says, what it deliberately does not, and the
    # deep link's shape.
    has -F 'ntfy'
    has -F 'inotify-tools'
    has -F 'needs input'
    has -F '?arg='
}

@test "docs/remote-access.md repeats no advice that would break or unbolt the front door" {
    local section
    section="$(remote_doc)"
    [ -n "$section" ]

    # Both checks below run against the doc's FENCED BLOCKS only - what a
    # reader copies out. Applied to the whole doc they would forbid the prose
    # that explains why each is wrong, which is the opposite of what this doc
    # needs to say.
    local blocks
    blocks="$(printf '%s\n' "$section" | awk '/^```/ { inblock = !inblock; next } inblock')"
    [ -n "$blocks" ]

    # $host, not $http_host, is the single most repeatable way to break this
    # setup: nginx's $host has the port stripped, ttyd keeps the port in what
    # --check-origin compares unless it is 80 or 443, and a vhost on any
    # other port then refuses every WebSocket while serving the page fine.
    # docs/nginx-dejima.conf.example is already guarded against it; this doc
    # is the other place the line gets copied from.
    run bash -c 'printf "%s\n" "$1" | grep -nE "\\\$host([^_a-zA-Z]|$)"' _ "$blocks"
    [ "$status" -ne 0 ]

    # No bare package-manager one-liner for ttyd. A distro's default suite is
    # where the too-old builds are - bookworm 1.7.3, Ubuntu 22.04 1.6.3 - so an
    # untargeted apt line here is an instruction that yields a broken front
    # door, and a command in a fenced block is what gets copied, not the caveat
    # beside it. An explicitly release-targeted install (sid packages 1.7.7) is
    # the one form that says which build you get, so only that is allowed.
    run bash -c 'printf "%s\n" "$1" | grep -nE "apt(-get)? install .*ttyd" \
        | grep -vE "install +-t +(unstable|sid) "' _ "$blocks"
    [ "$status" -ne 0 ]

    # And a recipe that adds unstable has to pin it, or it is an instruction to
    # drag the whole host to sid on the next upgrade.
    if printf '%s\n' "$blocks" | grep -qE '\bunstable\b|\bsid\b'; then
        printf '%s\n' "$blocks" | grep -q 'Pin-Priority'
    fi

    # Any instruction to install ttyd from a package has to be accompanied by
    # the one that disables the service the package turns on. Debian/Ubuntu
    # enable it on install; it serves a login prompt and, passing no
    # --interface, binds every address - so it is reachable from inside a
    # sandbox, on the port this feature defaults to, purely as a result of
    # following the install step above it. Documenting the install without the
    # disable is worse than documenting neither.
    # Both halves, asserted separately: disable stops the running listener,
    # mask is what stops the next `apt install` from turning it back on, and
    # an alternation over the two passes on a file that only has one.
    if printf '%s\n' "$blocks" | grep -qE 'apt(-get)? install .*ttyd'; then
        printf '%s\n' "$blocks" | grep -qE 'systemctl +disable.*ttyd'
        printf '%s\n' "$blocks" | grep -qE 'systemctl +mask.*ttyd'
    fi

    # This repo is public, and this doc is where an operator's own setup is
    # most likely to leak in. Every absolute URL has to be loopback, a name
    # that cannot belong to anyone (RFC 2606), or one of a short list of public
    # infrastructure hosts nobody could mistake for a personal one.
    # test/static.bats catches address- and suffix-shaped leaks across the
    # README and docs/; this catches a real ntfy topic, which is always a URL.
    run bash -c 'printf "%s\n" "$1" | grep -hoiE "https?://[a-z0-9.:@_-]+" \
        | grep -viE "^https?://(127\.0\.0\.1(:[0-9]+)?|(www\.)?example\.(com|net|org)|[a-z0-9-]+\.(invalid|example|test)|deb\.debian\.org)"' \
        _ "$section"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "one session-finished push per stop, not a second one a minute later" {
    # Claude Code raises Notification when it needs permission and when the
    # prompt has sat idle. A dejima session runs with permission prompts off,
    # so only the timer is left, and it expires shortly after the Stop it
    # follows - two pushes on a phone for one event, the second carrying
    # nothing the first had not. Debouncing cannot merge them: the watcher
    # keys on run id AND event, deliberately, so waiting and done are separate
    # signals whenever a harness can actually tell them apart.
    stub_launch
    write_remote_config
    launch "$PROJ"
    run jq -r '[.hooks[][].hooks[].command] | join(" ")' "$LAUNCH_DIR/settings-copy.json"
    [[ "$output" == *'dejima-notify.sh done'* ]] \
        || { echo "the stop notification is gone entirely: $output"; return 1; }
    [[ "$output" != *'dejima-notify.sh waiting'* ]] \
        || { echo "the idle timer is registered again: $output"; return 1; }
    rm -rf "$PROJ"
}

@test "the watcher still consumes a waiting marker no hook registers" {
    # Nothing writes one by default now, and that changes nothing here: the
    # marker directory is bind-mounted read-write, so a session creates
    # whatever names it likes. The enum is the boundary, not the registration,
    # and dropping `waiting` from it would leave a marker that accumulates
    # rather than one that is refused.
    conf_with_ntfy
    stub_curl
    write_entry 0123456789abcdef '%1' 'work:2'
    marker 0123456789abcdef waiting
    run "$REPO_ROOT/bin/dejima-notify-watch" --once
    [ "$status" -eq 0 ]
    [ ! -e "$RUNTIME_DIR/dejima/notify/0123456789abcdef/waiting" ] \
        || { echo "the marker was left to accumulate"; return 1; }
    assert_argv 'myproject needs input' 'Session is waiting for you.' \
        'https://dejima.example.invalid/?arg=0123456789abcdef'
}

@test "the session picker starts on a clean screen, scrollback included" {
    # Reopening it from the web toolbar is a full page load, and it drew on
    # top of whatever the previous session had left on screen - rows
    # interleaved with the tail of the session just left, which reads as a
    # rendering fault rather than a new screen (#213). Invisible over SSH,
    # where a fresh connection to the forced command starts on a blank one.
    write_remote_config
    stub_docker_run_id 0123456789abcdef
    start_tmux
    write_entry 0123456789abcdef "$TARGET_PANE" 'work:1'

    run script -qec "echo q | '$REPO_ROOT/bin/dejima-attach'" /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033[2J'* ]] || { echo "the screen is not cleared"; return 1; }
    # And the scrollback with it: without 3J a swipe up on a phone lands in
    # the middle of the previous session's output.
    [[ "$output" == *$'\033[3J'* ]] || { echo "the scrollback is left behind"; return 1; }

    # Not on the machine interface. ttyd feeds run ids back in from --list,
    # and these bytes in a log are the failure this is gated to avoid.
    run script -qec "'$REPO_ROOT/bin/dejima-attach' --list" /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\033[2J'* ]] || { echo "--list cleared the screen"; return 1; }
}

@test "no terminal, no clear" {
    # A pipe or a dumb terminal gets none of it. NO_COLOR does not suppress it
    # though: that asks for no decoration, not for a front door drawn over the
    # last session.
    local out
    out="$(bash -c 'source "$1"; tui_clear; echo AFTER' _ "$REPO_ROOT/bin/dejima-tui-lib.sh")"
    [ "$out" = AFTER ] || { echo "a pipe got escape bytes: $(printf '%q' "$out")"; return 1; }
    run script -qec "TERM=dumb bash -c 'source $REPO_ROOT/bin/dejima-tui-lib.sh; tui_clear; echo AFTER'" /dev/null
    [[ "$output" != *$'\033['* ]] || { echo "a dumb terminal got escape bytes"; return 1; }
    # NO_COLOR too, on a real terminal. It rides the same switch as the colour
    # and the glyphs, which is the reading this file already committed to -
    # the alternative is a picker answering to two ideas of "plain".
    run script -qec "NO_COLOR=1 TERM=xterm bash -c 'source $REPO_ROOT/bin/dejima-tui-lib.sh; tui_clear; echo AFTER'" /dev/null
    [[ "$output" != *$'\033['* ]] || { echo "NO_COLOR still got a screen clear"; return 1; }
}
