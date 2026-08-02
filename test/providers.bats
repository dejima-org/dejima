#!/usr/bin/env bats
# Providers are data, not code. These tests are mostly about what a malformed
# or over-reaching manifest is NOT allowed to do.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/bin/dejima-provider-lib.sh"
    CONFIG_DIR="$(mktemp -d)"
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR"
}
teardown() { rm -rf "$CONFIG_DIR" ${FAKE_ROOT:+"$FAKE_ROOT"}; }

lib() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

@test "every shipped manifest validates" {
    for axis in forge workflow harness; do
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            run lib manifest_validate "$axis" "$name"
            [ "$status" -eq 0 ] || { echo "$axis/$name: $output"; return 1; }
        done < <(lib provider_list "$axis")
    done
}

@test "each axis ships at least one provider" {
    for axis in forge workflow harness; do
        [ -n "$(lib provider_list "$axis")" ] || { echo "no $axis providers"; return 1; }
    done
}

@test "an unknown manifest key is fatal" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/bogus"
    printf 'capabilities = pr\nnonesuch = 1\n' > "$FAKE_ROOT/forges/bogus/forge.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; manifest_validate forge bogus' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown key"* ]]
}

@test "a manifest is parsed, never sourced" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/evil"
    printf 'capabilities = pr\npr_command = $(touch %s/PWNED)\n' "$FAKE_ROOT" \
        > "$FAKE_ROOT/forges/evil/forge.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; manifest_validate forge evil' _ "$LIB"
    [ ! -e "$FAKE_ROOT/PWNED" ]
    # And the value is refused outright rather than merely not executed.
    [ "$status" -ne 0 ]
}

@test "provider_dir refuses a name that escapes the axis directory" {
    for bad in ".." "../../etc" "a/b" "" "."; do
        run lib provider_dir forge "$bad"
        [ "$status" -ne 0 ] || { echo "accepted provider name '$bad'"; return 1; }
    done
}

@test "manifest_get returns a value and refuses an unknown key" {
    run lib manifest_get forge gitea pr_command
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    run lib manifest_get forge gitea nonesuch
    [ "$status" -ne 0 ]
}

@test "provider_dir refuses a symlink pointing outside the axis directory" {
    FAKE_ROOT="$(mktemp -d)"
    TARGET="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges" "$TARGET/planted"
    printf 'capabilities = pr\n' > "$TARGET/planted/forge.conf"
    ln -s "$TARGET/planted" "$FAKE_ROOT/forges/evil-link"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; provider_dir forge evil-link' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" == *"forges"* ]]
    rm -rf "$TARGET"
}

@test "provider_dir refuses a dangling symlink" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges"
    ln -s /nonexistent/target "$FAKE_ROOT/forges/dangling-link"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; provider_dir forge dangling-link' _ "$LIB"
    [ "$status" -ne 0 ]
}

@test "gitea's manifest names the CLIs it actually ships" {
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -f "$REPO_ROOT/forges/gitea/$rel" ] \
            || { echo "install names a missing file: $rel"; return 1; }
        [ -x "$REPO_ROOT/forges/gitea/$rel" ] \
            || { echo "install names a non-executable file: $rel"; return 1; }
    done < <(lib manifest_get forge gitea install | tr ' ' '\n')
}

@test "a forge's pr_command resolves to something the image will have" {
    # Either a file the forge ships, or a binary the Dockerfile installs.
    for f in $(lib provider_list forge); do
        cmd="$(lib manifest_get forge "$f" pr_command)"
        [ -n "$cmd" ] || continue
        word0="${cmd%% *}"
        if [ -f "$REPO_ROOT/forges/$f/bin/$word0" ]; then continue; fi
        grep -q "$word0" "$REPO_ROOT/docker/Dockerfile" \
            || { echo "$f: pr_command '$cmd' is neither shipped nor installed"; return 1; }
    done
}

@test "the Dockerfile copies every forge's bin, not one forge by name" {
    grep -q 'COPY forges/' "$REPO_ROOT/docker/Dockerfile"
    run grep -n 'COPY bin/gitea' "$REPO_ROOT/docker/Dockerfile"
    [ "$status" -ne 0 ]
}

@test "gitea's CLIs moved out of bin/ and into its forge" {
    [ ! -e "$REPO_ROOT/bin/gitea-pr" ]
    [ ! -e "$REPO_ROOT/bin/gitea-issue" ]
    [ -x "$REPO_ROOT/forges/gitea/bin/gitea-pr" ]
    [ -x "$REPO_ROOT/forges/gitea/bin/gitea-issue" ]
}

@test "a workflow requiring a capability its forge lacks is refused" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/bare" "$FAKE_ROOT/workflows/needy" "$FAKE_ROOT/harnesses/h"
    printf 'capabilities =\n' > "$FAKE_ROOT/forges/bare/forge.conf"
    printf 'requires = pr\npush = off\n' > "$FAKE_ROOT/workflows/needy/workflow.conf"
    printf 'command = claude\n' > "$FAKE_ROOT/harnesses/h/harness.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; provider_validate_selection bare needy h' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" == *"pr"* ]]
    [[ "$output" == *"bare"* ]]
    [[ "$output" == *"needy"* ]]
}

@test "a pushing workflow on a forge with no hosts is not refused - rule 3 is deferred to Phase 3" {
    # gitea's ssh_host/api have no schema default and install.sh writes them
    # commented out, so refusing this would refuse a fresh install - see the
    # comment above provider_validate_selection's push check. Phase 3 adds
    # `forge = none` and this becomes a refusal then.
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/hostless" "$FAKE_ROOT/workflows/pusher" "$FAKE_ROOT/harnesses/h"
    printf 'capabilities =\n' > "$FAKE_ROOT/forges/hostless/forge.conf"
    printf 'requires =\npush = on\n' > "$FAKE_ROOT/workflows/pusher/workflow.conf"
    printf 'command = claude\n' > "$FAKE_ROOT/harnesses/h/harness.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; provider_validate_selection hostless pusher h' _ "$LIB"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the shipped selection validates" {
    # provider_validate_selection runs after bin/dejima's own config_exists
    # gate in real use, so a config file is always present by then - gitea's
    # requires (ssh_host, api) need real values here for the same reason.
    printf '[forge.gitea]\nssh_host = git.example\napi = https://api.example/v1\n' \
        > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a wholly unconfigured forge produces no warning and still validates" {
    # The supported "I don't use a forge" case (rule 3's comment, README
    # "Skip this if you only push to GitHub") - a test asserting only the
    # warning below would pass against a version that refused this instead.
    # gitea's requires includes token_file, which has a schema default
    # (~/.config/gitea/token) and so ALWAYS resolves to a non-empty value
    # via config_get, even though nothing here sets it - this must still
    # count as "unset" (config_is_set, not config_get) or a config that sets
    # none of gitea's keys would look partly configured and warn.
    printf '[core]\nfirewall = on\n' > "$CONFIG_DIR/config"
    run lib config_default forge.gitea.token_file
    [ -n "$output" ] || { echo "test premise broken: token_file has no default"; return 1; }
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"Warning"* ]] || { echo "unexpected warning: $output"; return 1; }
}

@test "a partially configured forge warns but still validates" {
    printf '[forge.gitea]\nssh_host = git.example\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"partly configured"* ]]
    [[ "$output" == *"api"* ]]
}

@test "forge_hosts unions literal host keys, URL-derived hosts and fixed hosts" {
    printf '[forge.gitea]\nssh_host = git.example\napi = https://api.example/v1\n' \
        > "$CONFIG_DIR/config"
    run lib forge_hosts gitea
    [ "$status" -eq 0 ]
    [[ "$output" == *"git.example"* ]]
    [[ "$output" == *"api.example"* ]]
    # The scheme and path never survive into a firewall entry.
    [[ "$output" != *"https"* ]]
    [[ "$output" != *"/v1"* ]]
}
