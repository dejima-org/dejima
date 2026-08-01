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

@test "path rejects a colon, which would split a docker -v mount spec" {
    # docker-compose.yml mounts share_dir as "${SANDBOX_SHARE_DIR}:${HOME}/shared".
    # A colon in the value silently redirects source and target instead of
    # failing, so it must not validate.
    run lib _config_valid_value path /tmp/a:b
    [ "$status" -ne 0 ]
    run lib _config_valid_value path "$(printf '/tmp/a\nb')"
    [ "$status" -ne 0 ]
}

@test "path still accepts a space, which is a legal path character" {
    # Every consumer quotes this value, so rejecting spaces would only break
    # operators whose home directory has one.
    run lib _config_valid_value path '/home/someone/My Documents/proj'
    [ "$status" -eq 0 ]
}

write_config() {
    printf '%s\n' "$@" > "$CONFIG_DIR/config"
}

@test "config_get returns the schema default when the key is absent" {
    write_config '[core]' 'firewall = on'
    run lib config_get audit keep
    [ "$status" -eq 0 ]
    [ "$output" = "10" ]
}

@test "config_get returns an explicitly empty value rather than the default" {
    write_config '[core]' 'ssh_key ='
    run lib config_get core ssh_key
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    # Distinct from absence, which yields the default.
    write_config '[core]' 'firewall = on'
    run lib config_get core known_hosts
    [ "$output" = "$HOME/.ssh/known_hosts" ]
}

@test "config_get expands a leading tilde on path types only" {
    write_config '[core]' 'share_dir = ~/somewhere' '[logging]' 'loki_url = https://x.example/~y'
    run lib config_get core share_dir
    [ "$output" = "$HOME/somewhere" ]
    run lib config_get logging loki_url
    [ "$output" = "https://x.example/~y" ]
}

@test "config_get expands a tilde in every element of a list" {
    write_config '[mounts]' 'readonly = ~/a:/b'
    run lib config_get mounts readonly
    [ "$output" = "$HOME/a:/b" ]
}

@test "comments, blank lines and surrounding whitespace are ignored" {
    write_config '# leading comment' '' '  [core]  ' '; semicolon comment' \
                 '   firewall   =   off   ' ''
    run lib config_get core firewall
    [ "$status" -eq 0 ]
    [ "$output" = "off" ]
}

@test "a later assignment of the same key wins" {
    write_config '[core]' 'firewall = on' 'firewall = off'
    run lib config_get core firewall
    [ "$output" = "off" ]
}

@test "an unknown section is fatal" {
    write_config '[nonesuch]' 'x = y'
    run lib config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown section"* ]]
    [[ "$output" == *"nonesuch"* ]]
}

@test "an unknown key is fatal and names the section" {
    write_config '[core]' 'nonesuch = 1'
    run lib config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown key"* ]]
    [[ "$output" == *"core"* ]]
    [[ "$output" == *"nonesuch"* ]]
}

@test "an invalid value is fatal and names the key" {
    write_config '[audit]' 'keep = 0'
    run lib config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid value"* ]]
    [[ "$output" == *"keep"* ]]
}

@test "a key outside any section is fatal" {
    write_config 'firewall = on'
    run lib config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside any section"* ]]
}

@test "a line that is neither a section nor an assignment is fatal" {
    write_config '[core]' 'this is not an assignment'
    run lib config_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"malformed"* ]]
}

@test "config_get refuses a key the schema does not define" {
    write_config '[core]' 'firewall = on'
    run lib config_get core nonesuch
    [ "$status" -ne 0 ]
}

@test "config_get validates the whole file, not just the requested key" {
    write_config '[core]' 'firewall = on' '[audit]' 'keep = 99999'
    run lib config_get core firewall
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid value"* ]]
}

@test "config_get_bool maps on and off to 1 and 0" {
    write_config '[core]' 'firewall = off'
    run lib config_get_bool core firewall
    [ "$output" = "0" ]
    write_config '[core]' 'firewall = on'
    run lib config_get_bool core firewall
    [ "$output" = "1" ]
}

@test "config_exists reports whether the file is there" {
    run lib config_exists
    [ "$status" -ne 0 ]
    write_config '[core]' 'firewall = on'
    run lib config_exists
    [ "$status" -eq 0 ]
}

@test "a missing config file is not silently an all-defaults config" {
    run lib config_get core firewall
    [ "$status" -ne 0 ]
}

@test "remote_enabled is false until enabled is explicitly on" {
    PROJECT_LIB="$REPO_ROOT/bin/dejima-project-lib.sh"
    plib() { bash -c 'source "$1"; shift; "$@"' _ "$PROJECT_LIB" "$@"; }
    write_config '[core]' 'firewall = on'
    run plib remote_enabled
    [ "$status" -ne 0 ]
    # A base_url alone must NOT open the front doors - the switch is explicit.
    write_config '[remote-access]' 'base_url = https://dejima.example'
    run plib remote_enabled
    [ "$status" -ne 0 ]
    write_config '[remote-access]' 'enabled = on'
    run plib remote_enabled
    [ "$status" -eq 0 ]
    write_config '[remote-access]' 'enabled = off'
    run plib remote_enabled
    [ "$status" -ne 0 ]
}

@test "ntfy alone is a complete remote-access setup, with no base_url" {
    # BASE_URL was always optional - ntfy is the only half that has to be
    # reachable from a phone. Making a URL the switch would have dropped this
    # supported configuration silently.
    PROJECT_LIB="$REPO_ROOT/bin/dejima-project-lib.sh"
    plib() { bash -c 'source "$1"; shift; "$@"' _ "$PROJECT_LIB" "$@"; }
    write_config '[remote-access]' 'enabled = on' \
                 'ntfy_url = https://ntfy.example.invalid/dejima'
    run plib remote_enabled
    [ "$status" -eq 0 ]
    run lib config_get remote-access base_url
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "remote_enabled survives a malformed line elsewhere in the config" {
    # dejima-attach reads no VALUE out of the config, so a typo in an
    # unrelated section must not take away the terminal an operator would fix
    # that typo from. Everything that DOES read a value still refuses - the
    # next test pins that contrast.
    PROJECT_LIB="$REPO_ROOT/bin/dejima-project-lib.sh"
    plib() { bash -c 'source "$1"; shift; "$@"' _ "$PROJECT_LIB" "$@"; }
    write_config '[remote-access]' 'enabled = on' \
                 '[audit]' 'keep = 0' \
                 '[core]' 'this is not an assignment'
    run plib remote_enabled
    [ "$status" -eq 0 ]
}

@test "a value read still refuses on the same malformed config" {
    write_config '[remote-access]' 'enabled = on' '[audit]' 'keep = 0'
    run lib config_get remote-access ntfy_url
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid value"* ]]
}

@test "an existing remote.conf grants nothing" {
    PROJECT_LIB="$REPO_ROOT/bin/dejima-project-lib.sh"
    plib() { bash -c 'source "$1"; shift; "$@"' _ "$PROJECT_LIB" "$@"; }
    write_config '[core]' 'firewall = on'
    printf 'BASE_URL=https://old.example\n' > "$CONFIG_DIR/remote.conf"
    run plib remote_enabled
    [ "$status" -ne 0 ]
}

@test "ttyd port and font size come from the config with their old bounds" {
    PROJECT_LIB="$REPO_ROOT/bin/dejima-project-lib.sh"
    plib() { bash -c 'source "$1"; shift; "$@"' _ "$PROJECT_LIB" "$@"; }
    write_config '[remote-access]' 'base_url = https://d.example'
    run plib remote_ttyd_port
    [ "$output" = "7681" ]
    run plib remote_ttyd_font_size
    [ "$output" = "" ]
    write_config '[remote-access]' 'base_url = https://d.example' \
                 'ttyd_port = 9000' 'ttyd_font_size = 20'
    run plib remote_ttyd_port
    [ "$output" = "9000" ]
    run plib remote_ttyd_font_size
    [ "$output" = "20" ]
    # The bounds that stopped an unreadable terminal are now schema-enforced.
    write_config '[remote-access]' 'base_url = https://d.example' 'ttyd_font_size = 200'
    run plib remote_ttyd_font_size
    [ "$status" -ne 0 ]
}

@test "project-lib re-exports config-lib's helpers without redefining them" {
    # One definition of each, or the two files drift.
    run grep -c '^valid_domain()' "$REPO_ROOT/bin/dejima-project-lib.sh"
    [ "$output" = "0" ]
    run grep -c '^config_root()' "$REPO_ROOT/bin/dejima-project-lib.sh"
    [ "$output" = "0" ]
    run grep -c '^valid_domain()' "$REPO_ROOT/bin/dejima-config-lib.sh"
    [ "$output" = "1" ]
    run grep -c '^config_root()' "$REPO_ROOT/bin/dejima-config-lib.sh"
    [ "$output" = "1" ]
}

@test "no script still calls the retired remote.conf accessors" {
    run grep -rn 'remote_conf_get\|remote_conf_path\|valid_remote_key\|valid_remote_value' \
        "$REPO_ROOT/bin" "$REPO_ROOT/install.sh"
    [ "$status" -ne 0 ]
}

@test "--print-config resolves every schema key" {
    write_config '[core]' 'firewall = off' '[audit]' 'keep = 3'
    run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"core.firewall=off"* ]]
    [[ "$output" == *"audit.keep=3"* ]]
    # Absent keys resolve to their defaults, expanded.
    [[ "$output" == *"core.known_hosts=$HOME/.ssh/known_hosts"* ]]
    [[ "$output" == *"credentials.transport=tls"* ]]
}

@test "--print-config emits one line per schema key and nothing else" {
    write_config '[core]' 'firewall = on'
    run "$REPO_ROOT/bin/dejima" --print-config
    expected="$(lib _config_keys | wc -l)"
    [ "$(printf '%s\n' "$output" | wc -l)" -eq "$expected" ]
}

@test "--print-config refuses an invalid config rather than printing defaults" {
    write_config '[audit]' 'keep = 0'
    run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid value"* ]]
}

@test "--print-config does not need Docker or a workspace argument" {
    write_config '[core]' 'firewall = on'
    PATH="/nonexistent:$PATH" run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ]
}

@test "core.command refuses a value with a leading dash" {
    # entrypoint.sh expands SANDBOX_CMD unquoted into `gosu "$SANDBOX_USER"
    # ${SANDBOX_CMD:-claude}` - a leading "-" would be parsed as an option to
    # gosu rather than as the command to run. --print-config exits before
    # this is wired in, so this exercises the real launch path far enough to
    # reach it (a fake HOME with a minimal settings.json, a dedicated
    # SANDBOX_SSH_KEY so the missing-agent check doesn't fire first) without
    # needing Docker, since the guard fires before any docker invocation.
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.claude"
    echo '{}' > "$FAKE_HOME/.claude/settings.json"
    key="$FAKE_HOME/sandbox-key"
    : > "$key"
    chmod 600 "$key"
    write_config '[core]' "ssh_key = $key" 'command = --evil'
    workspace="$(mktemp -d)"
    HOME="$FAKE_HOME" SSH_AUTH_SOCK= run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"core.command"* ]]
    rm -rf "$FAKE_HOME" "$workspace"
}

@test "dejima-audit takes its directories from the config" {
    store="$(mktemp -d)"
    write_config '[audit]' "dir = $store/reports" "baselines_dir = $store/base" 'keep = 4'
    run "$REPO_ROOT/bin/dejima-audit" --print-paths
    [ "$status" -eq 0 ]
    [[ "$output" == *"$store/reports"* ]]
    [[ "$output" == *"$store/base"* ]]
    rm -rf "$store"
}

@test "dejima-audit no longer reads its retired variables" {
    run grep -n 'DEJIMA_AUDIT_DIR\|DEJIMA_AUDIT_BASELINE_DIR\|DEJIMA_AUDIT_KEEP\|DEJIMA_AUDIT_STATUSLINE\|DEJIMA_AUDIT_PROJECTS_DIR' \
        "$REPO_ROOT/bin/dejima-audit"
    [ "$status" -ne 0 ]
}

@test "dejima-audit keeps its repo-root test hook" {
    run grep -q 'DEJIMA_AUDIT_REPO_ROOT' "$REPO_ROOT/bin/dejima-audit"
    [ "$status" -eq 0 ]
}

# The bug this guards against: before dejima-audit read the config too, it
# fell back to its own ${XDG_DATA_HOME:-...} formula while bin/dejima read
# the config - two different answers for the same directory, so the
# exit-time audit could snapshot/report into a store bin/dejima's own
# startup warning never looks at. An explicit config value and a case that
# only exercises the default would each have passed against that broken
# code (the divergence needs an unset-in-config default AND a non-default
# XDG_DATA_HOME to surface), so both are exercised here.
@test "bin/dejima and dejima-audit agree on audit and baseline directories with an explicit config" {
    store="$(mktemp -d)"
    write_config '[audit]' "dir = $store/reports" "baselines_dir = $store/base"
    run env XDG_DATA_HOME=/tmp/some-other-xdg "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ]
    dejima_dir="$(printf '%s\n' "$output" | grep '^audit.dir=' | cut -d= -f2-)"
    dejima_base="$(printf '%s\n' "$output" | grep '^audit.baselines_dir=' | cut -d= -f2-)"
    run env XDG_DATA_HOME=/tmp/some-other-xdg "$REPO_ROOT/bin/dejima-audit" --print-paths
    [ "$status" -eq 0 ]
    audit_dir="$(printf '%s\n' "$output" | grep '^audit_dir=' | cut -d= -f2-)"
    audit_base="$(printf '%s\n' "$output" | grep '^baselines_dir=' | cut -d= -f2-)"
    [ "$dejima_dir" = "$audit_dir" ]
    [ "$dejima_base" = "$audit_base" ]
    [ "$dejima_dir" = "$store/reports" ]
    [ "$dejima_base" = "$store/base" ]
    rm -rf "$store"
}

@test "a flag overrides the config file" {
    write_config '[core]' 'firewall = on' 'command = claude'
    run "$REPO_ROOT/bin/dejima" --print-config
    [[ "$output" == *"core.firewall=on"* ]]
    run "$REPO_ROOT/bin/dejima" --no-firewall --print-config
    [[ "$output" == *"core.firewall=off"* ]]
    run "$REPO_ROOT/bin/dejima" --cmd nvim --print-config
    [[ "$output" == *"core.command=nvim"* ]]
}

@test "a flag value is validated against the same schema type" {
    write_config '[core]' 'firewall = on'
    run "$REPO_ROOT/bin/dejima" --cmd 'rm -rf /' --print-config
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid value"* ]]
}

@test "an unknown flag is refused rather than treated as a path" {
    write_config '[core]' 'firewall = on'
    run "$REPO_ROOT/bin/dejima" --nonesuch --print-config
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown option"* ]]
}

@test "a flag requiring a value refuses to consume the next flag as one" {
    write_config '[core]' 'firewall = on'
    run "$REPO_ROOT/bin/dejima" --cmd --no-firewall --print-config
    [ "$status" -ne 0 ]
    [[ "$output" == *"--cmd"* ]]
}

@test "flags stop at -- so container arguments pass through untouched" {
    write_config '[core]' 'firewall = on'
    # A double dash means everything after it belongs to the container
    # command, including something that looks like one of our own flags.
    run "$REPO_ROOT/bin/dejima" --print-config -- --cmd nvim
    [ "$status" -eq 0 ]
    [[ "$output" != *"core.command=nvim"* ]]
}

@test "a repeated flag takes the last value, same as a repeated config key" {
    write_config '[core]' 'firewall = on' 'command = a' 'command = b'
    run lib config_get core command
    [ "$output" = "b" ]
    run "$REPO_ROOT/bin/dejima" --cmd first --cmd second --print-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"core.command=second"* ]]
    [[ "$output" != *"core.command=first"* ]]
}

@test "bin/dejima and dejima-audit agree on the default audit directory even with XDG_DATA_HOME set" {
    write_config '[core]' 'firewall = on'
    run env XDG_DATA_HOME=/tmp/some-other-xdg "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ]
    dejima_dir="$(printf '%s\n' "$output" | grep '^audit.dir=' | cut -d= -f2-)"
    dejima_base="$(printf '%s\n' "$output" | grep '^audit.baselines_dir=' | cut -d= -f2-)"
    run env XDG_DATA_HOME=/tmp/some-other-xdg "$REPO_ROOT/bin/dejima-audit" --print-paths
    [ "$status" -eq 0 ]
    audit_dir="$(printf '%s\n' "$output" | grep '^audit_dir=' | cut -d= -f2-)"
    audit_base="$(printf '%s\n' "$output" | grep '^baselines_dir=' | cut -d= -f2-)"
    [ "$dejima_dir" = "$audit_dir" ]
    [ "$dejima_base" = "$audit_base" ]
}
