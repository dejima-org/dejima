#!/usr/bin/env bats
# Host-side tests for the single config file. The parser is a trust
# boundary in the weak sense that a malformed config must stop a launch
# rather than silently produce a differently-configured sandbox, so most of
# what is here is about what it refuses.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    # [forge.<name>]/[harness.<name>] schema now comes from the provider
    # manifest (dejima-provider-lib.sh), not a row hardcoded in
    # dejima-config-lib.sh - lib() sources the former, a strict superset of
    # the latter, so every existing call site still resolves.
    LIB="$REPO_ROOT/bin/dejima-provider-lib.sh"
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
    # A launch is refused without a harness, so every fixture needs one. Its
    # own [core] section, which is legal and resolves the same; a test that
    # means to omit it writes the file directly.
    # A key assignment, not the word anywhere in the arguments: a [mounts]
    # path containing "harness" would otherwise suppress the seeding.
    local _a _has=0
    for _a in "$@"; do
        [[ "$_a" =~ ^[[:space:]]*harness[[:space:]]*= ]] && _has=1
    done
    [ "$_has" -eq 1 ] || printf '[core]\nharness = claude-code\n' >> "$CONFIG_DIR/config"
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

@test "warming the config cache does not swallow the reason it is invalid" {
    # bin/dejima parses the config once in its own shell before anything reads
    # a key, so the parse survives into the subshells that do the reading. That
    # warm redirects stderr away, and the parse status is cached - so caching a
    # FAILED warm would let the real caller return the failure with the message
    # already discarded, refusing a config without ever saying why.
    #
    # Asserted on a real launch rather than on --print-config, because the warm
    # runs before either and this is the path an operator actually takes.
    write_config '[core]' 'firewall = maybe'
    local workspace; workspace="$(mktemp -d)"
    run "$REPO_ROOT/bin/dejima" "$workspace"
    rm -rf "$workspace"
    [ "$status" -ne 0 ] || { echo "an invalid config launched"; return 1; }
    [[ "$output" == *"invalid value"* ]] \
        || { echo "refused without saying why: $output"; return 1; }
    [[ "$output" == *firewall* ]] \
        || { echo "the refusal does not name the key: $output"; return 1; }
}

@test "--harness selects a harness for one launch without changing the default" {
    # A host keeps one harness as its default and reaches another when it wants
    # to. Everything else was already in place - harnesses configure side by
    # side under their own [harness.<name>] sections, and the image layer is
    # keyed on the harness name so switching switches images. Only the flag was
    # missing, which is why this is one line beside --forge and --workflow.
    write_config '[core]' 'harness = claude-code' 'forge = none' 'workflow = local-only' \
                 '[harness.cline]' 'model = m'
    run "$REPO_ROOT/bin/dejima" --print-config
    [[ "$output" == *"core.harness=claude-code"* ]] \
        || { echo "default not in effect: $output"; return 1; }
    run "$REPO_ROOT/bin/dejima" --harness cline --print-config
    [[ "$output" == *"core.harness=cline"* ]] \
        || { echo "the flag did not select it: $output"; return 1; }
    # And the file is unchanged - a flag is for one launch.
    grep -q '^harness = claude-code$' "$CONFIG_DIR/config" \
        || { echo "the flag rewrote the config file"; return 1; }
}

@test "--harness refuses a harness that does not exist" {
    # Validated against the same provider set the config key is, so a typo
    # fails at the flag rather than at plugin load with a worse message.
    write_config '[core]' 'harness = claude-code' 'forge = none' 'workflow = local-only'
    run "$REPO_ROOT/bin/dejima" --harness not-a-harness --print-config
    [ "$status" -ne 0 ] || { echo "an unknown harness was accepted"; return 1; }
    [[ "$output" == *"invalid value for --harness"* ]] || { echo "$output"; return 1; }
}

@test "--harness changes what the session is actually told, not just the printed config" {
    # The flag has to reach the composed briefing, or it would select a harness
    # for the container while the session was briefed about a different one.
    # Cline's fragment names its own resume command, which Claude Code's does
    # not, so the two are distinguishable.
    write_config '[core]' 'harness = claude-code' 'forge = none' 'workflow = local-only' \
                 '[harness.cline]' 'model = m'
    run "$REPO_ROOT/bin/dejima" --print-briefing
    [[ "$output" != *"CLINE_DATA_DIR"* ]] || { echo "default briefed as cline"; return 1; }
    run "$REPO_ROOT/bin/dejima" --harness cline --print-briefing
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"CLINE_DATA_DIR"* ]] \
        || { echo "the briefing is still the default harness's: $output"; return 1; }
}

@test "--print-config refuses an invalid config rather than printing defaults" {
    write_config '[audit]' 'keep = 0'
    run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid value"* ]]
}

@test "an invalid [core] forge reports one error, not two" {
    # config_get already prints "invalid value for [core] forge ..." and
    # returns empty; the collision-warning pass right after it used to feed
    # that empty value on to manifest_get, which failed a second time with
    # its own "invalid forge name:" line - noise on top of the real error.
    write_config '[core]' 'forge = not-a-real-forge'
    run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid value for [core] forge"* ]]
    [[ "$output" != *"invalid forge name"* ]]
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
    # forge = none, workflow = local-only: provider_validate_selection runs
    # ahead of this check, and the default gitea/worktree-pr pair is refused
    # unconfigured (see providers.bats) - this test is about core.command,
    # not about forge selection, so it sidesteps that with the honest
    # "no forge, no push" pair instead of configuring one just to get past it.
    write_config '[core]' "ssh_key = $key" 'command = --evil' 'forge = none' 'workflow = local-only'
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
    # vacuously over an empty list. 25, not 23: GITEA_TOKEN and GH_TOKEN each
    # also point at [forge.gitea]/[github] token_file, alongside the
    # corresponding _FILE row.
    [ "$(printf '%s\n' "$keys" | wc -l)" -eq 25 ]
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
    write_config '[core]' "ssh_key = $key" 'forge = none' 'workflow = local-only'
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
        '[forge.gitea]' 'ssh_host = git.example' 'api = https://api.example/v1' \
        'token_file = /nonexistent/gitea-token'
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

@test "selecting the github forge warns that [github] token_file is unused" {
    local tok="$CONFIG_DIR/push-token"
    printf 'ghp_example\n' > "$tok"
    local ro="$CONFIG_DIR/ro-token"
    printf 'ghp_readonly\n' > "$ro"
    write_config '[core]' 'forge = github' 'workflow = branch-push' \
        '[github]' "token_file = $ro" \
        '[forge.github]' "push_token_file = $tok"
    run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"[github] token_file is not used"* ]]
    [[ "$output" == *"push_token_file"* ]]
}

@test "the github token_file warning is silent for any other forge" {
    write_config '[core]' 'forge = gitea' '[github]' "token_file = $CONFIG_DIR/ro"
    run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ]
    [[ "$output" != *"is not used"* ]]
}

@test "the github token_file warning is silent when push_token_file is not also set" {
    # The warning claims GH_TOKEN comes from push_token_file - false unless
    # that is actually configured too. Wholly unconfigured (push_token_file
    # unset) is the same silent case provider_validate_selection's own
    # partial-config refusal defers to, not something to say out loud here.
    local ro="$CONFIG_DIR/ro-token"
    printf 'ghp_readonly\n' > "$ro"
    write_config '[core]' 'forge = github' "[github]" "token_file = $ro"
    run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"is not used"* ]]
}

@test "the github forge with no push_token_file leaves the read-only GH_TOKEN alone at launch" {
    # forge_env_exports must not emit `GH_TOKEN=` (empty) when
    # push_token_file is unset: `-e GH_TOKEN=` on `docker
    # compose run` overrides docker-compose.yml's own `environment: GH_TOKEN:
    # ${GH_TOKEN:-}` entry - the one carrying the independent read-only
    # [github] token_file value every session is supposed to get regardless
    # of forge. Asserted on the actual argument list handed to `docker`, not
    # on a warning, so this catches the container-facing symptom directly.
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.claude"
    echo '{}' > "$FAKE_HOME/.claude/settings.json"
    local ro="$CONFIG_DIR/ro-token"
    printf 'ghp_readonly\n' > "$ro"
    write_config '[core]' 'forge = github' 'workflow = local-only' \
        '[github]' "token_file = $ro"
    workspace="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >> "$SANDBOX_TEST_DOCKER_LOG"; done
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    docker_log="$(mktemp)"
    HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    ! grep -qxF 'GH_TOKEN=' "$docker_log" \
        || { echo "GH_TOKEN= reached docker, clobbering the read-only token"; cat "$docker_log"; return 1; }
    rm -rf "$FAKE_HOME" "$workspace" "$docker_log"
}

# Records both the environment `docker` is invoked with and its full
# argument list - the two places a resolved DEJIMA_*/ALLOW_* value can reach
# the container, and the only observable evidence of the firewall posture a
# launch actually asks for without booting one (test/runtime.bats has the
# other half, and needs Docker).
stub_docker_log() {
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
echo "ALLOW_GITHUB_PUSH=$ALLOW_GITHUB_PUSH" >> "$SANDBOX_TEST_DOCKER_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$SANDBOX_TEST_DOCKER_LOG"; done
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
}

@test "the github forge's hosts reach the push guard, never the extra-domains allowlist" {
    # entrypoint.sh folds DEJIMA_FORGE_HOSTS into EXTRA_ALLOWED_DOMAINS,
    # which init-firewall.sh resolves into the port-UNRESTRICTED
    # allowed-domains ipset and dns-proxy.sh exempts from stop-dns-rebind.
    # Right for a self-hosted forge host, a silent widening for GitHub's
    # public names - and the firewall's own startup self-check refuses to
    # bring the container up when github.com:22 is reachable without the
    # push grant, so this also used to be a container that never started.
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.claude"
    echo '{}' > "$FAKE_HOME/.claude/settings.json"
    local tok="$CONFIG_DIR/push-token"
    printf 'ghp_example\n' > "$tok"
    # A pushing workflow refuses to launch without a push credential; a
    # dedicated key file is the headless form of that, and keeps this test
    # independent of whether the host running it has an agent.
    local key="$FAKE_HOME/sandbox-key"
    : > "$key"
    chmod 600 "$key"
    write_config '[core]' 'forge = github' 'workflow = worktree-pr' \
        "ssh_key = $key" \
        '[forge.github]' "push_token_file = $tok"
    workspace="$(mktemp -d)"
    stub_docker_log
    docker_log="$(mktemp)"
    HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Nothing of this forge's in the extra-domains list at all.
    grep -qxF 'DEJIMA_FORGE_HOSTS=' "$docker_log" \
        || { echo "DEJIMA_FORGE_HOSTS was not empty:"; grep '^DEJIMA_FORGE_HOSTS' "$docker_log"; return 1; }
    # But the guard still knows them, or the push it is told to make is
    # refused inside the container.
    grep -qxF 'DEJIMA_PUSH_HOSTS=github.com ssh.github.com api.github.com' "$docker_log" \
        || { echo "push hosts wrong:"; grep '^DEJIMA_PUSH_HOSTS' "$docker_log"; return 1; }
    # And port 22 opens through the documented, logged, self-checked path.
    grep -qxF 'ALLOW_GITHUB_PUSH=1' "$docker_log" \
        || { echo "the push grant was not opened"; return 1; }
    rm -rf "$FAKE_HOME" "$workspace" "$docker_log"
}

@test "the github forge with a non-pushing workflow leaves port 22 shut" {
    # The grant is tied to the workflow actually pushing, not to the forge
    # being selected - local-only never pushes, so there is nothing to open.
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.claude"
    echo '{}' > "$FAKE_HOME/.claude/settings.json"
    local tok="$CONFIG_DIR/push-token"
    printf 'ghp_example\n' > "$tok"
    write_config '[core]' 'forge = github' 'workflow = local-only' \
        '[forge.github]' "push_token_file = $tok"
    workspace="$(mktemp -d)"
    stub_docker_log
    docker_log="$(mktemp)"
    HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF 'ALLOW_GITHUB_PUSH=0' "$docker_log" \
        || { echo "the push grant was opened for a non-pushing workflow"; return 1; }
    grep -qxF 'DEJIMA_PUSH_HOSTS=' "$docker_log"
    grep -qxF 'DEJIMA_FORGE_HOSTS=' "$docker_log"
    rm -rf "$FAKE_HOME" "$workspace" "$docker_log"
}

@test "a self-hosted forge's host still takes the extra-domains path" {
    # The other side of the same manifest key: a forge that does NOT declare
    # hosts_allowlisted_by_core keeps the behaviour that path exists for -
    # its host resolved into the allowlist, and no GitHub push grant.
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.claude"
    echo '{}' > "$FAKE_HOME/.claude/settings.json"
    local key="$FAKE_HOME/sandbox-key"
    : > "$key"
    chmod 600 "$key"
    write_config '[core]' 'forge = gitea' 'workflow = branch-push' \
        "ssh_key = $key" \
        '[forge.gitea]' 'ssh_host = git.example' 'api = https://api.example/v1' \
        'token_file = /dev/null'
    workspace="$(mktemp -d)"
    stub_docker_log
    docker_log="$(mktemp)"
    HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF 'DEJIMA_FORGE_HOSTS=git.example api.example' "$docker_log" \
        || { echo "forge hosts wrong:"; grep '^DEJIMA_FORGE_HOSTS' "$docker_log"; return 1; }
    grep -qxF 'ALLOW_GITHUB_PUSH=0' "$docker_log"
    rm -rf "$FAKE_HOME" "$workspace" "$docker_log"
}

@test "logging.loki_url reaches the launch environment" {
    FAKE_HOME="$(mktemp -d)"
    mkdir -p "$FAKE_HOME/.claude"
    echo '{}' > "$FAKE_HOME/.claude/settings.json"
    key="$FAKE_HOME/sandbox-key"
    : > "$key"
    chmod 600 "$key"
    write_config '[core]' "ssh_key = $key" 'forge = none' 'workflow = local-only' \
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

@test "install.sh reports the changed forge/workflow defaults to a config that relies on them" {
    # The defaults moved from gitea + worktree-pr to none + local-only, which
    # silently stops an existing sandbox pushing. Same stance as the
    # remote.conf notice above: a config whose meaning changed under the
    # operator gets told so, with the lines that restore the old behaviour.
    write_config '[core]' 'firewall = on'
    run_install
    [[ "$output" == *"forge = gitea"* ]]
    [[ "$output" == *"workflow = worktree-pr"* ]]
    [[ "$output" == *"local-only"* ]]
}

@test "install.sh stays quiet about the defaults once forge and workflow are explicit" {
    write_config '[core]' 'forge = none' 'workflow = local-only'
    run_install
    [[ "$output" != *"have changed"* ]]
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

    # docs/ and systemd/ are operator-facing prose, no live plumbing, so a
    # retired name there is either the deliberate "no longer read" notice, a
    # stale instruction, or one of two cases that are neither:
    #
    # - A manifest-field line (`env_export = GITEA_API=api ...`), which is
    #   providers.md quoting a manifest verbatim. These names are retired as
    #   host-side operator-set variables, not as the container-side names
    #   env_export produces.
    # - A backtick-quoted mention - prose naming a variable reads a value, it
    #   does not tell anyone to set one.
    while IFS= read -r name; do
        out="$(grep -rnE "\b${name}\b" "$REPO_ROOT/docs" "$REPO_ROOT/systemd" 2>/dev/null \
            | grep -v 'no longer read' \
            | grep -vE ':[[:space:]]*env_export[[:space:]]*=' \
            | grep -vE "\`${name}\`" || true)"
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
    HOME="$RW_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK="${RW_AGENT_SOCK-}" \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" \
        run "$REPO_ROOT/bin/dejima" "$1"
}

# A real agent, carrying nothing. `ssh-add -l` against it exits nonzero,
# which is the condition the "no identities loaded" warning keys on, and a
# handmade socket file would not reproduce it.
_empty_agent() {
    eval "$(ssh-agent -s)" >/dev/null
    RW_AGENT_SOCK="$SSH_AUTH_SOCK"
    RW_AGENT_PID="$SSH_AGENT_PID"
}
_kill_agent() { [ -n "${RW_AGENT_PID:-}" ] && kill "$RW_AGENT_PID" 2>/dev/null; return 0; }

# The forwarded agent is the fallback; [core] ssh_key is the arrangement the
# docs recommend, because it is a dedicated identity and works unattended.
# So an empty agent is only worth mentioning when nothing else can push -
# otherwise the warning fires at exactly the operators who took the advice.
# ~/.claude/file-history is keyed by session id, so nothing in its own paths
# says which project a directory belongs to. The transcript names are what
# resolve it, and this is the assertion that the resolution is right: a
# session of this workspace is mounted, one belonging to another project is
# not, and neither is one whose slug merely extends this workspace's - the
# sibling case that #104 turned on.
@test "file-history is mounted for this workspace's sessions and no others" {
    _rw_setup
    workspace="$(mktemp -d)"
    local slug sib own foreign sibling
    slug="$(printf '%s' "$workspace" | sed 's/[^a-zA-Z0-9]/-/g')"
    sib="$slug-extra"
    own=11111111-1111-1111-1111-111111111111
    foreign=22222222-2222-2222-2222-222222222222
    sibling=33333333-3333-3333-3333-333333333333
    mkdir -p "$RW_HOME/.claude/projects/$slug" \
             "$RW_HOME/.claude/projects/-some-other-project" \
             "$RW_HOME/.claude/projects/$sib"
    : > "$RW_HOME/.claude/projects/$slug/$own.jsonl"
    : > "$RW_HOME/.claude/projects/-some-other-project/$foreign.jsonl"
    : > "$RW_HOME/.claude/projects/$sib/$sibling.jsonl"
    mkdir -p "$RW_HOME/.claude/file-history/$own" \
             "$RW_HOME/.claude/file-history/$foreign" \
             "$RW_HOME/.claude/file-history/$sibling"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qF "file-history/$own" "$docker_log" \
        || { echo "own session not mounted:"; grep file-history "$docker_log"; return 1; }
    run grep -F "file-history/$foreign" "$docker_log"
    [ "$status" -ne 0 ] || { echo "another project's file-history was mounted"; return 1; }
    run grep -F "file-history/$sibling" "$docker_log"
    [ "$status" -ne 0 ] || { echo "a sibling project's file-history was mounted"; return 1; }
    rm -rf "$workspace"
}

# No default on purpose: a release changing it would move an operator who
# never chose to a different harness on upgrade.
@test "a config with no [core] harness is refused, and says what to add" {
    _rw_setup
    workspace="$(mktemp -d)"
    # Written directly, not through write_config, which seeds a harness for
    # every other fixture precisely because a launch needs one.
    printf '[core]\nssh_key = %s\nforge = none\nworkflow = local-only\n' \
        "$RW_KEY" > "$CONFIG_DIR/config"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched with no harness selected:"; echo "$output"; return 1; }
    [[ "$output" == *"[core] harness is not set"* ]]
    [[ "$output" == *"harness = claude-code"* ]]   # the line to add
    [[ "$output" == *"Available:"*"claude-code"* ]]
    rm -rf "$workspace"
}

@test "the harness schema carries no default to fall back to" {
    # Directly again: write_config seeds one, which is the whole point of it.
    printf '[core]\nforge = none\nworkflow = local-only\n' > "$CONFIG_DIR/config"
    run lib config_get core harness
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "" ]
}

# --print-config is what an operator reaches for to find out what is unset, so
# it has to survive the thing being unset.
@test "--print-config still works when no harness is selected" {
    printf '[core]\nforge = none\nworkflow = local-only\n' > "$CONFIG_DIR/config"
    run "$REPO_ROOT/bin/dejima" --print-config
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"core.harness="* ]]
    [[ "$output" != *"invalid harness name"* ]]
}

@test "an empty ssh-agent is not warned about when [core] ssh_key is set" {
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _empty_agent
    _rw_launch "$workspace"
    _kill_agent
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"no identities loaded"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

# The positive control for the test above: with no key configured the
# forwarded agent really is the only way to push, and an empty one is worth
# saying so before it fails deep into a session.
# --extra-readonly / --extra-read-write append to the config's own lists
# rather than carrying their own mount code, so these assert the mount lands
# and then that every refusal the configured form gets applies to the flag
# too. If they ever stop sharing a path, the guard tests below pass while the
# flags quietly stop being covered by them.
_rw_launch_flags() {
    local ws="$1"; shift
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
        run "$REPO_ROOT/bin/dejima" "$@" "$ws"
}

@test "--extra-readonly and --extra-read-write mount for one launch" {
    _rw_setup
    workspace="$(mktemp -d)"; ro="$(mktemp -d)"; rw="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch_flags "$workspace" --extra-readonly "$ro" --extra-read-write "$rw"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF "$ro:$ro:ro" "$docker_log" || { cat "$docker_log"; return 1; }
    grep -qxF "$rw:$rw" "$docker_log" || { cat "$docker_log"; return 1; }
    rm -rf "$workspace" "$ro" "$rw"
}

@test "the short forms are the same flags, and both are repeatable" {
    _rw_setup
    workspace="$(mktemp -d)"; a="$(mktemp -d)"; b="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch_flags "$workspace" --ro "$a" --ro "$b"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF "$a:$a:ro" "$docker_log" || { cat "$docker_log"; return 1; }
    grep -qxF "$b:$b:ro" "$docker_log" || { cat "$docker_log"; return 1; }
    rm -rf "$workspace" "$a" "$b"
}

# The flags add to the configured lists; they do not replace them. A launch
# that dropped the config's own entries would still pass the two tests above.
@test "a flag adds to [mounts] readonly rather than replacing it" {
    _rw_setup
    workspace="$(mktemp -d)"; configured="$(mktemp -d)"; extra="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[mounts]' "readonly = $configured"
    _rw_launch_flags "$workspace" --ro "$extra"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF "$configured:$configured:ro" "$docker_log" || { cat "$docker_log"; return 1; }
    grep -qxF "$extra:$extra:ro" "$docker_log" || { cat "$docker_log"; return 1; }
    rm -rf "$workspace" "$configured" "$extra"
}

# The point of appending to the same list: a flag is a way to say where, not
# a way past the refusals. Both directions, since the two lists are guarded
# by different code.
@test "--extra-readonly is refused when it names the approval store" {
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch_flags "$workspace" --ro "$CONFIG_DIR"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"Refusing --extra-readonly path"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

@test "--extra-read-write is refused when it names the approval store" {
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch_flags "$workspace" --rw "$CONFIG_DIR"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"Refusing --extra-read-write path"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

# A refusal that named "[mounts] readonly" would send someone to a config
# file that does not mention the path.
@test "a rejected flag path is reported as a flag, not as a config entry" {
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch_flags "$workspace" --ro /nonexistent-flag-path
    [ "$status" -ne 0 ]
    [[ "$output" == *"--extra-readonly path does not exist"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

# Both lists are colon-separated, so such a path cannot be represented in one
# and would split into two mounts that each fail the existence check.
@test "a flag path containing a colon is refused" {
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch_flags "$workspace" --ro /tmp/has:colon
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not contain a colon"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

# #15. Both of these reach `extra_mounts+=(-v ...)` with a path computed at
# run time, so the static grep for a literal $PROJECT_STORE / config_root
# cannot see either one - it passed throughout. [mounts] read_write has been
# guarded since it was added; these two were not.
@test "[mounts] readonly is refused when it names the approval store" {
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[mounts]' "readonly = $CONFIG_DIR"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"Refusing [mounts] readonly entry"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

# The target is discovered from a symlink rather than configured, so nothing
# had vetted it: a hook pointing into the approval store mounted the store.
@test "a ~/.claude symlink is refused when its target sits in the approval store" {
    _rw_setup
    workspace="$(mktemp -d)"
    mkdir -p "$RW_HOME/.claude/hooks" "$CONFIG_DIR/sub"
    : > "$CONFIG_DIR/sub/hook.sh"
    ln -s "$CONFIG_DIR/sub/hook.sh" "$RW_HOME/.claude/hooks/hook.sh"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"Refusing ~/.claude symlink target"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

# The ordinary case the symlink scan exists for: this repo's own hooks/ are
# symlinked into ~/.claude and must still be mounted. Without this, refusing
# everything would pass the two tests above.
@test "a ~/.claude symlink to an ordinary directory is still mounted" {
    _rw_setup
    workspace="$(mktemp -d)"
    hookdir="$(mktemp -d)"
    : > "$hookdir/hook.sh"
    mkdir -p "$RW_HOME/.claude/hooks"
    ln -s "$hookdir/hook.sh" "$RW_HOME/.claude/hooks/hook.sh"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF "$hookdir:$hookdir:ro" "$docker_log" \
        || { echo "hook target not mounted:"; cat "$docker_log"; return 1; }
    rm -rf "$workspace" "$hookdir"
}

@test "an empty ssh-agent is warned about when [core] ssh_key is not set" {
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' 'forge = none' 'workflow = local-only'
    _empty_agent
    _rw_launch "$workspace"
    _kill_agent
    [[ "$output" == *"no identities loaded"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

@test "a read_write entry is mounted without :ro, unlike a readonly one" {
    _rw_setup
    rw="$(mktemp -d)"
    ro="$(mktemp -d)"
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[mounts]' "read_write = $rw" "readonly = $ro"
    _rw_launch "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF "$rw:$rw" "$docker_log" \
        || { echo "read_write not mounted read-write:"; cat "$docker_log"; return 1; }
    grep -qxF "$ro:$ro:ro" "$docker_log" \
        || { echo "readonly lost its :ro"; return 1; }
    # The session learns which paths persist through the composed briefing
    # now (see "--print-briefing names a configured read_write directory"
    # below), not a raw DEJIMA_RW_MOUNTS env var - nothing inside the
    # container reads that any more, since hooks/sandbox-context.sh only
    # substitutes runtime placeholders into whatever briefing it is handed.
    run grep -qxF "DEJIMA_RW_MOUNTS=$rw" "$docker_log"
    [ "$status" -ne 0 ] || { echo "DEJIMA_RW_MOUNTS is still forwarded into the container"; return 1; }
    rm -rf "$rw" "$ro" "$workspace" "$RW_HOME" "$docker_log"
}

@test "--print-briefing names a configured read_write directory" {
    # Regression check: --print-briefing used to compose before
    # DEJIMA_RW_MOUNTS was resolved (that happened later, only on the real
    # launch path), so the diagnostic silently dropped this sentence even
    # though an actual session was told correctly. briefing_compose now
    # reads the same DEJIMA_RW_MOUNTS a real launch would.
    rw="$(mktemp -d)"
    # forge = none, workflow = local-only: --print-briefing now runs after
    # provider_validate_selection too, and the default gitea/worktree-pr pair
    # is refused unconfigured - this test is about the mounts sentence, not
    # forge selection.
    write_config '[core]' 'forge = none' 'workflow = local-only' \
                 '[mounts]' "read_write = $rw"
    run "$REPO_ROOT/bin/dejima" --print-briefing
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"outlive the container too: $rw"* ]]
    rm -rf "$rw"
}

@test "declaring corpus does not turn it on; approving it does" {
    # The security half, and the reason this is not simply "does the file
    # exist". .dejima/ is in the workspace, which is session-writable - so a
    # session that could turn this on by writing a file would be writing the
    # next session's system prompt. The project declares, the operator
    # approves, and bin/dejima reads only what was approved.
    local ws; ws="$(mktemp -d)"
    write_config '[core]' 'forge = none' 'workflow = local-only'
    mkdir -p "$ws/.dejima"
    printf 'commit-per-step\n' > "$ws/.dejima/corpus"

    run bash -c 'cd "$1" && "$2" --print-briefing' _ "$ws" "$REPO_ROOT/bin/dejima"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"its own commit"* ]] \
        || { echo "a declaration alone put the rule in force"; return 1; }

    yes | "$REPO_ROOT/bin/dejima-project" approve "$ws" >/dev/null 2>&1

    run bash -c 'cd "$1" && "$2" --print-briefing' _ "$ws" "$REPO_ROOT/bin/dejima"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"its own commit"* ]] \
        || { echo "approving it did not put the rule in force: $output"; return 1; }
    rm -rf "$ws"
}

@test "an unknown corpus rule is refused rather than approved and ignored" {
    # A rule nothing implements would approve cleanly, sit in the store, and
    # do nothing - which reads as being in force when it is not.
    local ws; ws="$(mktemp -d)"
    write_config '[core]' 'forge = none' 'workflow = local-only'
    mkdir -p "$ws/.dejima"
    printf 'commit-per-hour\n' > "$ws/.dejima/corpus"
    run "$REPO_ROOT/bin/dejima-project" status "$ws"
    [[ "$output" == *"commit-per-hour"* ]] || { echo "not reported at all: $output"; return 1; }
    [[ "$output" != *"pending   commit-per-hour"* ]] \
        || { echo "an unimplemented rule is offered for approval: $output"; return 1; }
    rm -rf "$ws"
}

@test "the corpus rule is resolved before --print-briefing exits" {
    # --print-briefing composes and exits early, so anything it needs has to
    # be resolved above it. DEJIMA_RW_MOUNTS was caught by exactly this once,
    # its sentence missing from the printed briefing while real sessions were
    # told correctly - a diagnostic that disagrees with the session is worse
    # than no diagnostic.
    local ws; ws="$(mktemp -d)"
    write_config '[core]' 'forge = none' 'workflow = local-only'
    mkdir -p "$ws/.dejima"
    printf 'commit-per-step\n' > "$ws/.dejima/corpus"
    yes | "$REPO_ROOT/bin/dejima-project" approve "$ws" >/dev/null 2>&1
    run bash -c 'cd "$1" && "$2" --print-briefing' _ "$ws" "$REPO_ROOT/bin/dejima"
    [[ "$output" == *"its own commit"* ]] \
        || { echo "--print-briefing disagrees with what a session would get"; return 1; }
    rm -rf "$ws"
}

@test "a read_write entry overlapping a protected path is refused, not warned" {
    _rw_setup
    workspace="$(mktemp -d)"
    # Guarded paths that may not exist on a given host are created first:
    # otherwise the entry is rejected as a missing directory and the overlap
    # rule never runs, which would pass this test for the wrong reason.
    mkdir -p "$CONFIG_DIR" "$RW_HOME/.claude" "$RW_HOME/.local/bin"
    for guarded in "$CONFIG_DIR" "$RW_HOME/.claude" "$RW_HOME/.local/bin" "$REPO_ROOT"; do
        write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                     '[mounts]' "read_write = $guarded"
        _rw_launch "$workspace"
        [ "$status" -ne 0 ] || { echo "accepted a writable mount over $guarded"; return 1; }
        [[ "$output" == *"Refusing"* ]] \
            || { echo "wrong failure for $guarded: $output"; return 1; }
    done
    # The workspace is already mounted read-write; naming it again is a config
    # error worth surfacing, not a harmless duplicate.
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[mounts]' "read_write = $workspace"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Refusing"* ]]
    # A bare home directory contains several guarded paths, so the same
    # both-directions rule catches it without needing an entry of its own.
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[mounts]' "read_write = $RW_HOME"
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
                 'forge = none' 'workflow = local-only' \
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
        write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
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
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
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
        write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
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
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[mounts]' "read_write = $d" "readonly = $d"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"both name the same"* ]]
    rm -rf "$d" "$workspace" "$RW_HOME"
}

@test "a read_write entry that is not an existing directory is refused" {
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[mounts]' 'read_write = /nonexistent/nowhere'
    _rw_launch "$workspace"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not an existing directory"* ]]
    rm -rf "$workspace" "$RW_HOME"
}

@test "the briefing names writable mounts so nothing survives being called disposable" {
    # This sentence is composed host-side now (bin/dejima-provider-lib.sh's
    # briefing_compose, via the {{writable_mounts}} placeholder) rather than
    # by the hook, which only substitutes the two runtime placeholders in
    # whatever briefing it is handed - see providers.bats for that half.
    provider_lib="$REPO_ROOT/bin/dejima-provider-lib.sh"
    run env DEJIMA_RW_MOUNTS="/srv/one /srv/two" bash -c \
        'source "$1"; briefing_compose gitea worktree-pr claude-code' _ "$provider_lib"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"/srv/one /srv/two"* ]]
    [[ "$output" == *"outlive the container too"* ]]
    # And says nothing at all when there are none, rather than an empty list.
    run bash -c 'source "$1"; briefing_compose gitea worktree-pr claude-code' _ "$provider_lib"
    [ "$status" -eq 0 ]
    [[ "$output" != *"outlive the container too"* ]]
}

@test "a token file with an embedded newline makes bin/dejima exit non-zero, before docker is invoked" {
    # A refusal in forge_env_exports that gets swallowed by a process
    # substitution would launch anyway with a partial environment - this test
    # exercises the real launch path to verify the refusal actually stops it.
    _rw_setup
    workspace="$(mktemp -d)"
    # Configure gitea forge with a valid config plus a token file with a
    # newline. forge/workflow are named explicitly because this test is about
    # a gitea token reaching the container: the shipped defaults select no
    # forge at all, so leaving them implicit would mean nothing ever reads
    # token_file and the refusal under test could never fire.
    printf '[core]\nharness = claude-code\nfirewall = on\nssh_key = %s\nforge = gitea\nworkflow = worktree-pr\n[forge.gitea]\nssh_host = git.example\napi = https://api.example\ntoken_file = %s/token\n' \
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

# --- epitaph: what a session leaves when its context dies ---------------------------------------------------
#
# What a long session worked out is in the summary Claude Code writes when it
# compacts, and that goes away with the container. The store is host-side and
# never mounted, so a later session can neither read what an earlier one
# concluded nor edit what this one is about to record (#104).

_epitaph_fixture() {
    EPI_STORE="$(mktemp -d)"
    EPI_TR="$(mktemp -d)"
    EPI_WS="$(mktemp -d)"; git -C "$EPI_WS" init -q
    EPI_SLUG="$(printf '%s' "$EPI_WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$EPI_TR/$EPI_SLUG"
    # The transcripts directory reaches the tool through the harness's own
    # config key, not as an argument: where transcripts live is the harness's,
    # and dejima-epitaph no longer knows the shape of it. `list` needs the same
    # key to report whether the session behind an epitaph is still resumable.
    write_config '[epitaph]' "dir = $EPI_STORE" \
        '[harness.claude-code]' "projects_dir = $EPI_TR"
}

# One compact_boundary carrying the metadata, then the summary itself. The
# session id matches the transcript's filename, as Claude Code's own do -
# that pairing is what `list` resolves to decide a session is still there.
_epitaph_transcript() {
    local f="$EPI_TR/$EPI_SLUG/$1.jsonl" text="${2:-worked out X}" uid="${3:-aaaabbbb}"
    local ts="${4:-2026-01-02T03:04:05.000Z}"
    {
        printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":900,"postTokens":90}}\n'
        printf '{"type":"user","isCompactSummary":true,"uuid":"%s","sessionId":"%s","timestamp":"%s","message":{"content":"%s"}}\n' "$uid" "$1" "$ts" "$text"
    } > "$f"
}

# Three epitaphs in a known order, so an index means something to assert on.
_epitaph_three() {
    _epitaph_fixture
    _epitaph_transcript s1 "the firewall drops IPv6"      aaaa1111 2026-01-02T03:04:05.000Z
    _epitaph_transcript s2 "the DNS proxy rewrote resolv" bbbb2222 2026-02-03T04:05:06.000Z
    _epitaph_transcript s3 "worked out the audit baseline" cccc3333 2026-03-04T05:06:07.000Z
    "$REPO_ROOT/bin/dejima-epitaph" save "$EPI_WS" "$EPI_TR" >/dev/null 2>&1
}

@test "an epitaph is written out of the container's reach" {
    _epitaph_fixture
    _epitaph_transcript s1 "the thing this session worked out"
    run "$REPO_ROOT/bin/dejima-epitaph" save "$EPI_WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local saved; saved="$(find "$EPI_STORE" -name '*.md')"
    [ -n "$saved" ]
    grep -q 'the thing this session worked out' "$saved"
    grep -q 'trigger: manual' "$saved"
    grep -q '900 before, 90 after' "$saved"
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "saving twice does not duplicate an epitaph already kept" {
    # `save` runs on every exit, and a session compacted three times has two
    # epitaphs an earlier run already wrote.
    _epitaph_fixture
    _epitaph_transcript s1 "once only"
    "$REPO_ROOT/bin/dejima-epitaph" save "$EPI_WS" >/dev/null 2>&1
    "$REPO_ROOT/bin/dejima-epitaph" save "$EPI_WS" >/dev/null 2>&1
    [ "$(find "$EPI_STORE" -name '*.md' | wc -l)" -eq 1 ]
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "another project's epitaphs are not collected" {
    _epitaph_fixture
    _epitaph_transcript s1 "mine"
    mkdir -p "$EPI_TR/-some-other-project"
    printf '{"type":"user","isCompactSummary":true,"uuid":"cccc","sessionId":"s-2","timestamp":"2026-01-02T03:04:05.000Z","message":{"content":"theirs"}}\n' \
        > "$EPI_TR/-some-other-project/s2.jsonl"
    "$REPO_ROOT/bin/dejima-epitaph" save "$EPI_WS" >/dev/null 2>&1
    run grep -rl 'theirs' "$EPI_STORE"
    [ "$status" -ne 0 ] || { echo "collected another project's summary"; return 1; }
    grep -rq 'mine' "$EPI_STORE"
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "no epitaph is written when [epitaph] enabled is off" {
    _epitaph_fixture
    write_config '[epitaph]' "dir = $EPI_STORE" 'enabled = off'
    _epitaph_transcript s1 "should not be kept"
    "$REPO_ROOT/bin/dejima-epitaph" save "$EPI_WS" >/dev/null 2>&1
    [ -z "$(find "$EPI_STORE" -name '*.md' 2>/dev/null)" ]
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "a slug that kept nothing gets no directory" {
    # A workspace's worktrees are slugs of its own, and they have transcripts;
    # what they mostly do not have is a compaction summary in any of them. A
    # directory per slug therefore made the store read as one entry per
    # worktree, all of them empty.
    _epitaph_fixture
    _epitaph_transcript s1 "kept"
    git -C "$EPI_WS" -c user.email=t@example.com -c user.name=t \
        commit -q --allow-empty -m init
    local wt="$EPI_WS/wt" wt_slug
    git -C "$EPI_WS" worktree add -q "$wt" -b side
    wt_slug="$(printf '%s' "$wt" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$EPI_TR/$wt_slug"
    printf '{"type":"user","message":{"content":"no summary in here"}}\n' \
        > "$EPI_TR/$wt_slug/s2.jsonl"
    # A directory an earlier run already left behind goes too.
    mkdir -p "$EPI_STORE/$wt_slug"
    "$REPO_ROOT/bin/dejima-epitaph" save "$EPI_WS" >/dev/null 2>&1
    [ ! -d "$EPI_STORE/$wt_slug" ] \
        || { echo "empty directory left for $wt_slug"; return 1; }
    [ -n "$(find "$EPI_STORE/$EPI_SLUG" -name '*.md' 2>/dev/null)" ] \
        || { echo "the workspace's own epitaph was not kept"; return 1; }
    git -C "$EPI_WS" worktree remove --force "$wt" 2>/dev/null || true
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "list shows one row per epitaph, oldest first" {
    _epitaph_three
    run "$REPO_ROOT/bin/dejima-epitaph" list "$EPI_WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -cE '^ +[0-9]+  [0-9]{4}-' <<< "$output")" -eq 3 ] || { echo "$output"; return 1; }
    # Chronological by the timestamp in the name, which is what makes an
    # index stable enough for `show <n>` to mean anything.
    grep -q '^ *1  2026-01-02' <<< "$output" || { echo "$output"; return 1; }
    grep -q '^ *3  2026-03-04' <<< "$output" || { echo "$output"; return 1; }
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "list says whether the session behind an epitaph is still resumable" {
    # Resuming the real session beats reading a summary of it, so the listing
    # has to say which of the two is still on offer.
    _epitaph_three
    run "$REPO_ROOT/bin/dejima-epitaph" list "$EPI_WS"
    [ "$(grep -c 'resumable' <<< "$output")" -eq 3 ] || { echo "$output"; return 1; }
    rm -f "$EPI_TR/$EPI_SLUG/s2.jsonl"
    run "$REPO_ROOT/bin/dejima-epitaph" list "$EPI_WS"
    [ "$(grep -c 'resumable' <<< "$output")" -eq 2 ] || { echo "$output"; return 1; }
    grep -q '^ *2  .*aged out' <<< "$output" || { echo "$output"; return 1; }
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "reading the store is not gated on [epitaph] enabled" {
    # Turning epitaph off must not strand what it already kept: the operator
    # who switches it off is the one most likely to want to look at, and get
    # rid of, what is there.
    _epitaph_three
    write_config '[epitaph]' "dir = $EPI_STORE" 'enabled = off' \
        '[harness.claude-code]' "projects_dir = $EPI_TR"
    run "$REPO_ROOT/bin/dejima-epitaph" list "$EPI_WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -cE '^ +[0-9]+  [0-9]{4}-' <<< "$output")" -eq 3 ] || { echo "$output"; return 1; }
    # Writing still is.
    _epitaph_transcript s4 "should not be kept" dddd4444 2026-04-05T06:07:08.000Z
    "$REPO_ROOT/bin/dejima-epitaph" save "$EPI_WS" "$EPI_TR" >/dev/null 2>&1
    [ "$(find "$EPI_STORE" -name '*.md' | wc -l)" -eq 3 ]
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "search finds an epitaph by content and reports its listing index" {
    # The names are a timestamp and a uuid, so nothing about a filename says
    # which session it was. Search is the only way in.
    _epitaph_three
    run "$REPO_ROOT/bin/dejima-epitaph" search "resolv" "$EPI_WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q '1 of 3' <<< "$output" || { echo "$output"; return 1; }
    # The index it prints is the position in the same listing `list` shows,
    # so `show <n>` straight after a search opens what the search found.
    grep -qE '^ *2  20260203' <<< "$output" || { echo "$output"; return 1; }
    run "$REPO_ROOT/bin/dejima-epitaph" show 2 "$EPI_WS"
    grep -q 'the DNS proxy rewrote resolv' <<< "$output" || { echo "$output"; return 1; }
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "search matching nothing says so without failing" {
    _epitaph_three
    run "$REPO_ROOT/bin/dejima-epitaph" search "nothing-in-any-of-them" "$EPI_WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q 'no epitaph matches' <<< "$output" || { echo "$output"; return 1; }
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "show writes to stdout when there is no terminal to open an editor on" {
    # `dejima-epitaph show | grep` must not try to launch an editor, and a
    # test is the same case as a pipe.
    _epitaph_three
    run env VISUAL=/bin/false EDITOR=/bin/false \
        "$REPO_ROOT/bin/dejima-epitaph" show 1 "$EPI_WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q 'the firewall drops IPv6' <<< "$output" || { echo "$output"; return 1; }
    # Newest by default.
    run env VISUAL=/bin/false "$REPO_ROOT/bin/dejima-epitaph" show "$EPI_WS"
    grep -q 'worked out the audit baseline' <<< "$output" || { echo "$output"; return 1; }
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "show opens the editor and leaves the epitaph at 0600" {
    command -v script >/dev/null 2>&1 || skip "no script(1) to allocate a pty"
    _epitaph_three
    local ed; ed="$(mktemp -d)"
    # Rewrites through a temp file and a rename, which is what an editor
    # does and what drops the mode to the umask's.
    printf '#!/bin/bash\nprintf "%%s\\n" "$1" > %s/got\nprintf edited > "$1.t" && mv "$1.t" "$1"\n' \
        "$ed" > "$ed/ed"
    chmod +x "$ed/ed"
    local f; f="$(find "$EPI_STORE" -name '*.md' | sort | head -1)"
    chmod 600 "$f"
    run env VISUAL="$ed/ed" EDITOR="$ed/ed" script -qec \
        "$REPO_ROOT/bin/dejima-epitaph show 1 $EPI_WS" /dev/null
    [ -f "$ed/got" ] || { echo "the editor was never run: $output"; return 1; }
    [ "$(cat "$ed/got")" = "$f" ] || { echo "opened $(cat "$ed/got"), wanted $f"; return 1; }
    [ "$(stat -c %a "$f")" = "600" ] \
        || { echo "left at $(stat -c %a "$f") after the editor rewrote it"; return 1; }
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS" "$ed"
}

@test "an unknown epitaph subcommand is refused" {
    _epitaph_fixture
    run "$REPO_ROOT/bin/dejima-epitaph" delete-everything "$EPI_WS"
    [ "$status" -eq 2 ] || { echo "$output"; return 1; }
    grep -q 'usage:' <<< "$output" || { echo "$output"; return 1; }
    rm -rf "$EPI_STORE" "$EPI_TR" "$EPI_WS"
}

@test "the epitaph store is not mounted into the container" {
    # The whole point: a session must not be able to read what earlier
    # sessions concluded, or edit what this one is about to record.
    run grep -n 'epitaph' "$REPO_ROOT/docker/docker-compose.yml"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    run grep -nE 'extra_mounts\+=.*epitaph' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

# The epitaph store holds every earlier session's own account of what it
# worked out, in a directory nothing mounts - that is the whole design. It
# was not in the guarded list, so an operator could name it in [mounts]
# readonly and hand a session exactly what the store exists to withhold. The
# audit and baseline stores live beside it and were guarded; this one was
# added later and was not.
@test "[mounts] readonly is refused when it names the epitaph store" {
    _rw_setup
    workspace="$(mktemp -d)"
    epi="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[epitaph]' "dir = $epi" \
                 '[mounts]' "readonly = $epi"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"Refusing [mounts] readonly entry"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace" "$epi"
}

# Writable is the worse direction: a session could edit what an earlier one
# recorded, or plant an epitaph for the operator to read as an earlier
# session's own account.
@test "[mounts] read_write is refused when it names the epitaph store" {
    _rw_setup
    workspace="$(mktemp -d)"
    epi="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[epitaph]' "dir = $epi" \
                 '[mounts]' "read_write = $epi"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"Refusing [mounts] read_write entry"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace" "$epi"
}

# --- harness plugins ------------------------------------------------------

@test "a harness with a manifest but no plugin is refused" {
    # Support is per harness and deliberate. A manifest alone would present
    # as a supported harness while none of what dejima does for a harness
    # had been written, which is the "thin drop-in manifest" this design
    # exists to prevent.
    _rw_setup
    workspace="$(mktemp -d)"
    # A provider root of its own, via the DEJIMA_PROVIDER_ROOT test hook,
    # rather than a directory added to the checkout: a suite that writes into
    # the repository it is testing leaves litter when it aborts and collides
    # with a concurrent run.
    proot="$(mktemp -d)"
    cp -a "$REPO_ROOT/forges" "$REPO_ROOT/workflows" "$REPO_ROOT/harnesses" "$proot/"
    mkdir -p "$proot/harnesses/test-no-plugin"
    printf 'command = true\n' > "$proot/harnesses/test-no-plugin/harness.conf"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 'harness = test-no-plugin'
    DEJIMA_PROVIDER_ROOT="$proot" _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"No harness plugin for 'test-no-plugin'"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace" "$proot"
}

@test "emit_mount refuses a harness state directory that overlaps a guarded store" {
    # The reason the refusal lives in emit_mount rather than in each plugin.
    # A harness's state paths are computed from config rather than written
    # down, so this is exactly the shape that reaches a mount without anyone
    # having looked at the value - the same blind spot as #15.
    _rw_setup
    workspace="$(mktemp -d)"
    audit_dir="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[audit]' "dir = $audit_dir" \
                 '[harness.claude-code]' "projects_dir = $audit_dir/projects"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"Refusing harness state mount"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace" "$audit_dir"
}

@test "a harness that cannot host a guard says so at launch" {
    # The capability bar allows a harness to be supported at a smaller guard
    # set. What it does not allow is that being invisible: an operator who
    # has these everywhere else would otherwise have to read a manifest to
    # find out they are gone here.
    _rw_setup
    workspace="$(mktemp -d)"
    proot="$(mktemp -d)"
    cp -a "$REPO_ROOT/forges" "$REPO_ROOT/workflows" "$REPO_ROOT/harnesses" "$proot/"
    # Same harness, minus two guards, so the message is the only difference.
    sed -i 's/^guards .*/guards          = bash-deny notify/' \
        "$proot/harnesses/claude-code/harness.conf"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    DEJIMA_PROVIDER_ROOT="$proot" _rw_launch "$workspace"
    [[ "$output" == *"does not support 2 of dejima's guards"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"push-guard"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"merge-guard"* ]] || { echo "$output"; return 1; }
    # What is lost has to be what is actually lost. Since the push and merge
    # guards became PATH shadows they hold whatever the harness declares, so
    # a message saying pushes are not refused would send an operator looking
    # for a hole that is not there. What a harness adds by hosting them is
    # the invocation the shadow cannot see.
    [[ "$output" == *"PATH shadow"* ]] \
        || { echo "the message overstates what an undeclared guard costs:"; echo "$output"; return 1; }
    [[ "$output" != *"pushes to hosts and branches outside the allowed set are not refused"* ]] \
        || { echo "$output"; return 1; }
    rm -rf "$workspace" "$proot"
}

@test "a harness hosting every guard says nothing about missing ones" {
    # The message must not become a line an operator learns to scroll past.
    # Matched on the report's own wording rather than the bare word "guards":
    # the not-registered warning is a different message about a different
    # problem, and this once failed on it.
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch "$workspace"
    [[ "$output" != *"does not support"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"of dejima's guards"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

@test "a harness declaring a guard dejima does not know is refused" {
    # A typo would otherwise turn a guard off silently, which is the failure
    # the declaration exists to prevent.
    _rw_setup
    workspace="$(mktemp -d)"
    proot="$(mktemp -d)"
    cp -a "$REPO_ROOT/forges" "$REPO_ROOT/workflows" "$REPO_ROOT/harnesses" "$proot/"
    sed -i 's/^guards .*/guards          = bash-deny push-gaurd/' \
        "$proot/harnesses/claude-code/harness.conf"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    DEJIMA_PROVIDER_ROOT="$proot" _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"unknown guard: push-gaurd"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace" "$proot"
}

@test "install.sh registers the selected harness's guards, gated on its declarations" {
    # Which guards exist and how they are installed is the harness's, so a
    # harness declaring fewer gets fewer - and dejima does not write a
    # config belonging to a harness the operator did not choose.
    local proot; proot="$(mktemp -d)"
    cp -a "$REPO_ROOT/forges" "$REPO_ROOT/workflows" "$REPO_ROOT/harnesses" "$proot/"
    sed -i 's/^guards .*/guards          = bash-deny/' \
        "$proot/harnesses/claude-code/harness.conf"
    run_install DEJIMA_PROVIDER_ROOT="$proot"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    run jq -r '[.hooks.PreToolUse[]?.hooks[]?.command] | join(" ")' \
        "$CONFIG_DIR/.claude/settings.json"
    [[ "$output" == *"deny-dangerous-bash.sh"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"git-push-guard.sh"* ]] \
        || { echo "registered an undeclared guard: $output"; return 1; }
    [[ "$output" != *"merge-guard.sh"* ]] \
        || { echo "registered an undeclared guard: $output"; return 1; }
    rm -rf "$proot"
}

@test "install.sh registers every guard when the harness declares them all" {
    # The shipped harness, unmodified: the behaviour this replaced, kept.
    run_install
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local cmds
    cmds="$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command,
                    .hooks.SessionStart[]?.hooks[]?.command] | join(" ")' \
        "$CONFIG_DIR/.claude/settings.json")"
    local h
    for h in sandbox-context.sh git-push-guard.sh merge-guard.sh deny-dangerous-bash.sh; do
        [[ "$cmds" == *"$h"* ]] || { echo "$h not registered: $cmds"; return 1; }
    done
    # Linked for the read-only hooks mount, but registered per session by
    # bin/dejima rather than here, where it would fire for host sessions too.
    [ -L "$CONFIG_DIR/.claude/hooks/dejima-notify.sh" ]
    [[ "$cmds" != *"dejima-notify.sh"* ]] \
        || { echo "notify registered host-wide: $cmds"; return 1; }
}

@test "install.sh registers no guards when no harness is selected" {
    # Writing one harness's config for an operator who has chosen another,
    # or none, is the coupling this removed.
    # A config that already exists is never overwritten, so this is how an
    # operator upgrading from before [core] harness was required arrives.
    printf '[core]\nforge = none\nworkflow = local-only\n' > "$CONFIG_DIR/config"
    run_install
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"No [core] harness is set"* ]] || { echo "$output"; return 1; }
    [ ! -f "$CONFIG_DIR/.claude/settings.json" ] \
        || { echo "wrote a harness config anyway"; return 1; }
}

@test "install.sh names the broken line rather than blaming the harness" {
    # A config that does not parse leaves config_get empty for every key, so
    # the harness read comes back empty too - and reporting that as "no
    # harness is set" sends the operator to a line that is already correct.
    # The key here is real: it is one a newer dejima accepts, which is how an
    # operator arrives with a config their checkout does not know yet.
    printf '[core]\nharness = claude-code\nforge = none\nworkflow = local-only\n' \
        > "$CONFIG_DIR/config"
    printf '[harness.claude-code]\nno_such_key = 1\n' >> "$CONFIG_DIR/config"
    run_install
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [[ "$output" == *"no_such_key"* ]] \
        || { echo "did not name the offending key: $output"; return 1; }
    [[ "$output" != *"No [core] harness is set"* ]] \
        || { echo "blamed the harness line, which is correct: $output"; return 1; }
    [ ! -f "$CONFIG_DIR/.claude/settings.json" ] \
        || { echo "registered guards from a config it could not read"; return 1; }
}

@test "[mounts] readonly is refused when it names the filesystem root" {
    # Root contains every guarded store, so mounting it hands the session all
    # of them at once - the approval store, the audit reports, the epitaphs.
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only' \
                 '[mounts]' "readonly = /"
    _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched anyway:"; echo "$output"; return 1; }
    [[ "$output" == *"Refusing [mounts] readonly entry"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

@test "a launch says so when the harness's hooks were never registered" {
    # install.sh registers them gated on [core] harness. An operator who set
    # that key without re-running it gets no briefing and no guards, on every
    # launch, with nothing saying why.
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    # _rw_setup writes a settings.json with no hooks in it at all.
    _rw_launch "$workspace"
    [[ "$output" == *"not in force this session"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"the session briefing"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

@test "a launch names the one guard a hand-edited config dropped" {
    # The realistic failure is all-or-nothing, so a check on the briefing
    # alone would pass here - and a session would run without the merge
    # guard, silently, which is what the report exists to prevent.
    _rw_setup
    workspace="$(mktemp -d)"
    jq -n '{hooks: {
        SessionStart: [{matcher: "startup", hooks: [{type: "command",
            command: "$HOME/.claude/hooks/sandbox-context.sh"}]}],
        PreToolUse: [{matcher: "Bash", hooks: [
            {type: "command", command: "$HOME/.claude/hooks/git-push-guard.sh"},
            {type: "command", command: "$HOME/.claude/hooks/deny-dangerous-bash.sh"}]}]}}' \
        > "$RW_HOME/.claude/settings.json"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch "$workspace"
    [[ "$output" == *"merge-guard"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"the session briefing"* ]] \
        || { echo "named something that is registered: $output"; return 1; }
    rm -rf "$workspace"
}

@test "a launch stays quiet when the harness's hooks are registered" {
    _rw_setup
    workspace="$(mktemp -d)"
    jq -n '{hooks: {
        SessionStart: [{matcher: "startup", hooks: [{type: "command",
            command: "$HOME/.claude/hooks/sandbox-context.sh"}]}],
        PreToolUse: [{matcher: "Bash", hooks: [
            {type: "command", command: "$HOME/.claude/hooks/git-push-guard.sh"},
            {type: "command", command: "$HOME/.claude/hooks/merge-guard.sh"},
            {type: "command", command: "$HOME/.claude/hooks/deny-dangerous-bash.sh"}]}]}}' \
        > "$RW_HOME/.claude/settings.json"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    _rw_launch "$workspace"
    [[ "$output" != *"not in force this session"* ]] || { echo "$output"; return 1; }
    rm -rf "$workspace"
}

# --- the harness layer ----------------------------------------------------

@test "the selected harness is built into a layer of its own, and the session runs on it" {
    # The base image carries no harness. What the session actually runs has to
    # be the layer that installed the selected one - a launch that built the
    # layer and then started the base image would be a session with no
    # harness, failing as an exec error inside the container.
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    # SANDBOX_IMAGE is what `docker compose run` is given, and it arrives in
    # the environment rather than in argv - so the stub records it. Asserting
    # on the `docker build -t` line instead would pass a launch that built the
    # layer and then started the base image, which is the mistake worth
    # catching: the session comes up without its harness.
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >> "$SANDBOX_TEST_DOCKER_LOG"; done
[ "$1" != compose ] || printf '%s\n' "${SANDBOX_IMAGE:-<unset>}" >> "$SANDBOX_TEST_IMAGE_LOG"
exit 0
STUB
    chmod +x "$STUB_DIR/docker"
    docker_log="$(mktemp)"; image_log="$(mktemp)"
    HOME="$RW_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG="$docker_log" SANDBOX_TEST_IMAGE_LOG="$image_log" \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"harness-claude-code"* ]] \
        || { echo "no harness layer was built:"; echo "$output"; return 1; }
    grep -qxF "dejima:$(id -un)-harness-claude-code" "$docker_log" \
        || { echo "the harness layer was not tagged as expected:"; cat "$docker_log"; return 1; }
    # The LAST compose invocation is the run; the first builds the base.
    local ran
    ran="$(tail -1 "$image_log")"
    [ "$ran" = "dejima:$(id -un)-harness-claude-code" ] \
        || { echo "the session ran on '$ran', not the harness layer"; cat "$image_log"; return 1; }
    rm -rf "$workspace" "$RW_HOME" "$docker_log" "$image_log"
}

@test "a harness install spec that is not a dependency spec refuses the launch" {
    # Manifest data reaching a Dockerfile RUN line built on the host, and the
    # provider directories are session-writable when dejima sandboxes its own
    # checkout - so this is refused at launch rather than trusted for having
    # come from a file dejima ships.
    _rw_setup
    workspace="$(mktemp -d)"
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/harnesses/evil" "$root/forges" "$root/workflows"
    cp -r "$REPO_ROOT/forges/." "$root/forges/"
    cp -r "$REPO_ROOT/workflows/." "$root/workflows/"
    printf 'command = evil\ninstall = npm:x$(id>/tmp/pwned)\nno_confirm_args = -y\n' \
        > "$root/harnesses/evil/harness.conf"
    write_config '[core]' "ssh_key = $RW_KEY" 'harness = evil' 'forge = none' 'workflow = local-only'
    DEJIMA_PROVIDER_ROOT="$root" _rw_launch "$workspace"
    [ "$status" -ne 0 ] || { echo "launched with an unvalidated install spec"; return 1; }
    [ ! -e /tmp/pwned ]
    rm -rf "$workspace" "$RW_HOME" "$root" "${docker_log:-}"
}

@test "the harness layer creates the harness's own state directories and environment" {
    # These were in the base image, imposed on every image dejima builds. They
    # are the selected harness's now, and have to actually reach its layer -
    # a manifest key nothing consumes would leave the directories to Docker,
    # which creates a mount's missing parent root-owned and leaves the session
    # unable to write beside it.
    _rw_setup
    workspace="$(mktemp -d)"
    write_config '[core]' "ssh_key = $RW_KEY" 'forge = none' 'workflow = local-only'
    STUB_DIR="$(mktemp -d)"
    dockerfile_log="$(mktemp)"
    cat > "$STUB_DIR/docker" <<'STUB'
#!/bin/bash
if [ "$1" = build ]; then
    nextf=0
    for a in "$@"; do
        [ "$nextf" = 1 ] && { cat "$a" >> "$SANDBOX_TEST_DOCKERFILE_LOG"; nextf=0; }
        [ "$a" = -f ] && nextf=1
    done
fi
exit 0
STUB
    chmod +x "$STUB_DIR/docker"
    HOME="$RW_HOME" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_DOCKER_LOG=/dev/null SANDBOX_TEST_DOCKERFILE_LOG="$dockerfile_log" \
        run "$REPO_ROOT/bin/dejima" "$workspace"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local df
    df="$(cat "$dockerfile_log")"
    [[ "$df" == *'mkdir -p "${SANDBOX_HOME}"/.claude '* ]] \
        || { echo "the layer creates no state directories:"; echo "$df"; return 1; }
    [[ "$df" == *'.claude/file-history'* ]] \
        || { echo "a declared directory is missing from the layer:"; echo "$df"; return 1; }
    # Owned by the session's user and 0700, which is the whole reason they are
    # pre-created rather than left to Docker.
    [[ "$df" == *'chown -R ${SANDBOX_USER}:${SANDBOX_USER}'* ]] || { echo "$df"; return 1; }
    [[ "$df" == *'chmod 700'* ]] || { echo "$df"; return 1; }
    [[ "$df" == *'ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1'* ]] \
        || { echo "the declared environment is missing from the layer:"; echo "$df"; return 1; }
    rm -rf "$workspace" "$RW_HOME" "$dockerfile_log"
}
