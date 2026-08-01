#!/usr/bin/env bats
# Host-side tests for the single config file. The parser is a trust
# boundary in the weak sense that a malformed config must stop a launch
# rather than silently produce a differently-configured sandbox, so most of
# what is here is about what it refuses.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/bin/dejima-config-lib.sh"
    CONFIG_DIR="$(mktemp -d)"
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR"
}

teardown() {
    rm -rf "$CONFIG_DIR" ${STUB_DIR:+"$STUB_DIR"}
}

lib() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

# install.sh refuses to run without docker, and the fast CI job's container
# has jq/python3/bats but deliberately no docker - the whole point of the
# split is that this half needs nothing but a shell. Stub it so the tests
# that drive install.sh exercise what they are actually about.
stub_docker() {
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
# `docker compose version` is the only call install.sh makes.
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
}

@test "config_root honours DEJIMA_CONFIG_DIR and config_path appends config" {
    run lib config_root
    [ "$status" -eq 0 ]
    [ "$output" = "$CONFIG_DIR" ]
    run lib config_path
    [ "$output" = "$CONFIG_DIR/config" ]
}

@test "_config_spec resolves a known key and rejects an unknown one" {
    run lib _config_spec core.firewall
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'bool\ton')" ]
    run lib _config_spec core.nonesuch
    [ "$status" -ne 0 ]
}

@test "config_type and config_default split the spec" {
    run lib config_type audit.keep
    [ "$output" = "int:1:1000" ]
    run lib config_default audit.keep
    [ "$output" = "10" ]
}

@test "every key in the table has a type and a resolvable spec" {
    while IFS= read -r key; do
        run lib _config_spec "$key"
        [ "$status" -eq 0 ] || { echo "no spec for $key"; return 1; }
        run lib config_type "$key"
        [ -n "$output" ] || { echo "empty type for $key"; return 1; }
    done < <(lib _config_keys)
}

@test "the schema table has no duplicate keys" {
    dupes="$(lib _config_keys | sort | uniq -d)"
    [ -z "$dupes" ] || { echo "duplicate keys: $dupes"; return 1; }
}
