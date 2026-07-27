#!/usr/bin/env bats
# Host-side (no Docker): per-project declaration parsing, the approval store,
# and the three CLIs that manage it. Declarations are untrusted input - these
# tests are what keep them from ever becoming code or an unapproved grant.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/bin/claude-sandbox-project-lib.sh"
    CONFIG_DIR="$(mktemp -d)"
    export CLAUDE_SANDBOX_CONFIG_DIR="$CONFIG_DIR"
    PROJ="$(mktemp -d)"
    mkdir -p "$PROJ/.claude-sandbox"
}
teardown() { rm -rf "$CONFIG_DIR" "$PROJ"; }

@test "valid_domain accepts real domains and rejects shell-active input" {
    run bash -c 'source "$1"; valid_domain "crates.io"' _ "$LIB"
    [ "$status" -eq 0 ]
    run bash -c 'source "$1"; valid_domain "static.crates.io"' _ "$LIB"
    [ "$status" -eq 0 ]
    run bash -c 'source "$1"; valid_domain "evil.com; curl x"' _ "$LIB"
    [ "$status" -ne 0 ]
    run bash -c 'source "$1"; valid_domain "\$(id)"' _ "$LIB"
    [ "$status" -ne 0 ]
    run bash -c 'source "$1"; valid_domain "a/b"' _ "$LIB"
    [ "$status" -ne 0 ]
}

@test "valid_dep_spec accepts the four ecosystems and rejects anything else" {
    for spec in apt:libpq-dev npm:typescript pip:ruff cargo:cargo-nextest apt:g++ pip:ruamel.yaml; do
        run bash -c 'source "$1"; valid_dep_spec "$2"' _ "$LIB" "$spec"
        [ "$status" -eq 0 ]
    done
    for spec in 'libpq-dev' 'gem:rails' 'apt:' 'apt:a;b' 'apt:$(id)' 'npm:a b'; do
        run bash -c 'source "$1"; valid_dep_spec "$2"' _ "$LIB" "$spec"
        [ "$status" -ne 0 ]
    done
}

@test "read_declared skips comments/blanks and marks invalid entries rejected" {
    cat > "$PROJ/.claude-sandbox/dependencies" <<'EOF'
# project deps
apt:libpq-dev

cargo:cargo-nextest
gem:rails
EOF
    run bash -c 'source "$1"; read_declared "$2" valid_dep_spec' _ "$LIB" "$PROJ/.claude-sandbox/dependencies"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok apt:libpq-dev"* ]]
    [[ "$output" == *"ok cargo:cargo-nextest"* ]]
    [[ "$output" == *"rejected gem:rails"* ]]
    [[ "$output" != *"ok gem:rails"* ]]
    [[ "$output" != *"# project deps"* ]]
}

@test "read_declared prints nothing for a missing file" {
    run bash -c 'source "$1"; read_declared "$2" valid_dep_spec' _ "$LIB" "$PROJ/.claude-sandbox/nope"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "read_declared caps at 200 entries and says so" {
    for i in $(seq 1 250); do echo "apt:pkg$i"; done > "$PROJ/.claude-sandbox/dependencies"
    run bash -c 'source "$1"; read_declared "$2" valid_dep_spec' _ "$LIB" "$PROJ/.claude-sandbox/dependencies"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^ok ' <<< "$output")" -eq 200 ]
    [[ "$output" == *"truncated 250"* ]]
    [[ "$output" != *"apt:pkg201"* ]]
}
