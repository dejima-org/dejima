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
teardown() { rm -rf "$CONFIG_DIR" "$PROJ" ${STUB_DIR:+"$STUB_DIR"} ${LAUNCH_DIR:+"$LAUNCH_DIR"}; }

store_of() {
    printf '%s/projects/%s' "$CONFIG_DIR" \
        "$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$1")"
}

# A fake `docker` on PATH, so the container-facing half of
# claude-sandbox-allow can be exercised without a daemon. $1 is how many
# running sandboxes to report, $2 the exit status the in-container curl
# reachability check should return.
stub_docker() {
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<EOF
#!/bin/bash
if [ "\$1" = ps ]; then
    [ "$1" -eq 0 ] || echo claude-sandbox-test-container
    exit 0
fi
case "\$*" in
    *dig*)  echo 10.0.0.1; exit 0 ;;
    *curl*) exit $2 ;;
    *)      exit 0 ;;
esac
EOF
    chmod +x "$STUB_DIR/docker"
    PATH="$STUB_DIR:$PATH"
}

# bin/claude-sandbox is where an approval finally becomes a grant (a firewall
# entry, an installed package), and nothing else in this suite exercises that
# translation - the checks on it are greps over its source, which a deleted
# line can satisfy just as well as a working one. These two helpers run the
# real launcher against a stub `docker` and a throwaway $HOME, and capture the
# environment it would have handed the container. Split in two because bats'
# `run` executes in a subshell: everything the assertions need to see has to
# be set up out here first.
launch_setup() {
    LAUNCH_DIR="$(mktemp -d)"
    LAUNCH_ENV="$LAUNCH_DIR/run-env"
    mkdir -p "$LAUNCH_DIR/home/.claude"
    echo '{}' > "$LAUNCH_DIR/home/.claude/settings.json"
    cat > "$LAUNCH_DIR/docker" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    [ "$arg" = run ] || continue
    env > "$SANDBOX_TEST_RUN_ENV"
    break
done
exit 0
EOF
    chmod +x "$LAUNCH_DIR/docker"
    : > "$LAUNCH_DIR/sandbox-key"
    chmod 600 "$LAUNCH_DIR/sandbox-key"
}

launch() {
    HOME="$LAUNCH_DIR/home" PATH="$LAUNCH_DIR:$PATH" \
        SANDBOX_TEST_RUN_ENV="$LAUNCH_ENV" \
        SANDBOX_CREDENTIAL_PROXY=0 \
        SANDBOX_SSH_KEY="$LAUNCH_DIR/sandbox-key" \
        SSH_AUTH_SOCK= ALLOWED_DOMAINS= \
        "$REPO_ROOT/bin/claude-sandbox" "$@"
}

launched_env() { sed -n "s/^$1=//p" "$LAUNCH_ENV"; }

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
    for spec in 'libpq-dev' 'gem:rails' 'apt:' 'apt:a;b' 'apt:$(id)' 'npm:a b' \
        'apt:--allow-unauthenticated' 'npm:--force' 'pip:-r' 'cargo:--offline' 'apt:-'; do
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

@test "ensure_global_store creates config_root and prints it" {
    run bash -c 'source "$1"; ensure_global_store' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "$CONFIG_DIR" ]
    [ -d "$CONFIG_DIR" ]
}

@test "ensure_global_store is idempotent and does not disturb an existing project store" {
    bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ" >/dev/null
    run bash -c 'source "$1"; ensure_global_store' _ "$LIB"
    [ "$status" -eq 0 ]
    run bash -c 'source "$1"; ensure_global_store' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "$CONFIG_DIR" ]
    [ "$(cat "$(store_of "$PROJ")/path")" = "$PROJ" ]
}

@test "approve_entry on the global store round-trips through approved_entries on config_root" {
    bash -c 'source "$1"; approve_entry "$(ensure_global_store)" allowed-domains example.com' _ "$LIB"
    run bash -c 'source "$1"; approved_entries "$(config_root)" allowed-domains' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "example.com" ]
}

@test "the global store and a project store hold independent entries" {
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    bash -c 'source "$1"; approve_entry "$(ensure_global_store)" allowed-domains global.example' _ "$LIB"
    bash -c 'source "$1"; approve_entry "$2" allowed-domains project.example' _ "$LIB" "$store"

    run bash -c 'source "$1"; approved_entries "$(config_root)" allowed-domains' _ "$LIB"
    [ "$output" = "global.example" ]
    run bash -c 'source "$1"; approved_entries "$2" allowed-domains' _ "$LIB" "$store"
    [ "$output" = "project.example" ]
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

@test "approving from inside a worktree writes to the project's store, not a shadowing one" {
    # Readers walk ancestors, writers used to create a store at the exact
    # path - so the first approval made from inside a worktree created one
    # that shadowed the project's for every later read, silently un-applying
    # everything the worktree had been inheriting. Both writers, since they
    # share ensure_project_store.
    local parent wt
    parent="$CONFIG_DIR/projects/$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    wt="$PROJ/.worktrees/feat"
    "$REPO_ROOT/bin/claude-sandbox-dep" add apt:parentpkg --project "$PROJ" >/dev/null
    mkdir -p "$wt"

    run "$REPO_ROOT/bin/claude-sandbox-dep" add apt:branchpkg --project "$wt"
    [ "$status" -eq 0 ]
    run env CLAUDE_SANDBOX_ALLOW_SKIP_SESSION=1 \
        "$REPO_ROOT/bin/claude-sandbox-allow" branch.example --project "$wt"
    [ "$status" -eq 0 ]

    [ ! -d "$CONFIG_DIR/projects/$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$wt")" ]
    grep -qx 'apt:branchpkg' "$parent/dependencies"
    grep -qx 'branch.example' "$parent/allowed-domains"
    # and the inherited approval is still in force from the worktree
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --project "$wt"
    [[ "$output" == *"apt:parentpkg"* ]]
}

@test "ensure_project_store heals a store that has no slug-collision guard" {
    # An interrupted write or a hand-restored directory leaves projects/<slug>/
    # with no path file, and that file is the only thing resolve_project_store
    # checks to catch two projects sanitizing to the same slug. Attaching to
    # such a store without healing it leaves it unguarded permanently.
    mkdir -p "$(store_of "$PROJ")"
    run bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ"
    [ "$status" -eq 0 ]
    grep -qx "$PROJ" "$(store_of "$PROJ")/path"
}

@test "healing an unguarded store records the owner, not the path being approved" {
    # The store found for a worktree belongs to the project above it. Writing
    # the worktree's own path into it would make every later read from the
    # real owner look like a slug collision and fail.
    local wt="$PROJ/.worktrees/feat"
    mkdir -p "$(store_of "$PROJ")" "$wt"
    run bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$wt"
    [ "$status" -eq 0 ]
    grep -qx "$PROJ" "$(store_of "$PROJ")/path"
    run bash -c 'source "$1"; resolve_project_store "$2"' _ "$LIB" "$PROJ"
    [ "$status" -eq 0 ]
    [ "$output" = "$(store_of "$PROJ")" ]
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

@test "claude-sandbox-dep add --global writes the global store, not a project entry" {
    run "$REPO_ROOT/bin/claude-sandbox-dep" add cargo:cargo-nextest --global
    [ "$status" -eq 0 ]
    grep -qx 'cargo:cargo-nextest' "$CONFIG_DIR/dependencies"
    [ ! -d "$CONFIG_DIR/projects" ]
}

@test "claude-sandbox-dep list --global shows global deps, plain list in an unrelated project does not" {
    "$REPO_ROOT/bin/claude-sandbox-dep" add cargo:cargo-nextest --global >/dev/null
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --global
    [[ "$output" == *"cargo:cargo-nextest"* ]]
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --project "$PROJ"
    [[ "$output" != *"cargo:cargo-nextest"* ]]
}

@test "claude-sandbox-dep remove --global removes a globally approved spec" {
    "$REPO_ROOT/bin/claude-sandbox-dep" add cargo:cargo-nextest --global >/dev/null
    run "$REPO_ROOT/bin/claude-sandbox-dep" remove cargo:cargo-nextest --global
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/claude-sandbox-dep" list --global
    [[ "$output" != *"cargo:cargo-nextest"* ]]
}

@test "claude-sandbox-dep rejects --global combined with --project and writes nothing" {
    run "$REPO_ROOT/bin/claude-sandbox-dep" add apt:foo --global --project /tmp/x
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
    [ ! -f "$CONFIG_DIR/dependencies" ]
    [ ! -d "$CONFIG_DIR/projects" ]
}

@test "claude-sandbox-dep add --global rejects an invalid spec before writing anything" {
    run "$REPO_ROOT/bin/claude-sandbox-dep" add 'apt:a;b' --global
    [ "$status" -ne 0 ]
    [ ! -f "$CONFIG_DIR/dependencies" ]
}

@test "claude-sandbox-allow --project persists without needing a container" {
    run env CLAUDE_SANDBOX_ALLOW_SKIP_SESSION=1 \
        "$REPO_ROOT/bin/claude-sandbox-allow" crates.io --project "$PROJ"
    [ "$status" -eq 0 ]
    store="$CONFIG_DIR/projects/$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    grep -qx 'crates.io' "$store/allowed-domains"
}

@test "claude-sandbox-allow --project records the approval with no sandbox running" {
    # The documented moment to approve is right after leaving the sandbox -
    # dependency approvals need a relaunch - so requiring a live container
    # broke the main path: the domain was never persisted at all.
    stub_docker 0 0
    run "$REPO_ROOT/bin/claude-sandbox-allow" crates.io --project "$PROJ"
    [ "$status" -eq 0 ]
    grep -qx 'crates.io' "$(store_of "$PROJ")/allowed-domains"
}

@test "claude-sandbox-allow --project records a domain the reachability probe rejects" {
    # A declared host may legitimately not answer on 443 - an internal
    # service, an SSH-only host, an apex that only serves a subdomain. The
    # probe's verdict is worth reporting, but it is not the user's approval
    # decision, and it used to discard it.
    stub_docker 1 7
    run "$REPO_ROOT/bin/claude-sandbox-allow" crates.io --project "$PROJ"
    [ "$status" -eq 2 ]
    [[ "$output" == *"still NOT reachable"* ]]
    grep -qx 'crates.io' "$(store_of "$PROJ")/allowed-domains"
}

@test "--global stays gated on the reachability probe even though --project no longer is" {
    # Run from a copy so the real config/env is never touched: env_file is
    # resolved relative to the script's own realpath.
    local fake; fake="$(mktemp -d)"
    mkdir -p "$fake/bin" "$fake/config"
    cp "$REPO_ROOT/bin/claude-sandbox-allow" "$REPO_ROOT/bin/claude-sandbox-project-lib.sh" "$fake/bin/"
    chmod +x "$fake/bin/claude-sandbox-allow"
    printf 'export ALLOWED_DOMAINS=""\n' > "$fake/config/env"
    stub_docker 1 7
    run "$fake/bin/claude-sandbox-allow" crates.io --global --project "$PROJ"
    [ "$status" -eq 2 ]
    # one run must not add a demonstrably broken domain to every project...
    grep -qx 'export ALLOWED_DOMAINS=""' "$fake/config/env"
    # ...but the project the user explicitly named is their decision to make
    grep -qx 'crates.io' "$(store_of "$PROJ")/allowed-domains"
    rm -rf "$fake"
}

@test "claude-sandbox-project approve persists every domain when one fails to apply" {
    # Under set -e the first claude-sandbox-allow to exit nonzero used to
    # abort the loop, silently skipping every domain after it - and, before
    # persistence moved ahead of the container work, persisting none at all.
    printf 'apt:libpq-dev\n' > "$PROJ/.claude-sandbox/dependencies"
    printf 'crates.io\nstatic.crates.io\n' > "$PROJ/.claude-sandbox/allowed-domains"
    stub_docker 1 7
    run bash -c 'echo y | "$1" approve "$2"' _ "$REPO_ROOT/bin/claude-sandbox-project" "$PROJ"
    [ "$status" -eq 0 ]
    grep -qx 'crates.io' "$(store_of "$PROJ")/allowed-domains"
    grep -qx 'static.crates.io' "$(store_of "$PROJ")/allowed-domains"
    grep -qx 'apt:libpq-dev' "$(store_of "$PROJ")/dependencies"
    [[ "$output" == *"not applied to a running session"* ]]
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

@test "generate_derived_dockerfile emits one layer per ecosystem and re-asserts privilege" {
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    printf 'apt:libpq-dev\nnpm:typescript\npip:ruff\n' > "$store/dependencies"
    run bash -c 'source "$1"; generate_derived_dockerfile base:tag "$2"' _ "$LIB" "$store"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FROM base:tag"* ]]
    [[ "$output" == *"apt-get install -y --no-install-recommends libpq-dev"* ]]
    [[ "$output" == *"npm install -g typescript"* ]]
    [[ "$output" == *"pip install --break-system-packages ruff"* ]]
    # the last privilege-relevant lines must restore the base posture
    [[ "$(grep -E '^(USER|ENTRYPOINT)' <<< "$output" | tail -2)" == "USER root
ENTRYPOINT [\"/usr/local/bin/entrypoint.sh\"]" ]]
}

@test "generate_derived_dockerfile installs rustup only when a cargo spec is present" {
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    printf 'apt:libpq-dev\n' > "$store/dependencies"
    run bash -c 'source "$1"; generate_derived_dockerfile base:tag "$2"' _ "$LIB" "$store"
    [[ "$output" != *"rustup"* ]]
    printf 'cargo:cargo-nextest\n' > "$store/dependencies"
    run bash -c 'source "$1"; generate_derived_dockerfile base:tag "$2"' _ "$LIB" "$store"
    [[ "$output" == *"rustup"* ]]
    [[ "$output" == *"cargo install cargo-nextest"* ]]
    [[ "$output" == *".cargo/bin"* ]]
}

@test "generate_derived_dockerfile refuses a corrupt approved deps file without emitting a partial Dockerfile" {
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    # A valid line FOLLOWED by a corrupt one - the security property is "never
    # emit a partial Dockerfile," which a single-line corrupt file can't tell
    # apart from "refused before emitting anything at all."
    printf 'apt:libpq-dev\napt:evil; curl x\n' > "$store/dependencies"
    run bash -c 'source "$1"; generate_derived_dockerfile base:tag "$2" 2>/dev/null' _ "$LIB" "$store"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "the launcher passes approved project domains to the container, and declared ones never" {
    printf 'declared.example.com\n' > "$PROJ/.claude-sandbox/allowed-domains"
    "$REPO_ROOT/bin/claude-sandbox-dep" add apt:libpq-dev --project "$PROJ" >/dev/null
    printf 'approved.example.com\n' > "$(store_of "$PROJ")/allowed-domains"
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [ -f "$LAUNCH_ENV" ]
    [[ " $(launched_env ALLOWED_DOMAINS) " == *" approved.example.com "* ]]
    [[ " $(launched_env ALLOWED_DOMAINS) " != *" declared.example.com "* ]]
}

@test "the launcher runs the derived image only when the project has approved dependencies" {
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [ "$(launched_env SANDBOX_IMAGE)" = "claude-sandbox:$(id -un)" ]

    "$REPO_ROOT/bin/claude-sandbox-dep" add apt:libpq-dev --project "$PROJ" >/dev/null
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    slug="$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    [ "$(launched_env SANDBOX_IMAGE)" = "claude-sandbox:$(id -un)-$slug" ]
}

@test "the launcher warns when the approval store sits inside the mounted workspace" {
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" != *"no longer out of reach"* ]]

    # Same project, but with the store somewhere the session can rewrite it.
    export CLAUDE_SANDBOX_CONFIG_DIR="$PROJ/.config/claude-sandbox"
    "$REPO_ROOT/bin/claude-sandbox-dep" add apt:libpq-dev --project "$PROJ" >/dev/null
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no longer out of reach"* ]]
}
