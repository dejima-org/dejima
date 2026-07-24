#!/usr/bin/env bats
# Host-side (no Docker): the config/env parser must extract ALLOWED_DOMAINS
# without ever executing the file, so a compromised self-mounted session
# can't plant host shell there for the next launch to run.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    source "$REPO_ROOT/bin/claude-sandbox-env.sh"
    ENVFILE="$(mktemp)"
}
teardown() { rm -f "$ENVFILE"; }

@test "accepts the export ALLOWED_DOMAINS=\"...\" format written by claude-sandbox-allow" {
    printf 'export ALLOWED_DOMAINS="crates.io index.crates.io"\n' > "$ENVFILE"
    run parse_allowed_domains_env "$ENVFILE"
    [ "$status" -eq 0 ]
    [ "$output" = "crates.io index.crates.io" ]
}

@test "accepts an unquoted bare assignment" {
    printf 'ALLOWED_DOMAINS=example.com\n' > "$ENVFILE"
    run parse_allowed_domains_env "$ENVFILE"
    [ "$output" = "example.com" ]
}

@test "does NOT execute command substitution in the value" {
    printf 'export ALLOWED_DOMAINS="$(touch %s/pwned)"\n' "$BATS_TEST_TMPDIR" > "$ENVFILE"
    run parse_allowed_domains_env "$ENVFILE"
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    [ "$output" = "" ]
}

@test "does NOT execute a trailing command line" {
    printf 'export ALLOWED_DOMAINS="ok.com"\ntouch %s/pwned\n' "$BATS_TEST_TMPDIR" > "$ENVFILE"
    run parse_allowed_domains_env "$ENVFILE"
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    [ "$output" = "ok.com" ]
}

@test "rejects a value containing shell metacharacters, yielding empty" {
    printf 'export ALLOWED_DOMAINS="a.com; rm -rf /"\n' > "$ENVFILE"
    run parse_allowed_domains_env "$ENVFILE"
    [ "$output" = "" ]
}

@test "ignores comments and blank lines, missing file yields empty" {
    run parse_allowed_domains_env /nonexistent/config/env
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
