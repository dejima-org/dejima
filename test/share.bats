#!/usr/bin/env bats
# The per-project share directory: what a launch mounts at ~/shared, and the
# host-side CLI that says where it is.
#
# `[core] share_dir` used to be mounted whole, so every session saw every other
# session's handoff files, across projects. What is asserted here is that the
# mount is now one project's subdirectory, that an operator can still find it,
# and that the files left over from the old layout are neither hidden silently
# nor moved without being asked about.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/bin/dejima-provider-lib.sh"
    SLUG_LIB="$REPO_ROOT/bin/dejima-slug-lib.sh"
    HOST="$(mktemp -d)"
    CONFIG_DIR="$HOST/config"
    SHARE="$HOST/share"
    WS="$HOST/ws"
    mkdir -p "$CONFIG_DIR" "$SHARE" "$WS" "$HOST/home/.claude"
    echo '{}' > "$HOST/home/.claude/settings.json"
    KEY="$HOST/sandbox-key"
    : > "$KEY"
    chmod 600 "$KEY"
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR"
    # A dejima session exports several of these into every shell it starts, so
    # a test that meant "unset" by not setting them would be reading the
    # invoking environment rather than stating its own precondition.
    unset SANDBOX_SHARE_DIR SANDBOX_CMD SANDBOX_EXTRA_MOUNTS LOKI_URL \
        ENABLE_FIREWALL ALLOWED_DOMAINS
}

teardown() {
    rm -rf "$HOST" ${STUB_DIR:+"$STUB_DIR"}
}

write_config() {
    {
        printf '[core]\nharness = claude-code\nforge = none\nworkflow = local-only\n'
        printf 'update_check = off\nssh_key = %s\nshare_dir = %s\n' "$KEY" "$SHARE"
        [ "$#" -eq 0 ] || printf '%s\n' "$@"
    } > "$CONFIG_DIR/config"
}

slug() { bash -c 'source "$1"; ws_slug "$2"' _ "$SLUG_LIB" "$1"; }

share() { "$REPO_ROOT/bin/dejima-share" "$@"; }

# Drives the real launch with a stubbed docker, and records what
# SANDBOX_SHARE_DIR was when compose was invoked. Reading --print-config
# instead would pass against a version that resolved the path correctly and
# then mounted something else.
launch() {
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "${SANDBOX_SHARE_DIR-}" >> "$SANDBOX_TEST_SHARE_LOG"
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    SHARE_LOG="$HOST/share-log"
    : > "$SHARE_LOG"
    HOME="$HOST/home" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_SHARE_LOG="$SHARE_LOG" \
        run "$REPO_ROOT/bin/dejima" "${1:-$WS}"
}

# What the launch actually handed compose, deduplicated - compose is invoked
# more than once per launch and every call must agree.
mounted_share() { sort -u "$SHARE_LOG" | grep -v '^$' | head -1; }

@test "a launch mounts one project's subdirectory, not share_dir itself" {
    write_config
    launch
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(mounted_share)" = "$SHARE/projects/$(slug "$WS")" ] \
        || { echo "mounted '$(mounted_share)'"; return 1; }
    [ -d "$SHARE/projects/$(slug "$WS")" ] \
        || { echo "the launch did not create the directory it mounts"; return 1; }
}

@test "two projects get two directories" {
    local other="$HOST/other"
    mkdir -p "$other"
    write_config
    launch "$WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local first="$(mounted_share)"
    launch "$other"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$first" != "$(mounted_share)" ] \
        || { echo "both projects mounted $first"; return 1; }
}

@test "dejima-share path prints the directory a launch mounts, and creates it" {
    write_config
    run share path "$WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$output" ] || { echo "path did not create $output"; return 1; }
    local printed="$output"
    launch
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # The point of the shared layout helpers: an operator dropping a file where
    # `path` says would otherwise be dropping it where nothing reads it.
    [ "$printed" = "$(mounted_share)" ] \
        || { echo "path said $printed, the launch mounted $(mounted_share)"; return 1; }
}

@test "dejima-share path defaults to the current directory" {
    write_config
    cd "$WS"
    run share path
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "$SHARE/projects/$(slug "$WS")" ] || { echo "$output"; return 1; }
}

@test "dejima-share path refuses a directory that does not exist" {
    # It would otherwise answer a typo with a share directory nothing will
    # ever mount, which is worse than refusing: the file goes somewhere real
    # and no session sees it.
    write_config
    run share path "$HOST/no-such-project"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such directory"* ]] || { echo "$output"; return 1; }
}

@test "a launch says which files the split left behind, every time until they are gone" {
    write_config
    echo secret > "$SHARE/left-over.txt"
    launch
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"left-over.txt"* ]] \
        || { echo "the launch hid a file it stopped mounting: $output"; return 1; }
    [[ "$output" == *"dejima-share adopt"* ]] \
        || { echo "it does not say what to do about it: $output"; return 1; }
    # Said again rather than once: a file handed to a session yesterday and
    # silently not arriving today is the failure this exists against.
    launch
    [[ "$output" == *"left-over.txt"* ]] || { echo "$output"; return 1; }
    rm "$SHARE/left-over.txt"
    launch
    [[ "$output" != *"no session can see"* ]] \
        || { echo "still warning with nothing left over: $output"; return 1; }
}

@test "the per-project root is not itself reported as left behind" {
    write_config
    launch
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"no session can see"* ]] \
        || { echo "a clean share_dir warned about its own projects dir: $output"; return 1; }
}

@test "an isolated launch's share is its own, and the root is not reported as loose" {
    write_config
    # launch() takes a workspace, which --isolated refuses - so this one
    # drives the launcher directly with the same stub.
    STUB_DIR="$(mktemp -d)"
    cat > "$STUB_DIR/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "${SANDBOX_SHARE_DIR-}" >> "$SANDBOX_TEST_SHARE_LOG"
exit 0
EOF
    chmod +x "$STUB_DIR/docker"
    SHARE_LOG="$HOST/share-log"
    : > "$SHARE_LOG"
    HOME="$HOST/home" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
        SANDBOX_TEST_SHARE_LOG="$SHARE_LOG" \
        run "$REPO_ROOT/bin/dejima" --isolated
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    case "$(mounted_share)" in
        "$SHARE"/isolated/*) ;;
        *) echo "mounted '$(mounted_share)', not a directory under the isolated root"
           return 1 ;;
    esac
    [ -d "$(mounted_share)" ] \
        || { echo "the launch did not create the directory it mounts"; return 1; }
    # The root holding them is dejima's, like projects/ - so a launch must
    # not go on telling the operator about it every time as something that
    # was left behind by hand.
    [[ "$output" != *"no session can see"* ]] \
        || { echo "the isolated root was reported as left behind: $output"; return 1; }
}

@test "dejima-share list names each project and flags what is loose" {
    write_config
    share path "$WS" > /dev/null
    echo x > "$SHARE/loose-file"
    run share list
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"$(slug "$WS")"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"loose-file"* ]] || { echo "$output"; return 1; }
    # The retention story is the only one there is: nothing prunes this.
    [[ "$output" == *"Nothing prunes this"* ]] || { echo "$output"; return 1; }
}

@test "adopt moves nothing without a yes" {
    write_config
    echo keep > "$SHARE/left-over.txt"
    run bash -c 'printf "n\n" | "$1" adopt "$2"' _ "$REPO_ROOT/bin/dejima-share" "$WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$SHARE/left-over.txt" ] || { echo "declining still moved it"; return 1; }
    # And an empty answer is a no, not a prompt loop or a yes.
    run bash -c 'printf "\n" | "$1" adopt "$2"' _ "$REPO_ROOT/bin/dejima-share" "$WS"
    [ -f "$SHARE/left-over.txt" ] || { echo "an empty answer moved it"; return 1; }
}

@test "adopt moves what is loose into one project's share" {
    write_config
    echo one > "$SHARE/a.txt"
    mkdir -p "$SHARE/adir"
    echo two > "$SHARE/adir/b.txt"
    run bash -c 'printf "y\n" | "$1" adopt "$2"' _ "$REPO_ROOT/bin/dejima-share" "$WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local dest="$SHARE/projects/$(slug "$WS")"
    [ -f "$dest/a.txt" ] || { echo "a.txt did not arrive"; return 1; }
    [ -f "$dest/adir/b.txt" ] || { echo "the directory did not arrive whole"; return 1; }
    [ ! -e "$SHARE/a.txt" ] || { echo "a.txt is still loose"; return 1; }
    [ "$(cat "$dest/a.txt")" = one ] || { echo "contents changed"; return 1; }
}

@test "adopt never overwrites" {
    # Both files are the operator's and this cannot know which one they meant,
    # so the loose one stays loose and says so.
    write_config
    local dest="$SHARE/projects/$(slug "$WS")"
    mkdir -p "$dest"
    echo kept > "$dest/a.txt"
    echo incoming > "$SHARE/a.txt"
    run bash -c 'printf "y\n" | "$1" adopt "$2"' _ "$REPO_ROOT/bin/dejima-share" "$WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(cat "$dest/a.txt")" = kept ] || { echo "it overwrote the destination"; return 1; }
    [ -f "$SHARE/a.txt" ] || { echo "it removed the source it refused to move"; return 1; }
    [[ "$output" == *"already has one"* ]] || { echo "$output"; return 1; }
}

@test "adopt says so when there is nothing loose" {
    write_config
    share path "$WS" > /dev/null
    run share adopt "$WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Nothing loose"* ]] || { echo "$output"; return 1; }
}

@test "a writable mount naming the share root is refused" {
    # The ~/shared mount is per project only while nothing else hands the whole
    # of it over. A session's own share arrives without going through
    # [mounts] read_write at all, so refusing costs nothing here.
    write_config '[mounts]' "read_write = $SHARE/projects"
    mkdir -p "$SHARE/projects"
    launch
    [ "$status" -ne 0 ] || { echo "mounted every project's handoff files"; return 1; }
    [[ "$output" == *"Refusing"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"handoff"* ]] || { echo "the refusal does not say why: $output"; return 1; }
}

@test "a read-only mount naming the share root is refused too" {
    write_config
    mkdir -p "$SHARE/projects"
    launch_ro() {
        STUB_DIR="$(mktemp -d)"
        printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/docker"
        chmod +x "$STUB_DIR/docker"
        HOME="$HOST/home" PATH="$STUB_DIR:$PATH" SSH_AUTH_SOCK= \
            run "$REPO_ROOT/bin/dejima" --extra-readonly "$SHARE/projects" "$WS"
    }
    launch_ro
    [ "$status" -ne 0 ] || { echo "read-only was enough to hand it over"; return 1; }
    [[ "$output" == *"Refusing"* ]] || { echo "$output"; return 1; }
}

@test "the briefing tells the session the share directory is this project's" {
    # The agent is told to leave things in ~/shared and to pick things up
    # there. The path inside the container did not change, so what has to
    # change is what it is told about who else can read it.
    local out flat
    out="$(bash -c 'source "$1"; briefing_compose none local-only claude-code' _ "$LIB")" \
        || { echo "$out"; return 1; }
    [[ "$out" == *"~/shared"* ]] || { echo "the briefing lost ~/shared"; return 1; }
    # Flattened, because the sentence wraps: a phrase spanning a line break
    # matches nothing and the test fails on a reflow that changed no words.
    flat="$(tr '\n' ' ' <<< "$out" | tr -s ' ')"
    [[ "$flat" == *"this project's own"* ]] \
        || { echo "the briefing still reads as one directory for the host"; return 1; }
    [[ "$flat" == *"every session against this project shares it"* ]] \
        || { echo "the briefing does not say who else can read it"; return 1; }
}
