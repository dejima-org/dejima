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
    # Retired variables may already be exported by whatever launched this
    # shell (a dejima session itself sets several of these) - clear them so
    # tests see a hermetic baseline instead of depending on the invoking
    # environment.
    unset GITEA_SSH_HOST GITEA_API GITEA_TOKEN_FILE GITEA_TOKEN GH_TOKEN_FILE \
        GH_TOKEN SANDBOX_CMD SANDBOX_SSH_KEY SANDBOX_SHARE_DIR SANDBOX_EXTRA_MOUNTS \
        SANDBOX_NVIM_CONFIG SANDBOX_CREDENTIAL_PROXY SANDBOX_ANTHROPIC_TRANSPORT \
        SANDBOX_LOG_CONVERSATION LOKI_URL ENABLE_FIREWALL SSH_KNOWN_HOSTS \
        ALLOW_GITHUB_PUSH DEJIMA_AUDIT_DIR DEJIMA_AUDIT_BASELINE_DIR \
        DEJIMA_AUDIT_KEEP DEJIMA_AUDIT_STRICT DEJIMA_AUDIT_STATUSLINE \
        DEJIMA_AUDIT_PROJECTS_DIR DEJIMA_DEBOUNCE_SECONDS
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

@test "config_is_set distinguishes absent, empty and defaulted" {
    write_config '[core]' 'ssh_key =' 'known_hosts = ~/x'
    # Absent entirely - not in the file at all.
    run lib config_is_set core firewall
    [ "$status" -ne 0 ]
    # Present with a value.
    run lib config_is_set core known_hosts
    [ "$status" -eq 0 ]
    # Present but empty - still "set", distinct from absent.
    run lib config_is_set core ssh_key
    [ "$status" -eq 0 ]
    # A schema default is not the same as being set: audit.keep has a
    # default (10) and config_get returns it, but it never appears in this
    # file, so config_is_set must say so - this is the whole point of the
    # function, and the bug it exists to prevent (see provider_validate_selection).
    run lib config_get audit keep
    [ "$output" = "10" ]
    run lib config_is_set audit keep
    [ "$status" -ne 0 ]
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

@test "config_is_set refuses an unknown key, like config_get does" {
    write_config '[core]' 'firewall = on'
    run lib config_is_set core nonesuch
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown config key"* ]]
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

@test "a missing config file refuses the launch and names the path" {
    rm -f "$CONFIG_DIR/config"
    run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -ne 0 ]
    [[ "$output" == *"$CONFIG_DIR/config"* ]]
    [[ "$output" == *"install.sh"* ]]
}

@test "a retired variable in the environment is named, with its new home" {
    write_config '[core]' 'firewall = on'
    GITEA_SSH_HOST=git.example run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"GITEA_SSH_HOST"* ]]
    [[ "$output" == *"no longer read"* ]]
    [[ "$output" == *"[forge.gitea] ssh_host"* ]]
}

@test "the newest retired variable is detected too" {
    write_config '[core]' 'firewall = on'
    SANDBOX_ANTHROPIC_TRANSPORT=loopback run "$REPO_ROOT/bin/dejima" --print-config
    [[ "$output" == *"SANDBOX_ANTHROPIC_TRANSPORT"* ]]
    [[ "$output" == *"[credentials] transport"* ]]
    # Named, never honoured.
    [[ "$output" == *"credentials.transport=tls"* ]]
}

@test "a clean environment produces no migration noise" {
    write_config '[core]' 'firewall = on'
    run env -u GITEA_SSH_HOST -u GITEA_API -u LOKI_URL -u SANDBOX_CMD \
        "$REPO_ROOT/bin/dejima" --print-config
    [[ "$output" != *"no longer read"* ]]
}

@test "every retired variable in the detector names a real schema key" {
    # Scoped to the detector's own table rather than the whole file: a loose
    # scan also matches operator-facing text like the "[c] continue" prompt,
    # and the fix for that must never be to reword the prompt. The "="
    # anchor matters too: every real entry is NAME=[section] key, so
    # anchoring on it excludes prose that merely contains a bracket.
    local keys
    keys="$(sed -n '/^_warn_legacy_env()/,/^}/p' "$REPO_ROOT/bin/dejima" \
            | grep -oE '=\[[a-z.-]+\] [a-z_]+' \
            | sed 's/^=\[//; s/\] /./')"
    # Asserted explicitly so a grep that silently stops matching anything
    # (e.g. after the table is reformatted) fails loudly instead of passing
    # vacuously over an empty list. 24, not 22: GITEA_TOKEN and GH_TOKEN each
    # also point at [forge.gitea]/[github] token_file, alongside the
    # corresponding _FILE row.
    [ "$(printf '%s\n' "$keys" | wc -l)" -eq 24 ]
    while IFS= read -r key; do
        run lib _config_spec "$key"
        [ "$status" -eq 0 ] || { echo "detector names unknown key: $key"; return 1; }
    done <<< "$keys"
}

@test "ALLOW_GITHUB_PUSH in the environment does not open the push path" {
    write_config '[core]' 'firewall = on'
    ALLOW_GITHUB_PUSH=1 run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALLOW_GITHUB_PUSH"* ]]
    [[ "$output" == *"no longer read"* ]]
    # --print-config exits before ALLOW_GITHUB_PUSH is exported, so this
    # exercises the real launch path far enough to reach it - same technique
    # as the core.command leading-dash test above.
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.claude"
    echo '{}' > "$FAKE_HOME/.claude/settings.json"
    key="$FAKE_HOME/sandbox-key"
    : > "$key"
    chmod 600 "$key"
    write_config '[core]' "ssh_key = $key"
    workspace="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
echo "ALLOW_GITHUB_PUSH=$ALLOW_GITHUB_PUSH" >> "$SANDBOX_TEST_DOCKER_LOG"
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    docker_log="$(mktemp)"
    HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" ALLOW_GITHUB_PUSH=1 \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -eq 0 ]
    grep -q '^ALLOW_GITHUB_PUSH=0$' "$docker_log"
    rm -rf "$FAKE_HOME" "$workspace" "$docker_log"
}

@test "a stale exported GITEA_TOKEN does not survive a missing token file" {
    write_config '[core]' 'firewall = on'
    GITEA_TOKEN=stale-secret run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"GITEA_TOKEN"* ]]
    [[ "$output" == *"no longer read"* ]]
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.claude"
    echo '{}' > "$FAKE_HOME/.claude/settings.json"
    key="$FAKE_HOME/sandbox-key"
    : > "$key"
    chmod 600 "$key"
    write_config '[core]' "ssh_key = $key" \
        '[forge.gitea]' 'token_file = /nonexistent/gitea-token'
    workspace="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
echo "GITEA_TOKEN=$GITEA_TOKEN" >> "$SANDBOX_TEST_DOCKER_LOG"
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    docker_log="$(mktemp)"
    HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" GITEA_TOKEN=stale-secret \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -eq 0 ]
    grep -q '^GITEA_TOKEN=$' "$docker_log"
    ! grep -q 'stale-secret' "$docker_log"
    rm -rf "$FAKE_HOME" "$workspace" "$docker_log"
}

@test "GITEA_TOKEN and GH_TOKEN are both named by the detector, pointing at the token file setting" {
    write_config '[core]' 'firewall = on'
    GITEA_TOKEN=x GH_TOKEN=y run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"GITEA_TOKEN"* ]]
    [[ "$output" == *"GH_TOKEN"* ]]
    [[ "$output" == *"[forge.gitea] token_file"* ]]
    [[ "$output" == *"[github] token_file"* ]]
    [[ "$output" == *"set the path, not the token"* ]]
}

@test "logging.loki_url reaches the launch environment" {
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.claude"
    echo '{}' > "$FAKE_HOME/.claude/settings.json"
    key="$FAKE_HOME/sandbox-key"
    : > "$key"
    chmod 600 "$key"
    write_config '[core]' "ssh_key = $key" \
        '[logging]' 'loki_url = https://loki.example.invalid'
    workspace="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
echo "LOKI_URL=$LOKI_URL" >> "$SANDBOX_TEST_DOCKER_LOG"
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    docker_log="$(mktemp)"
    HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -eq 0 ]
    grep -q '^LOKI_URL=https://loki.example.invalid$' "$docker_log"
    rm -rf "$FAKE_HOME" "$workspace" "$docker_log"
}

run_install() {
    stub_docker
    run env PATH="$STUB_DIR:$PATH" DEJIMA_CONFIG_DIR="$CONFIG_DIR" HOME="$CONFIG_DIR" \
        "$@" bash "$REPO_ROOT/install.sh"
}

@test "install.sh writes a starter config that validates" {
    run_install
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$CONFIG_DIR/config" ]
    run lib config_validate
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "install.sh seeds the starter config from a legacy variable" {
    run_install GITEA_SSH_HOST=git.example
    [ "$status" -eq 0 ]
    grep -q '^ssh_host = git.example$' "$CONFIG_DIR/config"
    # A seeded config must still validate - the seeded line is written
    # uncommented, so a bad legacy value would otherwise ship a config that
    # refuses every later launch.
    run lib config_validate
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "install.sh never overwrites an existing config" {
    write_config '[core]' 'firewall = off'
    run_install
    grep -q 'firewall = off' "$CONFIG_DIR/config"
    [[ "$output" == *"already"* ]]
}

@test "install.sh reports an existing remote.conf as no longer read" {
    printf 'BASE_URL=https://old.example\n' > "$CONFIG_DIR/remote.conf"
    run_install
    [[ "$output" == *"remote.conf"* ]]
    [[ "$output" == *"no longer read"* ]]
    # Reported, not deleted - it is the operator's file.
    [ -f "$CONFIG_DIR/remote.conf" ]
}

@test "the fast CI suite includes config.bats" {
    grep -q 'test/config.bats' "$REPO_ROOT/.gitea/workflows/tests.yml"
}

@test "the README documents the config file, not the retired variables" {
    # The retired variables must be gone from the setup instructions...
    run grep -nE '^\| `(SANDBOX_CMD|SANDBOX_EXTRA_MOUNTS|SANDBOX_NVIM_CONFIG|SANDBOX_SHARE_DIR|SANDBOX_CREDENTIAL_PROXY|LOKI_URL|ENABLE_FIREWALL|GITEA_SSH_HOST|GITEA_API|GITEA_TOKEN)`' \
        "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ] || { echo "README still tables retired vars:"; echo "$output"; return 1; }
    run grep -qE 'Export `GITEA_SSH_HOST`' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
    # ...and the config file must be documented in their place, by path and
    # with real section names, not merely mentioned.
    grep -q '~/.config/dejima/config' "$REPO_ROOT/README.md"
    for section in '\[core\]' '\[forge.gitea\]' '\[remote-access\]' '\[audit\]'; do
        grep -qE "$section" "$REPO_ROOT/README.md" \
            || { echo "README never documents section $section"; return 1; }
    done
}

@test "no shipped file still instructs setting a variable dejima retired" {
    # Same idea as the README test above, generalized: driven off
    # _warn_legacy_env's own table in bin/dejima, not a hardcoded list here,
    # so a future addition there is covered automatically instead of the two
    # copies drifting apart.
    local names
    names="$(sed -n '/^_warn_legacy_env() {/,/^}/p' "$REPO_ROOT/bin/dejima" \
        | grep -oE '"[A-Z_]+=' | tr -d '"=')"
    [ -n "$names" ]

    local func_start func_end
    func_start="$(grep -n '^_warn_legacy_env() {' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)"
    func_end="$(awk -v s="$func_start" 'NR>=s && /^}/ { print NR; exit }' "$REPO_ROOT/bin/dejima")"

    local name out hit=0

    # docs/ and systemd/ are pure operator-facing prose - nothing there is
    # live shell plumbing, so any mention of a retired name is either the
    # deliberate "no longer read" notice (install.sh's remote.conf one lives
    # outside these two directories, but the exclusion is kept here too in
    # case a future doc adds one) or a stale instruction.
    while IFS= read -r name; do
        out="$(grep -rnE "\b${name}\b" "$REPO_ROOT/docs" "$REPO_ROOT/systemd" 2>/dev/null \
            | grep -v 'no longer read' || true)"
        if [ -n "$out" ]; then
            echo "$out" >&2
            hit=1
        fi
    done <<< "$names"

    # bin/ and docker/entrypoint.sh still use several of these exact names as
    # live internal plumbing between bin/dejima and the container (exported
    # here, read there), so a bare mention alone is not an error - the same
    # name in docker-compose.yml's `NAME: ${NAME:-default}` form is exactly
    # that plumbing and needs no separate exclusion, since it never matches
    # either alternative below. What IS an error is a comment or a printed
    # message that hands the name to the reader as something to type:
    # "NAME=value", or "set ... NAME".
    local pattern
    while IFS= read -r name; do
        pattern="^\\s*#.*((?<!\\\$)\\b${name}=|\\bset (the )?\\\$?${name}\\b)"
        pattern="${pattern}|echo .*((?<!\\\$)\\b${name}=|\\bset (the )?\\\$?${name}\\b)"
        pattern="${pattern}|printf .*((?<!\\\$)\\b${name}=|\\bset (the )?\\\$?${name}\\b)"
        out="$(grep -nPi "$pattern" \
            "$REPO_ROOT"/bin/dejima "$REPO_ROOT"/bin/dejima-audit "$REPO_ROOT"/bin/dejima-ttyd \
            "$REPO_ROOT"/bin/dejima-notify-watch "$REPO_ROOT"/bin/dejima-attach \
            "$REPO_ROOT"/docker/entrypoint.sh 2>/dev/null || true)"
        if [ -n "$out" ]; then
            # _warn_legacy_env's own table names every retired variable this
            # way by design - allowed to match, so exclude only that range.
            out="$(printf '%s\n' "$out" | awk -F: -v f="$REPO_ROOT/bin/dejima" -v s="$func_start" -v e="$func_end" \
                '{ if ($1 == f && $2+0 >= s && $2+0 <= e) next; print }')"
        fi
        if [ -n "$out" ]; then
            echo "$out" >&2
            hit=1
        fi
    done <<< "$names"

    [ "$hit" = 0 ]
}


# --- [mounts] read_write -----------------------------------------------------

# A fake HOME with a settings.json and an ssh key, so bin/dejima gets far
# enough to build its mount arguments. Sets RW_HOME and RW_KEY for the caller
# to reference in its config - the key has to exist before the config naming
# it is written, which is why this is separate from _rw_launch below.
_rw_setup() {
    RW_HOME="$(mktemp -d)"
    mkdir -p "$RW_HOME/.claude"
    echo '{}' > "$RW_HOME/.claude/settings.json"
    RW_KEY="$RW_HOME/sandbox-key"
    : > "$RW_KEY"
    chmod 600 "$RW_KEY"
}

# Drives the real launch path with a stubbed docker that records every
# argument. A test that only read --print-config would pass against a version
# that validated the value and then never mounted it.
_rw_launch() {
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >> "$SANDBOX_TEST_DOCKER_LOG"; done
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    docker_log="$(mktemp)"
    HOME="$RW_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" \
        run "$REPO_ROOT/bin/dejima" "$1"
}

@test "a read_write entry is mounted without :ro, unlike a readonly one" {
    _rw_setup
    rw="$(mktemp -d)"
    ro="$(mktemp -d)"
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" \
                 '[mounts]' "read_write = $rw" "readonly = $ro"
    _rw_launch "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF "$rw:$rw" "$docker_log" \
        || { echo "read_write not mounted read-write:"; cat "$docker_log"; return 1; }
    grep -qxF "$ro:$ro:ro" "$docker_log" \
        || { echo "readonly lost its :ro"; return 1; }
    grep -qxF "DEJIMA_RW_MOUNTS=$rw" "$docker_log" \
        || { echo "session never told which paths persist"; return 1; }
    rm -rf "$rw" "$ro" "$workspace" "$RW_HOME" "$docker_log"
}

@test "a read_write entry overlapping a protected path is refused, not warned" {
    _rw_setup
    workspace="$(mktemp -d)"
    # Guarded paths that may not exist on a given host are created first:
    # otherwise the entry is rejected as a missing directory and the overlap
    # rule never runs, which would pass this test for the wrong reason.
    mkdir -p "$CONFIG_DIR" "$RW_HOME/.claude" "$RW_HOME/.local/bin"
    for guarded in "$CONFIG_DIR" "$RW_HOME/.claude" "$RW_HOME/.local/bin" "$REPO_ROOT"; do
        write_config '[core]' "ssh_key = $RW_KEY" '[mounts]' "read_write = $guarded"
        _rw_launch "$workspace"
        [ "$status" -ne 0 ] || { echo "accepted a writable mount over $guarded"; return 1; }
        [[ "$output" == *"Refusing"* ]] \
            || { echo "wrong failure for $guarded: $output"; return 1; }
    done
    # The workspace is already mounted read-write; naming it again is a config
    # error worth surfacing, not a harmless duplicate.
    write_config '[core]' "ssh_key = $RW_KEY" '[mounts]' "read_write = $workspace"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing"* ]]
    # A bare home directory contains several guarded paths, so the same
    # both-directions rule catches it without needing an entry of its own.
    write_config '[core]' "ssh_key = $RW_KEY" '[mounts]' "read_write = $RW_HOME"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing"* ]]
    rm -rf "$workspace" "$RW_HOME"
}

@test "a guarded path that does not exist yet is still guarded" {
    # readlink -f yields nothing unless at most the final component is
    # missing, so skipping an unresolvable guarded path would leave the audit
    # stores unprotected exactly when their parents have not been created -
    # letting a session mount a writable ancestor of the store dejima-audit is
    # about to write findings into.
    _rw_setup
    workspace="$(mktemp -d)"
    mkdir -p "$RW_HOME/data"
    write_config '[core]' "ssh_key = $RW_KEY" "share_dir = $RW_HOME/share" \
                 '[audit]' "dir = $RW_HOME/data/store/audit" \
                 '[mounts]' "read_write = $RW_HOME/data"
    [ ! -e "$RW_HOME/data/store" ]
    _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "mounted a writable ancestor of the audit store"; return 1; }
    [[ "$output" == *"Refusing"* ]]
    rm -rf "$workspace" "$RW_HOME"
}

@test "the audit and baseline stores are guarded, not just the obvious paths" {
    # Named explicitly because a regression that dropped them from the guarded
    # list would otherwise pass every other test here.
    _rw_setup
    workspace="$(mktemp -d)"
    store="$(mktemp -d)"
    # Created first, or the entry is rejected as a missing directory and the
    # overlap rule under test never runs.
    mkdir -p "$store/audit"
    for key in dir baselines_dir; do
        write_config '[core]' "ssh_key = $RW_KEY" \
                     '[audit]' "$key = $store/audit" \
                     '[mounts]' "read_write = $store/audit"
        _rw_launch "$workspace"
        [ "$status" -ne 0 ] || { echo "accepted a mount over [audit] $key"; return 1; }
        [[ "$output" == *"Refusing"* ]] || { echo "wrong failure for [audit] $key"; return 1; }
    done
    rm -rf "$workspace" "$store" "$RW_HOME"
}

@test "overlap is caught in the containment direction, not only on equality" {
    # Every other overlap case here names the guarded path exactly, which the
    # equality fast path catches without ever reaching the containment logic.
    _rw_setup
    workspace="$(mktemp -d)"
    outer="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" \
                 '[audit]' "dir = $outer/nested/audit" \
                 '[mounts]' "read_write = $outer"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "entry containing a guarded path was accepted"; return 1; }
    [[ "$output" == *"Refusing"* ]]
    rm -rf "$workspace" "$outer" "$RW_HOME"
}

@test "the same directory spelled two ways is still refused in both lists" {
    # The duplicate check compares canonical paths, so a trailing slash, a
    # "." component or a doubled slash cannot smuggle one directory into both
    # lists and leave Docker to decide which mount wins.
    _rw_setup
    workspace="$(mktemp -d)"
    for spelling in "/" "/." "//"; do
        d="$(mktemp -d)"
        write_config '[core]' "ssh_key = $RW_KEY" \
                     '[mounts]' "readonly = $d" "read_write = ${d}${spelling}"
        _rw_launch "$workspace"
        [ "$status" -ne 0 ] || { echo "both lists accepted '$d' vs '${d}${spelling}'"; return 1; }
        [[ "$output" == *"both name the same"* ]] \
            || { echo "wrong failure for spelling '$spelling': $output"; return 1; }
        rm -rf "$d"
    done
    rm -rf "$workspace" "$RW_HOME"
}

@test "a path in both read_write and readonly is refused rather than resolved by mount order" {
    _rw_setup
    d="$(mktemp -d)"
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" '[mounts]' "read_write = $d" "readonly = $d"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"both name the same"* ]]
    rm -rf "$d" "$workspace" "$RW_HOME"
}

@test "a read_write entry that is not an existing directory is refused" {
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" '[mounts]' 'read_write = /nonexistent/nowhere'
    _rw_launch "$workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not an existing directory"* ]]
    rm -rf "$workspace" "$RW_HOME"
}

@test "the briefing names writable mounts so nothing survives being called disposable" {
    run env DEJIMA=1 DEJIMA_RW_MOUNTS="/srv/one /srv/two" bash -c \
        'printf "{\"session_id\":\"t\",\"cwd\":\"$PWD\"}" | bash "$1"' _ \
        "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -eq 0 ]
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"/srv/one /srv/two"* ]]
    [[ "$ctx" == *"outlive the container too"* ]]
    # And says nothing at all when there are none, rather than an empty list.
    run env DEJIMA=1 bash -c \
        'printf "{\"session_id\":\"t\",\"cwd\":\"$PWD\"}" | bash "$1"' _ \
        "$REPO_ROOT/hooks/sandbox-context.sh"
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" != *"outlive the container too"* ]]
}

@test "a token file with an embedded newline makes bin/dejima exit non-zero, before docker is invoked" {
    # A refusal in forge_env_exports that gets swallowed by a process
    # substitution would launch anyway with a partial environment - this test
    # exercises the real launch path to verify the refusal actually stops it.
    _rw_setup
    workspace="$(mktemp -d)"
    # Configure gitea forge with a valid config plus a token file with a newline.
    printf '[core]\nfirewall = on\nssh_key = %s\n[forge.gitea]\nssh_host = git.example\napi = https://api.example\ntoken_file = %s/token\n' \
        "$RW_KEY" "$CONFIG_DIR" > "$CONFIG_DIR/config"
    printf 'real-secret\ngarbage\n' > "$CONFIG_DIR/token"
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
echo "DOCKER WAS CALLED - TEST SHOULD HAVE FAILED" >&2
exit 1
EOF
    chmod +x "$STUB_DIR/docker"
    HOME="$RW_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -ne 0 ] || { echo "bin/dejima did not fail"; return 1; }
    [[ "$output" == *"newline"* ]] || { echo "no refusal message: $output"; return 1; }
    # docker must not have been invoked at all.
    [[ "$output" != *"DOCKER WAS CALLED"* ]] \
        || { echo "docker was invoked despite the refusal"; return 1; }
    rm -rf "$workspace" "$RW_HOME" "$STUB_DIR"
}
