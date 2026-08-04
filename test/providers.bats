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

@test "a briefing fragment that is a symlink escaping its provider directory is refused" {
    # File-level counterpart to the directory-level checks above:
    # provider_dir contains the *directory*, but the manifest's `briefing`
    # relpath still names a filesystem entry that can itself be a symlink -
    # e.g. a compromised session on the read-write project mount replacing a
    # provider's briefing.md with a symlink to an arbitrary host file (an SSH
    # key, say). Confirmed this leaks without the fix: composing against the
    # unpatched _briefing_provider_fragment printed the planted secret text
    # verbatim, with exit 0.
    FAKE_ROOT="$(mktemp -d)"
    TARGET="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/f" "$FAKE_ROOT/workflows/w" "$FAKE_ROOT/harnesses/h"
    printf 'capabilities = pr\npr_command = x\n' > "$FAKE_ROOT/forges/f/forge.conf"
    printf 'requires = pr\npush = off\nbriefing = briefing.md\n' > "$FAKE_ROOT/workflows/w/workflow.conf"
    printf 'command = claude\n' > "$FAKE_ROOT/harnesses/h/harness.conf"
    printf 'FAKE-HOST-SECRET-abc123\n' > "$TARGET/secret"
    ln -s "$TARGET/secret" "$FAKE_ROOT/workflows/w/briefing.md"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" DEJIMA_CONFIG_DIR="$CONFIG_DIR" \
        bash -c 'source "$1"; briefing_compose f w h' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" != *"FAKE-HOST-SECRET"* ]]
    rm -rf "$TARGET"
}

@test "a briefing fragment that is a dangling symlink is refused" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/f" "$FAKE_ROOT/workflows/w" "$FAKE_ROOT/harnesses/h"
    printf 'capabilities = pr\npr_command = x\n' > "$FAKE_ROOT/forges/f/forge.conf"
    printf 'requires = pr\npush = off\nbriefing = briefing.md\n' > "$FAKE_ROOT/workflows/w/workflow.conf"
    printf 'command = claude\n' > "$FAKE_ROOT/harnesses/h/harness.conf"
    ln -s /nonexistent/target "$FAKE_ROOT/workflows/w/briefing.md"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" DEJIMA_CONFIG_DIR="$CONFIG_DIR" \
        bash -c 'source "$1"; briefing_compose f w h' _ "$LIB"
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

@test "a token file containing an embedded newline makes forge_env_exports fail" {
    printf '[forge.gitea]\ntoken_file = %s/token\n' "$CONFIG_DIR" > "$CONFIG_DIR/config"
    printf 'line1\nline2\n' > "$CONFIG_DIR/token"
    run lib forge_env_exports gitea
    [ "$status" -ne 0 ]
    [[ "$output" == *"newline"* ]]
    # The secret must never appear in the error message.
    [[ "$output" != *"line1"* ]]
    [[ "$output" != *"line2"* ]]
}

@test "a single-line token file with trailing newline works and yields one record" {
    printf '[forge.gitea]\ntoken_file = %s/token\n' "$CONFIG_DIR" > "$CONFIG_DIR/config"
    printf 'my-secret-token\n' > "$CONFIG_DIR/token"
    run lib forge_env_exports gitea
    [ "$status" -eq 0 ]
    # $(<file) strips trailing newlines, so the GITEA_TOKEN line should have no
    # embedded newline - the output includes the api and ssh_host lines too, and
    # the test is specifically about the token line surviving a trailing newline.
    # grep for just the line with content and verify it has no embedded newlines.
    token_line="$(printf '%s\n' "$output" | grep '^GITEA_TOKEN=')"
    [ "$token_line" = "GITEA_TOKEN=my-secret-token" ]
}

@test "an '&' in a substituted value survives composition literally" {
    # Regression check: bash 5.2's patsub_replacement (on by default) makes a
    # literal "&" in a ${var//pat/rep} replacement expand to the matched
    # text - here the {{writable_mounts}} token itself - which leaves the
    # marker in place instead of substituting it. [mounts] read_write's own
    # `path` type explicitly permits "&", so a value like /tmp/x/R&D made
    # bin/dejima refuse to launch with "an unresolved placeholder remains
    # after briefing composition" - confirmed directly against the unpatched
    # _briefing_substitute before this fix, which fails closed only by luck
    # of the marker containing braces.
    printf '[forge.gitea]\nssh_host = git.example\napi = https://api.example/v1\ntoken_file = /dev/null\n' \
        > "$CONFIG_DIR/config"
    run env DEJIMA_RW_MOUNTS='/tmp/x/R&D' bash -c \
        'source "$1"; briefing_compose gitea worktree-pr claude-code' _ "$LIB"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *'/tmp/x/R&D'* ]]
    [[ "$output" != *"{{"* ]]
    [[ "$output" != *"}}"* ]]
}

@test "composition substitutes the whitelist and defers the two runtime keys" {
    printf '[forge.gitea]\nssh_host = git.example\napi = https://api.example/v1\ntoken_file = /dev/null\n' \
        > "$CONFIG_DIR/config"
    run lib briefing_compose gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"gitea-pr create"* ]]
    [[ "$output" == *"git.example"* ]]
    [[ "$output" == *"@@SESSION_ID@@"* ]]
    [[ "$output" == *"@@CONTAINER_ID@@"* ]]
    # No placeholder survives composition in either spelling.
    [[ "$output" != *"{{"* ]]
    [[ "$output" != *"}}"* ]]
}

@test "an unknown placeholder is refused rather than emitted literally" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/f" "$FAKE_ROOT/workflows/w" "$FAKE_ROOT/harnesses/h"
    printf 'capabilities = pr\npr_command = x\n' > "$FAKE_ROOT/forges/f/forge.conf"
    printf 'requires = pr\npush = off\nbriefing = briefing.md\n' > "$FAKE_ROOT/workflows/w/workflow.conf"
    printf 'command = claude\n' > "$FAKE_ROOT/harnesses/h/harness.conf"
    printf 'Run {{nonesuch}} to proceed.\n' > "$FAKE_ROOT/workflows/w/briefing.md"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" DEJIMA_CONFIG_DIR="$CONFIG_DIR" \
        bash -c 'source "$1"; briefing_compose f w h' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nonesuch"* ]]
}

@test "the core fragment is present and is not provider-supplied" {
    run lib briefing_compose gitea worktree-pr claude-code
    [ "$status" -eq 0 ]
    # The containment reasoning a provider must not be able to remove.
    [[ "$output" == *"allowlist"* ]]
    [[ "$output" == *"Stay within the task"* ]]
    # And it is not reachable as a file any provider ships.
    run bash -c 'ls "$1"/workflows/*/core* "$1"/forges/*/core* 2>/dev/null' _ "$REPO_ROOT"
    [ -z "$output" ]
}

@test "a provider briefing fragment is capped" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/f" "$FAKE_ROOT/workflows/w" "$FAKE_ROOT/harnesses/h"
    printf 'capabilities = pr\npr_command = x\n' > "$FAKE_ROOT/forges/f/forge.conf"
    printf 'requires = pr\npush = off\nbriefing = briefing.md\n' > "$FAKE_ROOT/workflows/w/workflow.conf"
    printf 'command = claude\n' > "$FAKE_ROOT/harnesses/h/harness.conf"
    head -c 40000 /dev/zero | tr '\0' 'x' > "$FAKE_ROOT/workflows/w/briefing.md"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" DEJIMA_CONFIG_DIR="$CONFIG_DIR" \
        bash -c 'source "$1"; briefing_compose f w h' _ "$LIB"
    [ "${#output}" -lt 40000 ]
}

@test "every placeholder in every shipped fragment is in the whitelist" {
    found=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        while IFS= read -r ph; do
            [ -n "$ph" ] || continue
            found=1
            case "$ph" in
                pr_command|issue_command|forge_name|forge_ssh_host|blocked_branches) ;;
                container_id|project_dir|workspace_dir|session_id) ;;
                resume_command|writable_mounts) ;;
                *) echo "$f uses unknown placeholder: $ph"; return 1 ;;
            esac
        done < <(grep -oE '\{\{[a-z_]+\}\}' "$f" | tr -d '{}')
    done < <(find "$REPO_ROOT/workflows" "$REPO_ROOT/harnesses" "$REPO_ROOT/forges" -name '*.md' -o -name '*.conf')
    # Guards against a grep that silently matches nothing.
    [ "$found" = 1 ]
}

@test "the hook substitutes only the two runtime placeholders" {
    b="$(mktemp)"
    printf 'session=@@SESSION_ID@@ container=@@CONTAINER_ID@@\n' > "$b"
    run env DEJIMA=1 DEJIMA_BRIEFING_FILE="$b" bash -c \
        'printf "{\"session_id\":\"abc123\",\"cwd\":\"$PWD\"}" | bash "$1"' _ \
        "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -eq 0 ]
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"session=abc123"* ]]
    [[ "$ctx" != *"@@SESSION_ID@@"* ]]
    [[ "$ctx" != *"@@CONTAINER_ID@@"* ]]
    rm -f "$b"
}

@test "the hook handles session ids with & / and \\ without mangling them" {
    # Regression check: bash 5.2's patsub_replacement (on by default) makes "&"
    # in parameter expansion replacements expand to the matched text. A session
    # id from the harness payload (untrusted) containing "&" would defeat the
    # substitution, leaving the marker and corrupting the --resume line. The fix
    # uses prefix/suffix removal instead, which never interprets the value.
    # Covering all three special cases (& / \) ensures a future rewrite that
    # switches to sed or another mechanism doesn't regress on any of them.
    b="$(mktemp)"
    printf 'resume-cmd: dejima --resume @@SESSION_ID@@\ncontainer=@@CONTAINER_ID@@\n' > "$b"
    # Session id crafted to test each special case in the replacement context.
    # Use printf %s so the value is never interpreted by the shell.
    run env DEJIMA=1 DEJIMA_BRIEFING_FILE="$b" bash -c \
        'printf "{\"session_id\":%s,\"cwd\":\"%s\"}" "$(printf "%s" "$1" | jq -Rs .)" "$PWD" | bash "$2"' _ \
        'pr-42&rm -rf /tmp\test/path' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -eq 0 ]
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    # The session id must appear verbatim
    [[ "$ctx" == *"pr-42&rm -rf /tmp"* ]] || { echo "session id & not found"; return 1; }
    [[ "$ctx" == *"test/path"* ]] || { echo "session id path not found"; return 1; }
    # No marker may remain
    [[ "$ctx" != *"@@SESSION_ID@@"* ]] || { echo "@@SESSION_ID@@ marker remained"; return 1; }
    [[ "$ctx" != *"@@CONTAINER_ID@@"* ]] || { echo "@@CONTAINER_ID@@ marker remained"; return 1; }
    rm -f "$b"
}

@test "a missing briefing file degrades rather than failing the session" {
    run env DEJIMA=1 DEJIMA_BRIEFING_FILE=/nonexistent/briefing bash -c \
        'printf "{\"session_id\":\"x\",\"cwd\":\"$PWD\"}" | bash "$1"' _ \
        "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}

@test "the hook no longer carries the briefing text itself" {
    # The prose lives in the core fragment and the provider fragments now; a
    # copy left behind here would drift silently.
    run grep -c 'gitea-pr create' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$output" = "0" ]
    run grep -ci 'gitea' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$output" = "0" ]
}

@test "the none forge declares no capabilities, keys or hosts" {
    run lib manifest_validate forge none
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -z "$(lib manifest_get forge none capabilities)" ]
    [ -z "$(lib manifest_get forge none keys)" ]
    [ -z "$(lib manifest_get forge none requires)" ]
    # No host sources at all - this is what makes it the honest "I have no
    # forge" answer rather than a forge that merely isn't configured yet.
    [ -z "$(lib forge_hosts none)" ]
    [ -z "$(lib forge_env_exports none)" ]
}

@test "the none forge ships no CLIs into the image" {
    [ -z "$(lib manifest_get forge none install)" ]
    [ ! -d "$REPO_ROOT/forges/none/bin" ]
}

@test "a workflow needing a capability is refused against the none forge" {
    run lib provider_validate_selection none worktree-pr claude-code
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires the 'pr' capability"* ]]
}

@test "docs/providers.md documents every manifest key" {
    for axis in forge workflow harness; do
        while IFS=$'\t' read -r key _rest; do
            [ -n "$key" ] || continue
            grep -q "\`$key\`" "$REPO_ROOT/docs/providers.md" \
                || { echo "$axis key '$key' is undocumented"; return 1; }
        done < <(bash -c 'source "$1"; _manifest_table "$2"' _ "$LIB" "$axis")
    done
}

@test "no doc still points at the old gitea CLI paths" {
    run grep -rn 'bin/gitea-pr\|bin/gitea-issue' "$REPO_ROOT/README.md" \
        "$REPO_ROOT/docs" "$REPO_ROOT/install.sh"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "the briefing names a real forge host, and says nothing about one for none" {
    printf '[forge.gitea]\nssh_host = git.example\n' > "$CONFIG_DIR/config"
    run lib briefing_compose gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub read-only, the configured gitea host (git.example), plus anything"* ]]

    # workflows/local-only (Task 4) is what `forge = none` is meant to pair
    # with - none's capabilities are empty, and local-only requires none, so
    # this composes the real shipped trio rather than a throwaway workflow.
    run lib briefing_compose none local-only claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # No dangling article, no "none" read as a forge name.
    [[ "$output" == *"GitHub read-only, plus anything"* ]]
    [[ "$output" != *"configured none host"* ]]
}

@test "branch-push pushes and blocks main, but attempts no PR" {
    run lib manifest_validate workflow branch-push
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(lib manifest_get workflow branch-push push)" = "on" ]
    [ "$(lib manifest_get workflow branch-push blocked_branches)" = "main master" ]
    [ "$(lib manifest_get workflow branch-push block_merge)" = "off" ]
    [ "$(lib manifest_get workflow branch-push requires_worktree)" = "on" ]
    [ "$(lib manifest_get workflow branch-push autonomy)" = "push-branch" ]
    # Requires no capability, so it is usable against a forge that offers none.
    [ -z "$(lib manifest_get workflow branch-push requires)" ]
    run lib provider_validate_selection none branch-push claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the branch-push briefing tells the agent to stop at the push" {
    run lib briefing_compose gitea branch-push claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Push that branch"* ]]
    # It must not instruct opening a PR - that is worktree-pr's job, and this
    # workflow's whole point is that it stops earlier.
    [[ "$output" != *"create"*"PR"* ]] || { echo "branch-push briefing mentions opening a PR"; return 1; }
}

@test "local-only pushes nothing and blocks no branches" {
    run lib manifest_validate workflow local-only
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(lib manifest_get workflow local-only push)" = "off" ]
    [ "$(lib manifest_get workflow local-only block_merge)" = "off" ]
    [ "$(lib manifest_get workflow local-only requires_worktree)" = "off" ]
    [ "$(lib manifest_get workflow local-only autonomy)" = "commit" ]
    # blocked_branches is empty BECAUSE push is off - there is no push to
    # block. This pins the pair together: turning push on later without
    # revisiting this would silently allow a push to main.
    [ -z "$(lib manifest_get workflow local-only blocked_branches)" ]
}

@test "none + local-only is a valid, fully unconfigured selection" {
    run lib provider_validate_selection none local-only claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -z "$output" ]
}

@test "the github forge pushes with its own token, not the read-only one" {
    run lib manifest_validate forge github
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(lib manifest_get forge github capabilities)" = "pr issues" ]
    [ "$(lib manifest_get forge github pr_command)" = "gh pr" ]
    [ "$(lib manifest_get forge github merge_block)" = "gh pr merge" ]
    # The write-capable token is its own key. Reusing [github] token_file
    # would promote a deliberately read-only PAT to a pushing credential.
    [ "$(lib manifest_get forge github requires)" = "push_token_file" ]
    [[ "$(lib manifest_get forge github env_export)" == *"GH_TOKEN=@push_token_file"* ]]
    # Ships no CLI: gh is already in the image.
    [ -z "$(lib manifest_get forge github install)" ]
}

@test "the briefing does not call GitHub read-only when the forge can push to it" {
    # The other half of Task 2's network_allowlist resolver, tested here
    # because this is where the github forge starts existing.
    printf '[forge.github]\npush_token_file = /dev/null\n' > "$CONFIG_DIR/config"
    run lib briefing_compose github branch-push claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"GitHub read-only"* ]]
    [[ "$output" == *"GitHub, which this session can also push to"* ]]
}

@test "the github forge contributes its hosts without any config" {
    hosts="$(lib forge_hosts github)"
    for h in github.com ssh.github.com api.github.com; do
        [[ " $hosts " == *" $h "* ]] || { echo "missing $h in: $hosts"; return 1; }
    done
}

@test "an unset push_token_file yields no GH_TOKEN pair at all, not an empty one" {
    # docker-compose.yml declares GH_TOKEN itself, carrying the independent
    # read-only [github] token_file value. `-e GH_TOKEN=` (the pair
    # forge_env_exports used to emit for an unresolved value) overrides that
    # entry to empty on `docker compose run` - wholly unconfigured must stay
    # silent here, exactly like it already does for provider_validate_selection's
    # own partial-config warning, or selecting this forge with no push token
    # yet silently voids the baseline read-only access every session gets.
    printf '[core]\nforge = github\n' > "$CONFIG_DIR/config"
    run lib forge_env_exports github
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -z "$output" ]
}

@test "a configured push_token_file still yields a real GH_TOKEN pair" {
    tok="$CONFIG_DIR/push-token"
    printf 'ghp_example\n' > "$tok"
    printf '[forge.github]\npush_token_file = %s\n' "$tok" > "$CONFIG_DIR/config"
    run lib forge_env_exports github
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "GH_TOKEN=ghp_example" ]
}

@test "open-pr autonomy is refused against a forge with no pr capability" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/nopr" "$FAKE_ROOT/workflows/wants-pr" "$FAKE_ROOT/harnesses/h"
    printf 'capabilities =\n' > "$FAKE_ROOT/forges/nopr/forge.conf"
    # requires is empty, so rule 1 passes and only the autonomy rule can catch this.
    printf 'requires =\npush = on\nautonomy = open-pr\n' > "$FAKE_ROOT/workflows/wants-pr/workflow.conf"
    printf 'command = claude\n' > "$FAKE_ROOT/harnesses/h/harness.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; provider_validate_selection nopr wants-pr h' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" == *"open-pr"* ]]
}

@test "push-branch autonomy is refused when the workflow does not push" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/f" "$FAKE_ROOT/workflows/contradiction" "$FAKE_ROOT/harnesses/h"
    printf 'capabilities =\n' > "$FAKE_ROOT/forges/f/forge.conf"
    printf 'requires =\npush = off\nautonomy = push-branch\n' > "$FAKE_ROOT/workflows/contradiction/workflow.conf"
    printf 'command = claude\n' > "$FAKE_ROOT/harnesses/h/harness.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; provider_validate_selection f contradiction h' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" == *"push-branch"* ]]
}

@test "every shipped workflow's autonomy is supported by a forge that ships" {
    # worktree-pr/open-pr against gitea, branch-push against none, local-only
    # against none - the combinations the README tells operators to use.
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "gitea+worktree-pr: $output"; return 1; }
    run lib provider_validate_selection none branch-push claude-code
    [ "$status" -eq 0 ] || { echo "none+branch-push: $output"; return 1; }
    run lib provider_validate_selection none local-only claude-code
    [ "$status" -eq 0 ] || { echo "none+local-only: $output"; return 1; }
}
