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
    rm -rf "$CONFIG_DIR" "$RUNTIME_DIR" ${STUB_DIR:+"$STUB_DIR"} ${LAUNCH_DIR:+"$LAUNCH_DIR"}
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
