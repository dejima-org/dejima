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

@test "project_slug matches the log-shipper project-key rule" {
    run bash -c 'source "$1"; project_slug "/home/brad/my-proj"' _ "$LIB"
    [ "$output" = "-home-brad-my-proj" ]
}

@test "ensure_project_store creates the store and records the real path" {
    run bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ"
    [ "$status" -eq 0 ]
    [ -d "$output" ]
    [ "$(cat "$output/path")" = "$PROJ" ]
}

@test "resolve_project_store finds nothing before anything is approved" {
    run bash -c 'source "$1"; resolve_project_store "$2"' _ "$LIB" "$PROJ"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "resolve_project_store walks up so a worktree inherits its parent's approvals" {
    bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ" >/dev/null
    mkdir -p "$PROJ/.worktrees/feature-x"
    run bash -c 'source "$1"; resolve_project_store "$2"' _ "$LIB" "$PROJ/.worktrees/feature-x"
    [ "$status" -eq 0 ]
    [ "$(cat "$output/path")" = "$PROJ" ]
}

@test "resolve_project_store fails loudly on a slug collision" {
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    echo "/some/other/project" > "$store/path"
    run bash -c 'source "$1"; resolve_project_store "$2"' _ "$LIB" "$PROJ"
    [ "$status" -ne 0 ]
    [[ "$output" == *"collision"* ]]
}

@test "approve_entry is idempotent and unapprove_entry removes" {
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    bash -c 'source "$1"; approve_entry "$2" allowed-domains crates.io' _ "$LIB" "$store"
    bash -c 'source "$1"; approve_entry "$2" allowed-domains crates.io' _ "$LIB" "$store"
    run bash -c 'source "$1"; approved_entries "$2" allowed-domains' _ "$LIB" "$store"
    [ "$(grep -c 'crates.io' <<< "$output")" -eq 1 ]
    bash -c 'source "$1"; unapprove_entry "$2" allowed-domains crates.io' _ "$LIB" "$store"
    run bash -c 'source "$1"; approved_entries "$2" allowed-domains' _ "$LIB" "$store"
    [ "$output" = "" ]
}

@test "approved_entries rejects a corrupt approval file rather than using it" {
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    echo 'evil.com; curl x' > "$store/allowed-domains"
    run bash -c 'source "$1"; approved_entries "$2" allowed-domains' _ "$LIB" "$store"
    [ "$status" -ne 0 ]
    [[ "$output" == *"corrupt"* ]]
}

@test "resolve_project_store rejects relative paths without hanging" {
    run timeout 2 bash -c 'source "$1"; resolve_project_store "foo/bar"' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" == *"absolute"* ]]
}

@test "claude-sandbox-dep add approves a spec and list shows it" {
    run "$REPO_ROOT/bin/claude-sandbox-dep" add apt:libpq-dev --project "$PROJ"
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --project "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"apt:libpq-dev"* ]]
}

@test "claude-sandbox-dep add says the change needs a relaunch" {
    run "$REPO_ROOT/bin/claude-sandbox-dep" add apt:libpq-dev --project "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"next launch"* ]]
}

@test "claude-sandbox-dep rejects a malformed spec without writing anything" {
    run "$REPO_ROOT/bin/claude-sandbox-dep" add 'apt:a;b' --project "$PROJ"
    [ "$status" -ne 0 ]
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --project "$PROJ"
    [[ "$output" != *"a;b"* ]]
}

@test "claude-sandbox-dep remove takes a spec back out" {
    "$REPO_ROOT/bin/claude-sandbox-dep" add npm:typescript --project "$PROJ" >/dev/null
    run "$REPO_ROOT/bin/claude-sandbox-dep" remove npm:typescript --project "$PROJ"
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --project "$PROJ"
    [[ "$output" != *"npm:typescript"* ]]
}

@test "claude-sandbox-allow --project persists without needing a container" {
    run env CLAUDE_SANDBOX_ALLOW_SKIP_SESSION=1 \
        "$REPO_ROOT/bin/claude-sandbox-allow" crates.io --project "$PROJ"
    [ "$status" -eq 0 ]
    store="$CONFIG_DIR/projects/$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    grep -qx 'crates.io' "$store/allowed-domains"
}

@test "claude-sandbox-allow --project still refuses an invalid domain" {
    run env CLAUDE_SANDBOX_ALLOW_SKIP_SESSION=1 \
        "$REPO_ROOT/bin/claude-sandbox-allow" 'evil.com; curl x' --project "$PROJ"
    [ "$status" -ne 0 ]
}

@test "claude-sandbox-project status shows declared, approved and rejected" {
    printf 'apt:libpq-dev\ngem:rails\n' > "$PROJ/.claude-sandbox/dependencies"
    printf 'static.crates.io\n' > "$PROJ/.claude-sandbox/allowed-domains"
    "$REPO_ROOT/bin/claude-sandbox-dep" add apt:libpq-dev --project "$PROJ" >/dev/null
    run "$REPO_ROOT/bin/claude-sandbox-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"approved"*"apt:libpq-dev"* ]]
    [[ "$output" == *"rejected"*"gem:rails"* ]]
    [[ "$output" == *"static.crates.io"* ]]
}

@test "claude-sandbox-project approve declines without confirmation" {
    printf 'apt:libpq-dev\n' > "$PROJ/.claude-sandbox/dependencies"
    run bash -c 'echo n | "$1" approve "$2"' _ "$REPO_ROOT/bin/claude-sandbox-project" "$PROJ"
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --project "$PROJ"
    [[ "$output" != *"apt:libpq-dev"* ]]
}

@test "claude-sandbox-project approve approves the declared set on confirmation" {
    printf 'apt:libpq-dev\n' > "$PROJ/.claude-sandbox/dependencies"
    printf 'static.crates.io\n' > "$PROJ/.claude-sandbox/allowed-domains"
    run bash -c 'echo y | CLAUDE_SANDBOX_ALLOW_SKIP_SESSION=1 "$1" approve "$2"' \
        _ "$REPO_ROOT/bin/claude-sandbox-project" "$PROJ"
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --project "$PROJ"
    [[ "$output" == *"apt:libpq-dev"* ]]
    store="$CONFIG_DIR/projects/$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    grep -qx 'static.crates.io' "$store/allowed-domains"
}

@test "claude-sandbox-project approve never approves a rejected entry" {
    printf 'gem:rails\n' > "$PROJ/.claude-sandbox/dependencies"
    run bash -c 'echo y | "$1" approve "$2"' _ "$REPO_ROOT/bin/claude-sandbox-project" "$PROJ"
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --project "$PROJ"
    [[ "$output" != *"gem:rails"* ]]
}

@test "claude-sandbox-project approve reports a rejected entry's literal text, unsplit and unglobbed" {
    printf 'npm:has space\n' > "$PROJ/.claude-sandbox/dependencies"
    printf 'a*evil\n' > "$PROJ/.claude-sandbox/allowed-domains"
    run "$REPO_ROOT/bin/claude-sandbox-project" approve "$PROJ" < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"npm:has space"* ]]
    [[ "$output" == *"a*evil"* ]]
}

@test "claude-sandbox-project approve warns about entries beyond the 200-entry cap" {
    for i in $(seq 1 250); do echo "apt:pkg$i"; done > "$PROJ/.claude-sandbox/dependencies"
    run bash -c 'echo n | "$1" approve "$2"' _ "$REPO_ROOT/bin/claude-sandbox-project" "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"250"* ]]
}

@test "claude-sandbox-project approve exits 0 and approves nothing when stdin is already at EOF" {
    printf 'apt:libpq-dev\n' > "$PROJ/.claude-sandbox/dependencies"
    run "$REPO_ROOT/bin/claude-sandbox-project" approve "$PROJ" < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing approved."* ]]
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --project "$PROJ"
    [[ "$output" != *"apt:libpq-dev"* ]]
}
