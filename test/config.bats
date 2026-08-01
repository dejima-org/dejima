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

@test "bool accepts on and off and nothing else" {
    run lib _config_valid_value bool on
    [ "$status" -eq 0 ]
    run lib _config_valid_value bool off
    [ "$status" -eq 0 ]
    for bad in true false 1 0 yes "" ON; do
        run lib _config_valid_value bool "$bad"
        [ "$status" -ne 0 ] || { echo "bool wrongly accepted: '$bad'"; return 1; }
    done
}

@test "int enforces its declared range" {
    run lib _config_valid_value int:1:65535 7681
    [ "$status" -eq 0 ]
    for bad in 0 65536 -1 abc 12.5 ""; do
        run lib _config_valid_value int:1:65535 "$bad"
        [ "$status" -ne 0 ] || { echo "int wrongly accepted: '$bad'"; return 1; }
    done
}

@test "enum accepts only its listed members" {
    run lib _config_valid_value 'enum:tls|loopback' tls
    [ "$status" -eq 0 ]
    run lib _config_valid_value 'enum:tls|loopback' loopback
    [ "$status" -eq 0 ]
    for bad in TLS tl "tls|loopback" ""; do
        run lib _config_valid_value 'enum:tls|loopback' "$bad"
        [ "$status" -ne 0 ] || { echo "enum wrongly accepted: '$bad'"; return 1; }
    done
}

@test "path requires an absolute or tilde-rooted value" {
    run lib _config_valid_value path /tmp/x
    [ "$status" -eq 0 ]
    run lib _config_valid_value path '~/specs'
    [ "$status" -eq 0 ]
    for bad in relative/path ./x ""; do
        run lib _config_valid_value path "$bad"
        [ "$status" -ne 0 ] || { echo "path wrongly accepted: '$bad'"; return 1; }
    done
}

@test "the optional prefix is what permits an empty value" {
    run lib _config_valid_value path ""
    [ "$status" -ne 0 ]
    run lib _config_valid_value '?path' ""
    [ "$status" -eq 0 ]
    run lib _config_valid_value '?int:8:72' ""
    [ "$status" -eq 0 ]
    # A non-empty value under "?" is still type-checked, not waved through.
    run lib _config_valid_value '?int:8:72' 200
    [ "$status" -ne 0 ]
}

@test "url accepts the shapes dejima actually configures" {
    for good in "https://example.com/api/v1" "http://192.0.2.10:3100" \
                "https://gitbox.example.io/api/v1" "https://ntfy.sh/topic?x=1"; do
        run lib _config_valid_value url "$good"
        [ "$status" -eq 0 ] || { echo "url wrongly rejected: '$good'"; return 1; }
    done
}

@test "url rejects a space, a shell metacharacter, or a missing scheme" {
    for bad in "http://a b" 'http://a;id' 'http://a&b' 'http://a$(id)' \
               'http://a`id`' 'http://a|b' "ftp://a.b" "example.com"; do
        run lib _config_valid_value url "$bad"
        [ "$status" -ne 0 ] || { echo "url wrongly accepted: '$bad'"; return 1; }
    done
}

@test "hostname uses the same expression the approval store validates with" {
    run lib _config_valid_value hostname gitbox.example.com
    [ "$status" -eq 0 ]
    for bad in "a b" "a/b" 'a;b' ""; do
        run lib _config_valid_value hostname "$bad"
        [ "$status" -ne 0 ] || { echo "hostname wrongly accepted: '$bad'"; return 1; }
    done
}

@test "list:path validates every colon-separated element" {
    run lib _config_valid_value 'list:path' /a:/b:'~/c'
    [ "$status" -eq 0 ]
    run lib _config_valid_value 'list:path' /a:relative
    [ "$status" -ne 0 ]
}
