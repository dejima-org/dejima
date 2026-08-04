#!/usr/bin/env bats
# Host-side (no Docker): per-project declaration parsing, the approval store,
# and the three CLIs that manage it. Declarations are untrusted input - these
# tests are what keep them from ever becoming code or an unapproved grant.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/bin/dejima-project-lib.sh"
    CONFIG_DIR="$(mktemp -d)"
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR"
    PROJ="$(mktemp -d)"
    mkdir -p "$PROJ/.dejima"
}
teardown() { rm -rf "$CONFIG_DIR" "$PROJ" ${STUB_DIR:+"$STUB_DIR"} ${LAUNCH_DIR:+"$LAUNCH_DIR"}; }

store_of() {
    printf '%s/projects/%s' "$CONFIG_DIR" \
        "$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$1")"
}

# A fake `docker` on PATH, so the container-facing half of
# dejima-allow can be exercised without a daemon. $1 is how many
# running sandboxes to report, $2 the exit status the in-container curl
# reachability check should return.
stub_docker() {
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<EOF
#!/bin/bash
if [ "\$1" = ps ]; then
    [ "$1" -eq 0 ] || echo dejima-test-container
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

# bin/dejima is where an approval finally becomes a grant (a firewall
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
echo "$*" >> "${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
# For a real `docker build` (never `docker compose ... build`, whose $1 is
# "compose"), also log the generated Dockerfile's own content, tagged by -t -
# argv alone can't tell whether the Dockerfile's FROM line actually points at
# the previous layer.
if [ "$1" = build ] && [ -n "${SANDBOX_TEST_DOCKERFILE_LOG:-}" ]; then
    tag="" dockerfile=""
    args=("$@")
    for i in "${!args[@]}"; do
        case "${args[$i]}" in
            -t) tag="${args[$((i + 1))]}" ;;
            -f) dockerfile="${args[$((i + 1))]}" ;;
        esac
    done
    { echo "=== $tag ==="; cat "$dockerfile"; } >> "$SANDBOX_TEST_DOCKERFILE_LOG"
fi
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

# ssh_key is written into whatever config file config_root() currently
# resolves to (DEJIMA_CONFIG_DIR, which a few tests point elsewhere) rather
# than always $CONFIG_DIR/config, and appended rather than written, so it
# layers over anything a test already put there (e.g. approved dependencies)
# instead of clobbering it.
launch() {
    local conf
    conf="$(bash -c 'source "$1"; config_path' _ "$LIB")"
    mkdir -p "$(dirname "$conf")"
    printf '[core]\nssh_key = %s\n' "$LAUNCH_DIR/sandbox-key" >> "$conf"
    HOME="$LAUNCH_DIR/home" PATH="$LAUNCH_DIR:$PATH" \
        SANDBOX_TEST_RUN_ENV="$LAUNCH_ENV" \
        SANDBOX_TEST_DOCKER_LOG="$LAUNCH_DIR/docker-log" \
        SANDBOX_TEST_DOCKERFILE_LOG="$LAUNCH_DIR/dockerfile-log" \
        SSH_AUTH_SOCK= ALLOWED_DOMAINS= \
        "$REPO_ROOT/bin/dejima" "$@"
}

launched_env() { sed -n "s/^$1=//p" "$LAUNCH_ENV"; }
docker_log() { cat "$LAUNCH_DIR/docker-log" 2>/dev/null; }
# Prints just the lines generate_derived_dockerfile wrote for the build
# tagged $1, so callers can assert its FROM line without the other layer's
# Dockerfile (also in the same log) satisfying a plain grep.
dockerfile_for() {
    awk -v want="=== $1 ===" '$0 == want { on=1; next } /^=== / { on=0 } on' \
        "$LAUNCH_DIR/dockerfile-log" 2>/dev/null
}

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
    cat > "$PROJ/.dejima/dependencies" <<'EOF'
# project deps
apt:libpq-dev

cargo:cargo-nextest
gem:rails
EOF
    run bash -c 'source "$1"; read_declared "$2" valid_dep_spec' _ "$LIB" "$PROJ/.dejima/dependencies"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok apt:libpq-dev"* ]]
    [[ "$output" == *"ok cargo:cargo-nextest"* ]]
    [[ "$output" == *"rejected gem:rails"* ]]
    [[ "$output" != *"ok gem:rails"* ]]
    [[ "$output" != *"# project deps"* ]]
}

@test "read_declared prints nothing for a missing file" {
    run bash -c 'source "$1"; read_declared "$2" valid_dep_spec' _ "$LIB" "$PROJ/.dejima/nope"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "read_declared caps at 200 entries and says so" {
    for i in $(seq 1 250); do echo "apt:pkg$i"; done > "$PROJ/.dejima/dependencies"
    run bash -c 'source "$1"; read_declared "$2" valid_dep_spec' _ "$LIB" "$PROJ/.dejima/dependencies"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^ok ' <<< "$output")" -eq 200 ]
    [[ "$output" == *"truncated 250"* ]]
    [[ "$output" != *"apt:pkg201"* ]]
}

@test "project_slug matches the log-shipper project-key rule" {
    run bash -c 'source "$1"; project_slug "/home/someone/my-proj"' _ "$LIB"
    [ "$output" = "-home-someone-my-proj" ]
}

@test "ensure_project_store creates the store and records the real path" {
    run bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ"
    [ "$status" -eq 0 ]
    [ -d "$output" ]
    [ "$(cat "$output/path")" = "$PROJ" ]
}

@test "ensure_global_store creates config_root and prints it" {
    # setup()'s mktemp -d would make the [ -d ] below true whether or not
    # ensure_global_store created anything, so start from a config_root that
    # does not exist - which is the state of every host before its first
    # global approval.
    rm -rf "$CONFIG_DIR"
    run bash -c 'source "$1"; ensure_global_store' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "$CONFIG_DIR" ]
    [ -d "$CONFIG_DIR" ]
}

@test "the first global approval on a host with no config_root succeeds and creates it" {
    # The project scope creates config_root as a side effect of mkdir -p on
    # projects/<slug>; only the global scope depends on ensure_global_store
    # for it. Without that mkdir this is the one command that fails, and it
    # fails on the first --global anyone ever runs.
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR/fresh/dejima"
    [ ! -d "$DEJIMA_CONFIG_DIR" ]
    run "$REPO_ROOT/bin/dejima-dep" add --global cargo:cargo-nextest
    [ "$status" -eq 0 ]
    [ -d "$DEJIMA_CONFIG_DIR" ]
    grep -qx 'cargo:cargo-nextest' "$DEJIMA_CONFIG_DIR/dependencies"
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
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:parentpkg >/dev/null
    mkdir -p "$wt"

    run "$REPO_ROOT/bin/dejima-dep" add --project "$wt" apt:branchpkg
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/dejima-allow" --project "$wt" branch.example
    [ "$status" -eq 0 ]

    [ ! -d "$CONFIG_DIR/projects/$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$wt")" ]
    grep -qx 'apt:branchpkg' "$parent/dependencies"
    grep -qx 'branch.example' "$parent/allowed-domains"
    # and the inherited approval is still in force from the worktree
    run "$REPO_ROOT/bin/dejima-dep" list --project "$wt"
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

@test "dejima-dep add approves a spec and list shows it" {
    run "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:libpq-dev
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"apt:libpq-dev"* ]]
}

@test "dejima-dep add says the change needs a relaunch" {
    run "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:libpq-dev
    [ "$status" -eq 0 ]
    [[ "$output" == *"next launch"* ]]
}

@test "dejima-dep rejects a malformed spec without writing anything" {
    run "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" 'apt:a;b'
    [ "$status" -ne 0 ]
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
    [[ "$output" != *"a;b"* ]]
}

@test "dejima-dep remove takes a spec back out" {
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" npm:typescript >/dev/null
    run "$REPO_ROOT/bin/dejima-dep" remove --project "$PROJ" npm:typescript
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
    [[ "$output" != *"npm:typescript"* ]]
}

@test "dejima-dep add --global writes the global store, not a project entry" {
    run "$REPO_ROOT/bin/dejima-dep" add --global cargo:cargo-nextest
    [ "$status" -eq 0 ]
    grep -qx 'cargo:cargo-nextest' "$CONFIG_DIR/dependencies"
    [ ! -d "$CONFIG_DIR/projects" ]
}

@test "dejima-dep list --global shows global deps, plain list in an unrelated project does not" {
    "$REPO_ROOT/bin/dejima-dep" add --global cargo:cargo-nextest >/dev/null
    run "$REPO_ROOT/bin/dejima-dep" list --global
    [[ "$output" == *"cargo:cargo-nextest"* ]]
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
    [[ "$output" != *"cargo:cargo-nextest"* ]]
}

@test "dejima-dep remove --global removes a globally approved spec" {
    "$REPO_ROOT/bin/dejima-dep" add --global cargo:cargo-nextest >/dev/null
    run "$REPO_ROOT/bin/dejima-dep" remove --global cargo:cargo-nextest
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/dejima-dep" list --global
    [[ "$output" != *"cargo:cargo-nextest"* ]]
}

@test "dejima-dep remove fails the same way in both scopes when no store exists" {
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR/fresh/dejima"
    run "$REPO_ROOT/bin/dejima-dep" remove --global cargo:cargo-nextest
    [ "$status" -eq 1 ]
    [[ "$output" != *"Removed"* ]]
    run "$REPO_ROOT/bin/dejima-dep" remove --project "$PROJ" cargo:cargo-nextest
    [ "$status" -eq 1 ]
    [[ "$output" != *"Removed"* ]]
}

@test "dejima-dep rejects --global combined with --project and writes nothing" {
    run "$REPO_ROOT/bin/dejima-dep" add --global --project /tmp/x apt:foo
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
    [ ! -f "$CONFIG_DIR/dependencies" ]
    [ ! -d "$CONFIG_DIR/projects" ]
}

@test "dejima-dep rejects --global combined with --project and no path" {
    # The form that discriminates: with an explicit path, dj_project is
    # non-empty and a check keyed on emptiness would still refuse it. With no
    # path, only dj_project_set can tell "--project meaning cwd" from
    # "--project absent" - so this is the case that catches the regression.
    run "$REPO_ROOT/bin/dejima-dep" add --global --project apt:foo
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
}

@test "dejima-dep add --global rejects an invalid spec before writing anything" {
    run "$REPO_ROOT/bin/dejima-dep" add --global 'apt:a;b'
    [ "$status" -ne 0 ]
    [ ! -f "$CONFIG_DIR/dependencies" ]
}

@test "dejima-allow --project persists without needing a container" {
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" crates.io
    [ "$status" -eq 0 ]
    store="$CONFIG_DIR/projects/$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    grep -qx 'crates.io' "$store/allowed-domains"
}

@test "dejima-allow --project records the approval with no sandbox running" {
    # The documented moment to approve is right after leaving the sandbox -
    # dependency approvals need a relaunch - so requiring a live container
    # broke the main path: the domain was never persisted at all.
    stub_docker 0 0
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" crates.io
    [ "$status" -eq 0 ]
    grep -qx 'crates.io' "$(store_of "$PROJ")/allowed-domains"
}

@test "dejima-allow --project --container records a domain the reachability probe rejects" {
    # A declared host may legitimately not answer on 443 - an internal
    # service, an SSH-only host, an apex that only serves a subdomain. The
    # probe's verdict is worth reporting, but it is not the user's approval
    # decision, and it used to discard it. --container is required to reach
    # the probe at all here, since --project alone never goes near docker.
    stub_docker 1 7
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" --container c1 crates.io
    [ "$status" -eq 2 ]
    [[ "$output" == *"still NOT reachable"* ]]
    grep -qx 'crates.io' "$(store_of "$PROJ")/allowed-domains"
}

@test "dejima-allow --global persists without needing a container" {
    run "$REPO_ROOT/bin/dejima-allow" --global example.com
    [ "$status" -eq 0 ]
    grep -qx 'example.com' "$CONFIG_DIR/allowed-domains"
    [ ! -d "$CONFIG_DIR/projects" ]
}

@test "dejima-allow --global records the approval with no sandbox running" {
    # --global used to require a live container to exit 0 at all. It no
    # longer does, deliberately: --global never goes near docker without an
    # explicit --container, so this passes with no docker on PATH at all,
    # not merely with a stub reporting zero running containers.
    run "$REPO_ROOT/bin/dejima-allow" --global example.com
    [ "$status" -eq 0 ]
    grep -qx 'example.com' "$CONFIG_DIR/allowed-domains"
}

@test "dejima-allow --global and --project together persist to both stores" {
    run "$REPO_ROOT/bin/dejima-allow" --global --project "$PROJ" example.com
    [ "$status" -eq 0 ]
    grep -qx 'example.com' "$CONFIG_DIR/allowed-domains"
    grep -qx 'example.com' "$(store_of "$PROJ")/allowed-domains"
}

@test "dejima-allow rejects an invalid domain before persisting to either store" {
    run "$REPO_ROOT/bin/dejima-allow" --global --project "$PROJ" 'evil.com; curl x'
    [ "$status" -ne 0 ]
    [ ! -f "$CONFIG_DIR/allowed-domains" ]
    [ ! -d "$CONFIG_DIR/projects" ]
}

@test "dejima-allow --global --container records a domain the reachability probe rejects" {
    # --global used to be gated on this probe, refusing any global approval
    # for a host that legitimately doesn't answer on 443 (an SSH-only host,
    # an internal service). It now persists exactly like --project: the
    # probe's verdict is worth reporting, but it is not the approval decision.
    # --container is required to reach the probe at all here, since --global
    # alone never goes near docker.
    stub_docker 1 7
    run "$REPO_ROOT/bin/dejima-allow" --global --container c1 crates.io
    [ "$status" -eq 2 ]
    [[ "$output" == *"still NOT reachable"* ]]
    grep -qx 'crates.io' "$CONFIG_DIR/allowed-domains"
}

@test "dejima-project approve persists every domain even when a docker call would have failed" {
    # Under set -e the first dejima-allow to exit nonzero used to abort the
    # loop, silently skipping every domain after it. dejima-project's internal
    # call uses --project alone, with no --container, so it no longer goes
    # near docker at all (issue #61) - a docker stub that fails loudly if
    # called proves that directly, rather than relying on a reachability
    # failure to exercise the old abort-the-loop path.
    printf 'apt:libpq-dev\n' > "$PROJ/.dejima/dependencies"
    printf 'crates.io\nstatic.crates.io\n' > "$PROJ/.dejima/allowed-domains"
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
echo "docker was called: $*" >&2
exit 97
EOF
    chmod +x "$STUB_DIR/docker"
    run env PATH="$STUB_DIR:$PATH" \
        bash -c 'echo y | "$1" approve "$2"' _ "$REPO_ROOT/bin/dejima-project" "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" != *"docker was called"* ]]
    grep -qx 'crates.io' "$(store_of "$PROJ")/allowed-domains"
    grep -qx 'static.crates.io' "$(store_of "$PROJ")/allowed-domains"
    grep -qx 'apt:libpq-dev' "$(store_of "$PROJ")/dependencies"
}

@test "dejima-project approve attempts every domain even when persisting one fails" {
    # The set -e loop-abort guard above (the `|| unapplied=...` collector) has
    # no cover left once nothing in the loop can fail via docker - dejima-allow
    # --project can still exit nonzero with no docker involved at all: an
    # unwritable store, a slug collision, a corrupt approval file. An
    # unwritable store induces that here. Without the collector, set -e would
    # abort on the first domain and static.crates.io would never be attempted
    # at all - so both must show up in the failure report, not just the first.
    printf 'crates.io\nstatic.crates.io\n' > "$PROJ/.dejima/allowed-domains"
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    chmod 500 "$store"
    run bash -c 'echo y | "$1" approve "$2"' _ "$REPO_ROOT/bin/dejima-project" "$PROJ"
    chmod 700 "$store"
    # Both domain names are already in the pre-confirmation listing
    # regardless of what happens after, so the real proof that neither
    # attempt was skipped is two separate failures, not just two mentions.
    [ "$(grep -c 'Permission denied' <<< "$output")" -eq 2 ]
    line="$(grep '^NOT approved' <<< "$output")"
    [[ "$line" == *"crates.io"* ]]
    [[ "$line" == *"static.crates.io"* ]]
}

@test "dejima-allow --project still refuses an invalid domain" {
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" 'evil.com; curl x'
    [ "$status" -ne 0 ]
}

@test "dejima-project status shows declared, approved and rejected" {
    printf 'apt:libpq-dev\ngem:rails\n' > "$PROJ/.dejima/dependencies"
    printf 'static.crates.io\n' > "$PROJ/.dejima/allowed-domains"
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:libpq-dev >/dev/null
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"approved"*"apt:libpq-dev"* ]]
    [[ "$output" == *"rejected"*"gem:rails"* ]]
    [[ "$output" == *"static.crates.io"* ]]
}

@test "dejima-project status shows a dep approved only globally as approved" {
    printf 'apt:libpq-dev\n' > "$PROJ/.dejima/dependencies"
    "$REPO_ROOT/bin/dejima-dep" add --global apt:libpq-dev >/dev/null
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"approved"*"apt:libpq-dev"* ]]
}

@test "dejima-project status shows a dep approved in neither store as pending" {
    printf 'apt:libpq-dev\n' > "$PROJ/.dejima/dependencies"
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pending"*"apt:libpq-dev"* ]]
}

@test "dejima-project status prints the global store path" {
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Global approvals: $CONFIG_DIR"* ]]
}

@test "dejima-project status and approve refuse a corrupt global store rather than treating it as empty" {
    printf 'apt:libpq-dev\n' > "$PROJ/.dejima/dependencies"
    mkdir -p "$CONFIG_DIR"
    echo 'apt:evil; curl x' > "$CONFIG_DIR/dependencies"
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -ne 0 ]
    [[ "$output" != *"approved apt:libpq-dev"* ]]
    [[ "$output" != *"pending apt:libpq-dev"* ]]
    run "$REPO_ROOT/bin/dejima-project" approve "$PROJ" < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" != *"Declared but not approved"* ]]
    [[ "$output" != *"Nothing pending approval"* ]]
}

@test "dejima-project approve reports nothing pending when declared entries are approved globally" {
    printf 'apt:libpq-dev\n' > "$PROJ/.dejima/dependencies"
    printf 'static.crates.io\n' > "$PROJ/.dejima/allowed-domains"
    "$REPO_ROOT/bin/dejima-dep" add --global apt:libpq-dev >/dev/null
    run "$REPO_ROOT/bin/dejima-allow" --global static.crates.io
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/dejima-project" approve "$PROJ" < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing pending approval"* ]]
}

@test "dejima-project approve declines without confirmation" {
    printf 'apt:libpq-dev\n' > "$PROJ/.dejima/dependencies"
    run bash -c 'echo n | "$1" approve "$2"' _ "$REPO_ROOT/bin/dejima-project" "$PROJ"
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
    [[ "$output" != *"apt:libpq-dev"* ]]
}

@test "dejima-project approve approves the declared set on confirmation" {
    printf 'apt:libpq-dev\n' > "$PROJ/.dejima/dependencies"
    printf 'static.crates.io\n' > "$PROJ/.dejima/allowed-domains"
    run bash -c 'echo y | "$1" approve "$2"' \
        _ "$REPO_ROOT/bin/dejima-project" "$PROJ"
    [ "$status" -eq 0 ]
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
    [[ "$output" == *"apt:libpq-dev"* ]]
    store="$CONFIG_DIR/projects/$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    grep -qx 'static.crates.io' "$store/allowed-domains"
}

@test "dejima-project approve never approves a rejected entry" {
    printf 'gem:rails\n' > "$PROJ/.dejima/dependencies"
    run bash -c 'echo y | "$1" approve "$2"' _ "$REPO_ROOT/bin/dejima-project" "$PROJ"
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
    [[ "$output" != *"gem:rails"* ]]
}

@test "dejima-project approve reports a rejected entry's literal text, unsplit and unglobbed" {
    printf 'npm:has space\n' > "$PROJ/.dejima/dependencies"
    printf 'a*evil\n' > "$PROJ/.dejima/allowed-domains"
    run "$REPO_ROOT/bin/dejima-project" approve "$PROJ" < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"npm:has space"* ]]
    [[ "$output" == *"a*evil"* ]]
}

@test "dejima-project approve warns about entries beyond the 200-entry cap" {
    for i in $(seq 1 250); do echo "apt:pkg$i"; done > "$PROJ/.dejima/dependencies"
    run bash -c 'echo n | "$1" approve "$2"' _ "$REPO_ROOT/bin/dejima-project" "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"250"* ]]
}

@test "dejima-project approve exits 0 and approves nothing when stdin is already at EOF" {
    printf 'apt:libpq-dev\n' > "$PROJ/.dejima/dependencies"
    run "$REPO_ROOT/bin/dejima-project" approve "$PROJ" < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing approved."* ]]
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
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
    printf 'declared.example.com\n' > "$PROJ/.dejima/allowed-domains"
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:libpq-dev >/dev/null
    printf 'approved.example.com\n' > "$(store_of "$PROJ")/allowed-domains"
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [ -f "$LAUNCH_ENV" ]
    [[ " $(launched_env ALLOWED_DOMAINS) " == *" approved.example.com "* ]]
    [[ " $(launched_env ALLOWED_DOMAINS) " != *" declared.example.com "* ]]
}

@test "the launcher passes an approved global domain to the container" {
    printf 'global.example.com\n' > "$CONFIG_DIR/allowed-domains"
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [ -f "$LAUNCH_ENV" ]
    [[ " $(launched_env ALLOWED_DOMAINS) " == *" global.example.com "* ]]
}

@test "the launcher merges global and project approved domains, neither replacing the other" {
    printf 'global.example.com\n' > "$CONFIG_DIR/allowed-domains"
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    printf 'project.example.com\n' > "$store/allowed-domains"
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [ -f "$LAUNCH_ENV" ]
    [[ " $(launched_env ALLOWED_DOMAINS) " == *" global.example.com "* ]]
    [[ " $(launched_env ALLOWED_DOMAINS) " == *" project.example.com "* ]]
}

@test "an ALLOWED_DOMAINS exported before invocation is ignored, not merged in" {
    # The approved domain is what keeps this test honest: without it, the
    # absence of evil.example would also be satisfied by the launcher setting
    # no domains at all, or by the env prefix below never reaching the child.
    printf 'good.example.com\n' > "$CONFIG_DIR/allowed-domains"
    launch_setup
    printf '[core]\nssh_key = %s\n' "$LAUNCH_DIR/sandbox-key" >> "$CONFIG_DIR/config"
    HOME="$LAUNCH_DIR/home" PATH="$LAUNCH_DIR:$PATH" \
        SANDBOX_TEST_RUN_ENV="$LAUNCH_ENV" \
        SSH_AUTH_SOCK= ALLOWED_DOMAINS=evil.example \
        run "$REPO_ROOT/bin/dejima" "$PROJ"
    [ "$status" -eq 0 ]
    [ -f "$LAUNCH_ENV" ]
    [[ " $(launched_env ALLOWED_DOMAINS) " == *" good.example.com "* ]]
    [[ " $(launched_env ALLOWED_DOMAINS) " != *"evil.example"* ]]
}

@test "--allow-github-push adds github.com/ssh.github.com to DEJIMA_PUSH_HOSTS" {
    # At bafad17, ALLOW_GITHUB_PUSH itself was what git-push-guard.sh checked.
    # Now the guard only reads DEJIMA_PUSH_HOSTS, so the flag's actual effect
    # has to be widening that list - exporting ALLOW_GITHUB_PUSH alone (which
    # nothing reads anymore) would make the flag a no-op that still opens
    # port 22 in the firewall for nothing. DEJIMA_PUSH_HOSTS reaches the
    # container as a `docker ... -e` argument, not an exported env var of
    # this process, so it's read off the logged argv rather than
    # launched_env (which only sees what's actually exported).
    launch_setup
    run launch --allow-github-push "$PROJ"
    [ "$status" -eq 0 ]
    run_line="$(grep -- ' run --rm ' "$LAUNCH_DIR/docker-log" | tail -1)"
    [ -n "$run_line" ]
    [[ "$run_line" == *"-e DEJIMA_PUSH_HOSTS="*"github.com"* ]]
    [[ "$run_line" == *"ssh.github.com"* ]]
}

@test "without --allow-github-push, DEJIMA_PUSH_HOSTS carries no github hosts" {
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    run_line="$(grep -- ' run --rm ' "$LAUNCH_DIR/docker-log" | tail -1)"
    [ -n "$run_line" ]
    [[ "$run_line" != *"github.com"* ]]
}

@test "the launcher refuses to start when either store's approved domains are corrupt" {
    # A store entry that no longer validates means a bug or tampering, not
    # user error - launching anyway would either drop it silently or write it
    # into a dnsmasq server= line. Both stores are read on the same path, so
    # both are checked here.
    launch_setup
    printf 'evil.example; curl x\n' > "$CONFIG_DIR/allowed-domains"
    run launch "$PROJ"
    [ "$status" -ne 0 ]
    [[ "$output" == *"corrupt approval entry"* ]]
    [ ! -f "$LAUNCH_ENV" ]

    rm -f "$CONFIG_DIR/allowed-domains"
    store=$(bash -c 'source "$1"; ensure_project_store "$2"' _ "$LIB" "$PROJ")
    printf 'evil.example; curl x\n' > "$store/allowed-domains"
    run launch "$PROJ"
    [ "$status" -ne 0 ]
    [[ "$output" == *"corrupt approval entry"* ]]
    [ ! -f "$LAUNCH_ENV" ]
}

@test "the launcher refuses to start on a settings.json that isn't valid JSON" {
    # Claude Code ignores an unparseable settings.json wholesale, with only a
    # startup warning, so the session would come up with no permissions, no
    # hooks and no skipDangerousModePermissionPrompt - a bypass-mode warning
    # and nothing pointing at the settings file. A stray character appended to
    # the real file is exactly how this turned up.
    launch_setup
    printf '{"theme": "dark"}\nx\n' > "$LAUNCH_DIR/home/.claude/settings.json"
    run launch "$PROJ"
    [ "$status" -ne 0 ]
    [[ "$output" == *"settings.json is not valid JSON"* ]]
    [ ! -f "$LAUNCH_ENV" ]

    printf '{"theme": "dark"}\n' > "$LAUNCH_DIR/home/.claude/settings.json"
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [ -f "$LAUNCH_ENV" ]
}

@test "the launcher runs the derived image only when the project has approved dependencies" {
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [ "$(launched_env SANDBOX_IMAGE)" = "dejima:$(id -un)" ]

    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:libpq-dev >/dev/null
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    slug="$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    [ "$(launched_env SANDBOX_IMAGE)" = "dejima:$(id -un)-$slug" ]
}

@test "the launcher builds and runs the global layer when only global deps are approved" {
    "$REPO_ROOT/bin/dejima-dep" add --global apt:libpq-dev >/dev/null
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    grep -q -- "-t dejima:$(id -un)-global -f" <(docker_log)
    [ "$(launched_env SANDBOX_IMAGE)" = "dejima:$(id -un)-global" ]
}

@test "the launcher builds the global layer then the project layer on top of it" {
    "$REPO_ROOT/bin/dejima-dep" add --global apt:libpq-dev >/dev/null
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:libpq-dev >/dev/null
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    slug="$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    global_line=$(grep -n -- "-t dejima:$(id -un)-global -f" <(docker_log) | cut -d: -f1)
    project_line=$(grep -n -- "-t dejima:$(id -un)-$slug -f" <(docker_log) | cut -d: -f1)
    [ -n "$global_line" ]
    [ -n "$project_line" ]
    [ "$global_line" -lt "$project_line" ]
    [ "$(launched_env SANDBOX_IMAGE)" = "dejima:$(id -un)-$slug" ]
}

@test "the project layer's Dockerfile is generated FROM the global layer, not the base image" {
    # The ordering test above only shows the two builds happen in order - it
    # can't tell whether the second one's Dockerfile actually names the first
    # one as its base, versus both independently FROM-ing the base image
    # (which would silently drop the global packages from every project that
    # also has its own deps).
    "$REPO_ROOT/bin/dejima-dep" add --global apt:libpq-dev >/dev/null
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:libpq-dev >/dev/null
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    slug="$(bash -c 'source "$1"; project_slug "$2"' _ "$LIB" "$PROJ")"
    dockerfile_for "dejima:$(id -un)-global" | grep -qxF "FROM dejima:$(id -un)"
    dockerfile_for "dejima:$(id -un)-$slug" | grep -qxF "FROM dejima:$(id -un)-global"
}

@test "the launcher builds no dependency layer when neither global nor project deps are approved" {
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    run grep -- "-t dejima:" <(docker_log)
    [ "$status" -ne 0 ]
    [ "$(launched_env SANDBOX_IMAGE)" = "dejima:$(id -un)" ]
}

@test "the launcher warns when the approval store sits inside the mounted workspace" {
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" != *"writable from inside the sandbox"* ]]

    # Same project, but with the store somewhere the session can rewrite it.
    export DEJIMA_CONFIG_DIR="$PROJ/.config/dejima"
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:libpq-dev >/dev/null
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"the approval store"* ]]
    [[ "$output" == *"approve its own domains and dependencies"* ]]
}

@test "the launcher warns when the audit report or baseline store sits inside the mounted workspace" {
    launch_setup
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" != *"writable from inside the sandbox"* ]]

    printf '[audit]\ndir = %s\n' "$PROJ/.audit" >> "$CONFIG_DIR/config"
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"the audit report store"* ]]
    [[ "$output" == *"delete the exit-time reports of earlier runs"* ]]
    # Right alarm, right consequence: these three stores used to share the
    # approval store's text verbatim, so the audit store described a hazard
    # that was not the one it has.
    [[ "$output" != *"the approval store"* ]]

    printf '[audit]\nbaselines_dir = %s\n' "$PROJ/.baselines" >> "$CONFIG_DIR/config"
    run launch "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"the audit baseline store"* ]]
    [[ "$output" == *"write its own acknowledgements"* ]]
}

# --- issue #61: the optional-path rule for --project ---

# Runs parse_scope_args in a subshell and prints its results one per line, so a
# test can assert on each independently. Everything after $1 is passed to the
# parser verbatim.
parse() {
    local required="$1"; shift
    bash -c '
        source "$1"; required="$2"; shift 2
        parse_scope_args "$required" "$@" || exit $?
        printf "global=%s\n" "$dj_global"
        printf "project=%s\n" "$dj_project"
        printf "project_set=%s\n" "$dj_project_set"
        printf "container=%s\n" "$dj_container"
        printf "positional=%s\n" "${dj_positional[*]-}"
    ' _ "$LIB" "$required" "$@"
}

@test "--project with only the required positional after it means the current directory" {
    run parse 1 --project example.com
    [ "$status" -eq 0 ]
    # An empty project= line, i.e. the parser left the path unset for the
    # caller to default to $PWD. Written as the exact "project=" + newline
    # because a bare *"project="* substring match would hold for any value.
    [[ "$output" == *"project="$'\n'* ]]
    [[ "$output" == *"project_set=1"* ]]
    [[ "$output" == *"positional=example.com"* ]]
}

@test "--project takes a path when a positional still follows it" {
    run parse 1 --project /tmp/myproj example.com
    [ "$status" -eq 0 ]
    [[ "$output" == *"project=/tmp/myproj"* ]]
    [[ "$output" == *"positional=example.com"* ]]
}

@test "a forgotten positional is not silently swallowed as the project path" {
    # The failure this rule has to degrade safely for: the caller meant to name
    # a domain and named only a path. It must reach the domain validator (which
    # rejects it) rather than quietly becoming the scope.
    run parse 1 --project /tmp/myproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"positional=/tmp/myproj"* ]]
    [[ "$output" == *"project="$'\n'* ]] || [[ "$output" != *"project=/tmp/myproj"* ]]
}

@test "--project takes a path for a command that requires no trailing positional" {
    # `dejima-dep list --project ~/p` has nothing after the path to protect, so
    # the naive "never consume the last token" rule would send this to the
    # current directory instead. Required-count-aware is why it does not.
    run parse 0 --project /tmp/myproj
    [ "$status" -eq 0 ]
    [[ "$output" == *"project=/tmp/myproj"* ]]
    [[ "$output" == *"positional="$'\n'* ]] || [[ "$output" != *"positional=/tmp"* ]]
}

@test "--project with nothing after it at all means the current directory" {
    run parse 0 --project
    [ "$status" -eq 0 ]
    [[ "$output" == *"project_set=1"* ]]
    [[ "$output" != *"project=/"* ]]
}

@test "--container's value is never mistaken for the project path or a positional" {
    run parse 1 --project --container abc123 example.com
    [ "$status" -eq 0 ]
    [[ "$output" == *"container=abc123"* ]]
    [[ "$output" == *"positional=example.com"* ]]
    [[ "$output" != *"project=abc123"* ]]
}

@test "--container's value is counted correctly when deciding the project path" {
    # The lookahead must skip --container's value, or it would count it as a
    # positional and consume /tmp/myproj's successor by mistake.
    run parse 1 --project /tmp/myproj --container abc123 example.com
    [ "$status" -eq 0 ]
    [[ "$output" == *"project=/tmp/myproj"* ]]
    [[ "$output" == *"container=abc123"* ]]
    [[ "$output" == *"positional=example.com"* ]]
}

@test "the old argument order is rejected rather than reinterpreted" {
    run parse 1 example.com --global
    [ "$status" -eq 0 ]
    [[ "$output" == *"global=1"* ]]
    [[ "$output" == *"positional=example.com"* ]]
}

@test "an unknown option is refused" {
    run parse 1 --nope example.com
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "--container without a value is refused" {
    run parse 1 --container
    [ "$status" -ne 0 ]
    [[ "$output" == *"--container"* ]]
}

@test "multiple positionals are preserved in order" {
    run parse 1 add cargo:nextest
    [ "$status" -eq 0 ]
    [[ "$output" == *"positional=add cargo:nextest"* ]]
}

@test "dejima-allow --project never consults docker" {
    # The complaint in the issue: a project-level invocation talked about
    # running containers. With a `docker` stub that would fail loudly if
    # called, a --project run must still succeed - proving it never went near
    # one, rather than relying on an env var to hide the evidence.
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
echo "docker was called: $*" >&2
exit 97
EOF
    chmod +x "$STUB_DIR/docker"
    run env PATH="$STUB_DIR:$PATH" \
        "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" crates.io
    [ "$status" -eq 0 ]
    [[ "$output" != *"docker was called"* ]]
    [[ "$output" != *"No running dejima container"* ]]
    grep -qx 'crates.io' "$(store_of "$PROJ")/allowed-domains"
}

@test "dejima-allow --global never consults docker" {
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
echo "docker was called: $*" >&2
exit 97
EOF
    chmod +x "$STUB_DIR/docker"
    run env PATH="$STUB_DIR:$PATH" \
        "$REPO_ROOT/bin/dejima-allow" --global crates.io
    [ "$status" -eq 0 ]
    [[ "$output" != *"docker was called"* ]]
    grep -qx 'crates.io' "$CONFIG_DIR/allowed-domains"
}

@test "dejima-allow --project --container does both" {
    stub_docker 1 0
    run env PATH="$STUB_DIR:$PATH" \
        "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" --container c1 crates.io
    [ "$status" -eq 0 ]
    grep -qx 'crates.io' "$(store_of "$PROJ")/allowed-domains"
    [[ "$output" == *"Verified"* ]]
}

@test "dejima-allow with no scope flag still patches the running session" {
    stub_docker 1 0
    run env PATH="$STUB_DIR:$PATH" "$REPO_ROOT/bin/dejima-allow" crates.io
    [ "$status" -eq 0 ]
    [[ "$output" == *"allowed for the running session"* ]]
}

@test "dejima-allow rejects the old argument order" {
    run "$REPO_ROOT/bin/dejima-allow" crates.io --project "$PROJ"
    [ "$status" -ne 0 ]
}

@test "dejima-dep add takes the spec last" {
    run "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep
    [ "$status" -eq 0 ]
    grep -qx 'apt:ripgrep' "$(store_of "$PROJ")/dependencies"
}

@test "dejima-dep add --project with no path uses the current directory" {
    run bash -c "cd '$PROJ' && '$REPO_ROOT/bin/dejima-dep' add --project apt:ripgrep"
    [ "$status" -eq 0 ]
    grep -qx 'apt:ripgrep' "$(store_of "$PROJ")/dependencies"
}

@test "dejima-dep list --project still takes its path" {
    # The row the required-count-aware rule exists for: list has no trailing
    # positional, so the path is the last token and must still be consumed.
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep >/dev/null
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"apt:ripgrep"* ]]
}

@test "dejima-dep rejects the old argument order" {
    run "$REPO_ROOT/bin/dejima-dep" add apt:ripgrep --project "$PROJ"
    [ "$status" -ne 0 ]
}

@test "dejima-allow --project writes the declaration as well as the approval" {
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" example.com
    [ "$status" -eq 0 ]
    grep -qx 'example.com' "$PROJ/.dejima/allowed-domains"
    grep -qx 'example.com' "$(store_of "$PROJ")/allowed-domains"
}

@test "dejima-allow --project creates .dejima when the project has none" {
    rm -rf "$PROJ/.dejima"
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" example.com
    [ "$status" -eq 0 ]
    grep -qx 'example.com' "$PROJ/.dejima/allowed-domains"
}

@test "declaring the same entry twice appends nothing" {
    "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" example.com >/dev/null
    "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" example.com >/dev/null
    [ "$(grep -cx 'example.com' "$PROJ/.dejima/allowed-domains")" -eq 1 ]
}

@test "dejima-allow --global writes no declaration" {
    # There is no project to declare in, and creating a .dejima in $PWD would
    # be a surprise edit to whatever directory the user happened to be in.
    run bash -c "cd '$PROJ' && '$REPO_ROOT/bin/dejima-allow' --global example.com"
    [ "$status" -eq 0 ]
    [ ! -f "$PROJ/.dejima/allowed-domains" ]
}

@test "dejima-dep add --project writes the declaration as well as the approval" {
    run "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep
    [ "$status" -eq 0 ]
    grep -qx 'apt:ripgrep' "$PROJ/.dejima/dependencies"
    grep -qx 'apt:ripgrep' "$(store_of "$PROJ")/dependencies"
}

@test "dejima-dep remove --project leaves the declaration alone" {
    # Withdrawing one machine's approval is not the same decision as editing a
    # file the whole team shares, so remove touches only the approval.
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep >/dev/null
    run "$REPO_ROOT/bin/dejima-dep" remove --project "$PROJ" apt:ripgrep
    [ "$status" -eq 0 ]
    grep -qx 'apt:ripgrep' "$PROJ/.dejima/dependencies"
    run "$REPO_ROOT/bin/dejima-dep" list --project "$PROJ"
    [[ "$output" != *"apt:ripgrep"* ]]
}

@test "a declaration written from a worktree says where it landed" {
    # The approval attaches to the parent's store (existing inheritance), but
    # the declaration goes to the checkout the caller named - a file on that
    # branch. Both facts have to be visible or the pair looks lost.
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:parentpkg >/dev/null
    wt="$PROJ/.worktrees/feat"
    mkdir -p "$wt"
    run "$REPO_ROOT/bin/dejima-allow" --project "$wt" branch.example
    [ "$status" -eq 0 ]
    grep -qx 'branch.example' "$wt/.dejima/allowed-domains"
    grep -qx 'branch.example' "$(store_of "$PROJ")/allowed-domains"
    [[ "$output" == *"$wt/.dejima"* ]]
}

@test "an unwritable project still records the approval and says so" {
    # approve_entry runs first and ungated, so by the time declare_entry
    # fails the domain is already granted for every future session. A run
    # that aborts here without saying so would read as "nothing happened,"
    # when in fact access was just extended.
    rm -rf "$PROJ/.dejima"
    chmod 555 "$PROJ"
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" example.com
    chmod 755 "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"IS recorded"* ]]
    grep -qx 'example.com' "$(store_of "$PROJ")/allowed-domains"
    [ ! -d "$PROJ/.dejima" ]
}

@test "status shows an approval that was never declared" {
    # The reported bug: a domain approved with --project was invisible,
    # because status only ever iterated the declaration file.
    printf 'example.com\n' > "$(mktemp -d)/unused"
    mkdir -p "$(store_of "$PROJ")"
    printf '%s\n' "$PROJ" > "$(store_of "$PROJ")/path"
    printf 'orphan.example\n' > "$(store_of "$PROJ")/allowed-domains"
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orphan.example"* ]]
    [[ "$output" == *"not declared"* ]]
}

@test "status marks where an approval came from" {
    mkdir -p "$(store_of "$PROJ")"
    printf '%s\n' "$PROJ" > "$(store_of "$PROJ")/path"
    printf 'proj.example\n' > "$(store_of "$PROJ")/allowed-domains"
    printf 'glob.example\n' > "$CONFIG_DIR/allowed-domains"
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"proj.example"*"(project"* ]]
    [[ "$output" == *"glob.example"*"(global"* ]]
}

@test "status still marks a declared-but-unapproved entry pending" {
    printf 'pending.example\n' > "$PROJ/.dejima/allowed-domains"
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pending"*"pending.example"* ]]
}

@test "status still marks a malformed declaration rejected" {
    printf 'not a domain\n' > "$PROJ/.dejima/allowed-domains"
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rejected"* ]]
}

@test "status labels each store rather than printing a bare path" {
    run "$REPO_ROOT/bin/dejima-project" status "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Project approvals:"* ]]
    [[ "$output" == *"Global approvals:"* ]]
}

@test "approve records without chasing a running session" {
    # approve shells out to dejima-allow --project, which no longer touches
    # containers - so a docker that would fail loudly must never be reached.
    printf 'approved.example\n' > "$PROJ/.dejima/allowed-domains"
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/bash
echo "docker was called: $*" >&2
exit 97
EOF
    chmod +x "$STUB_DIR/docker"
    run env PATH="$STUB_DIR:$PATH" \
        bash -c 'echo y | "$1" approve "$2"' _ "$REPO_ROOT/bin/dejima-project" "$PROJ"
    [ "$status" -eq 0 ]
    [[ "$output" != *"docker was called"* ]]
    grep -qx 'approved.example' "$(store_of "$PROJ")/allowed-domains"
}

# --- a declaration path the session controls ---
#
# .dejima lives on the read-write bind mount, so everything below is something
# a compromised session can arrange on its own and then ask the user to
# trigger - the startup briefing tells it to hand over the exact
# `dejima-allow --project` command that would follow the planted link. The
# writer is host-side and unsandboxed, so following one turns a session's
# write access to its own directory into a write anywhere the user can reach.

@test "dejima-allow --project refuses a .dejima that is a symlink to a directory" {
    # The broadest shape: mkdir -p follows a directory symlink, so no file in
    # it needs to exist beforehand for the append to land outside the project.
    local elsewhere
    elsewhere="$(mktemp -d)"
    rm -rf "$PROJ/.dejima"
    ln -s "$elsewhere" "$PROJ/.dejima"
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" example.com
    [[ "$output" == *"Refusing"* ]]
    [[ "$output" == *"symlink"* ]]
    [ ! -e "$elsewhere/allowed-domains" ]
    # The approval is separate and still recorded - the refusal is about where
    # the declaration would have gone, not about the grant.
    grep -qx 'example.com' "$(store_of "$PROJ")/allowed-domains"
    rm -rf "$elsewhere"
}

@test "dejima-allow --project refuses a declaration file that is a symlink to the global store" {
    # The escalation the guard exists for: the user asks for one project's
    # scope and the entry lands in the store that applies to every project on
    # the machine, while the output claims the project was written.
    printf '%s\n' 'already.example' > "$CONFIG_DIR/allowed-domains"
    ln -sf "$CONFIG_DIR/allowed-domains" "$PROJ/.dejima/allowed-domains"
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" evil.example
    [[ "$output" == *"Refusing"* ]]
    [[ "$output" == *"symlink"* ]]
    run grep -c . "$CONFIG_DIR/allowed-domains"
    [ "$output" -eq 1 ]
    run grep -qx 'evil.example' "$CONFIG_DIR/allowed-domains"
    [ "$status" -ne 0 ]
}

@test "dejima-allow --project refuses a declaration symlinked at the global dependency list" {
    # Persistent denial of service rather than escalation: a domain is not a
    # valid dependency spec, so approved_entries' refuse-rather-than-proceed
    # contract would fire against the global store and stop bin/dejima
    # building a derived image for ANY project until the file is hand-edited.
    printf 'apt:libpq-dev\n' > "$CONFIG_DIR/dependencies"
    ln -sf "$CONFIG_DIR/dependencies" "$PROJ/.dejima/allowed-domains"
    run "$REPO_ROOT/bin/dejima-allow" --project "$PROJ" evil.example
    [[ "$output" == *"Refusing"* ]]
    run bash -c 'source "$1"; approved_entries "$2" dependencies' _ "$LIB" "$CONFIG_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"evil.example"* ]]
}

@test "dejima-dep add --project refuses a .dejima that is a symlink to a directory" {
    local elsewhere
    elsewhere="$(mktemp -d)"
    rm -rf "$PROJ/.dejima"
    ln -s "$elsewhere" "$PROJ/.dejima"
    run "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep
    [[ "$output" == *"Refusing"* ]]
    [[ "$output" == *"symlink"* ]]
    [ ! -e "$elsewhere/dependencies" ]
    grep -qx 'apt:ripgrep' "$(store_of "$PROJ")/dependencies"
    rm -rf "$elsewhere"
}

@test "dejima-dep add --project refuses a declaration file symlinked at an arbitrary host file" {
    # Neither store is involved here: any path the user can write is a target
    # once the link is followed, which is why the guard is on the write and
    # not on a list of paths worth protecting.
    local victim
    victim="$(mktemp -d)/victim"
    printf 'original\n' > "$victim"
    ln -sf "$victim" "$PROJ/.dejima/dependencies"
    run "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep
    [[ "$output" == *"Refusing"* ]]
    [[ "$output" == *"symlink"* ]]
    [ "$(cat "$victim")" = "original" ]
    rm -rf "$(dirname "$victim")"
}

@test "dejima-project approve attempts every dependency even when one fails" {
    # The dep loop had no collector, so under set -e the first failure aborted
    # the whole script: the second dep and BOTH domains were never attempted
    # and no summary was printed at all. An unwritable config root fails every
    # entry without needing docker anywhere near this.
    printf 'apt:one\napt:two\n' > "$PROJ/.dejima/dependencies"
    printf 'a.example\nb.example\n' > "$PROJ/.dejima/allowed-domains"
    chmod 500 "$CONFIG_DIR"
    run bash -c 'echo y | "$1" approve "$2"' _ "$REPO_ROOT/bin/dejima-project" "$PROJ"
    chmod 700 "$CONFIG_DIR"
    line="$(grep 'dejima-dep failed' <<< "$output")"
    [[ "$line" == *"apt:one"* ]]
    [[ "$line" == *"apt:two"* ]]
    # The domains are the real proof the abort is gone: they come after the
    # dep loop entirely, so a fatal first dep meant they were never tried.
    line="$(grep 'dejima-allow failed' <<< "$output")"
    [[ "$line" == *"a.example"* ]]
    [[ "$line" == *"b.example"* ]]
}

@test "dejima-project approve exits non-zero when nothing could be approved" {
    # `dejima-project approve ~/p && dejima` is the obvious way to chain
    # these. Exiting 0 after recording nothing walks that chain into a session
    # with none of the approvals the user just confirmed.
    printf 'a.example\n' > "$PROJ/.dejima/allowed-domains"
    chmod 500 "$CONFIG_DIR"
    run bash -c 'echo y | "$1" approve "$2"' _ "$REPO_ROOT/bin/dejima-project" "$PROJ"
    chmod 700 "$CONFIG_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT approved"* ]]
    [[ "$output" != *"Restart the sandbox"* ]]
}

@test "dejima-dep refuses --container rather than silently ignoring it" {
    # Before the shared parser this was an "Unknown option". Adopting
    # dejima-allow's parser handed dejima-dep a flag it has no concept of, and
    # swallowing it would give a caller who meant to scope an approval to one
    # session a persistent project-scoped grant plus a zero exit.
    run "$REPO_ROOT/bin/dejima-dep" add --container bogusctr --project "$PROJ" apt:ripgrep
    [ "$status" -ne 0 ]
    [[ "$output" == *"--container"* ]]
    [ ! -e "$(store_of "$PROJ")/dependencies" ]
    [ ! -e "$PROJ/.dejima/dependencies" ]
}

@test "dejima-dep remove --project says the declaration will re-offer the entry" {
    # The asymmetry is deliberate but was invisible and self-undoing: the
    # entry goes back to pending, the briefing reports it missing, and the
    # next approve puts it straight back.
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep >/dev/null
    run "$REPO_ROOT/bin/dejima-dep" remove --project "$PROJ" apt:ripgrep
    [ "$status" -eq 0 ]
    [[ "$output" == *"$PROJ/.dejima/dependencies"* ]]
    [[ "$output" == *"approve will offer it again"* ]]
}

@test "declaring into a FIFO planted at the declaration path does not hang" {
    # The other way a session-owned path attacks a host CLI: not misdirecting
    # the write but never completing it. touch, the duplicate-check grep and
    # the append all block on a FIFO until someone opens the far end, which
    # the session simply never does - wedging a command the briefing told the
    # user to run. `timeout` is the assertion: exit 124 is the bug.
    rm -f "$PROJ/.dejima/dependencies"
    mkfifo "$PROJ/.dejima/dependencies"
    run timeout 5 "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep
    [ "$status" -ne 124 ]
    [[ "$output" == *"Refusing"* ]]
    # and the approval, which is the part that grants, still landed
    grep -qx 'apt:ripgrep' "$(store_of "$PROJ")/dependencies"
}

@test "declaring into an oversized declaration file is refused, not read into memory" {
    # The third shape, and the one the atomic rewrite introduced: the duplicate
    # check has to read back a file the session owns, and `truncate -s 8G` makes
    # that file arbitrarily large at zero cost - it is sparse, du reports 0. A
    # slurping read turns the command the briefing told the user to run into a
    # host OOM, aimed at whatever else that host is running.
    #
    # The address-space limit is so that a regression fails THIS test rather
    # than the machine it runs on. With the bound the read stops at 1 MiB and
    # nothing comes near the limit; without it, this is a MemoryError here
    # instead of dockerd or an editor being killed.
    truncate -s 8G "$PROJ/.dejima/dependencies"
    run timeout 30 bash -c 'ulimit -v 2097152; exec "$@"' _ \
        "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep
    [ "$status" -ne 124 ]
    [[ "$output" == *"Refusing"* ]]
    [[ "$output" == *"larger than"* ]]
    [[ "$output" != *"Traceback"* ]]
    # and the approval, which is the part that grants, still landed
    grep -qx 'apt:ripgrep' "$(store_of "$PROJ")/dependencies"
}

@test "declaring into a declaration file just under the cap still works" {
    # The discriminating neighbour: the cap must be a ceiling on a hostile file,
    # not a new way for a large-but-real declaration to be refused.
    python3 -c 'import sys; open(sys.argv[1], "wb").write(b"# " + b"x" * ((1 << 20) - 4) + b"\n")' \
        "$PROJ/.dejima/dependencies"
    run "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep
    [ "$status" -eq 0 ]
    [[ "$output" != *"Refusing"* ]]
    [ "$(tail -n 1 "$PROJ/.dejima/dependencies")" = "apt:ripgrep" ]
}

# The two above plant the link and wait. A session does not have to wait: the
# briefing tells it to ask the user to run `dejima-allow --project` from a
# terminal outside the sandbox, so the session is normally still running when
# the CLI does, and it is the one that chose the moment. The tests below are
# that session - a loop swapping the path while the writer works. A
# check-then-write loses this; both were written against the old guard first
# and it lost both, appending to the victim within a few hundred attempts.
#
# The assertion is one-sided on purpose: the victim must never be written. The
# refusal count is only there to prove the swap window was real, so a run where
# the swapper never landed cannot pass vacuously.
swap_loop() {
    python3 - "$1" "$2" <<'PY' &
import os, sys, time

path, target = sys.argv[1], sys.argv[2]
held = path + ".held"
end = time.time() + 60
while time.time() < end:
    try:
        os.rename(path, held)
        os.symlink(target, path)
    except OSError:
        pass
    time.sleep(0.004)
    try:
        os.unlink(path)
        os.rename(held, path)
    except OSError:
        pass
    time.sleep(0.004)
PY
    SWAPPER=$!
}

declare_repeatedly() {
    bash -c '
        source "$1"
        refused=0
        for _ in $(seq 1 60); do
            declare_entry "$2" allowed-domains evil.example >/dev/null 2>&1 \
                || refused=$((refused + 1))
        done
        printf "%s\n" "$refused"
    ' _ "$LIB" "$PROJ"
}

@test "a session swapping the declaration file mid-write cannot redirect it" {
    local victim refused
    victim="$(mktemp -d)/victim"
    printf 'original\n' > "$victim"
    printf 'declared.example\n' > "$PROJ/.dejima/allowed-domains"
    swap_loop "$PROJ/.dejima/allowed-domains" "$victim"
    refused="$(declare_repeatedly)"
    kill "$SWAPPER" 2>/dev/null || true
    [ "$(cat "$victim")" = "original" ]
    [ "$refused" -gt 0 ]
    rm -rf "$(dirname "$victim")"
}

@test "a session swapping the .dejima directory mid-write cannot redirect it" {
    # The directory needs the same treatment as the file: a guard that only
    # opened the file safely would still create or append inside whatever
    # directory the path resolved to at the moment of the open.
    local elsewhere refused
    elsewhere="$(mktemp -d)"
    printf 'original\n' > "$elsewhere/allowed-domains"
    swap_loop "$PROJ/.dejima" "$elsewhere"
    refused="$(declare_repeatedly)"
    kill "$SWAPPER" 2>/dev/null || true
    [ "$(cat "$elsewhere/allowed-domains")" = "original" ]
    [ "$refused" -gt 0 ]
    rm -rf "$elsewhere"
}

@test "removing with a FIFO planted at the declaration path does not hang" {
    # The re-offer notice reads the same session-owned path, so it needs the
    # same guard as the write does.
    "$REPO_ROOT/bin/dejima-dep" add --project "$PROJ" apt:ripgrep >/dev/null
    rm -f "$PROJ/.dejima/dependencies"
    mkfifo "$PROJ/.dejima/dependencies"
    run timeout 5 "$REPO_ROOT/bin/dejima-dep" remove --project "$PROJ" apt:ripgrep
    [ "$status" -ne 124 ]
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed apt:ripgrep"* ]]
}
