#!/usr/bin/env bats
# Fast checks that don't need Docker: catch regressions in the security
# invariants that are visible directly in the repo's files, without paying
# for an image build + container boot. See runtime.bats for everything that
# actually needs a live container.

setup() {
    SANDBOX_DIR="$BATS_TEST_DIRNAME/../docker"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
}

@test "Dockerfile never installs sudo" {
    run grep -E '^\s*sudo\s*\\?\s*$' "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ]
}

@test "Dockerfile never creates a sudoers entry" {
    run grep -i "sudoers" "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ]
}

@test "Dockerfile creates a SANDBOX_USER matching the host user, not a hardcoded node" {
    grep -qE '^ARG SANDBOX_USER=node\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ARG SANDBOX_UID=1000\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ARG SANDBOX_GID=1000\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ARG SANDBOX_HOME=/home/node\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -q 'useradd -u "$SANDBOX_UID" -g "$SANDBOX_GID" -m -d "$SANDBOX_HOME"' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ENV SANDBOX_USER=\$SANDBOX_USER\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ENV SANDBOX_HOME=\$SANDBOX_HOME\s*$' "$SANDBOX_DIR/Dockerfile"
    # No literal "USER node" anywhere - the mid-build USER switch must use
    # the parametrized variable, not the old hardcoded name.
    run grep -E '^USER\s+node\s*$' "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ]
    grep -qE '^USER\s+\$SANDBOX_USER\s*$' "$SANDBOX_DIR/Dockerfile"
}

@test "entrypoint.sh drops privilege via SANDBOX_USER, not a literal node" {
    run grep -E 'gosu node\b' "$SANDBOX_DIR/entrypoint.sh"
    [ "$status" -ne 0 ]
    grep -q 'gosu "$SANDBOX_USER"' "$SANDBOX_DIR/entrypoint.sh"
}

@test "Playwright is installed and require()-able globally" {
    # A global npm install only puts the CLI on PATH, not the module on
    # Node's require() resolution path - NODE_PATH is what makes
    # require("playwright") work from any script, not just one with its own
    # local node_modules (see runtime.bats for the actual launch test).
    grep -q 'npm install -g playwright' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^\s*ENV\s+NODE_PATH=' "$SANDBOX_DIR/Dockerfile"
}

# One awk pass rather than a grep chain: a filtering grep exits 1 when it
# discards every line, which here is the "nothing wrong" case, so the chain
# would report its own success as a failure. Comment lines are skipped - one
# of them quotes, verbatim, the invocation the second test bans.
@test "every build-time download in the Dockerfile retries rather than dying on one blip" {
    # These fetches all sit below the SANDBOX_* ARGs, so any build overriding
    # one of those - test/runtime.bats' first test, or simply a host whose uid
    # isn't 1000 - invalidates the cache and re-runs every one of them. The
    # odds that matter are then the odds of *any* of them blipping, not of a
    # particular one, and a single-shot fetch turns that into a dead build.
    local unguarded
    unguarded=$(awk '
        /^[[:space:]]*#/ { next }
        /wget/ && !/--tries=[0-9]/ { print FNR": "$0 }
        /curl/ && !/--retry [0-9]/ { print FNR": "$0 }
    ' "$SANDBOX_DIR/Dockerfile")
    [ -z "$unguarded" ] || {
        echo "these downloads have no retry flags:" >&2
        echo "$unguarded" >&2
        false
    }
}

# The runtime counterpart of the test above. Build-time downloads have had a
# retry guard for a while; the fetches that run on every container START had
# nothing, which is the worse place for it - a dead build is obvious, and a
# container that never comes up reads as the sandbox being broken.
@test "every fetch in the container's startup path has a deadline" {
    # curl has no default overall timeout. --connect-timeout alone is not one
    # either: it bounds reaching the far end, not a transfer that connects and
    # then stalls, which is the shape that hangs a startup indefinitely.
    local unguarded
    unguarded=$(awk '
        /^[[:space:]]*#/ { next }
        /curl/ && /https?:\/\// && !/--max-time [0-9]/ { print FILENAME": "FNR": "$0 }
    ' "$SANDBOX_DIR"/*.sh)
    [ -z "$unguarded" ] || {
        echo "these runtime fetches have no --max-time, so they can hang a container start:" >&2
        echo "$unguarded" >&2
        false
    }
}

@test "the GitHub ranges fetch reports its own failure instead of letting set -e swallow it" {
    # init-firewall.sh runs under `set -euo pipefail`, so a bare
    # `var=$(curl ...)` that fails takes the whole script down ON THE
    # ASSIGNMENT - before any of the diagnostics written for exactly that case
    # can run. The container then exits having printed nothing after "Looking
    # up GitHub's IP ranges...", and the only symptom anyone sees is that the
    # sandbox did not start. It cost two CI rounds to not diagnose (#59).
    #
    # The fix is to capture curl's status rather than let set -e have it, so
    # this checks the fetch is not a bare assignment again.
    grep -q 'set -euo pipefail' "$SANDBOX_DIR/init-firewall.sh"
    # Continuations are joined before matching: the fetch spans two lines, and
    # the `||` that makes it safe is on the second one - so a line-at-a-time
    # pass would report the correct form as the broken one.
    local bare
    bare=$(awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            start = FNR
            while (line ~ /\\$/ && (getline) > 0) {
                sub(/\\$/, "", line)
                line = line $0
            }
            if (line ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$\(curl/ && line !~ /\|\|/)
                print start": "line
        }
    ' "$SANDBOX_DIR/init-firewall.sh")
    [ -z "$bare" ] || {
        echo "this fetch is a bare assignment, so set -e will kill the script before it can report:" >&2
        echo "$bare" >&2
        false
    }
    # And that the failure path actually says something. The message is what
    # separates "GitHub was unreachable" from "the sandbox is broken".
    grep -q "could not fetch GitHub's IP ranges" "$SANDBOX_DIR/init-firewall.sh"
}

@test "every startup script reports where it aborted instead of dying silently" {
    # `set -e` alone aborts with no output whatsoever. For a script that runs
    # during container startup that is the worst possible failure mode: the
    # container just never appears, and every cause - a failed lookup, a full
    # ipset, an unreachable API - presents identically, as "the sandbox is
    # broken". Three CI failures were spent on two different instances of it.
    #
    # log-shipper.sh is deliberately absent: it does not use -e at all, on
    # purpose, because one bad line should not kill the tailer.
    local script
    for script in init-firewall.sh dns-proxy.sh entrypoint.sh; do
        # -E, not just -e: without errtrace the handler does not fire inside
        # functions or subshells, which is where the fetch and the loops live.
        grep -qE '^set -Eeuo pipefail$' "$SANDBOX_DIR/$script" \
            || { echo "$script does not set -E, so its ERR trap would not fire in functions" >&2; false; }
        grep -q "trap .*ERR" "$SANDBOX_DIR/$script" \
            || { echo "$script has no ERR trap - a set -e abort in it would be silent" >&2; false; }
        # Naming itself matters: three scripts run back to back into the same
        # log, and "aborted at line 128" is useless without knowing whose.
        grep -q "aborted at line" "$SANDBOX_DIR/$script"
        grep -q "$script aborted" "$SANDBOX_DIR/$script" \
            || { echo "$script's ERR trap does not name $script" >&2; false; }
    done
}

@test "the ERR trap actually resolves the line and the command" {
    # Extracted from the real file rather than retyped, so a trap that has been
    # broken into single quotes - which would expand $LINENO and $BASH_COMMAND
    # at definition time and report the trap's own line forever - fails here.
    local trapline
    trapline=$(grep -m1 "trap .*ERR" "$SANDBOX_DIR/init-firewall.sh")
    cat > "$BATS_TEST_TMPDIR/probe.sh" <<EOF
set -Eeuo pipefail
$trapline
echo "Looking up files.pythonhosted.org..."
false
echo "should not be reached"
EOF
    run bash "$BATS_TEST_TMPDIR/probe.sh"
    [ "$status" -ne 0 ]
    [[ "$output" != *"should not be reached"* ]]
    [[ "$output" == *"init-firewall.sh aborted at line 4"* ]] \
        || { echo "trap did not report the failing line:" >&2; echo "$output" >&2; false; }
    [[ "$output" == *"false"* ]] \
        || { echo "trap did not report the failing command:" >&2; echo "$output" >&2; false; }
}

# The behaviour behind the two greps above, driven for real. init-firewall.sh
# cannot be sourced - it flushes iptables at the top level - so the function is
# extracted and run against a stubbed curl. No container, no network.
#
# `sleep` is shadowed by a no-op: the retry delays are deliberate in production
# and pure cost here.
run_fetch() {
    local behaviour="$1"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    cp "$behaviour" "$STUB_DIR/curl"
    chmod +x "$STUB_DIR/curl"
    PATH="$STUB_DIR:$PATH"
    sleep() { :; }
    eval "$(sed -n '/^fetch_github_ranges()/,/^}/p' "$SANDBOX_DIR/init-firewall.sh")"
    gh_auth=()
    fetch_github_ranges
}

# A minimal but structurally valid /meta response - enough for the .web/.api/
# .git check the function makes.
meta_json() {
    printf '{"web":["192.0.2.0/24"],"api":["192.0.2.0/24"],"git":["192.0.2.0/24"]}'
}

@test "the ranges fetch returns the body when GitHub answers" {
    cat > "$BATS_TEST_TMPDIR/ok" <<EOF
#!/bin/bash
printf '%s' '$(meta_json)'
EOF
    run run_fetch "$BATS_TEST_TMPDIR/ok"
    [ "$status" -eq 0 ]
    [ "$output" = "$(meta_json)" ]
}

@test "the ranges fetch reports a failing curl rather than dying on the assignment" {
    # 28 is curl's operation-timeout. Before the fix this case never reached a
    # message at all: set -e took the script down on the assignment itself.
    cat > "$BATS_TEST_TMPDIR/timeout" <<'EOF'
#!/bin/bash
echo "curl: (28) Operation timed out" >&2
exit 28
EOF
    run run_fetch "$BATS_TEST_TMPDIR/timeout"
    [ "$status" -ne 0 ]
    [[ "$output" == *"attempt 1/3: curl exited 28"* ]]
    [[ "$output" == *"attempt 3/3: curl exited 28"* ]]
    # curl's own reason has to survive too - it is the difference between
    # "GitHub was slow" and "DNS is broken in here".
    [[ "$output" == *"Operation timed out"* ]]
}

@test "the ranges fetch retries an API error body and surfaces its message" {
    # A rate limit answers 200-with-a-message or 403-with-a-message, not a
    # transport error, so curl exits 0 and only the response check catches it.
    # A burst of container starts is exactly what trips it, and it clears on
    # its own - so it has to be retried, which curl's own --retry would not do.
    cat > "$BATS_TEST_TMPDIR/ratelimited" <<'EOF'
#!/bin/bash
printf '%s' '{"message":"API rate limit exceeded"}'
EOF
    run run_fetch "$BATS_TEST_TMPDIR/ratelimited"
    [ "$status" -ne 0 ]
    [[ "$output" == *"API rate limit exceeded"* ]]
    [[ "$output" == *"attempt 3/3"* ]]
}

@test "the ranges fetch recovers when a later attempt succeeds" {
    # The point of retrying at all: one blip must cost seconds, not the launch.
    cat > "$BATS_TEST_TMPDIR/flaky" <<EOF
#!/bin/bash
n="\$BATS_TEST_TMPDIR/attempts"
count=\$(cat "\$n" 2>/dev/null || echo 0)
echo \$((count + 1)) > "\$n"
if [ "\$count" -lt 1 ]; then exit 7; fi
printf '%s' '$(meta_json)'
EOF
    run run_fetch "$BATS_TEST_TMPDIR/flaky"
    [ "$status" -eq 0 ]
    [[ "$output" == *"attempt 1/3: curl exited 7"* ]]
    [[ "$output" == *"$(meta_json)"* ]]
}

# Same harness, for the domain loop - the other place a silent `set -e` abort
# stopped a container mid-startup, at a different domain each time.
run_resolve() {
    local behaviour="$1" domain="${2:-files.pythonhosted.org}"
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    cp "$behaviour" "$STUB_DIR/dig"
    chmod +x "$STUB_DIR/dig"
    PATH="$STUB_DIR:$PATH"
    sleep() { :; }
    eval "$(sed -n '/^resolve_domain()/,/^}/p' "$SANDBOX_DIR/init-firewall.sh")"
    resolve_domain "$domain"
}

@test "domain resolution returns the A records dig answered with" {
    cat > "$BATS_TEST_TMPDIR/ok" <<'EOF'
#!/bin/bash
echo "files.pythonhosted.org.	60	IN	A	151.101.64.223"
echo "files.pythonhosted.org.	60	IN	A	151.101.128.223"
EOF
    run run_resolve "$BATS_TEST_TMPDIR/ok"
    [ "$status" -eq 0 ]
    [ "$output" = "151.101.64.223
151.101.128.223" ]
}

@test "a failing dig is reported rather than killing the script on the assignment" {
    # This is the one that aborted CI: `ips=$(dig ... | awk ...)` under
    # pipefail, with dig exiting non-zero. No message, no container.
    cat > "$BATS_TEST_TMPDIR/servfail" <<'EOF'
#!/bin/bash
echo ";; connection timed out; no servers could be reached" >&2
exit 9
EOF
    run run_resolve "$BATS_TEST_TMPDIR/servfail"
    [ "$status" -ne 0 ]
    [[ "$output" == *"attempt 1/3: dig exited 9"* ]]
    [[ "$output" == *"attempt 3/3: dig exited 9"* ]]
    [[ "$output" == *"no servers could be reached"* ]]
}

@test "an answer with no A records is distinguished from a failing lookup" {
    # A CNAME-only answer, or one dnsmasq's stop-dns-rebind refused. Both look
    # like an empty A list, and the raw answer is what tells them apart.
    cat > "$BATS_TEST_TMPDIR/cname" <<'EOF'
#!/bin/bash
echo "release-assets.githubusercontent.com. 60 IN CNAME example.map.fastly.net."
EOF
    run run_resolve "$BATS_TEST_TMPDIR/cname" release-assets.githubusercontent.com
    [ "$status" -ne 0 ]
    [[ "$output" == *"no A records"* ]]
    [[ "$output" == *"CNAME"* ]]
    [[ "$output" != *"dig exited"* ]]
}

@test "domain resolution recovers when a later attempt answers" {
    cat > "$BATS_TEST_TMPDIR/flaky" <<'EOF'
#!/bin/bash
n="$BATS_TEST_TMPDIR/digs"
count=$(cat "$n" 2>/dev/null || echo 0)
echo $((count + 1)) > "$n"
if [ "$count" -lt 1 ]; then exit 9; fi
echo "files.pythonhosted.org.	60	IN	A	151.101.64.223"
EOF
    run run_resolve "$BATS_TEST_TMPDIR/flaky"
    [ "$status" -eq 0 ]
    [[ "$output" == *"attempt 1/3: dig exited 9"* ]]
    [[ "$output" == *"151.101.64.223"* ]]
}

@test "each dig attempt is bounded, so one unanswered lookup cannot eat the budget" {
    # dig's defaults are 5s x 3 tries. Three attempts of that is 45s spent on
    # one domain, inside a startup the test suite gives 120s in total.
    grep -qE 'dig .*\+time=[0-9]+ \+tries=[0-9]+' "$SANDBOX_DIR/init-firewall.sh"
}

@test "the extra-domains loop resolves through the same path, so non-fatal is true" {
    # Its comment says failures there are non-fatal. With a bare
    # `ips=$(dig ... | awk ...)` that held for a domain that resolved to
    # nothing and not for one whose lookup errored - pipefail took the whole
    # script down instead of warning and skipping.
    local bare
    bare=$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*ips=\$\(dig/ { print FNR": "$0 }
    ' "$SANDBOX_DIR/init-firewall.sh")
    [ -z "$bare" ] || {
        echo "a dig is still assigned directly, so pipefail can kill the script:" >&2
        echo "$bare" >&2
        false
    }
    grep -q 'if ! ips=$(resolve_domain "$domain"); then' "$SANDBOX_DIR/init-firewall.sh"
}

@test "an empty response is reported as empty, not as a missing field" {
    cat > "$BATS_TEST_TMPDIR/empty" <<'EOF'
#!/bin/bash
exit 0
EOF
    run run_fetch "$BATS_TEST_TMPDIR/empty"
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty response"* ]]
}

@test "the zsh installer runs from a file, so a failed download fails the build" {
    # Upstream documents `sh -c "$(wget -O- ...)"`. In that form a failed
    # download substitutes to an empty string and `sh -c ""` exits 0, so the
    # build goes green having installed nothing - the kind of failure that
    # only surfaces later, as a shell that is inexplicably unconfigured.
    local substituted
    substituted=$(awk '
        /^[[:space:]]*#/ { next }
        /sh -c "\$\((wget|curl)/ { print FNR": "$0 }
    ' "$SANDBOX_DIR/Dockerfile")
    [ -z "$substituted" ] || {
        echo "a failed download here would exit 0 and install nothing:" >&2
        echo "$substituted" >&2
        false
    }
    grep -q -- '-O /tmp/zsh-in-docker.sh' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^\s*sh /tmp/zsh-in-docker.sh' "$SANDBOX_DIR/Dockerfile"
}

@test "every ipset add in init-firewall.sh is duplicate-safe" {
    # Same bug class that broke firewall startup twice (718f6b7, a86fefc):
    # ipset add without -exist errors on a duplicate entry, and set -e turns
    # that into the whole firewall - and thus the whole container - failing
    # to start with no clear error surfaced to the user. Every "ipset add"
    # line must either pass -exist or already be wrapped so a failure can't
    # propagate (e.g. `|| true`).
    while IFS= read -r line; do
        case "$line" in
            *-exist*) continue ;;
            *"|| true"*) continue ;;
        esac
        echo "unsafe ipset add: $line"
        return 1
    done < <(grep "ipset add" "$SANDBOX_DIR/init-firewall.sh")
}

@test "docker-compose.yml runs an init so orphaned processes get reaped" {
    # Without this the session's own command is PID 1 and never reaps, so
    # leaked children accumulate as zombies until the pids cgroup is full
    # and the container cannot fork - see the comment on the init: line.
    grep -qE '^\s*init:\s*true\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "docker-compose.yml never mounts the Docker socket" {
    run grep -i "docker.sock" "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml never mounts host SSH/cloud credential directories" {
    # Anchored to the *source* side of a mount (right after the leading
    # "- ") - the container's own $HOME legitimately contains .ssh/known_hosts
    # as a *destination* path now that it mirrors the host's $HOME, which
    # isn't the same thing as mounting the host's real ~/.ssh directory in.
    run grep -E '^\s*-\s*\$\{HOME\}/\.(ssh|aws|gcloud|azure)(/|:)' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "~/.claude is not mounted as a whole - its contents are enumerated" {
    # It used to be, read-write, with the config inside it layered back
    # read-only on top. Every one of those overlays was a mount point nested
    # inside a host-writable mount, and a single-file bind mount is pinned to
    # the dentry at that path: a host-side rename unlinks it, the mount
    # silently detaches, and the path falls through to the real writable host
    # file (#47, #48). The mask over .credentials.json went the same way,
    # handing the sandbox the operator's real OAuth token (#50). With no
    # parent mount, a detachment falls through to container-local emptiness.
    run grep -E '^\s*-\s*\$\{HOME\}/\.claude:\$\{HOME\}/\.claude\s*$' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
    run grep -E '^\s*-\s*\$\{HOME\}/\.claude/\.credentials' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "the image bakes in a user-owned ~/.claude for the enumerated mounts to land in" {
    # Nothing mounts the directory itself any more, so it has to exist and be
    # writable by the sandbox user - otherwise Docker auto-creates it root
    # owned while setting up the mounts nested under it, and the session
    # can't write its own cache or the config entrypoint.sh copies in.
    grep -qE '^RUN mkdir -p .*\$SANDBOX_HOME/\.claude' "$SANDBOX_DIR/Dockerfile"
    grep -qE 'chown -R \$SANDBOX_USER:\$SANDBOX_USER .*\$SANDBOX_HOME/\.claude' "$SANDBOX_DIR/Dockerfile"
}


# The config directories the selected harness declares, as "path<TAB>mode<TAB>scan"
# lines. Runs the hook rather than grepping the plugin, so these assert what a
# launch would actually mount.
_declared_config_dirs() {
    bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        HOME=/h
        harness_plugin_load claude-code
        harness_config_dirs_load
        printf "%s\n" ${DEJIMA_CONFIG_DIRS[@]+"${DEJIMA_CONFIG_DIRS[@]}"}
    '
}
@test "~/.claude runtime state that has to survive the session is mounted read-write" {
    # Directories, which is what makes them safe: a directory bind mount
    # can't detach the way a file one does, because a rename replaces an
    # entry *within* the mounted directory rather than the mount point.
    # projects/ and file-history/ are not in this list: both are mounted an
    # entry at a time by bin/dejima, see the tests below. The rest is the
    # task/plan state skills write and the ~/.claude.json backups.
    local dirs d
    dirs="$(_declared_config_dirs)"
    for d in backups tasks plans sessions; do
        grep -qxF "/h/.claude/$d"$'\t'$'\t' <<< "$dirs" \
            || { echo "$d is not declared read-write: $dirs"; return 1; }
    done
}

# The whole tree carries every project's transcripts and agent memory, and
# memory is loaded into context at session start - so write access to it is
# enough to plant text a future session in another project reads as
# background (#104). This is the assertion that the tree itself never comes
# back; the per-slug mounts that replace it are covered below.
# The service still refers to the static keys; only the volume Docker
# actually creates varies, so a hardcoded name here would silently put every
# project back on one shared set.
@test "the nvim volumes take their names from the environment" {
    grep -qE '^\s*name:\s*\$\{SANDBOX_NVIM_DATA:-' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*name:\s*\$\{SANDBOX_NVIM_STATE:-' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*name:\s*\$\{SANDBOX_NVIM_CACHE:-' "$SANDBOX_DIR/docker-compose.yml"
    grep -q 'export SANDBOX_NVIM_DATA=' "$REPO_ROOT/bin/dejima"
}

@test "docker-compose.yml never mounts the whole ~/.claude/projects tree" {
    run grep -nE '^\s*-\s*\$\{HOME\}/\.claude/projects:' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ] || {
        echo "the projects tree is mounted whole again:" >&2
        echo "$output" >&2
        false
    }
}

@test "the claude-code plugin mounts projects/ one slug at a time" {
    # Moved out of bin/dejima into the harness plugin: which directories a
    # harness keeps, and what decides an entry belongs to this workspace, is
    # a fact about the harness. The property is unchanged - the tree is
    # every project's transcripts and memory, and memory is read into
    # context at session start (#104).
    local p="$REPO_ROOT/bin/harness/claude-code.sh"
    grep -q 'workspace_slugs_sorted "$ws"' "$p"
    grep -q 'emit_mount "$projects/$slug"' "$p"
}

# Docker creates the parents of a mount point root-owned when they do not
# already exist. projects/ is now such a parent, so without this the session
# could not create a slug of its own - which is exactly what it must do when
# the workspace has no history yet.
@test "the image pre-creates ~/.claude/projects so the slug mounts have a writable parent" {
    grep -qE '^RUN mkdir -p .*\$SANDBOX_HOME/\.claude/projects' "$SANDBOX_DIR/Dockerfile"
}

# Each file-history/<session>/<hash>@v1 is a verbatim copy of an edited file,
# so mounting the tree hands a session every project's source outright -
# worse than the transcripts, which are a record about the work rather than
# the work. Writable too, so tampering with another project's undo record
# puts chosen content into a later restore there.
@test "docker-compose.yml never mounts the whole ~/.claude/file-history tree" {
    run grep -nE '^\s*-\s*\$\{HOME\}/\.claude/file-history:' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ] || {
        echo "the file-history tree is mounted whole again:" >&2
        echo "$output" >&2
        false
    }
}

@test "the claude-code plugin mounts file-history one session at a time" {
    local p="$REPO_ROOT/bin/harness/claude-code.sh"
    grep -q 'workspace_session_ids "$projects" "$ws"' "$p"
    grep -q 'emit_mount "$history/$sid"' "$p"
}

@test "the image pre-creates ~/.claude/file-history so the session mounts have a writable parent" {
    grep -qE '\$SANDBOX_HOME/\.claude/file-history' "$SANDBOX_DIR/Dockerfile"
}

# One definition of "this workspace's slugs", shared by the mount and the
# audit. If they drift, a slug the mount exposes but the audit calls foreign
# fires a finding every session, and a slug the audit calls its own but the
# mount does not expose is a hole nothing reports.
@test "bin/dejima and bin/dejima-audit share one slug definition" {
    grep -q 'source "$SCRIPT_DIR/dejima-slug-lib.sh"' "$REPO_ROOT/bin/dejima"
    grep -q 'dejima-slug-lib.sh"$' "$REPO_ROOT/bin/dejima-audit"
    # and neither keeps a private copy of the sed scheme
    run grep -n "s/\[^a-zA-Z0-9\]/-/g" "$REPO_ROOT/bin/dejima" "$REPO_ROOT/bin/dejima-audit"
    [ "$status" -ne 0 ] || {
        echo "an inline copy of the slug scheme is back:" >&2
        echo "$output" >&2
        false
    }
}

@test "~/.claude config files are staged for copying, not mounted at their real paths" {
    # A copy can't be detached by a host-side rename at all. entrypoint.sh
    # installs them root-owned and read-only; see its comment and the mount
    # inventory in docker-compose.yml.
    # Declared by the harness now, since which files these are is its own.
    local staged
    staged="$(bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        HOME=/h
        harness_plugin_load claude-code
        harness_staged_config_load
        printf "%s\n" ${DEJIMA_STAGED_CONFIG[@]+"${DEJIMA_STAGED_CONFIG[@]}"}
    ')"
    local f
    for f in settings.json CLAUDE.md statusline.sh; do
        grep -qxF "/h/.claude/$f"$'\t'".claude/$f" <<< "$staged" \
            || { echo "$f is not staged: $staged"; return 1; }
    done
    # And never mounted at their real paths, which is the property staging
    # exists for: a single-file mount detaches on a host-side rename.
    run grep -E '^\s*-\s*\$\{HOME\}/\.claude/(settings\.json|CLAUDE\.md|statusline\.sh):\$\{HOME\}/' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
    # The staging tree mirrors the destination, so entrypoint.sh names no
    # harness's paths - it installs <rel> at $SANDBOX_HOME/<rel>.
    grep -q 'rel="${staged#/etc/dejima-harness/}"' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'dest="$SANDBOX_HOME/$rel"' "$SANDBOX_DIR/entrypoint.sh"
    run grep -n 'dejima-claude' "$SANDBOX_DIR/entrypoint.sh"
    [ "$status" -ne 0 ] || { echo "entrypoint still names a harness path"; return 1; }
}

@test "~/.claude/hooks and plugins are mounted read-only" {
    # Hooks run automatically with no approval gate, and plugins carry code a
    # later unsandboxed host session loads - see docker-compose.yml's comment
    # on these mount lines. Without them, a compromised session can unlink a
    # hook symlink and drop a plain malicious file in its place, which the
    # dynamic-mount logic in bin/dejima never sees (it only protects symlink
    # targets that resolve outside ~/.claude).
    local dirs
    dirs="$(_declared_config_dirs)"
    grep -q "^/h/.claude/hooks"$'\t'"ro" <<< "$dirs" || { echo "$dirs"; return 1; }
    grep -q "^/h/.claude/plugins"$'\t'"ro" <<< "$dirs" || { echo "$dirs"; return 1; }
}

@test "~/.claude.json is a throwaway per-session copy, not the real file mounted directly" {
    # A plain read-only mount hangs Claude Code on startup (it does an
    # atomic write-temp-then-rename against this file even before login) -
    # the fix is a generated, discarded copy, not read-only. See
    # bin/dejima and README "Throwaway ~/.claude.json".
    grep -qE '^\s*-\s*\$\{SANDBOX_CLAUDE_JSON_FILE.*\}:\$\{HOME\}/\.claude\.json\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -q 'mktemp.*dejima-claude-json' "$REPO_ROOT/bin/dejima"
    grep -q 'rm -f "\$SANDBOX_SETTINGS_FILE" "\$SANDBOX_CLAUDE_JSON_FILE"' "$REPO_ROOT/bin/dejima"
}

@test "gitconfig is a throwaway copy in its own directory, not a single-file mount" {
    # entrypoint.sh's `gh auth setup-git` writes a credential-helper entry
    # via git's write-temp-then-rename pattern, which fails with "Device or
    # resource busy" on a single-file bind mount at ~/.gitconfig directly -
    # a real regression this guards against (Linux won't let a bind mount's
    # backing inode be replaced, only a file *within* a mounted directory
    # can be freely renamed over). Must be a directory mount, with
    # GIT_CONFIG_GLOBAL pointing git at the file inside it.
    grep -qE '^\s*-\s*\$\{SANDBOX_GITCONFIG_DIR.*\}:\$\{HOME\}/\.gitconfig-sandbox\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*GIT_CONFIG_GLOBAL:\s*\$\{HOME\}/\.gitconfig-sandbox/\.gitconfig\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -q 'mktemp -d.*gitconfig' "$REPO_ROOT/bin/dejima"
}

@test "every name cleanup() dereferences is bound by the time the EXIT trap can fire" {
    # bin/dejima runs under `set -u`, and a failing command in an EXIT trap
    # replaces the shell's exit status - so an unbound name in cleanup()
    # aborts the trap partway, before it reaches the audit that is
    # deliberately its last act. Structural, not behavioral: the window
    # between `trap cleanup EXIT` and a later assignment holds only comments
    # today, so nothing can currently exit inside it (a failed `VAR="$(...)"`
    # still binds VAR to the empty string before set -e fires). This guards
    # the invariant against the edit that puts something exitable there.
    #
    # A name is satisfied by EITHER a first assignment above the trap OR a
    # `${NAME:-}` form somewhere in cleanup() - the latter covers the bare
    # uses that sit inside their own `[ -n "${NAME:-}" ]` guard.
    d="$REPO_ROOT/bin/dejima"
    trap_line="$(grep -n '^trap cleanup EXIT' "$d" | cut -d: -f1)"
    [ -n "$trap_line" ]
    body="$(sed -n '/^cleanup() {/,/^}/p' "$d")"
    [ -n "$body" ]
    for v in $(printf '%s\n' "$body" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' \
                   | tr -d '${}' | sort -u); do
        printf '%s\n' "$body" | grep -q "\${$v:-" && continue
        asg="$(grep -nE "^[[:space:]]*(export )?$v=" "$d" | head -1 | cut -d: -f1)"
        [ -n "$asg" ] || { echo "cleanup() uses \$$v, never assigned at all"; false; }
        [ "$asg" -lt "$trap_line" ] \
            || { echo "cleanup() uses \$$v unguarded, first assigned at line $asg, after the trap at $trap_line"; false; }
    done
}

@test "docker-compose.yml never hardcodes /home/node - the container home is host-parametrized" {
    # ${HOME:-/home/node} (the SANDBOX_HOME build arg's own default value,
    # mirroring the Dockerfile's default) is the one legitimate exception -
    # it's a fallback expression, not a hardcoded container path.
    run bash -c "grep -v '^\s*#' '$SANDBOX_DIR/docker-compose.yml' | grep -v '\${HOME:-/home/node}' | grep '/home/node'"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml builds with a per-user image tag and passes the host identity as build args" {
    grep -qE '^\s*image:\s*\$\{SANDBOX_IMAGE:-dejima:\$\{SANDBOX_USER:-node\}\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_USER:\s*\$\{SANDBOX_USER:-node\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_UID:\s*\$\{SANDBOX_UID:-1000\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_GID:\s*\$\{SANDBOX_GID:-1000\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_HOME:\s*\$\{HOME:-/home/node\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "bin/dejima exports the host user identity for the build" {
    grep -q 'SANDBOX_USER="$(id -un)"' "$REPO_ROOT/bin/dejima"
    grep -q 'SANDBOX_UID="$(id -u)"' "$REPO_ROOT/bin/dejima"
    grep -q 'SANDBOX_GID="$(id -g)"' "$REPO_ROOT/bin/dejima"
}

@test "docker-compose.yml never hardcodes a dotfiles (or any other specific repo) mount" {
    # Hook-symlink targets are discovered dynamically at launch by
    # bin/dejima instead - see the next test. A hardcoded path here
    # would silently break for anyone whose hooks live somewhere else.
    run grep -i 'dotfiles' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "bin/dejima dynamically discovers and mounts hook-symlink targets" {
    grep -q 'readlink -f "\$entry"' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "\$real_dir:\$real_dir:ro")' "$REPO_ROOT/bin/dejima"
    grep -q '"\${extra_mounts\[@\]}"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima layers a writable lazy-lock.json over the read-only nvim config mount" {
    # SANDBOX_NVIM_CONFIG is mounted :ro, but lazy.nvim writes its lockfile
    # back into that same directory on every plugin sync - without this
    # overlay, that write fails with a read-only-filesystem error and the
    # sync aborts (a real bug: plugins never finish installing, so a
    # config's colorscheme fallback kicks in instead of the real one).
    grep -q 'mktemp.*dejima-nvim-lock' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "\$SANDBOX_NVIM_LOCKFILE:\$HOME/\.config/nvim/lazy-lock\.json")' "$REPO_ROOT/bin/dejima"
    grep -q 'rm -f .*"\${SANDBOX_NVIM_LOCKFILE:-}"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima mounts SANDBOX_EXTRA_MOUNTS entries read-only at their own path" {
    grep -q 'IFS=.:. read -ra extra_paths <<< "\$SANDBOX_EXTRA_MOUNTS"' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "\$path:\$path:ro")' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima forces sandbox.enabled to false in the generated override layer" {
    # Claude Code's own internal per-command sandboxing is redundant on top
    # of this container and can't actually function inside it (bwrap can't
    # create a namespace here) - a session can't be trusted to turn it off
    # itself, so this has to happen in the generation step on the host,
    # before the container starts.
    grep -qE 'jq -n .\{sandbox: \{enabled: false\}\}' "$REPO_ROOT/bin/dejima"
}

@test "the generated override layer is a delta, not a copy of the operator's settings" {
    # jq -n reads no input: what ships is only what the sandbox overrides,
    # and everything else still comes from the operator's real settings.json
    # through Claude Code's own layering. A copy would go stale the moment
    # the host edited the original, and would duplicate every hook it
    # carried across two layers that get merged.
    grep -qE '^jq -n .* > "\$SANDBOX_SETTINGS_FILE"$' "$REPO_ROOT/bin/dejima"
    # The operator's settings.json is read only to check that it parses. It
    # must never become an input to the override layer.
    run grep -E 'HOME/\.claude/settings\.json.*SANDBOX_SETTINGS_FILE' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
}

@test "the override layer is mounted outside ~/.claude and passed as --settings" {
    # Mounting it over ~/.claude/settings.json put the mount point inside the
    # read-write ~/.claude mount, where a host-side rename of the real file
    # detached it mid-session and silently reverted every override (#47).
    # A container-local path can't be renamed over from the host.
    grep -qE '^\s*-\s*\$\{SANDBOX_SETTINGS_FILE.*\}:/etc/dejima-settings\.json:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
    run grep -E '^\s*-\s*\$\{SANDBOX_SETTINGS_FILE.*\}:\$\{HOME\}/' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
    # Which only takes effect if the flag is actually passed. It goes in the
    # wrapper rather than the entrypoint so it also covers invocations the
    # entrypoint never sees (an interactive shell, claudecode.nvim).
    # The flag itself is the harness's now, not the wrapper's: the wrapper
    # is shared and a --settings it hardcoded would be handed to a harness
    # that layers settings some other way.
    grep -qE -- 'settings_args\s*=\s*--settings /etc/dejima-settings\.json' \
        "$REPO_ROOT/harnesses/claude-code/harness.conf"
    grep -q 'SANDBOX_HARNESS_SETTINGS' "$SANDBOX_DIR/harness-wrapper.sh"
    grep -qE -- '\$\{settings\[@\]\+"\$\{settings\[@\]\}"\}' "$SANDBOX_DIR/harness-wrapper.sh"
}

@test "bin/dejima pre-creates the ~/.claude config files so neither is mounted as a directory" {
    # Docker creates a missing bind source as a directory - without this, a
    # host that has never run install.sh gets a junk directory at
    # ~/.claude/settings.json and a session with no settings at all.
    grep -qE '\[ -f "\$HOME/\.claude/settings\.json" \] \|\| echo' "$REPO_ROOT/bin/dejima"
    grep -qE '\[ -f "\$HOME/\.claude/CLAUDE\.md" \] \|\|' "$REPO_ROOT/bin/dejima"
}

@test "Dockerfile never installs bubblewrap or socat" {
    # Nothing needs them now that sandbox.enabled is forced off - if they
    # come back, it's worth asking why before just re-adding them.
    run grep -E '^\s*(bubblewrap|socat)\s*\\?\s*$' "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ]
}

@test "the briefing never tells the agent to worktree outside the mounted project" {
    # ../<branch> (a sibling of the mounted project) or anything under $HOME
    # lands in container-local ephemeral storage, not real host storage -
    # the worktree, and whatever work went into it, silently vanishes when
    # the session ends. Regression check for exactly this bug. This
    # paragraph is core briefing prose (bin/dejima-provider-lib.sh), not
    # something the hook carries anymore - see providers.bats/config.bats
    # for the hook's own (much narrower) job.
    run grep -E '(worktree add|git worktree)[^\\n]*\.\./' "$REPO_ROOT/bin/dejima-provider-lib.sh"
    [ "$status" -ne 0 ]
    grep -q '.worktrees/' "$REPO_ROOT/bin/dejima-provider-lib.sh"
}

@test "the worktree-pr workflow tells the agent to close issues via the PR body" {
    # The session ends at the PR and the merge happens later, without the
    # agent - so anything it defers to "after the merge" is something it
    # won't be there to do, and an issue a merged PR fixed just stays open.
    # A closing keyword in the body is the only part of that it can control.
    # This lives in the workflow's own briefing fragment now, not the hook.
    grep -q 'Fixes #N' "$REPO_ROOT/workflows/worktree-pr/briefing.md"
    # And the counterpart, so partial work doesn't close anything.
    grep -q 'Refs #N' "$REPO_ROOT/workflows/worktree-pr/briefing.md"
    # The short form specifically: an issue's full URL renders as the same
    # link but does not trigger the close.
    grep -q "not the issue's URL" "$REPO_ROOT/workflows/worktree-pr/briefing.md"
}

@test "the worktree-pr workflow tells the agent not to hard-wrap bodies, and how to fix one" {
    # The forge renders a single newline as a line break, so a body wrapped
    # at a column arrives broken every ten words - worst on a phone, where
    # the screen wraps the line and the stray newline wraps it again. The
    # tools deliberately do not reflow anything (#79), which puts the whole
    # of this on the briefing.
    grep -q 'hard-wrap' "$REPO_ROOT/workflows/worktree-pr/briefing.md"
    grep -q 'newline as a line break' "$REPO_ROOT/workflows/worktree-pr/briefing.md"
    # And that revising the file a body came from sends nothing by itself -
    # the other half of #79, where edits were reported but never made.
    grep -q 'edit <N>' "$REPO_ROOT/workflows/worktree-pr/briefing.md"
}

@test "entrypoint runs as root and drops to node via gosu, not a baked-in USER node" {
    # The whole privilege-drop model depends on entrypoint.sh itself starting
    # as root (to set up the firewall) - a stray `USER node` before
    # ENTRYPOINT would silently break that.
    run tail -n 5 "$SANDBOX_DIR/Dockerfile"
    [[ "$output" == *"ENTRYPOINT"* ]]
    ! grep -qE '^\s*USER\s+node\s*$' <(tail -n 8 "$SANDBOX_DIR/Dockerfile")
}

@test "bin/dejima and bin/dejima-allow resolve their own location through symlinks" {
    # install.sh symlinks both into ~/.local/bin so they can be run by name
    # via PATH. A bare `dirname "${BASH_SOURCE[0]}"` (no readlink -f first)
    # resolves against the symlink's own directory in that case, not this
    # repo's real bin/ - a real bug hit on first use: dejima tried
    # to open ~/.local/docker/docker-compose.yml instead of this repo's.
    grep -q 'dirname "\$(readlink -f "\${BASH_SOURCE\[0\]}")"' "$REPO_ROOT/bin/dejima"
    grep -q 'dirname "\$(readlink -f "\${BASH_SOURCE\[0\]}")"' "$REPO_ROOT/bin/dejima-allow"
}

@test "bin/dejima-allow rejects a domain with shell metacharacters" {
    run "$REPO_ROOT/bin/dejima-allow" 'evil.com;touch /tmp/pwned'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not a valid domain"* ]]
}

@test "bin/dejima-allow rejects a domain with a slash (dnsmasq server= delimiter)" {
    run "$REPO_ROOT/bin/dejima-allow" 'evil.com/../etc'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not a valid domain"* ]]
}

@test "bin/dejima-allow accepts a well-formed domain (passes validation)" {
    # --container points at a name that can't exist, so this can *never*
    # reach a real running dejima session (and mutate its live
    # firewall) even if the machine running this test happens to have one -
    # it must fail at "container not found", not at validation.
    run "$REPO_ROOT/bin/dejima-allow" --container dejima-test-suite-nonexistent-target 'crates.io'
    [ "$status" -ne 0 ]
    [[ "$output" != *"Not a valid domain"* ]]
}

@test "the dedicated SSH key mount is optional, not a hard requirement" {
    grep -qE '^\s*-\s*\$\{SANDBOX_SSH_KEY_FILE:-/dev/null\}:/root/\.ssh-sandbox-key-src:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*-\s*\$\{SSH_AUTH_SOCK:-/dev/null\}:/ssh-agent\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "the dedicated SSH key source is mounted under /root, not the sandbox user's home" {
    # A mount under \$SANDBOX_HOME would be readable by the sandbox user
    # directly, since its uid now matches the host user's (see Dockerfile) -
    # /root is only reachable by root, which is all that should ever read
    # this file (see entrypoint.sh).
    run grep -E '\.ssh-sandbox-key-src' "$SANDBOX_DIR/docker-compose.yml"
    [[ "$output" != *'${HOME}'* ]]
    run grep -F 'SANDBOX_SSH_KEY_SRC=' "$SANDBOX_DIR/entrypoint.sh"
    [[ "$output" != *'SANDBOX_HOME'* ]]
    grep -qF 'SANDBOX_SSH_KEY_SRC="/root/.ssh-sandbox-key-src"' "$SANDBOX_DIR/entrypoint.sh"
}

@test "entrypoint.sh deletes the plaintext dedicated-key copy after loading it into the agent" {
    grep -q 'gosu "$SANDBOX_USER" ssh-add' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'rm -f "$SANDBOX_HOME/.ssh/sandbox-key"' "$SANDBOX_DIR/entrypoint.sh"
    ssh_add_line=$(grep -n 'gosu "$SANDBOX_USER" ssh-add' "$SANDBOX_DIR/entrypoint.sh" | head -1 | cut -d: -f1)
    rm_line=$(grep -n 'rm -f "$SANDBOX_HOME/.ssh/sandbox-key"' "$SANDBOX_DIR/entrypoint.sh" | head -1 | cut -d: -f1)
    [ "$rm_line" -gt "$ssh_add_line" ]
}

@test "bin/dejima allows a dedicated SANDBOX_SSH_KEY in place of a forwarded agent" {
    grep -q 'SANDBOX_SSH_KEY' "$REPO_ROOT/bin/dejima"
    grep -q 'export SANDBOX_SSH_KEY_FILE' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima warns when SANDBOX_SSH_KEY looks like a default personal key" {
    grep -q 'looks like a default personal SSH key' "$REPO_ROOT/bin/dejima"
    run grep -E '^\s*id_rsa\|id_ecdsa\|id_ed25519\|id_dsa\|id_ecdsa_sk\|id_ed25519_sk\)\s*$' "$REPO_ROOT/bin/dejima"
    [ "$status" -eq 0 ]
}

@test "init-firewall.sh sends GH_TOKEN on its GitHub API fetch when one is set" {
    # Unauthenticated /meta is capped at 60 requests/hour per source IP,
    # shared across every container start; exhausting it fails the launch.
    grep -q 'gh_auth=(-H "Authorization: Bearer \$GH_TOKEN")' "$SANDBOX_DIR/init-firewall.sh"
    # The array reaching the request to /meta is the property; the flags around
    # it are no longer pinned here, because they now have tests of their own
    # ("every fetch in the container's startup path has a deadline" and the
    # behavioural ones above). Pinning the whole invocation twice made adding a
    # timeout to it fail a test about the token.
    grep -q '\${gh_auth\[@\]+"\${gh_auth\[@\]}"} https://api.github.com/meta' "$SANDBOX_DIR/init-firewall.sh"
}

@test "ALLOW_GITHUB_PUSH defaults to 0 everywhere it's read" {
    grep -qE '^\s*ALLOW_GITHUB_PUSH:\s*\$\{ALLOW_GITHUB_PUSH:-0\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -q '\${ALLOW_GITHUB_PUSH:-0}' "$SANDBOX_DIR/init-firewall.sh"
}

@test "init-firewall.sh only opens port 22 to GitHub inside the ALLOW_GITHUB_PUSH conditional" {
    # The unconditional port-443-only rule must still be present unchanged;
    # the port-22 rule must only appear inside the new if-block, never as a
    # second unconditional rule alongside it.
    grep -q -- '-A OUTPUT -p tcp --dport 443 -m set --match-set github-domains dst -j ACCEPT' "$SANDBOX_DIR/init-firewall.sh"
    port22_line=$(grep -n -- '-A OUTPUT -p tcp --dport 22 -m set --match-set github-domains dst -j ACCEPT' "$SANDBOX_DIR/init-firewall.sh" | cut -d: -f1)
    [ -n "$port22_line" ]
    if_line=$(grep -n 'ALLOW_GITHUB_PUSH:-0.*=.*1' "$SANDBOX_DIR/init-firewall.sh" | head -1 | cut -d: -f1)
    [ -n "$if_line" ]
    [ "$port22_line" -gt "$if_line" ]
}

@test "git-push-guard.sh blocks direct pushes to a branch named in DEJIMA_BLOCKED_BRANCHES" {
    d="$(mktemp -d)"
    git -C "$d" init -q
    git -C "$d" remote add origin git@anywhere.example:x/y
    git -C "$d" checkout -qb main
    payload="$(printf '{"tool_input":{"command":"git push origin main"},"cwd":"%s"}' "$d")"
    run env DEJIMA=1 DEJIMA_PUSH_HOSTS="anywhere.example" DEJIMA_BLOCKED_BRANCHES="main master" \
        bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/hooks/git-push-guard.sh"
    [ "$status" -eq 2 ]
    rm -rf "$d"
}

@test "no gitea CLI passes the token as a command-line argument" {
    # /proc makes argv world-readable, so a token in a curl invocation is
    # visible to every other process for the life of the request - and this
    # runs alongside agents that read process listings.
    #
    # Every file, because they are deliberate copies of each other rather
    # than a shared library (see forges/gitea/bin/gitea-issue's header for
    # why), and a duplicated security property is exactly the kind that
    # drifts.
    local f
    for f in forges/gitea/bin/gitea-pr forges/gitea/bin/gitea-issue forges/gitea/bin/gitea-actions; do
        run grep -n 'curl.*Authorization: token' "$REPO_ROOT/$f"
        [ "$status" -ne 0 ]
        grep -q 'curl -sS -w .*-K -' "$REPO_ROOT/$f"
    done
}

@test "both gitea CLIs take a body from a file, and refuse to guess between two" {
    # Prose on a command line has to survive shell quoting, and an
    # apostrophe or a backtick is the common case, not the edge one. A body
    # that arrives via a file never enters argv at all.
    local f
    for f in forges/gitea/bin/gitea-pr forges/gitea/bin/gitea-issue; do
        grep -q -- '--body-file' "$REPO_ROOT/$f"
        # '-' means stdin, so a heredoc works without a temp file.
        grep -q 'file" = "-"' "$REPO_ROOT/$f"
        # Passing both is an error rather than a precedence rule: silently
        # picking one ships a body the caller did not mean to send.
        grep -q 'not both' "$REPO_ROOT/$f"
    done
}

# Runs a gitea CLI against a stub `curl` that records the request instead of
# making one, from a throwaway repo whose origin looks like the configured
# Gitea host. Every one of these tools reaches the network through a single
# `curl -K -` call, so this is their whole outbound surface.
#
# The stub answers the way gitea_api's callers parse: the body, then the
# status on its own line (which is what `-w '\n%{http_code}'` appends).
gitea_cli() {
    local cli="$1"; shift
    local d="$BATS_TEST_TMPDIR/cli"
    if [ ! -d "$d" ]; then
        mkdir -p "$d/stub" "$d/repo"
        cat > "$d/stub/curl" <<'STUB'
#!/bin/bash
prev=""
payload=""
for a in "$@"; do
    if [ "$prev" = "-d" ]; then
        payload="$a"
        printf '%s' "$a" > "$STUB_PAYLOAD"
    fi
    prev="$a"
done
cat >/dev/null
# A request carrying a body is a write, and its callers read one object
# back; the reads these tools make before writing are list endpoints, whose
# callers iterate. Answering both with the same shape would fail on the jq
# rather than on anything under test.
if [ -n "$payload" ]; then
    echo '{"html_url": "https://forge.invalid/x/y/pulls/1"}'
else
    # Reads answer `[]` unless the URL is one a test needs shaped data from.
    # `comments` walks reviews and then each review's own comments, so an
    # empty list at the first hop means the second never runs and the
    # rendering under test is never reached.
    url=""
    for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
    # Match on the path, not the whole URL: list reads carry ?limit&page, and
    # a pattern anchored at the end of the string stops matching the moment
    # one does.
    url="${url%%\?*}"
    case "$url" in
        */reviews/*/comments)
            # Three comments, two of them one thread. The resolved thread has a
            # reply carrying `resolver: null`, because Gitea stamps only a
            # thread's root - which is the case that made a closed thread read
            # as open.
            echo '[{"user":{"login":"reviewer"},"path":"docs/thing.md","position":118,"resolver":null,"diff_hunk":"@@ -105,0 +115,2 @@\n+a line the reviewer is looking at","body":"this bit is confusing"},{"user":{"login":"reviewer"},"path":"docs/other.md","position":42,"resolver":{"login":"reviewer"},"diff_hunk":"@@ -1,0 +42,1 @@\n+a line already dealt with","body":"already handled"},{"user":{"login":"reviewer"},"path":"docs/other.md","position":42,"resolver":null,"diff_hunk":"@@ -1,0 +42,1 @@\n+a line already dealt with","body":"a reply inside the closed thread"}]' ;;
        */reviews)
            echo '[{"id":32,"user":{"login":"reviewer"},"submitted_at":"2026-01-01T00:00:00Z","state":"COMMENTED","body":"","comments_count":1}]' ;;
        *)
            echo '[]' ;;
    esac
fi
echo 200
STUB
        chmod +x "$d/stub/curl"
        git -C "$d/repo" init -q -b feature
        # Identity passed per-command rather than inherited: a CI container
        # has no git config, and `commit` there exits 128 with "Author
        # identity unknown" - a precondition this suite was taking from
        # whoever ran it. The commit exists only so create's
        # `rev-parse --abbrev-ref HEAD` has a branch to report.
        git -C "$d/repo" -c user.name=t -c user.email=t@invalid \
            commit -q --allow-empty -m seed
        git -C "$d/repo" remote add origin git@forge.invalid:owner/name.git
    fi
    : > "$d/payload"
    ( cd "$d/repo" && env PATH="$d/stub:$PATH" \
        GITEA_SSH_HOST=forge.invalid GITEA_API=https://forge.invalid/api/v1 \
        GITEA_TOKEN=stub-token STUB_PAYLOAD="$d/payload" \
        "$REPO_ROOT/forges/gitea/bin/$cli" "$@" )
}

# What was in the -d of the last gitea_cli call.
cli_payload() { cat "$BATS_TEST_TMPDIR/cli/payload"; }

# curl normalises dot-segments, so a PR "number" that is really a path
# reaches a different repo's endpoint with this token on it. `edit` always
# checked; the other two took the argument as given.
@test "every gitea-pr subcommand taking a PR number refuses one that is a path" {
    local sub bad
    for sub in comments merge edit; do
        for bad in '../../../other/repo/pulls/7' '7abc' 'x'; do
            run gitea_cli gitea-pr "$sub" "$bad"
            [ "$status" -ne 0 ] \
                || { echo "gitea-pr $sub accepted '$bad'"; return 1; }
            [[ "$output" == *"Expected a PR number"* ]] \
                || { echo "gitea-pr $sub '$bad': $output"; return 1; }
        done
    done
}

@test "a PR-number subcommand with no argument says how to call it" {
    # "no argument" and "wrong argument" are different mistakes: one wants the
    # usage line, the other wants to know what was wrong with what was given.
    local sub=merge
    run gitea_cli gitea-pr "$sub"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage:"* ]] || { echo "$output"; return 1; }
}

# A paginating stub: full pages until the last one, so a caller that reads
# page one and stops sees a prefix of the list and cannot tell that it did.
paginating_cli() {
    local cli="$1"; shift
    local d="$BATS_TEST_TMPDIR/pcli"
    if [ ! -d "$d" ]; then
        mkdir -p "$d/stub" "$d/repo"
        cat > "$d/stub/curl" <<'STUB'
#!/bin/bash
url=""
for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
cat >/dev/null
page=1; limit=50
case "$url" in *page=*) page="${url##*page=}"; page="${page%%&*}" ;; esac
case "$url" in *limit=*) limit="${url##*limit=}"; limit="${limit%%&*}" ;; esac
emit() {
    local n="$1" start="$2" i out=""
    for ((i = 0; i < n; i++)); do
        out="$out,{\"id\":$((start + i)),\"user\":{\"login\":\"u\"},\"created_at\":\"t\",\"body\":\"comment-$((start + i))\"}"
    done
    echo "[${out#,}]"
}
case "$url" in
    */issues/*/comments*)
        # Two full pages and a short third: 105 comments in all.
        if   [ "$page" = 1 ]; then emit "$limit" 0
        elif [ "$page" = 2 ]; then emit "$limit" "$limit"
        elif [ "$page" = 3 ]; then emit 5 $((limit * 2))
        else echo '[]'; fi ;;
    *) echo '[]' ;;
esac
echo 200
STUB
        chmod +x "$d/stub/curl"
        git -C "$d/repo" init -q -b feature
        git -C "$d/repo" -c user.name=t -c user.email=t@invalid \
            commit -q --allow-empty -m seed
        git -C "$d/repo" remote add origin git@forge.invalid:owner/name.git
    fi
    ( cd "$d/repo" && env PATH="$d/stub:$PATH" \
        GITEA_SSH_HOST=forge.invalid GITEA_API=https://forge.invalid/api/v1 \
        GITEA_TOKEN=stub-token \
        "$REPO_ROOT/forges/gitea/bin/$cli" "$@" )
}

@test "gitea-pr comments reads past the first page of feedback" {
    # The documented review loop is `gitea-pr comments <n>`, act, repeat. A
    # read that stops at the server's page size drops the rest silently, so
    # whoever is addressing the review never learns the rest exists.
    run paginating_cli gitea-pr comments 1
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"comment-0"* ]] || { echo "the first page is missing"; return 1; }
    [[ "$output" == *"comment-50"* ]] || { echo "the second page was not read"; return 1; }
    [[ "$output" == *"comment-104"* ]] || { echo "the last page was not read"; return 1; }
}

@test "an inline review comment arrives with the diff it was left against" {
    # Gitea's review-comment objects have no `line` field, so the old
    # `\(.line // "?")` rendered every comment as `path:?`. A reviewer who
    # writes "this is confusing" about a passage is pointing at something they
    # can see and the reader cannot, and the reader then has to guess which
    # passage. `diff_hunk` is what removes the guess.
    run gitea_cli gitea-pr comments 1
    [ "$status" -eq 0 ]

    # The hunk itself, not merely the file it came from.
    [[ "$output" == *"a line the reviewer is looking at"* ]]
    [[ "$output" == *"@@ -105,0 +115,2 @@"* ]]
    # Attributed and located, with the diff offset rather than a bare `?`.
    [[ "$output" == *"[reviewer @ docs/thing.md @@118]"* ]]
    [[ "$output" != *":?]"* ]]
    # And the comment, distinguishable from the quoted code above it.
    [[ "$output" == *"--- comment ---"* ]]
    [[ "$output" == *"this bit is confusing"* ]]
}

@test "a resolved thread stays hidden, including a reply that carries no resolver" {
    # The trap this exists for: Gitea marks only a thread's ROOT comment as
    # resolved. A reply inside a closed thread comes back with
    # `resolver: null`, so judging each comment on its own reports a thread
    # you already dealt with as still needing an answer. On a real review that
    # meant hunting for a passage that had already been rewritten.
    run gitea_cli gitea-pr comments 1
    [ "$status" -eq 0 ]

    # The genuinely open one is there.
    [[ "$output" == *"this bit is confusing"* ]]
    # Neither half of the closed thread is, the reply included.
    [[ "$output" != *"already handled"* ]]
    [[ "$output" != *"a reply inside the closed thread"* ]]
    # And it says what it withheld rather than silently shrinking the list.
    [[ "$output" == *"1 resolved thread(s) hidden"* ]]
}

@test "--all includes resolved threads and marks them as resolved" {
    run gitea_cli gitea-pr comments 1 --all
    [ "$status" -eq 0 ]

    [[ "$output" == *"this bit is confusing"* ]]
    [[ "$output" == *"already handled"* ]]
    [[ "$output" == *"a reply inside the closed thread"* ]]
    # Marked, so a reader is not left to work out which are which.
    [[ "$output" == *"docs/other.md @@42  (resolved)"* ]]
    # The open one carries no marker.
    [[ "$output" == *"[reviewer @ docs/thing.md @@118]"* ]]
    # Nothing is hidden, so nothing is announced as hidden.
    [[ "$output" != *"hidden"* ]]
}

@test "an edit sends only the fields it was given, so a title edit cannot blank a body" {
    # The half of #79 that was silent: an agent that said it had updated a
    # description had not, because there was no way to. Sending a fixed
    # {title, body} pair instead would have traded that for a worse bug -
    # every title-only edit wiping the description.
    local cli
    for cli in gitea-pr gitea-issue; do
        gitea_cli "$cli" edit 1 --title "a new title"
        [ "$(cli_payload | jq -r '.title')" = "a new title" ]
        [ "$(cli_payload | jq 'has("body")')" = "false" ]

        gitea_cli "$cli" edit 1 --body "a new body"
        [ "$(cli_payload | jq 'has("title")')" = "false" ]
        # The provenance marker create writes survives an edit rather than
        # being shed by it.
        [[ "$(cli_payload | jq -r '.body')" == *"LLM agent"* ]]
        [[ "$(cli_payload | jq -r '.body')" == *"a new body"* ]]
    done
}

@test "an edit with neither a title nor a body is refused rather than sent empty" {
    local cli
    for cli in gitea-pr gitea-issue; do
        run gitea_cli "$cli" edit 1
        [ "$status" -ne 0 ]
        [[ "$output" == *"requires --title"* ]]
        # Nothing reached the network to be refused by the far end instead.
        [ ! -s "$BATS_TEST_TMPDIR/cli/payload" ]
    done
}

@test "create still sends head, base, title and body after sharing a parser with edit" {
    # create's own argument parsing moved into the function edit uses, so
    # that the two cannot disagree about --body vs --body-file. This is the
    # side of that move with no test of its own before now.
    gitea_cli gitea-pr create --title "a title" --body "a body" --base trunk
    [ "$(cli_payload | jq -r '.head')" = "feature" ]
    [ "$(cli_payload | jq -r '.base')" = "trunk" ]
    [ "$(cli_payload | jq -r '.title')" = "a title" ]
    [[ "$(cli_payload | jq -r '.body')" == *"a body"* ]]
}

@test "an edit takes its body from a file, the same way create does" {
    # The flag that matters inside the sandbox: a body written to a file
    # never enters the Bash command string deny-dangerous-bash.sh reads.
    echo "body out of a file" > "$BATS_TEST_TMPDIR/b.md"
    gitea_cli gitea-pr edit 1 --body-file "$BATS_TEST_TMPDIR/b.md"
    [[ "$(cli_payload | jq -r '.body')" == *"body out of a file"* ]]
}

@test "gitea-issue list asks for issues only, never pull requests" {
    # Gitea's issues endpoint returns PRs too - a PR is an issue with a
    # branch attached - so without type=issues every open PR shows up as an
    # issue and the work list reads as twice as long as it is.
    grep -q 'type=issues' "$REPO_ROOT/forges/gitea/bin/gitea-issue"
}

@test "gitea-actions only reads - it issues no request that could change anything" {
    # It authenticates with the same write-scoped token as gitea-pr, so
    # "it only fetches runs and logs" has to be a property of the file and
    # not merely of what its subcommands are named.
    run grep -nE '\-X (POST|PUT|PATCH|DELETE)|--data|[^a-z-]-d ' \
        "$REPO_ROOT/forges/gitea/bin/gitea-actions"
    [ "$status" -ne 0 ]
}

@test "gitea-actions asks for nothing that needs to own the repo" {
    # Gitea gates /repos/{o}/{r}/actions/runs - and the job and log endpoints
    # reached through it - behind reqOwner(). A sandbox should hold a token
    # for a dedicated account that is a collaborator and nothing more, and
    # that account is refused there with "user should be the owner of the
    # repo". No scope grants ownership, so a reader who hits this reaches for
    # a wider token, which is the wrong direction and the reason this is
    # pinned rather than left to the comment explaining it.
    #
    # Anchored on GITEA_API, not on the path: the log route is a web URL
    # under the same-looking /actions/runs/N/jobs/M prefix, and it is fine.
    local f="$REPO_ROOT/forges/gitea/bin/gitea-actions"
    run grep -nE '\$\{?GITEA_API\}?[^"]*actions/(runs|jobs)' "$f"
    [ "$status" -ne 0 ]
    # The three it may use instead, each reachable with plain read access.
    grep -q 'actions/tasks' "$f"
    grep -q 'commits/.*statuses' "$f"
    grep -q 'GITEA_WEB' "$f"
}

@test "the gitea CLIs format their own tables, rather than shelling out to column" {
    # util-linux's `column` is not in the sandbox image, and it is the last
    # command in the pipeline - so a missing one fails with 127 after the
    # request has already succeeded, which reads as an API problem rather
    # than a missing tool. bin/dejima-audit and bin/dejima-attach pad with
    # printf for the same reason; this keeps the forge CLIs consistent with
    # them.
    run grep -rn 'column -t' "$REPO_ROOT/forges/"
    [ "$status" -ne 0 ]
}

@test "gitea-issue is installed into the image alongside gitea-pr" {
    grep -q 'COPY forges/' "$SANDBOX_DIR/Dockerfile"
    # Through the manifest's install list, not a find over the directory
    # layout - see "what ships into the image is what a manifest declares".
    grep -q 'install-forge-bins.sh' "$SANDBOX_DIR/Dockerfile"
    [ -x "$REPO_ROOT/forges/gitea/bin/gitea-pr" ]
    [ -x "$REPO_ROOT/forges/gitea/bin/gitea-issue" ]
}

# forges/ is inside the audit's TCB, so `install =` in a forge manifest is a
# claim an operator is entitled to read as "this forge puts nothing else
# executable in the image". The image build enforces it, but that is the slow
# tier and only runs where Docker does; this catches a file added under a
# forge's bin/ without a declaration at the same time as the rest of the
# static checks, which is when someone is still looking at the change.
@test "what ships into the image is what a manifest declares, both ways" {
    local dest
    dest="$(mktemp -d)"
    run bash "$REPO_ROOT/docker/install-forge-bins.sh" "$REPO_ROOT/forges" "$dest"
    [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$dest"; return 1; }
    # Nothing under any forge's bin/ was skipped, and nothing else appeared.
    local shipped declared
    shipped="$(cd "$dest" && ls | sort)"
    declared="$(find "$REPO_ROOT/forges" -type f -path '*/bin/*' -printf '%f\n' | sort)"
    rm -rf "$dest"
    [ "$shipped" = "$declared" ] || {
        echo "installed:"; echo "$shipped"; echo "present under a bin/:"; echo "$declared"; return 1; }
}

@test "an undeclared file under a forge's bin/ fails the image build" {
    local fake dest
    fake="$(mktemp -d)"; dest="$(mktemp -d)"
    cp -r "$REPO_ROOT"/forges/. "$fake/"
    mkdir -p "$fake/github/bin"
    printf '#!/bin/sh\necho hi\n' > "$fake/github/bin/undeclared"
    run bash "$REPO_ROOT/docker/install-forge-bins.sh" "$fake" "$dest"
    [ "$status" -ne 0 ] || { echo "an undeclared CLI installed anyway"; rm -rf "$fake" "$dest"; return 1; }
    [ ! -e "$dest/undeclared" ]
    rm -rf "$fake" "$dest"
}

@test "a declared file a forge does not ship fails the image build" {
    local fake dest
    fake="$(mktemp -d)"; dest="$(mktemp -d)"
    cp -r "$REPO_ROOT"/forges/. "$fake/"
    rm "$fake/gitea/bin/gitea-pr"
    run bash "$REPO_ROOT/docker/install-forge-bins.sh" "$fake" "$dest"
    [ "$status" -ne 0 ] || { echo "a missing declared CLI passed"; rm -rf "$fake" "$dest"; return 1; }
    rm -rf "$fake" "$dest"
}

@test "merge-guard.sh blocks a sandbox merge and is a no-op on the host" {
    local hook="$REPO_ROOT/hooks/merge-guard.sh"
    local payload

    # Blocked in the sandbox, including path-qualified - /usr/local/bin is
    # where the image puts it, so a bare-name-only pattern would miss the
    # form an agent reaching past PATH would type.
    local cmd
    for cmd in 'gitea-pr merge 24' '/usr/local/bin/gitea-pr merge 24' 'cd /tmp && gitea-pr merge 24'; do
        payload=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
        run bash -c "printf '%s' \"\$1\" | DEJIMA=1 DEJIMA_MERGE_BLOCK='gitea-pr merge' bash '$hook'" _ "$payload"
        [ "$status" -eq 2 ]
        [[ "$output" == *"merge-guard.sh"* ]]
    done

    # The other verbs are the whole point of the tool and must pass through.
    for cmd in 'gitea-pr create --title x' 'gitea-pr comments 24' 'gitea-issue close 14'; do
        payload=$(jq -n --arg c "$cmd" '{tool_input: {command: $c}}')
        run bash -c "printf '%s' \"\$1\" | DEJIMA=1 DEJIMA_MERGE_BLOCK='gitea-pr merge' bash '$hook'" _ "$payload"
        [ "$status" -eq 0 ]
    done

    # Outside the sandbox it does nothing at all: an operator at a host shell
    # can still be asked to merge, which is what the CLAUDE.md rule allows.
    # env -u rather than DEJIMA= because the image sets DEJIMA=1 globally, so
    # a test running inside dejima would otherwise assert against itself.
    payload=$(jq -n '{tool_input: {command: "gitea-pr merge 24"}}')
    run bash -c "printf '%s' \"\$1\" | env -u DEJIMA DEJIMA_MERGE_BLOCK='gitea-pr merge' bash '$hook'" _ "$payload"
    [ "$status" -eq 0 ]
}

@test "the merge guard is linked and registered" {
    # In the harness plugin now: which file a guard is and where a harness
    # reads it from is the harness's, while whether it is installed at all
    # is gated on the manifest declaring the guard.
    local p="$REPO_ROOT/bin/harness/claude-code.sh"
    grep -q 'harness_has_guard merge-guard && _link_hook merge-guard.sh' "$p"
    grep -q '_register PreToolUse Bash merge-guard.sh' "$p"
}

# Runs install.sh against a throwaway HOME, with a stub `docker` on PATH so
# its tool check passes somewhere without one (this suite is the no-Docker
# half). Everything the script writes - hook symlinks, ~/.local/bin,
# settings.json, the starter config - lands under that HOME.
run_install() {
    local home="$1"
    mkdir -p "$home/stub"
    printf '#!/bin/sh\nexit 0\n' > "$home/stub/docker"
    chmod +x "$home/stub/docker"
    env HOME="$home" PATH="$home/stub:$PATH" DEJIMA_CONFIG_DIR="$home/config" \
        bash "$REPO_ROOT/install.sh"
}

# Every registered hook command, one per line.
registered_commands() {
    jq -r '[.hooks[]?[]?.hooks[]?.command // empty] | .[]' "$1/.claude/settings.json"
}

@test "install.sh replaces the pre-rename gitea-merge-guard.sh registration rather than reading it as one" {
    # Asserted by running it, not by grepping it: the bug this covers was a
    # register_hook call that was present in the source and did nothing. Its
    # dedupe matched the pre-rename command string as a substring, so the
    # merge guard was registered nowhere while install.sh reported success,
    # and every session start reported the missing hook the stale entry
    # still named.
    local home="$BATS_TEST_TMPDIR/h"
    mkdir -p "$home/.claude/hooks"
    ln -s "$REPO_ROOT/hooks/gone.sh" "$home/.claude/hooks/gitea-merge-guard.sh"
    jq -n '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command",
        command: "$HOME/.claude/hooks/gitea-merge-guard.sh"}]}]}}' \
        > "$home/.claude/settings.json"

    run_install "$home"

    run registered_commands "$home"
    [[ "$output" != *"gitea-merge-guard.sh"* ]]
    [ "$(registered_commands "$home" | grep -c '/merge-guard\.sh$')" -eq 1 ]
    [ ! -e "$home/.claude/hooks/gitea-merge-guard.sh" ]
}

@test "install.sh registers each hook exactly once across repeated runs" {
    # The other direction of the same dedupe: an exact match must still
    # match. A re-run after a git pull is the common case, and duplicate
    # registrations would run every guard twice.
    local home="$BATS_TEST_TMPDIR/h2" cmd
    run_install "$home"
    run_install "$home"

    while read -r cmd; do
        [ "$(registered_commands "$home" | grep -cxF "$cmd")" -eq 1 ]
    done < <(registered_commands "$home")
    [ "$(registered_commands "$home" | wc -l)" -eq 4 ]
}

@test "the push guard names no forge, and blocks everything when no host is allowed" {
    run grep -ci gitea "$REPO_ROOT/hooks/git-push-guard.sh"
    [ "$output" = "0" ]
    d="$(mktemp -d)"
    git -C "$d" init -q
    git -C "$d" remote add origin git@anywhere.example:x/y
    git -C "$d" checkout -qb feature
    payload="$(printf '{"tool_input":{"command":"git push origin feature"},"cwd":"%s"}' "$d")"
    # No hosts allowed at all: every push is refused.
    run env DEJIMA=1 DEJIMA_PUSH_HOSTS="" DEJIMA_BLOCKED_BRANCHES="" \
        bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/hooks/git-push-guard.sh"
    [ "$status" -eq 2 ]
    # Allowed host: permitted.
    run env DEJIMA=1 DEJIMA_PUSH_HOSTS="anywhere.example" DEJIMA_BLOCKED_BRANCHES="" \
        bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/hooks/git-push-guard.sh"
    [ "$status" -eq 0 ]
    rm -rf "$d"
}

@test "the merge guard is inert without a configured block pattern" {
    payload='{"tool_input":{"command":"gitea-pr merge 1"},"cwd":"/tmp"}'
    run env DEJIMA=1 DEJIMA_MERGE_BLOCK="" \
        bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/hooks/merge-guard.sh"
    [ "$status" -eq 0 ]
    run env DEJIMA=1 DEJIMA_MERGE_BLOCK="gitea-pr merge" \
        bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/hooks/merge-guard.sh"
    [ "$status" -eq 2 ]
}

@test "a merge-block pattern cannot inject a regex" {
    payload='{"tool_input":{"command":"echo hello"},"cwd":"/tmp"}'
    run env DEJIMA=1 DEJIMA_MERGE_BLOCK=".*" \
        bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/hooks/merge-guard.sh"
    [ "$status" -eq 0 ]
}

@test "an empty DEJIMA_PUSH_HOSTS blocks every push, pinning the fail-closed direction" {
    # DEJIMA_PUSH_HOSTS fails CLOSED: a workflow that never pushes, or an
    # unconfigured forge, must not silently become a workflow that can push
    # anywhere. This must hold even with other hosts and an unrelated
    # (empty) branch policy present, so a later change can't narrow the
    # test to pass while still widening what the guard actually permits.
    d="$(mktemp -d)"
    git -C "$d" init -q
    git -C "$d" remote add origin git@forge.example:x/y
    git -C "$d" checkout -qb feature
    payload="$(printf '{"tool_input":{"command":"git push origin feature"},"cwd":"%s"}' "$d")"
    run env DEJIMA=1 DEJIMA_PUSH_HOSTS="" DEJIMA_BLOCKED_BRANCHES="main" \
        bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/hooks/git-push-guard.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Blocked"* ]]
    rm -rf "$d"
}

@test "an empty DEJIMA_BLOCKED_BRANCHES allows a push to main, pinning the fail-open direction" {
    # DEJIMA_BLOCKED_BRANCHES fails OPEN: a workflow with genuinely no
    # branch policy must not have one manufactured for it by a failure to
    # read the value. The host is explicitly allowed here so only the
    # branch check is under test.
    d="$(mktemp -d)"
    git -C "$d" init -q
    git -C "$d" remote add origin git@forge.example:x/y
    git -C "$d" checkout -qb main
    payload="$(printf '{"tool_input":{"command":"git push origin main"},"cwd":"%s"}' "$d")"
    run env DEJIMA=1 DEJIMA_PUSH_HOSTS="forge.example" DEJIMA_BLOCKED_BRANCHES="" \
        bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/hooks/git-push-guard.sh"
    [ "$status" -eq 0 ]
    rm -rf "$d"
}

@test "an empty DEJIMA_MERGE_BLOCK allows the merge command through, pinning the fail-open direction" {
    # DEJIMA_MERGE_BLOCK fails OPEN: a forge/workflow combination with no
    # merge command to block must leave the hook inert rather than block
    # everything (or nothing meaningful) by accident.
    payload='{"tool_input":{"command":"gitea-pr merge 24 --admin"},"cwd":"/tmp"}'
    run env DEJIMA=1 DEJIMA_MERGE_BLOCK="" \
        bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$REPO_ROOT/hooks/merge-guard.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "dns-proxy.sh enables dnsmasq's stop-dns-rebind protection" {
    grep -qE '^stop-dns-rebind\s*$' "$SANDBOX_DIR/dns-proxy.sh"
    grep -q 'rebind-domain-ok=/\$domain/' "$SANDBOX_DIR/dns-proxy.sh"
}

@test "dns-proxy.sh refuses to start without Docker's embedded resolver, rather than falling back" {
    # The allowlist only works because every forward goes to 127.0.0.11 on
    # loopback; init-firewall.sh has no egress rule for UDP/53 anywhere else
    # on purpose. Resolving via the host's nameservers instead would be an
    # unrestricted-destination DNS channel, so absence must be fatal.
    grep -q "nameserver.*127\\\\.0\\\\.0\\\\.11" "$SANDBOX_DIR/dns-proxy.sh"
    grep -q '/etc/resolv.conf' "$SANDBOX_DIR/dns-proxy.sh"
}

@test "IPv6 blocking fails loud instead of silently swallowing errors once ip6tables is confirmed usable" {
    run grep -E 'ip6tables -P (INPUT|OUTPUT|FORWARD) DROP 2>/dev/null \|\| true' "$SANDBOX_DIR/init-firewall.sh"
    [ "$status" -ne 0 ]
    grep -q 'ip6tables -L >/dev/null 2>&1' "$SANDBOX_DIR/init-firewall.sh"
}

@test "~/.claude skills/commands/agents/output-styles are mounted read-only" {
    # Same persistence-path rationale as the hooks mount: these carry
    # executable skill scripts / injectable command, agent, and output-style
    # prompts that a later unsandboxed host session would run or load.
    # Read-only, and pre-created by bin/dejima since existence is what lets
    # Docker mount them at all.
    local dirs d
    dirs="$(_declared_config_dirs)"
    for d in skills commands agents output-styles; do
        grep -q "^/h/.claude/$d"$'\t'"ro" <<< "$dirs" \
            || { echo "$d is not declared read-only: $dirs"; return 1; }
    done
}

@test "bin/dejima pre-creates every enumerated ~/.claude mount source" {
    # Docker answers a missing bind source by creating a root-owned directory
    # in its place - on the host for the source, and at the destination for
    # the code-carrying dirs, which would leave a session with no skills or
    # hooks and junk on the host either way.
    # Every declared config directory is created before its mount is set up,
    # by one loop over the declarations rather than a list that could fall
    # out of step with what is mounted.
    grep -q 'mkdir -p "$_cdir"' "$REPO_ROOT/bin/dejima"
    grep -q 'harness_config_dirs_load' "$REPO_ROOT/bin/dejima"
    # And the two the state hook mounts an entry at a time, whose parents it
    # creates itself.
    grep -q 'mkdir -p "$projects/$(ws_slug "$ws")"' "$REPO_ROOT/bin/harness/claude-code.sh"
    grep -q 'mkdir -p "$history"' "$REPO_ROOT/bin/harness/claude-code.sh"
    # The set itself, so a directory silently dropped from the declaration
    # fails here rather than presenting as a missing skill in a session.
    local dirs d
    dirs="$(_declared_config_dirs)"
    for d in skills commands agents output-styles hooks plugins \
             backups tasks plans sessions; do
        grep -q "^/h/.claude/$d"$'\t' <<< "$dirs" \
            || { echo "$d is no longer declared: $dirs"; return 1; }
    done
}

@test "bin/dejima overlays the workspace .git/hooks read-only when .git is a real dir" {
    grep -q 'if \[ -d "$WORKSPACE_DIR/.git/hooks" \]' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "$WORKSPACE_DIR/.git/hooks:$WORKSPACE_DIR/.git/hooks:ro")' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima reads allowed domains only from the approval store" {
    [ ! -e "$REPO_ROOT/config/env" ]
    [ ! -e "$REPO_ROOT/bin/dejima-env.sh" ]
    run grep -n 'config/env\|dejima-env' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
    grep -q 'ALLOWED_DOMAINS="$(approved_entries "$(config_root)" allowed-domains' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima snapshots before the run and compares after" {
    grep -q '"$SCRIPT_DIR/dejima-audit" snapshot "$WORKSPACE_DIR"' "$REPO_ROOT/bin/dejima"
    grep -q '"$SCRIPT_DIR/dejima-audit" compare "$WORKSPACE_DIR"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima warns when the workspace is this repo itself (TCB self-mount)" {
    grep -q 'sandbox.s own repo' "$REPO_ROOT/bin/dejima" || \
    grep -q 'TCB' "$REPO_ROOT/bin/dejima"
}

@test "compose carries the credential-proxy env plumbing, empty by default" {
    grep -qE '^\s*ANTHROPIC_BASE_URL:\s*\$\{SANDBOX_ANTHROPIC_BASE_URL:-\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*ANTHROPIC_AUTH_TOKEN:\s*\$\{SANDBOX_ANTHROPIC_AUTH_TOKEN:-\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_ANTHROPIC_PROXY_SOCKET:\s*\$\{SANDBOX_ANTHROPIC_PROXY_SOCKET:-\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "the forwarder is baked into the image and started by the entrypoint when a socket is set" {
    grep -q 'COPY docker/anthropic-proxy-forwarder.js /usr/local/bin/anthropic-proxy-forwarder.js' "$SANDBOX_DIR/Dockerfile"
    grep -q 'if \[ -n "\${SANDBOX_ANTHROPIC_PROXY_SOCKET:-}" \]' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'gosu "\$SANDBOX_USER" node /usr/local/bin/anthropic-proxy-forwarder.js' "$SANDBOX_DIR/entrypoint.sh"
}

@test "entrypoint unsets empty ANTHROPIC_* vars so a disabled proxy changes nothing" {
    grep -q 'unset ANTHROPIC_BASE_URL' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'unset ANTHROPIC_AUTH_TOKEN' "$SANDBOX_DIR/entrypoint.sh"
}

@test "bin/dejima's exit-time audit still runs when the container run fails or is interrupted" {
    local run_line trap_line
    run_line=$(grep -n 'docker compose .* run --rm' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    trap_line=$(grep -n '^trap cleanup EXIT' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
    [ -n "$run_line" ]
    [ -n "$trap_line" ]
    # cleanup() is installed as the EXIT trap before the compose run, so it
    # fires - and runs the audit - on every exit from the run below,
    # including a nonzero/interrupted one under set -e that would otherwise
    # abort the script before a bare audit call placed after the run ever
    # ran.
    [ "$trap_line" -lt "$run_line" ]
    sed -n "1,${trap_line}p" "$REPO_ROOT/bin/dejima" | grep -q '"\$SCRIPT_DIR/dejima-audit" compare "\$WORKSPACE_DIR"'
    # The compose invocation must not itself be a bare command under set -e
    # either - a nonzero/interrupted exit there would otherwise skip the
    # credential-proxy check and the propagated exit code below it.
    grep -q '|| compose_status=\$?' <(sed -n "${run_line}p" "$REPO_ROOT/bin/dejima")
    sed -n "1,${run_line}p" "$REPO_ROOT/bin/dejima" | grep -q 'compose_status=0'
    tail -n "+$run_line" "$REPO_ROOT/bin/dejima" | grep -q 'exit "\$compose_status"'
}

# --- Task 10: the exit-time audit is the structural last writer ---

@test "the exit-time audit is the last thing that writes to the terminal" {
    audit_line=$(grep -n 'dejima-audit" compare' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
    trap_line=$(grep -n '^trap cleanup EXIT' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
    marker_line=$(grep -n 'could not remove the marker directory' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
    epitaph_line=$(grep -n 'dejima-epitaph" save' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
    [ -n "$marker_line" ]
    [ -n "$epitaph_line" ]
    [ "$audit_line" -lt "$trap_line" ]
    # Not just "inside cleanup()" but after the one line in it a session can
    # deliberately provoke to print - the actual last-writer invariant.
    [ "$marker_line" -lt "$audit_line" ]
    # Same invariant, for the other task in the trap that prints: epitaph
    # announces every summary it keeps, so it goes before the verdict.
    [ "$epitaph_line" -lt "$audit_line" ]
    run grep -c 'could not remove the marker directory' "$REPO_ROOT/bin/dejima"
    [ "$output" -eq 1 ]
}

@test "cleanup says what it is doing before each task that takes a while" {
    # A silent terminal between the container exiting and the prompt
    # returning reads as a hung one, and the operator's answer to that is
    # Ctrl-C - during the audit, which is the worst moment for it.
    local d="$REPO_ROOT/bin/dejima" start s1 epi s2 aud
    # Absolute line numbers, so each announcement is checked to sit with the
    # task it names rather than merely somewhere in the same function. The
    # definition of exit_step() itself is above cleanup() and so is skipped.
    start=$(grep -n '^cleanup() {' "$d" | cut -d: -f1)
    epi=$(grep -n 'dejima-epitaph" save' "$d" | head -1 | cut -d: -f1)
    aud=$(grep -n 'dejima-audit" compare' "$d" | head -1 | cut -d: -f1)
    s1=$(awk -v s="$start" 'NR>s && /exit_step /{print NR; exit}' "$d")
    s2=$(awk -v s="$epi" 'NR>s && /exit_step /{print NR; exit}' "$d")
    [ -n "$s1" ] && [ -n "$s2" ] || { echo "no announcement before a task"; return 1; }
    [ "$s1" -lt "$epi" ] || { echo "epitaph runs unannounced"; return 1; }
    [ "$s2" -lt "$aud" ] || { echo "the audit runs unannounced"; return 1; }
    # Gated on the snapshot, the same condition `compare` uses to decide it
    # has work: an exit before the session started is instant, and its last
    # line is the error that caused it - which announcements would bury.
    run sed -n '/^exit_step() {/,/^}/p' "$REPO_ROOT/bin/dejima"
    [ -n "$output" ] || { echo "exit_step is not defined"; return 1; }
    grep -q 'SANDBOX_AUDIT_STATE' <<< "$output"
    # A nonzero status from anything in an EXIT trap replaces the script's.
    grep -q 'return 0' <<< "$output"
}

@test "credential proxy is on by default, gated only by credentials.proxy" {
    grep -q 'config_get_bool credentials proxy' "$REPO_ROOT/bin/dejima"
    grep -Pq 'credentials\.proxy\tbool\ton' "$REPO_ROOT/bin/dejima-config-lib.sh"
}

@test "bin/dejima mounts the proxy socket dir and masks nothing" {
    # The socket dir is how API traffic gets back out to the host-side proxy
    # that holds the real credential. The credential itself, and the
    # .credentials-proxy-tmp staging directory the proxy writes rotated
    # tokens through, used to be covered by empty-file/-directory masks
    # mounted into the read-write ~/.claude mount. That was #50: the proxy's
    # own write-back renamed the credential out from under its mask,
    # detaching it and exposing the real token from the first refresh on.
    # Neither path is mounted at all now, so there is nothing left to mask -
    # the fake credential the tls transport mounts (see below) is a file the
    # container would otherwise not have, not a mask over the operator's.
    grep -q 'extra_mounts+=(-v "\$SANDBOX_ANTHROPIC_PROXY_DIR:\$SANDBOX_ANTHROPIC_PROXY_DIR:ro")' "$REPO_ROOT/bin/dejima"
    run grep -n 'CREDENTIALS_MASK_FILE\|CREDENTIALS_TMPDIR_MASK\|dejima-credentials-mask\|dejima-credentials-tmpdir-mask' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
}

@test "bin/dejima mounts the real credential only when the proxy is off" {
    # With ~/.claude no longer mounted as a whole, the documented
    # SANDBOX_CREDENTIAL_PROXY=0 downgrade no longer gets the credential for
    # free - it has to be stated. Read-write, because Claude Code refreshes
    # it in place. The only mount of it anywhere, and it sits under the
    # proxy-disabled branch.
    run grep -c 'extra_mounts+=(-v "\$HOME/\.claude/\.credentials\.json:\$HOME/\.claude/\.credentials\.json")' "$REPO_ROOT/bin/dejima"
    [ "$output" = "1" ]
    local mount_line branch_line
    mount_line=$(grep -n 'extra_mounts+=(-v "\$HOME/\.claude/\.credentials\.json' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    branch_line=$(grep -n 'elif \[ -f "\$HOME/\.claude/\.credentials\.json" \]; then' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$branch_line" ]
    [ "$branch_line" -lt "$mount_line" ]
}

@test "entrypoint.sh gives the container an empty credentials file of its own" {
    # The mask used to provide one; Claude Code shouldn't have to be trusted
    # to treat an absent credentials file the same as an empty one. Guarded
    # on non-existence so it can't clobber either of the credentials
    # bin/dejima does mount - the fake one under the tls transport, the real
    # one under SANDBOX_CREDENTIAL_PROXY=0 - since mounts are established
    # before the entrypoint runs.
    grep -q 'if \[ ! -e "\$SANDBOX_HOME/\.claude/\.credentials\.json" \]; then' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'install -o "\$SANDBOX_USER" -g "\$SANDBOX_USER" -m 600 /dev/null "\$SANDBOX_HOME/\.claude/\.credentials\.json"' "$SANDBOX_DIR/entrypoint.sh"
}

@test "bin/dejima refuses to launch when the proxy fails to start" {
    # Falling back to mounting the real credential would be a silent
    # security downgrade - the failure must be loud and the launch aborted.
    grep -q 'Credential proxy failed to start' "$REPO_ROOT/bin/dejima"
    grep -q '\[credentials\] proxy = off' "$REPO_ROOT/bin/dejima"
}

@test "cleanup reaps the proxy and its socket dir" {
    grep -q 'kill "\$SANDBOX_ANTHROPIC_PROXY_PID"' "$REPO_ROOT/bin/dejima"
    grep -q '"\${SANDBOX_ANTHROPIC_PROXY_DIR:-}"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima warns if the proxy died before the session ended" {
    grep -q 'credential proxy exited before' "$REPO_ROOT/bin/dejima"
}

@test "docker-compose.yml pins the compose project name so dejima-allow's label filter matches" {
    # bin/dejima-allow discovers running sandboxes via the
    # com.docker.compose.project=dejima label; without an explicit
    # top-level name, compose derives the project from the compose file's
    # directory ("docker"), which varies by checkout and breaks discovery.
    grep -qE '^name: dejima\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "sandbox-context.sh gives the agent its own container ID for dejima-allow" {
    # Agents used to guess their container ID and could hand back another
    # running sandbox's ID, making dejima-allow "succeed" against
    # the wrong container. /etc/hostname inside a container is its real ID.
    grep -q '/etc/hostname' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q -- '--container' "$REPO_ROOT/hooks/sandbox-context.sh"
}

@test "bin/dejima-allow ends with a real reachability check, not just config changes" {
    # "It said allowed but the sandbox still can't reach it" was a real
    # failure mode (wrong container targeted / stale ipset) - the script
    # must verify from inside the target container and say so definitively.
    grep -q 'connect-timeout' "$REPO_ROOT/bin/dejima-allow"
    grep -q 'Verified:' "$REPO_ROOT/bin/dejima-allow"
    grep -q 'NOT reachable' "$REPO_ROOT/bin/dejima-allow"
}

@test "bin/dejima-allow's multi-container error points at the sandbox's own ID" {
    grep -q '/etc/hostname' "$REPO_ROOT/bin/dejima-allow"
}

@test "bin/dejima-allow --global no longer rewrites config/env" {
    # --global persists to the host-side approval store now (Task 3); the old
    # sed -i rewrite of config/env's ALLOWED_DOMAINS is gone for good.
    run grep -F 'config/env' "$REPO_ROOT/bin/dejima-allow"
    [ "$status" -ne 0 ]
    run grep -F 'sed -i' "$REPO_ROOT/bin/dejima-allow"
    [ "$status" -ne 0 ]
}

@test "bin/dejima scans only the mounted ~/.claude dirs for symlink targets" {
    # A symlink inside one of these has to have its target reachable, or the
    # hook/skill it points at can't run in the container. Top-level files
    # (settings.json, CLAUDE.md, statusline.sh) are staged as copies instead,
    # and Docker resolves any symlink among them when it sets up that mount -
    # so scanning "." as well would mount a whole config checkout read-only
    # into the container for nothing.
    # The scan flag is per directory now, declared by the harness: an entry
    # in hooks/ or skills/ is routinely a link into a dotfiles checkout,
    # while plugins/ is bookkeeping the harness writes for itself.
    local dirs d
    dirs="$(_declared_config_dirs)"
    for d in hooks skills commands agents output-styles; do
        grep -q "^/h/.claude/$d"$'\t'"ro"$'\t'"scan" <<< "$dirs" \
            || { echo "$d is not scanned for symlink targets: $dirs"; return 1; }
    done
    grep -q "^/h/.claude/plugins"$'\t'"ro"$'\t'"scan" <<< "$dirs" \
        && { echo "plugins should not be scanned: $dirs"; return 1; }
    grep -q 'mounted_scan' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima stages ~/.claude/statusline.sh for copying, when present" {
    # settings.json's statusLine.command points at it and Claude Code
    # executes it on the host, so it's the same class of file as the config
    # staged at /etc/dejima-claude by docker-compose.yml, and staged the same
    # way. A read-only mount at its real path protected only the
    # plain-regular-file case: when statusline.sh is itself a symlink (the
    # common case, into a dotfiles checkout), bind-mount destination
    # resolution followed it, so the mount landed on the target and left the
    # symlink dentry writable and replaceable. Docker resolves that symlink
    # when it sets up the staging mount instead, so what entrypoint.sh copies
    # in is the real content at a path nothing on the host can reach. Still
    # conditional on existence: not every host has a statusline, and mounting
    # a nonexistent source would make Docker create a root-owned directory at
    # the target instead.
    # Declared by the harness with the rest of its staged config, and mounted
    # into the staging tree by core.
    grep -q 'emit_staged_config "$HOME/.claude/$f" ".claude/$f"' \
        "$REPO_ROOT/bin/harness/claude-code.sh"
    grep -q 'extra_mounts+=(-v "$_ssrc:/etc/dejima-harness/$_srel:ro")' "$REPO_ROOT/bin/dejima"
    # Executable staged files land executable; that distinction is what the
    # 555 used to encode, and it is now read from the source rather than
    # hardcoded per filename.
    grep -q 'install -o root -g root -m 555' "$SANDBOX_DIR/entrypoint.sh"
    run grep -F 'extra_mounts+=(-v "$HOME/.claude/statusline.sh:$HOME/.claude/statusline.sh' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
}

@test "bin/dejima refuses to launch rather than silently skip a dangling statusline.sh symlink" {
    # Plain -e follows symlinks and is false for a *dangling* one (target
    # doesn't exist, e.g. a dotfiles checkout that isn't present) - silently
    # skipping the mount in that case would reopen the exact gap the test
    # above closes. Docker also can't just attempt the mount anyway: it fails
    # deep in mount setup with an opaque "mkdir ...: file exists" (the
    # symlink already occupies that path), unconnected to the statusline for
    # the user. So this must be a hard, explicit error - same fail-loud
    # precedent as the credential proxy refusing to launch rather than
    # silently mounting the real OAuth credential.
    # The check is core's, over every staged file the harness declares - a
    # plugin filtering on existence itself would skip a dangling one silently,
    # which is the case this refuses for.
    grep -q 'if \[ -L "\$_ssrc" \] && \[ ! -e "\$_ssrc" \]' "$REPO_ROOT/bin/dejima"
    grep -q "Docker can't bind-mount a dangling symlink" "$REPO_ROOT/bin/dejima"
    run grep -n '\[ -e "\$HOME/\.claude/\$f" \]' "$REPO_ROOT/bin/harness/claude-code.sh"
    [ "$status" -ne 0 ] || { echo "the plugin filters on existence, hiding a dangling symlink"; return 1; }
}

@test "bin/dejima-audit monitors the home-level ~/.claude/statusline.sh (Finding 1 compensating control)" {
    # Staging it (the test above) is what actually closes the symlink gap the
    # old read-only mount left open; this stays as defence in depth, since a
    # session reaching the host statusline by some other route is exactly the
    # kind of thing an exit-time audit exists to surface. Full behavioral
    # coverage (snapshot/compare
    # against real fixtures, including the symlink-swap exploit) lives in
    # test/audit.bats; this just confirms the wiring exists.
    # The path and its label are the harness plugin's now; the mechanism
    # that snapshots and reports them is still the audit's.
    grep -q 'host_exec_snapshot' "$REPO_ROOT/bin/dejima-audit"
    grep -q 'host_exec_load' "$REPO_ROOT/bin/dejima-audit"
    grep -q 'statusline_path' "$REPO_ROOT/bin/harness/claude-code.sh"
    grep -q 'HOST-CODE-EXECUTION' "$REPO_ROOT/bin/harness/claude-code.sh"
}

@test "Dockerfile installs the sandbox clipboard fallback into nvim's VIMRUNTIME plugin dir" {
    # $VIMRUNTIME/plugin, NOT /etc/xdg/nvim: lazy.nvim's performance.rtp
    # reset strips /etc/xdg from the runtimepath, but always keeps
    # $VIMRUNTIME - this must load for lazy-managed configs too.
    grep -q 'COPY docker/sandbox-clipboard.lua /usr/local/share/nvim/runtime/plugin/sandbox-clipboard.lua' "$SANDBOX_DIR/Dockerfile"
}

@test "conversation shipping is opt-in, and runs on the host rather than in the session" {
    # It reads transcripts that are bind-mounted from the host, so it never
    # needed to be inside - and being inside put it in a process the session
    # shared a filesystem and a signal namespace with, where killing it
    # ended its own logging with nothing on the host noticing.
    grep -q 'config_get_bool logging conversation' "$REPO_ROOT/bin/dejima-conversation-ship"
    grep -q 'exit 0' "$REPO_ROOT/bin/dejima-conversation-ship"
    # Gone from the container entirely: the shipper there no longer reads
    # anything the session writes.
    run grep -n 'SANDBOX_LOG_CONVERSATION\|watch_transcripts\|transform_transcript' \
        "$SANDBOX_DIR/log-shipper.sh" "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ] || { echo "conversation shipping is still in the container:"; echo "$output"; return 1; }
    # And stopped before the exit-time audit, so the last lines a session
    # produced are shipped rather than discarded with the batch.
    local ship_line audit_line
    ship_line=$(grep -n 'SANDBOX_CONVERSATION_SHIP_PID' "$REPO_ROOT/bin/dejima" | sed -n '2p' | cut -d: -f1)
    audit_line=$(grep -n 'dejima-audit" compare' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
    [ "$ship_line" -lt "$audit_line" ]
}

@test "the transcript transform ships prompts/responses/tool commands, skips results/meta/thinking" {
    fixtures='{"type":"user","sessionId":"s1","isMeta":null,"message":{"role":"user","content":"fix the login bug"}}
{"type":"user","sessionId":"s1","isMeta":true,"message":{"role":"user","content":"meta noise"}}
{"type":"user","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","content":"tool output secret"}]}}
{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"thinking","thinking":"hidden reasoning"},{"type":"text","text":"done, deployed the fix"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}
this line is not json'
    # The transform is the harness's - it is a fact about that harness's
    # transcript format - so it lives in the plugin now. What it must and
    # must not ship is unchanged.
    run bash -c "
        source '$REPO_ROOT/bin/dejima-provider-lib.sh'
        source '$REPO_ROOT/bin/dejima-harness-lib.sh'
        harness_plugin_load claude-code
        harness_transform_transcript <<< \"\$1\"" _ "$fixtures"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"role":"user"'* ]]
    [[ "$output" == *"fix the login bug"* ]]
    [[ "$output" == *'"role":"assistant"'* ]]
    [[ "$output" == *"done, deployed the fix"* ]]
    [[ "$output" == *'"role":"tool"'* ]]
    [[ "$output" == *'ls -la'* ]]
    [[ "$output" != *"meta noise"* ]]
    [[ "$output" != *"tool output secret"* ]]
    [[ "$output" != *"hidden reasoning"* ]]
    [[ "$output" != *"not json"* ]]
}

@test "every container runtime.bats starts is attached to a user-defined network" {
    # On the default bridge there's no 127.0.0.11, so dns-proxy.sh aborts and
    # the container dies mid-startup - which used to surface as flaky,
    # sometimes vacuous tests rather than an obvious failure. See runtime.bats'
    # wait_ready comment.
    # Detached and foreground starts both count - the transport test runs its
    # container in the foreground, to read the container's own streams rather
    # than the daemon's log driver (see its comment), and it needs a network
    # every bit as much as the detached ones.
    #
    # Exempted: runs that replace the entrypoint with a plain shell. Those
    # never reach dns-proxy.sh, so there is nothing for a resolver to be
    # missing from - the image/checkout comparison in setup_file is one, and it
    # only runs md5sum.
    local runs networks
    runs=$(grep -E '^\s*(run timeout [0-9]+ )?docker run ' "$REPO_ROOT/test/runtime.bats" \
        | grep -vc -- '--entrypoint sh')
    networks=$(grep -cE '^\s*--network ' "$REPO_ROOT/test/runtime.bats")
    [ "$runs" -gt 0 ]
    [ "$runs" -eq "$networks" ] || {
        echo "$runs container starts that run the real entrypoint, but $networks --network flags" >&2
        false
    }
}

@test "runtime.bats readiness waits for the final sleep infinity, not any startup sleep" {
    # A bare `pgrep -x sleep` also matches dns-proxy.sh's dig-retry sleep and
    # entrypoint.sh's forwarder-bind sleep, both of which run before
    # init-firewall.sh has installed anything - asserting there would find
    # OUTPUT ACCEPT and no ipsets, passing egress tests for the wrong reason.
    grep -qF "pgrep -x -f 'sleep infinity'" "$REPO_ROOT/test/runtime.bats"
    run grep -nE 'docker exec.*pgrep -x sleep' "$REPO_ROOT/test/runtime.bats"
    [ "$status" -ne 0 ]
}

@test "dejima-allow has no env-triggered path that skips the live session" {
    # DEJIMA_ALLOW_SKIP_SESSION used to exist as a test-only escape hatch, and
    # by the end was consulted by nothing: every caller passed --project or
    # --global, which set session_wanted=0 on their own. An environment
    # variable that turns a firewall CLI into a silent no-op is worth keeping
    # out on purpose, not just deleting once - which is what this pins.
    # Matched on the read and the write, not the bare name: both files below
    # still name it in a comment explaining why it is gone, and a grep that
    # tripped on its own rationale would have to be deleted to pass.
    run grep -n '\${\?DEJIMA_ALLOW_SKIP_SESSION' "$REPO_ROOT/bin/dejima-allow"
    [ "$status" -ne 0 ]
    run grep -rn --exclude=static.bats 'DEJIMA_ALLOW_SKIP_SESSION=' \
        "$REPO_ROOT/test" "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
}

@test "dejima-allow's usage puts the domain last" {
    grep -q 'Usage: dejima-allow \[--global\] \[--project \[path\]\] \[--container <id>\] <domain>' \
        "$REPO_ROOT/bin/dejima-allow"
}

@test "bin/dejima merges approved project domains into ALLOWED_DOMAINS" {
    grep -q 'dejima-project-lib.sh' "$REPO_ROOT/bin/dejima"
    grep -q 'resolve_project_store "$WORKSPACE_DIR"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima never reads a declaration file as a grant" {
    # .dejima/ in the workspace is session-writable. It may only be
    # read by the reporting/approval path, never by the launcher deciding
    # what to allow.
    run grep -n '\.dejima/' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml image honors SANDBOX_IMAGE with today's default" {
    grep -qE '^\s*image:\s*\$\{SANDBOX_IMAGE:-dejima:\$\{SANDBOX_USER:-node\}\}\s*$' \
        "$SANDBOX_DIR/docker-compose.yml"
}

@test "bin/dejima explicitly builds the base image, pinned to the base tag on that exact line" {
    # docker-compose.yml's image: now honors $SANDBOX_IMAGE (see the test
    # above), so an unpinned `compose build claude` would inherit whatever
    # $SANDBOX_IMAGE happens to be in the caller's environment - e.g. a
    # derived tag left over from a previous project session - and rebuild
    # the base Dockerfile under that name instead of the base tag. Anchored
    # to the line immediately before the build invocation itself: the
    # fallback `SANDBOX_IMAGE="dejima:${SANDBOX_USER}"` assignment a
    # couple of lines later would satisfy a looser "does the pin appear
    # anywhere in the file" check just as well, without actually applying to
    # this build.
    local build_line
    build_line=$(grep -n 'docker compose -f "\$COMPOSE_FILE" build claude' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$build_line" ]
    run sed -n "$((build_line - 1))p" "$REPO_ROOT/bin/dejima"
    [[ "$output" == 'SANDBOX_IMAGE="dejima:${SANDBOX_USER}" \' ]]
}

@test "the derived image build never uses the workspace as its build context" {
    # A root-context build with the untrusted project as context would let a
    # session's own files influence the image it then runs in.
    run grep -n 'docker build.*"\$WORKSPACE_DIR"' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
    grep -q 'SANDBOX_DERIVED_CONTEXT' "$REPO_ROOT/bin/dejima"
}

@test "the global dependency layer is built under the -global tag, guarded by the global store" {
    # Anchored to the line immediately before the call: a file-wide grep for
    # the guard or the tag alone would pass even if they'd drifted apart.
    local call_line
    call_line=$(grep -n 'build_dep_layer "dejima:\${SANDBOX_USER}-global"' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$call_line" ]
    run sed -n "$((call_line - 1))p" "$REPO_ROOT/bin/dejima"
    [[ "$output" == 'if [ -s "$(config_root)/dependencies" ]; then' ]]
}

@test "build_dep_layer advances SANDBOX_IMAGE to the tag it just built" {
    # Without this, the second call in a global+project build would build the
    # project layer FROM the base image instead of FROM the global layer.
    grep -q 'SANDBOX_IMAGE="\$tag"' "$REPO_ROOT/bin/dejima"
}

@test "the project dependency layer is still guarded by a non-empty PROJECT_STORE" {
    local call_line
    call_line=$(grep -n 'build_dep_layer "dejima:\${SANDBOX_USER}-\$(project_slug' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$call_line" ]
    run sed -n "$((call_line - 1))p" "$REPO_ROOT/bin/dejima"
    [[ "$output" == 'if [ -n "$PROJECT_STORE" ] && [ -s "$PROJECT_STORE/dependencies" ]; then' ]]
}

@test "the approval store is never mounted into the container" {
    # The store is the only thing that actually grants anything, and the
    # container runs an agent with no tool-use confirmations - mounting it
    # anywhere, at any mode, would let a session widen its own next launch
    # (a read-only mount still leaks every other project's approvals).
    run grep -nE 'config/dejima|DEJIMA_CONFIG_DIR|PROJECT_STORE' \
        "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
    run grep -nE '^\s*extra_mounts\+=.*(PROJECT_STORE|config_root)' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
    # Both greps are literal, so neither can see a mount whose path is
    # computed at run time - and two of those reached the store (#15): a
    # [mounts] readonly entry naming it, and a ~/.claude symlink pointing
    # into it. What refuses them is asserted by running the launcher, in
    # config.bats ("refused when it names the approval store"). This test
    # is the cheap half and does not stand in for that one.
    grep -q '_refuse_guarded_mount' "$REPO_ROOT/bin/dejima"
}

@test "sandbox-context escapes a declared domain's dots before matching the servers file" {
    # $dom comes straight off a session-writable declaration and lands in a
    # grep BRE, where an unescaped "." matches any character: a project could
    # declare "aexample.com" and have the hook match the server= line for an
    # already-approved "a.example.com", reporting an unapproved domain as
    # allowed. Anchored to the matching line itself - the servers file is an
    # absolute path only the container has, so this can't be driven from a
    # host-side test, and a file-wide grep would be satisfied by the same
    # expression appearing anywhere else.
    run grep -n 'dnsmasq-sandbox-servers.conf' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    [[ "$output" == *'grep -q "^server=/${dom//./\\.}/"'* ]]
}

@test "sandbox-context reads its stdin payload once" {
    # jq is called more than once now (session_id and cwd); reading stdin
    # twice would silently give the second call nothing.
    grep -q 'payload=$(cat)' "$REPO_ROOT/hooks/sandbox-context.sh"
    run grep -c "jq -r '\.session_id" "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$output" -eq 1 ]
}

@test "sandbox-context probes declared dependencies and never treats them as granted" {
    grep -q 'dpkg-query' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q 'npm ls -g' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q 'pip list' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q 'cargo install --list' "$REPO_ROOT/hooks/sandbox-context.sh"
    # domains are checked against what this container actually resolves,
    # not against the host-side approval store it cannot see
    grep -q 'dnsmasq-sandbox-servers.conf' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q 'dejima-project approve' "$REPO_ROOT/hooks/sandbox-context.sh"
}

# The hook answers "is this installed?" per kind, and a tarball has no
# package manager to ask - it is there if its directory is. A tarball spec
# falling through to the package-name regex would be silently skipped, which
# reads to the agent as "declared and present" for something that is neither.
@test "sandbox-context reports a declared tarball dependency that is not unpacked" {
    local ws; ws="$(mktemp -d)"
    local sha=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    mkdir -p "$ws/.dejima"
    printf 'tarball:definitely-not-here@%s:https://example.com/x.tar.gz\n' "$sha" > "$ws/.dejima/dependencies"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"
    [[ "$out" == *"definitely-not-here"* ]]
    # The digest reaches the agent intact: it is what the operator is being
    # asked to approve, so a truncated form would be asking them to agree to
    # something they cannot see.
    [[ "$out" == *"$sha"* ]]
}

# The positive half of the test above. It needs a tarball dependency actually
# unpacked in the image, which only exists once a project has approved one -
# so on an image with none it skips rather than silently asserting nothing.
# A visible skip is the honest form here; a test that arranged its own
# /opt/dejima entry would be checking that mkdir works.
#
# The branch itself is pinned by the source-level test below, which holds
# regardless of what this image happens to contain.
@test "sandbox-context does not report a tarball dependency that is unpacked" {
    local present=""
    for d in /opt/dejima/*/; do [ -d "$d" ] && present="$(basename "$d")" && break; done
    [ -n "$present" ] || skip "no unpacked tarball dependency in this image"
    local ws; ws="$(mktemp -d)"
    local sha=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    mkdir -p "$ws/.dejima"
    printf 'tarball:%s@%s:https://example.com/x.tar.gz\n' "$present" "$sha" > "$ws/.dejima/dependencies"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"
    [[ "$out" != *"$present"* ]]
}

# runtime.bats proves the derived-image dependency mechanism works by
# declaring apt:cowsay and then finding cowsay installed. That only proves
# anything while the base image does not ship it - otherwise the assertion
# passes with the mechanism entirely broken. runtime.bats checks this for
# itself too, but only where Docker exists; this catches it in the suite that
# runs everywhere, at the point the package list changes.
@test "the base image ships none of the packages used as dependency fixtures" {
    for pkg in $(grep -oE "apt:[a-z0-9.+-]+" "$REPO_ROOT/test/runtime.bats" | cut -d: -f2 | sort -u); do
        run grep -nE "^ +$pkg \\\\$" "$SANDBOX_DIR/Dockerfile"
        [ "$status" -ne 0 ] || {
            echo "$pkg is a dependency-test fixture and is also in the base image" >&2
            false
        }
    done
}

# The image ships the sandbox's own machinery and the tooling with no route
# through dejima-dep. A language toolchain has a route - tarball: - so one
# appearing here means every project carries it with nobody having asked.
@test "no language toolchain is installed into the base image" {
    run grep -nE '^(RUN|ENV).*(golang|/usr/local/go|rustup|\.cargo/bin|pyenv|rbenv|sdkman)' \
        "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ] || {
        echo "declare it with dejima-dep instead:" >&2
        echo "$output" >&2
        false
    }
}

@test "sandbox-context decides a tarball is present by its unpack directory" {
    grep -q '\[ -d "/opt/dejima/\$name" \] && continue' "$REPO_ROOT/hooks/sandbox-context.sh"
}

@test "sandbox-context reports nothing when no project declarations exist" {
    local ws; ws="$(mktemp -d)"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"
    [[ "$out" != *"declares requirements"* ]]
}

@test "sandbox-context still reports a declared dependency with no trailing newline" {
    # A while/read loop fed straight from the file drops a final line that
    # has no trailing newline - not a validation rejection, just never read.
    local ws; ws="$(mktemp -d)"
    mkdir -p "$ws/.dejima"
    printf 'apt:definitely-not-installed-noeol' > "$ws/.dejima/dependencies"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"
    [[ "$out" == *"definitely-not-installed-noeol"* ]]
}

@test "sandbox-context bounds a huge declaration file instead of emitting nothing" {
    # .dejima/ is on the read-write workspace mount, so a compromised
    # session can append to it at will. Unbounded, that used to push the
    # assembled context past Linux's 128 KiB MAX_ARG_STRLEN and make jq fail
    # outright - costing every later session in the project its entire
    # briefing (sandbox notice, worktree rule, never-push-to-main rule), and
    # destroying the very report that would have named the junk.
    local ws lab i; ws="$(mktemp -d)"
    mkdir -p "$ws/.dejima"
    lab="$(printf 'a%.0s' $(seq 1 62))"
    for i in $(seq 1 700); do printf 'x%03d.%s.%s.%s\n' "$i" "$lab" "$lab" "$lab"; done \
        > "$ws/.dejima/allowed-domains"
    local b; b="$(mktemp)"
    printf 'dejima Docker container\n' > "$b"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" \
        | DEJIMA=1 DEJIMA_BRIEFING_FILE="$b" bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"; rm -f "$b"
    printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    [[ "$out" == *"dejima Docker container"* ]]
    # 700 declared, 200 considered (the cap read_declared applies host-side),
    # 20 of those named and the remaining 180 only counted. Both caps have to
    # hold for this exact number to appear.
    [[ "$out" == *"(+180 more)"* ]]
    [ "$(printf '%s' "$out" | wc -c)" -lt 16000 ]
    # The context must not travel as a single argv element even so - staying
    # just inside a limit is not the same as not having one.
    run grep -n 'jq -n --arg context' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -ne 0 ]
}

@test "sandbox-context probes each ecosystem once, not once per declared entry" {
    # An `npm ls -g` fork costs about a second, so one per declared entry
    # would run 200 of them at the cap - past Claude Code's hook timeout,
    # which drops the injected context just as completely as a jq failure.
    local ws stub i; ws="$(mktemp -d)"; stub="$(mktemp -d)"
    mkdir -p "$ws/.dejima"
    for i in $(seq 1 50); do echo "npm:nosuchpkg$i"; done > "$ws/.dejima/dependencies"
    cat > "$stub/npm" <<EOF
#!/bin/sh
echo call >> "$stub/calls"
exit 1
EOF
    chmod +x "$stub/npm"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" \
        | PATH="$stub:$PATH" DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    local calls; calls=$(wc -l < "$stub/calls")
    rm -rf "$ws" "$stub"
    [ "$calls" -eq 1 ]
    [[ "$out" == *"nosuchpkg1"* ]]
}

@test "sandbox-context ignores a dotless declared domain instead of echoing it verbatim" {
    # A bare word is not a domain this hook could ever be reporting on, so
    # accepting one only lets a session put arbitrary text into the next
    # session's context under a heading that reads as the project speaking.
    local ws; ws="$(mktemp -d)"
    mkdir -p "$ws/.dejima"
    printf 'IGNORE-PREVIOUS-INSTRUCTIONS\nreal.example.com\n' > "$ws/.dejima/allowed-domains"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"
    [[ "$out" != *"IGNORE-PREVIOUS-INSTRUCTIONS"* ]]
    [[ "$out" == *"real.example.com"* ]]
}

@test "install.sh links the per-project CLIs alongside the existing ones" {
    grep -qx 'link_bin dejima-dep' "$REPO_ROOT/install.sh"
    grep -qx 'link_bin dejima-project' "$REPO_ROOT/install.sh"
}

@test "install.sh puts the exit-time audit CLI on PATH" {
    # bin/dejima's own startup warning tells the operator to run
    # `dejima-audit ack ...` by name; that instruction is only true if the
    # installer links it like every other user-facing CLI here.
    grep -qx 'link_bin dejima-audit' "$REPO_ROOT/install.sh"
}

@test "README documents the declaration/approval split" {
    grep -q '\.dejima/' "$REPO_ROOT/README.md"
    grep -q 'dejima-project approve' "$REPO_ROOT/README.md"
    grep -q 'dejima-dep' "$REPO_ROOT/README.md"
}

@test "README no longer documents the removed config/env flow" {
    run grep -n 'config/env\|dejima-env' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
}

@test "README documents dejima-dep --global" {
    grep -q 'dejima-dep add --global cargo:cargo-nextest' "$REPO_ROOT/README.md"
}

@test "README documents that the exit-time audit's findings are not attributed to the session" {
    # Presence-only grep - it confirms the caveat sentence exists in the
    # Security notes teaser, not that the linked docs/security.md
    # explanation it points readers to is itself correct or complete.
    grep -q 'not a verdict on who caused them' "$REPO_ROOT/README.md"
}

# The absence of a finding needs documenting as much as a finding does, so
# that not detecting something stays a stated decision rather than something
# a reader has to infer from silence.
@test "docs/security.md says why there is no cross-project finding" {
    grep -q 'deliberately no .CROSS-PROJECT. finding' "$REPO_ROOT/docs/security.md"
    run grep -n 'CROSS-PROJECT history/memory write' "$REPO_ROOT/bin/dejima-audit"
    [ "$status" -ne 0 ] || { echo "the finding is back but the doc says it is gone" >&2; false; }
}

# The CI disclosure is the one part of issue #72 that helps a reader whatever
# else is or isn't mitigated on their runners, so it is pinned in all three
# places rather than left to survive a future edit on its own. Presence-only
# greps, same caveat as the two above.
@test "README and docs/security.md both disclose that push access is CI code execution" {
    for f in README.md docs/security.md; do
        grep -q 'push access is code execution elsewhere' "$REPO_ROOT/$f"
        grep -qi 'forge = none' "$REPO_ROOT/$f"
    done
}

@test "core never reads a harness's config by a literal harness name" {
    # `keys` is declared per harness, so a fixed [harness.<name>] at a call
    # site makes it a declaration only one harness can ever be read through:
    # a second harness is selected, is validated, and is then handed the
    # first one's paths with nothing erroring anywhere. A silent wrong
    # answer, so it gets a test rather than a convention.
    run grep -rn 'config_get["'"'"' ]*harness\.[a-z]' "$REPO_ROOT/bin"
    [ "$status" -ne 0 ] || { echo "use harness_config_get instead:"; echo "$output"; return 1; }
    grep -q '^harness_config_get()' "$REPO_ROOT/bin/dejima-provider-lib.sh"
}

@test "the harness guide states the bar a harness has to clear" {
    # Support is per harness and deliberate, at the depth Claude Code has.
    # That only holds if the requirements are written down: without them
    # each new harness is argued about rather than measured, and the first
    # one that cannot host a guard gets waved through.
    local sec r
    grep -q '^## Adding a new harness' "$REPO_ROOT/docs/development.md"
    sec="$(sed -n '/^### What a harness must be able to do/,/^### What the manifest/p' \
        "$REPO_ROOT/docs/development.md")"
    [ -n "$sec" ] || { echo "the capability bar is gone"; return 1; }
    for r in R1 R2 R3 R4 R5; do
        grep -q "\*\*$r\*\*" <<< "$sec" || { echo "no $r in the bar"; return 1; }
    done
    # Unattended execution is the premise every other control is justified
    # against, so it stays stated rather than assumed.
    grep -qi 'without confirming each one' <<< "$sec"
}

@test "a harness dejima declines is declined against a stated requirement" {
    # The reason has to point at a rule. Otherwise the bar is decoration and
    # the next harness is decided on how much someone wants it.
    local sec
    sec="$(sed -n '/^### Worked example/,/^### What the manifest/p' \
        "$REPO_ROOT/docs/development.md")"
    [ -n "$sec" ] || { echo "no worked example of a refusal"; return 1; }
    grep -q 'R2' <<< "$sec" \
        || { echo "the refusal names no requirement it failed"; return 1; }
}

@test "docs/ci.md exists and is linked from the README and docs/security.md" {
    [ -f "$REPO_ROOT/docs/ci.md" ]
    grep -q 'docs/ci\.md' "$REPO_ROOT/README.md"
    grep -q '(ci\.md)' "$REPO_ROOT/docs/security.md"
}

# The whole allowlist argument in docs/ci.md rests on reading the declaration
# from the branch the operator controls. A future edit that softens this into
# "read .dejima/allowed-domains" without saying from where would leave the
# document describing a control that doesn't control anything.
# runs-on lives in the workflow file, which lives in the branch, so a
# dedicated label routes honest jobs and stops nothing else. An earlier version
# of this document said jobs "cannot land anywhere else", which is true only of
# a branch that is not trying - the exact distinction the rest of the document
# is built on. Pinned so it cannot quietly come back.
# The counterintuitive half of the advisory, and the one a reader is most
# likely to skip: a project with no CI is exposed too, because a branch adds
# the first workflow. If that goes missing, the document reads as being about
# people who already run CI, which is the smaller group.
# Who wrote the prose. The repository argues at length in a voice that is not
# its maintainer's, and saying so is the difference between disclosure and
# letting a reader assume. Pinned because it is the kind of line that goes
# quietly in a tidy-up, and its absence is not visible from anything else.
@test "the README says the prose is written by agents" {
    grep -q 'A note from the developer' "$REPO_ROOT/README.md"
    grep -q 'the words are written rapidly' "$REPO_ROOT/README.md"
    # the contrast that makes both claims credible: ATTRIBUTION.md says the
    # artwork is the other way round, and the README points at it
    grep -q 'no AI tools were used to create it' "$REPO_ROOT/README.md"
    grep -q 'No AI tools were used' "$REPO_ROOT/ATTRIBUTION.md"
}

# The maturity disclaimer, pinned in all three places a reader can land. A
# project that argues at length for its own security properties is exactly the
# one that has to say those properties are unreviewed - and it is the first
# thing that gets quietly dropped as a project starts to feel established.
@test "every entry point says this is unreviewed early development" {
    local f
    for f in README.md SECURITY.md docs/security.md; do
        grep -q 'reviewed by anyone else\|outside review' "$REPO_ROOT/$f" || {
            echo "$f does not say the work is unreviewed" >&2
            false
        }
    done
    grep -q 'Not ready to be depended on' "$REPO_ROOT/README.md"
    grep -q 'not proven software' "$REPO_ROOT/SECURITY.md"
}

# The GitHub push default was documented as mechanism only - port 443, port 22
# unreachable - and a reader who needed the reason inferred the wrong one: that
# it is a containment measure against a hostile session. It is not. The
# repositories on the other side are other people's, and the failure it
# prevents takes no compromise, only an agent being helpful at a stranger's
# expense. Pinned in both places a reader lands, because getting this wrong
# leads someone to turn the flag on believing it costs them nothing.
@test "the GitHub push default is documented with its reason, not just its mechanism" {
    # Matched on a fragment rather than the whole sentence: it wraps
    # differently in each file, and a line-based grep cannot span that.
    local f
    for f in README.md docs/security.md; do
        grep -q 'not being used to push' "$REPO_ROOT/$f" || {
            echo "$f gives the mechanism without the principle" >&2
            false
        }
    done
    # the eager-agent case, which is what makes the principle concrete - and
    # that it is not softened into a well-meaning near-miss. The unsolicited
    # pull request is the thing being prevented, not a good deed with bad
    # timing; docs/responsible-use.md is where the cost to maintainers is set
    # out, and this must not read as disagreeing with it.
    grep -q 'an eager agent, not a compromised one' "$REPO_ROOT/docs/security.md"
    grep -q 'does not make it harmless' "$REPO_ROOT/docs/security.md"
    # and the ordering a reader got backwards: CI follows from the principle
    # rather than being the reason for it
    grep -q 'not the$\|reason for it' "$REPO_ROOT/docs/security.md"
    grep -q 'dont-point-it-at-repositories-you-dont-own' "$REPO_ROOT/docs/security.md"
}

# The branch convention is only a convention - nothing refuses a pull request
# aimed at main - so the three places an agent or a contributor looks have to
# agree, or the one that is stale becomes the instruction someone follows.
@test "the development-branch convention is stated where it is looked for" {
    local f
    for f in .dejima.md CONTRIBUTING.md docs/development.md; do
        grep -q 'development' "$REPO_ROOT/$f" || {
            echo "$f does not mention the development branch" >&2
            false
        }
    done
    # and the one thing that is easy to get wrong: gitea-pr's default base
    grep -q -- '--base development' "$REPO_ROOT/.dejima.md"
    grep -q -- '--base development' "$REPO_ROOT/docs/development.md"
}

@test "docs/ci.md says a project with no CI is exposed too" {
    grep -q 'applies to projects with no CI at all' "$REPO_ROOT/docs/ci.md"
    grep -q 'no workflows is not therefore safe' "$REPO_ROOT/docs/ci.md"
    grep -qi 'holds for projects with no CI' "$REPO_ROOT/README.md"
}

# Moving a public project to another owner breaks its name, its links and its
# ownership. It must not read as the recommended answer, and the alternatives
# that require moving nothing have to be present.
@test "docs/ci.md offers answers that do not require moving a repository" {
    local f="$REPO_ROOT/docs/ci.md"
    grep -q 'Scope the dangerous runner down, rather than moving' "$f"
    grep -q 'Turn CI off for that repository' "$f"
    grep -q 'Do not grant push' "$f"
}

@test "docs/ci.md does not present the runner label as a boundary" {
    grep -q 'A label is not a boundary' "$REPO_ROOT/docs/ci.md"
    grep -q 'weakest runner it can reach' "$REPO_ROOT/docs/ci.md"
    run grep -n 'cannot land anywhere else' "$REPO_ROOT/docs/ci.md"
    [ "$status" -ne 0 ] || { echo "$output" >&2; false; }
}

# The shared-identity point is what decides whether an operator's branch
# protection does anything, and it is the kind of thing that reads as a
# digression to a later editor. Pinned in both places, and pinned together
# with the separation that fixes it - stating the problem without the remedy
# would leave a reader with nothing to do about it.
@test "docs/security.md documents that the sandbox authenticates as the operator" {
    grep -q 'the sandbox is you' "$REPO_ROOT/docs/security.md"
    grep -qi 'guard rather than a boundary' "$REPO_ROOT/docs/security.md"
    grep -q 'forge.gitea. token_file' "$REPO_ROOT/docs/security.md"
    grep -q 'core. ssh_key' "$REPO_ROOT/docs/security.md"
}

@test "docs/ci.md's branch-protection prerequisite links the shared-identity section" {
    grep -q 'security.md#to-your-forge-the-sandbox-is-you' "$REPO_ROOT/docs/ci.md"
}

@test "docs/ci.md says the CI allowlist is read from main, not from the checkout" {
    grep -q 'origin/main' "$REPO_ROOT/docs/ci.md"
    grep -qi 'never from the checkout' "$REPO_ROOT/docs/ci.md"
}

# bin/dejima names docs/configuration.md in user-facing diagnostics and
# comments; bin/dejima, bin/dejima-anthropic-proxy and bin/dejima-audit all
# name docs/security.md the same way. Before the docs restructure these named
# the README, which cannot be renamed. Now they name files that can be. None
# of these are grep'd out of one canonical string the way docs/remote-access.md
# is above - each script just spells the path out - so this walks every
# docs/*.md reference actually present in these scripts and checks the target
# exists, rather than hardcoding the two names here too and letting a rename
# desync the test from the code.
@test "docs/*.md references in bin/dejima, bin/dejima-anthropic-proxy and bin/dejima-audit resolve to real files" {
    local f doc missing=0
    for f in bin/dejima bin/dejima-anthropic-proxy bin/dejima-audit; do
        for doc in $(grep -ohE 'docs/[a-z-]+\.md' "$REPO_ROOT/$f" | sort -u); do
            if [ ! -f "$REPO_ROOT/$doc" ]; then
                echo "$f references $doc, which does not exist" >&2
                missing=1
            fi
        done
    done
    [ "$missing" -eq 0 ]
}

# Other repositories in the organisation link to these two by absolute URL
# rather than keeping copies, so the terms cannot drift into two divergent
# statements. A rename here is a 404 in a repository whose tests cannot see
# this one.
@test "the org-wide policy files other repositories link to keep their names" {
    [ -f "$REPO_ROOT/SECURITY.md" ]
    [ -f "$REPO_ROOT/ATTRIBUTION.md" ]
}

# The wordmark is referenced by a fixed filename on purpose - see the comment
# above the tag - which means a rename is caught here or not at all.
# Markdown image syntax as well as <img>, and svg as well as png: the badge
# is referenced the markdown way and is the case this exists for.
@test "every image the README points at is committed" {
    local src missing=0
    for src in $(grep -ohE 'src="[^"]+\.(png|svg)"|\]\([^)]+\.(png|svg)\)' "$REPO_ROOT/README.md" \
        | sed 's/^src="//; s/"$//; s/^](//; s/)$//'); do
        if [ ! -f "$REPO_ROOT/$src" ]; then
            echo "README points at $src, which does not exist" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

# --- the labels this repo's own workflow asks for ---
#
# Whether a job container gets the Docker socket is settled by the runner's
# config.yaml - which lives in dejima-ci-hardener's territory, not this
# repository's - so the only lever here is which runner its jobs may land on.
# A generic label gives that lever away, which is what these pin.

# pull_request_target reads this workflow from the base branch, which is what
# pins runs-on out of a branch's reach. Reverting to pull_request hands that
# back, silently.
@test "the workflow is read from the base branch, not the branch under test" {
    local wf="$REPO_ROOT/.gitea/workflows/tests.yml"
    grep -qE '^  pull_request_target:' "$wf"

    # pull_request may still be present, but only while the transition is
    # explicitly in progress - it takes an untrusted run from the head with
    # branch-controlled runs-on, which is the thing being removed. Requiring
    # the marker means the day it is dropped, this fails until the trigger
    # goes with it, rather than the pair quietly becoming permanent.
    if grep -qE '^  pull_request:' "$wf"; then
        grep -q 'TRANSITIONAL' "$wf" || {
            echo "pull_request is still enabled without the transitional note -" >&2
            echo "it hands runs-on back to the branch. Remove the trigger." >&2
            false
        }
    fi
}

# The trap in that conversion: the run's ref is the BASE branch, so a bare
# checkout tests main and passes regardless of the change. Every suite that
# means to test the branch has to name the head explicitly - and a green run
# is exactly what it looks like when one does not.
@test "every suite that tests the branch checks out the branch" {
    local wf="$REPO_ROOT/.gitea/workflows/tests.yml"
    # The property, not a count: every checkout is either pinned to the head
    # sha or is one of the runner-env jobs, whose assertions should come from
    # the base branch. A count breaks on adding a job, which is when someone
    # is least likely to be thinking about which ref it reads.
    local checkouts pinned
    checkouts="$(grep -c 'uses: actions/checkout@v4' "$wf")"
    pinned="$(grep -c 'pull_request.head.sha' "$wf")"
    [ "$checkouts" -gt 0 ] || { echo "no checkout at all"; return 1; }
    # Each pin is the line after the `with:` under its own checkout, so the
    # pinned count can never exceed the checkout count.
    [ "$pinned" -le "$checkouts" ] || { echo "more pins than checkouts"; return 1; }
    # Every branch-testing job is pinned. The unpinned remainder is exactly
    # the two runner-env jobs, named here so adding a third is a decision.
    local unpinned=$((checkouts - pinned))
    [ "$unpinned" -eq 2 ] || {
        echo "$unpinned checkouts read the base branch, expected 2" >&2
        echo "(runner-env-confined and runner-env-privileged). A new job that" >&2
        echo "tests the change must pin \${{ github.event.pull_request.head.sha }}." >&2
        return 1
    }
}

@test "no workflow job runs on a generic runner label" {
    run grep -nE '^\s*runs-on:\s*(ubuntu|windows|macos|self-hosted)' \
        "$REPO_ROOT"/.gitea/workflows/*.yml
    [ "$status" -ne 0 ] || {
        echo "a generic label lets this job land on a runner nobody hardened:" >&2
        echo "$output" >&2
        false
    }
}

@test "every workflow job runs on a dejima-specific label" {
    while IFS= read -r label; do
        [[ "$label" == dejima-* ]] || {
            echo "unexpected runs-on label: $label" >&2
            false
        }
    done < <(grep -hE '^\s*runs-on:' "$REPO_ROOT"/.gitea/workflows/*.yml \
        | sed -E 's/^\s*runs-on:\s*//')
}

# Remote access is opt-in and off by default, so the marker-directory check
# must be inside the "was it configured at all" guard. Outside it, every
# ordinary session gets a warning about a feature it never asked for - and a
# warning that fires on every start is one nobody reads.
@test "the marker-directory check only runs when remote access is configured" {
    local f="$REPO_ROOT/docker/entrypoint.sh"
    grep -q 'if \[ -n "${DEJIMA_NOTIFY_DIR:-}" \]; then' "$f"
    # The check's own output must sit inside that guard, not before it.
    guard=$(grep -n 'if \[ -n "${DEJIMA_NOTIFY_DIR:-}" \]; then' "$f" | head -1 | cut -d: -f1)
    warn=$(grep -n 'remote access is enabled, but' "$f" | head -1 | cut -d: -f1)
    [ "$guard" -lt "$warn" ]
}

# Chowning it would restore notifications while the session stayed absent from
# dejima-attach, because the registry entry is written host-side and never
# mounted here - a session that looked fixed with half the feature still
# broken. The remedy is relaunching, which the message names.
@test "the marker-directory check reports rather than repairs" {
    local f="$REPO_ROOT/docker/entrypoint.sh"
    run grep -nE 'chown[^|]*DEJIMA_NOTIFY_DIR|chmod[^|]*DEJIMA_NOTIFY_DIR' "$f"
    [ "$status" -ne 0 ] || { echo "$output" >&2; false; }
    grep -q "start a new session with 'dejima'" "$f"
}

# bin/dejima warns and continues rather than refusing. The neighbouring
# state-dir check does refuse, but that one is about a symlink handing a
# session an attacker-chosen path; this one is only about an optional feature
# working, and blocking a launch over undeliverable notifications costs more
# than it saves.
@test "bin/dejima warns about an unusable marker directory without refusing" {
    local line
    line=$(grep -n 'is not a directory this user owns and can write' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
    [ -n "$line" ]
    run sed -n "$((line)),$((line + 6))p" "$REPO_ROOT/bin/dejima"
    [[ "$output" != *"exit 1"* ]]
}

@test "sandbox-context.sh no longer mentions ALLOWED_DOMAINS" {
    run grep -n 'ALLOWED_DOMAINS' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -ne 0 ]
}

# The repo is public; the operator's own network is not. Both shapes below
# leaked into it once (a .localdomain Gitea host in bin/gitea-pr, a real LAN
# address as the Loki example in docker-compose.yml), so they are pinned
# here. Documentation addresses belong in RFC 5737's ranges (192.0.2.0/24,
# 198.51.100.0/24, 203.0.113.0/24) and documentation names under RFC 2606's
# reserved TLDs.
#
# test/ is deliberately out of scope: fixtures stub real resolver answers
# (project.bats feeds dig a 10.0.0.1) and those are inputs to a test, not
# addresses an operator is being told to use.
#
# This catches address- and hostname-shaped leaks only. A personal domain
# that looks like any other public one is not mechanically distinguishable
# and still rests on review.
SCANNED_PATHS=(README.md SECURITY.md ATTRIBUTION.md docs docker bin forges workflows harnesses hooks install.sh systemd .gitea)

@test "no private or link-local address is used as a documentation example" {
    run grep -rnIE '\b(10|127\.0\.0\.[2-9]|169\.254|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' \
        "${SCANNED_PATHS[@]/#/$REPO_ROOT/}"
    [ "$status" -ne 0 ] || {
        echo "use an RFC 5737 documentation address instead:" >&2
        echo "$output" >&2
        false
    }
}

# The exemption above is only defensible while it is the address the docs
# actually recommend. If the recommendation changes and this does not, the
# exemption starts covering an address nothing points at - a hole rather than
# a carve-out.
@test "no hostname under a private-network suffix is used as a documentation example" {
    run grep -rnIE '[A-Za-z0-9-]+\.(localdomain|lan|internal|home\.arpa)\b' \
        "${SCANNED_PATHS[@]/#/$REPO_ROOT/}"
    [ "$status" -ne 0 ] || {
        echo "use an RFC 2606 reserved name (example.com, .invalid, .test) instead:" >&2
        echo "$output" >&2
        false
    }
}

# --- Task 9: startup warning about unacknowledged CRITICAL audit history ---

@test "dejima warns about unacknowledged critical history before starting" {
    grep -q 'CRITICAL.txt' "$REPO_ROOT/bin/dejima"
}

@test "the startup warning is emitted before the container runs" {
    warn_line=$(grep -n 'unacknowledged CRITICAL' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
    run_line=$(grep -n 'docker compose -f "\$COMPOSE_FILE" run' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
    [ "$warn_line" -lt "$run_line" ]
}

@test "the startup warning does not block when stdin is not a tty" {
    grep -q 'config_get_bool audit strict' "$REPO_ROOT/bin/dejima"
    grep -q '\-t 0' "$REPO_ROOT/bin/dejima"
}

# The three tests above are static (they hold even for a warning that never
# actually runs correctly). The ones below drive bin/dejima's real startup
# path end-to-end against a stubbed `docker` - same technique as
# test/project.bats' launch/launch_setup and test/remote.bats' stub_launch -
# so the warning is checked doing its actual job, not just present in the
# source.
teardown() {
    rm -rf ${DEJIMA_T:+"$DEJIMA_T"}
}

startup_warning_setup() {
    DEJIMA_T="$(mktemp -d)"
    mkdir -p "$DEJIMA_T/home/.claude" "$DEJIMA_T/config" "$DEJIMA_T/audit" "$DEJIMA_T/ws"
    echo '{}' > "$DEJIMA_T/home/.claude/settings.json"
    cat > "$DEJIMA_T/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "${SANDBOX_TEST_DOCKER_LOG:-/dev/null}"
exit 0
EOF
    chmod +x "$DEJIMA_T/docker"
    : > "$DEJIMA_T/sandbox-key"
    chmod 600 "$DEJIMA_T/sandbox-key"
    # forge = none, workflow = local-only: provider_validate_selection runs
    # ahead of the audit-startup path these tests are actually about, and the
    # default gitea/worktree-pr pair is refused unconfigured (see
    # providers.bats) - this fixture sidesteps that with the honest
    # "no forge, no push" pair rather than configuring a forge just to get
    # past validation.
    cat > "$DEJIMA_T/config/config" <<EOF
[core]
harness = claude-code
ssh_key = $DEJIMA_T/sandbox-key
forge = none
workflow = local-only
[audit]
dir = $DEJIMA_T/audit
EOF
}

# Redirected from /dev/null, so this is deterministically the "stdin is not a
# tty" path - real interactive [c]ontinue/[q]uit behavior needs a pty, which
# isn't available here (see the task report).
startup_warning_launch() {
    HOME="$DEJIMA_T/home" PATH="$DEJIMA_T:$PATH" \
        DEJIMA_CONFIG_DIR="$DEJIMA_T/config" \
        SANDBOX_TEST_DOCKER_LOG="$DEJIMA_T/docker-log" \
        SSH_AUTH_SOCK= ALLOWED_DOMAINS= \
        "$REPO_ROOT/bin/dejima" "$DEJIMA_T/ws" < /dev/null
}

startup_warning_slug() { printf '%s' "$DEJIMA_T/ws" | sed 's/[^a-zA-Z0-9]/-/g'; }

@test "bin/dejima's startup path stays silent about the audit with no unacknowledged CRITICAL history" {
    startup_warning_setup
    run startup_warning_launch
    [ "$status" -eq 0 ]
    [[ "$output" != *"unacknowledged CRITICAL"* ]]
    grep -q ' run --rm ' "$DEJIMA_T/docker-log"
}

@test "bin/dejima's startup warning fires for an unacknowledged CRITICAL report and still launches headlessly" {
    startup_warning_setup
    mkdir -p "$DEJIMA_T/audit/$(startup_warning_slug)"
    : > "$DEJIMA_T/audit/$(startup_warning_slug)/2020-01-01-000000-CRITICAL.txt"
    run startup_warning_launch
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 unacknowledged CRITICAL"* ]]
    [[ "$output" == *"dejima-audit ack"* ]]
    grep -q ' run --rm ' "$DEJIMA_T/docker-log"
}

# Through a real pty, because the [a]/[c]/[q] prompt only exists when stdin
# is a terminal - the same reason test/remote.bats drives its picker with
# `script` rather than a pipe.
startup_warning_launch_tty() {
    local keys="$1"
    printf '%s' "$keys" | HOME="$DEJIMA_T/home" PATH="$DEJIMA_T:$PATH" \
        DEJIMA_CONFIG_DIR="$DEJIMA_T/config" \
        SANDBOX_TEST_DOCKER_LOG="$DEJIMA_T/docker-log" \
        SSH_AUTH_SOCK= ALLOWED_DOMAINS= TERM=xterm-256color \
        script -qec "'$REPO_ROOT/bin/dejima' '$DEJIMA_T/ws'" /dev/null
}

@test "the startup warning offers to review the findings there and then" {
    # Without this the operator is told to run a command in another terminal,
    # at the one moment when nothing is waiting on them: the container has
    # not started yet (#65).
    startup_warning_setup
    mkdir -p "$DEJIMA_T/audit/$(startup_warning_slug)"
    : > "$DEJIMA_T/audit/$(startup_warning_slug)/2020-01-01-000000-CRITICAL.txt"
    run startup_warning_launch_tty 'a
q
'
    [[ "$output" == *"[a]"* ]]
    [[ "$output" == *"review now"* ]]
    # 'a' ran the audit review in-process, rather than only naming it.
    [[ "$output" == *"dejima audit:"* ]]
}

@test "the startup warning colours the tier and the keystrokes on a terminal" {
    # The complaint is that the warning is one undifferentiated block: the
    # word that says how bad it is, the run ids, and the keys to press all
    # read the same (#65).
    startup_warning_setup
    mkdir -p "$DEJIMA_T/audit/$(startup_warning_slug)"
    : > "$DEJIMA_T/audit/$(startup_warning_slug)/2020-01-01-000000-CRITICAL.txt"
    run startup_warning_launch_tty 'c
'
    [[ "$output" == *$'\033'* ]]
}

@test "the startup warning emits no colour when it is not going to a terminal" {
    startup_warning_setup
    mkdir -p "$DEJIMA_T/audit/$(startup_warning_slug)"
    : > "$DEJIMA_T/audit/$(startup_warning_slug)/2020-01-01-000000-CRITICAL.txt"
    run startup_warning_launch
    [[ "$output" == *"unacknowledged CRITICAL"* ]]
    [[ "$output" != *$'\033'* ]]
}

@test "audit.strict = on refuses to start over unacknowledged CRITICAL history when stdin is not a tty" {
    startup_warning_setup
    printf '[audit]\nstrict = on\n' >> "$DEJIMA_T/config/config"
    mkdir -p "$DEJIMA_T/audit/$(startup_warning_slug)"
    : > "$DEJIMA_T/audit/$(startup_warning_slug)/2020-01-01-000000-CRITICAL.txt"
    run startup_warning_launch
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to start"* ]]
    ! grep -q ' run --rm ' "$DEJIMA_T/docker-log" 2>/dev/null
}

@test "bin/dejima's startup path is unaffected when the audit dir does not exist yet" {
    # The common case for a fresh install / a workspace with no history at
    # all: DEJIMA_AUDIT_DIR itself (not just the per-workspace subdir) is
    # absent, so `find` on it fails - this must not abort the script under
    # bin/dejima's `set -euo pipefail`.
    startup_warning_setup
    rm -rf "$DEJIMA_T/audit"
    run startup_warning_launch
    [ "$status" -eq 0 ]
    [[ "$output" != *"unacknowledged CRITICAL"* ]]
    grep -q ' run --rm ' "$DEJIMA_T/docker-log"
}

@test "entrypoint terminates TLS for api.anthropic.com on loopback by default" {
    # The transport is normalized in exactly one place so the forwarder, the
    # cert generation, and the readiness probe cannot disagree about which
    # mode this session is in.
    grep -q 'SANDBOX_ANTHROPIC_TRANSPORT="\${SANDBOX_ANTHROPIC_TRANSPORT:-tls}"' "$SANDBOX_DIR/entrypoint.sh"
    # CN alone is not enough - Node verifies the SAN.
    grep -q 'subjectAltName=DNS:api.anthropic.com' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'CN=api.anthropic.com' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'NODE_EXTRA_CA_CERTS' "$SANDBOX_DIR/entrypoint.sh"
    grep -q '127.0.0.1 api.anthropic.com' "$SANDBOX_DIR/entrypoint.sh"
}

@test "entrypoint aborts when the forwarder never binds" {
    # A silent timeout would leave api.anthropic.com pointed at a loopback
    # port with nothing behind it - every API call then fails with a
    # connection error that gives no hint where it came from.
    grep -q 'the credential-proxy forwarder never bound' "$SANDBOX_DIR/entrypoint.sh"
    grep -q '\[credentials\] transport = loopback' "$SANDBOX_DIR/entrypoint.sh"
}

@test "the hosts entry is written only when the proxy is actually running" {
    # Under SANDBOX_CREDENTIAL_PROXY=0 there is no listener on :443, so a
    # hosts entry would black-hole the real API - which is why this cannot be
    # a compose extra_hosts entry. It must sit inside the proxy-socket guard.
    local guard body
    guard=$(grep -n 'if \[ -n "\${SANDBOX_ANTHROPIC_PROXY_SOCKET:-}" \]' "$SANDBOX_DIR/entrypoint.sh" | cut -d: -f1)
    [ -n "$guard" ]
    body=$(grep -n '127.0.0.1 api.anthropic.com' "$SANDBOX_DIR/entrypoint.sh" | cut -d: -f1)
    [ "$body" -gt "$guard" ]
}

@test "openssl is installed explicitly, not relied on transitively" {
    # entrypoint.sh generates the terminator's cert at startup; a transitive
    # dependency dropping out of the base image would break the credential
    # path at runtime rather than at build time.
    grep -qE '^\s+openssl \\$' "$SANDBOX_DIR/Dockerfile"
}

@test "entrypoint fails loudly, with a reason, if openssl cert generation fails" {
    # set -e already aborts on openssl's nonzero exit before chown/export can
    # touch a missing cert, so a failure here can't silently proceed or leak
    # the credential - but redirecting openssl's stderr to /dev/null would
    # still leave it dying silent-but-loud: nonzero exit, no explanation.
    grep -q 'if ! openssl_err=\$(openssl req -x509' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'FATAL: openssl failed to generate the TLS terminator cert' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'echo "\$openssl_err" >&2' "$SANDBOX_DIR/entrypoint.sh"
}

@test "compose passes the transport through and lets an unprivileged process bind :443" {
    grep -qE '^\s*SANDBOX_ANTHROPIC_TRANSPORT:\s*\$\{SANDBOX_ANTHROPIC_TRANSPORT:-\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    # Docker already defaults this to 0, but the terminator runs as the
    # unprivileged sandbox user: pinning it means a future default change
    # fails at launch instead of silently breaking the credential path.
    grep -qE '^\s*net\.ipv4\.ip_unprivileged_port_start:\s*0\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "compose does not pin api.anthropic.com to loopback unconditionally" {
    # That belongs in entrypoint.sh, inside the proxy guard - see the
    # entrypoint test above for why an unconditional entry breaks the
    # SANDBOX_CREDENTIAL_PROXY=0 path.
    ! grep -q 'extra_hosts' "$SANDBOX_DIR/docker-compose.yml"
}

@test "bin/dejima defaults to the tls transport and exports it" {
    grep -q 'SANDBOX_ANTHROPIC_TRANSPORT="\$(config_get credentials transport)"' "$REPO_ROOT/bin/dejima"
    grep -Pq 'credentials\.transport\tenum:tls\|loopback\ttls' "$REPO_ROOT/bin/dejima-config-lib.sh"
    grep -q 'export .*SANDBOX_ANTHROPIC_TRANSPORT' "$REPO_ROOT/bin/dejima"
}

@test "tls mode mounts a fake credential, never the real one, and sets no ANTHROPIC_* pair" {
    # tls mode is the one case that puts a credentials file into the
    # container: Claude Code reads .credentials.json directly when there is no
    # ANTHROPIC_AUTH_TOKEN, so the empty container-local file entrypoint.sh
    # would otherwise leave isn't enough - it needs a well-formed document,
    # with the secrets faked and the non-secret fields
    # (scopes/subscriptionType/rateLimitTier/clientId) copied so the session's
    # own UI state stays accurate.
    grep -q 'extra_mounts+=(-v "\$SANDBOX_FAKE_CREDENTIALS_FILE:\$HOME/\.claude/\.credentials\.json")' "$REPO_ROOT/bin/dejima"
    grep -q 'sandbox-credential-proxy-placeholder' "$REPO_ROOT/bin/dejima"
    grep -q 'subscriptionType' "$REPO_ROOT/bin/dejima"
    grep -q 'rateLimitTier' "$REPO_ROOT/bin/dejima"
    # Expiry is deliberately NOT mirrored from the real credential: a
    # near-term expiresAt makes Claude Code refresh with the fake refresh
    # token, fail, and log the session out.
    grep -q 'refreshTokenExpiresAt' "$REPO_ROOT/bin/dejima"
}

@test "the loopback transport still sets the base URL and placeholder token" {
    grep -q 'SANDBOX_ANTHROPIC_BASE_URL="http://127.0.0.1:18300"' "$REPO_ROOT/bin/dejima"
    grep -q 'SANDBOX_ANTHROPIC_AUTH_TOKEN="sandbox-credential-proxy-placeholder"' "$REPO_ROOT/bin/dejima"
}

# The built-in list grants to every sandbox on the host, for every project,
# with no review anywhere - so what belongs in it is what the sandbox itself
# cannot run without. A language package host reaching it is how the list
# grows one reasonable-looking entry at a time until "allowed by default"
# covers most of the internet a build would want.
#
# The route for these is an approval: `dejima-allow --global`, or a reviewed
# .dejima/allowed-domains line. Adding one back here means arguing that the
# sandbox itself needs it.
@test "no language package host is built into the allowlist" {
    run bash -c "SANDBOX_ANTHROPIC_PROXY_SOCKET=/tmp/p.sock; SANDBOX_HARNESS_DOMAINS='$(_harness_api_domains)'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${FIXED_DOMAINS[@]}\""
    [ "$status" -eq 0 ]
    for d in pypi.org files.pythonhosted.org proxy.golang.org sum.golang.org \
             crates.io static.crates.io rubygems.org gitlab.com; do
        ! grep -qx "$d" <<< "$output" || {
            echo "$d is built in; it should be an approval instead" >&2
            false
        }
    done
}

# The two values below come from the harness manifest rather than being
# written here, so these assert the wiring - a manifest that stopped
# declaring them would fail this rather than quietly allowlisting nothing.
_harness_api_domains() {
    sed -n 's/^api_domains *= *//p' "$REPO_ROOT/harnesses/claude-code/harness.conf"
}
_harness_proxied_domain() {
    sed -n 's/^proxied_api_domain *= *//p' "$REPO_ROOT/harnesses/claude-code/harness.conf"
}

@test "the selected harness's own domains are in the fixed list, not built into the image" {
    # A harness's own api_domains reach the fixed list through its manifest.
    # A name built into fixed-domains.sh instead would be inherited by every
    # harness while a second one still lacked its own.
    [ -n "$(_harness_api_domains)" ] || { echo "the harness declares no api_domains"; return 1; }
    # Non-comment lines only: the comment there names the harness's domains
    # to explain why they are not written in, which is prose, not a value.
    run bash -c "grep -vE '^[[:space:]]*#' '$SANDBOX_DIR/fixed-domains.sh' | grep -n 'platform\.claude\.com\|api\.anthropic\.com'"
    [ "$status" -ne 0 ] || { echo "a harness's domain is still built in:"; echo "$output"; return 1; }
    run bash -c "SANDBOX_ANTHROPIC_PROXY_SOCKET=/tmp/p.sock; SANDBOX_HARNESS_DOMAINS='$(_harness_api_domains)'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${FIXED_DOMAINS[@]}\""
    [ "$status" -eq 0 ]
    grep -qx 'platform.claude.com' <<< "$output" || { echo "$output"; return 1; }
    # And a harness declaring none gets none, rather than the last one's.
    run bash -c "set -u; SANDBOX_ANTHROPIC_PROXY_SOCKET=/tmp/p.sock; SANDBOX_HARNESS_DOMAINS=''; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${FIXED_DOMAINS[@]}\""
    [ "$status" -eq 0 ]
    ! grep -qx 'platform.claude.com' <<< "$output" || { echo "$output"; return 1; }
}

@test "api.anthropic.com is in the fixed domains only when the proxy is off" {
    # Not unconditionally allowlisted: with the proxy on, the session reaches
    # the API through the forwarder rather than by resolving this name, so
    # leaving it unresolvable defeats a bypass that looks it up by DNS. When
    # the proxy is off (kill
    # switch or API-key auth) DNS is the only path to the API, so it has to be
    # allowlisted - and in the *fixed* list, not EXTRA_ALLOWED_DOMAINS, which
    # dns-proxy.sh exempts from stop-dns-rebind and init-firewall.sh treats as
    # non-fatal when it fails to resolve.
    local pd; pd="$(_harness_proxied_domain)"
    [ -n "$pd" ] || { echo "the harness declares no proxied_api_domain"; return 1; }
    run bash -c "SANDBOX_ANTHROPIC_PROXY_SOCKET=/tmp/proxy.sock; SANDBOX_HARNESS_PROXIED_DOMAIN='$pd'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${FIXED_DOMAINS[@]}\""
    [ "$status" -eq 0 ]
    ! grep -qx 'api.anthropic.com' <<< "$output"

    run bash -c "SANDBOX_ANTHROPIC_PROXY_SOCKET=; SANDBOX_HARNESS_PROXIED_DOMAIN='$pd'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${FIXED_DOMAINS[@]}\""
    [ "$status" -eq 0 ]
    grep -qx 'api.anthropic.com' <<< "$output"

    # Unset (a bare `docker run` that passes no socket) must behave like empty.
    # Under `set -u`, as both consumers run, so that dropping the `:-` default
    # fails here rather than at container start.
    run bash -c "set -u; unset SANDBOX_ANTHROPIC_PROXY_SOCKET; SANDBOX_HARNESS_PROXIED_DOMAIN='$pd'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${FIXED_DOMAINS[@]}\""
    [ "$status" -eq 0 ]
    grep -qx 'api.anthropic.com' <<< "$output"

    # ...and entrypoint.sh no longer adds it to the extra list, which would
    # reinstate both of the exemptions above.
    ! grep -q 'extra_domains.*api.anthropic.com' "$SANDBOX_DIR/entrypoint.sh"
}

@test "an unrecognised SANDBOX_ANTHROPIC_TRANSPORT is rejected, not silently treated as loopback" {
    # bin/dejima branches on `loopback`, entrypoint.sh and the forwarder on
    # `tls` - so a typo configures the two halves for different transports and
    # every API call fails with nothing naming the cause.
    grep -q 'FATAL: SANDBOX_ANTHROPIC_TRANSPORT is set to' "$SANDBOX_DIR/entrypoint.sh"
    grep -q "The only valid values are 'tls' (the default) and 'loopback'" "$SANDBOX_DIR/entrypoint.sh"
    # Ahead of the proxy-socket guard, so it catches the typo whatever else
    # this session is configured for.
    local check guard
    check=$(grep -n 'FATAL: SANDBOX_ANTHROPIC_TRANSPORT is set to' "$SANDBOX_DIR/entrypoint.sh" | cut -d: -f1)
    guard=$(grep -n 'if \[ -n "\${SANDBOX_ANTHROPIC_PROXY_SOCKET:-}" \]' "$SANDBOX_DIR/entrypoint.sh" | cut -d: -f1)
    [ "$check" -lt "$guard" ]
}

@test "core names no forge" {
    # What keeps core free of forge names. Each file gets a narrow, justified
    # exclusion rather than a whole-file skip; everything else must match
    # nothing. Two scans, different subjects:
    #
    # (1) `gitea` and `github.com` as case-insensitive substrings, which
    #     catches a PROSE leak ("push to the Gitea remote") as much as a
    #     coupling.
    # (2) Every name `provider_list forge` reports, in literal position -
    #     derived from the shipped directories, so a new forge is covered the
    #     day it lands. Scan 1 missed exactly that: bare `github` matches
    #     neither alternative, so core could compare a forge name with this
    #     test green.
    #
    #     "Literal position" means quoted, backticked, a config section,
    #     `forge.`-prefixed, under `forges/`, or a case arm - not a bare-word
    #     scan, because `none` is an ordinary English word and `github` also
    #     names a core feature predating the forge axis (`[github]
    #     token_file`, `--allow-github-push`). Remedy text naming a config
    #     VALUE is outside these shapes too: a rule that refuses a
    #     combination has to say which one works.
    local f matches fail=0 name literals="" body
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        # The last alternative is a `case` arm - anchored to the start of a
        # line (optionally after other arms' `|`) so it is the shape bash
        # actually uses, not any prose that happens to close a parenthesis
        # after the word.
        literals="${literals:+$literals|}[\"'\`]$name[\"'\`]|\\[$name\\]|forge\\.$name|forges/$name|^[[:space:]]*[(|]?$name\\)|\\|$name\\)"
    done < <(bash -c 'source "$1"; provider_list forge' _ "$REPO_ROOT/bin/dejima-provider-lib.sh")
    [ -n "$literals" ] || { echo "no shipped forges to build the pattern from"; return 1; }
    for f in "$REPO_ROOT/bin/dejima" "$REPO_ROOT/bin/dejima-config-lib.sh" \
             "$REPO_ROOT/bin/dejima-provider-lib.sh" "$REPO_ROOT/docker/entrypoint.sh" \
             "$REPO_ROOT/docker/docker-compose.yml" "$REPO_ROOT/hooks/git-push-guard.sh" \
             "$REPO_ROOT/hooks/merge-guard.sh" "$REPO_ROOT/hooks/sandbox-context.sh"; do
        # _warn_legacy_env's table names the OLD environment variables
        # (GITEA_SSH_HOST, GITEA_API, ...) dejima read directly before the
        # manifest schema replaced them - a one-time migration aid for an
        # operator's existing shell profile. Those names only ever meant
        # gitea (nothing else was ever wired that way) and do not change when
        # a forge is added or removed, so excluding the function body - the
        # same range test/config.bats isolates by name for its own "every
        # retired variable" test - is exempting history, not a live coupling.
        # A no-op for every other file here: none of them define it.
        body="$(sed '/^_warn_legacy_env()/,/^}/d' "$f")"
        matches="$(grep -inE 'gitea|github\.com' <<< "$body" || true)"
        matches="$matches"$'\n'"$(grep -nE "$literals" <<< "$body" || true)"
        case "$f" in
            */bin/dejima)
                # A citation of an external issue URL, the same category as
                # hooks/sandbox-context.sh:3 below.
                matches="$(grep -vE 'claude-code/issues/29162' <<< "$matches" || true)"
                # --allow-github-push widening DEJIMA_PUSH_HOSTS with
                # github.com/ssh.github.com - the identical "GitHub read-only
                # [here, push], independent of forge selection" exception
                # docker/entrypoint.sh and docker-compose.yml already get
                # below, not a forge coupling.
                matches="$(grep -vE 'github\.com' <<< "$matches" || true)"
                # `[github] token_file` and the pairing that resolves it: the
                # CORE config section holding the read-only GitHub credential
                # every session gets whatever forge is selected. Same feature
                # as the exception above, in its config-file spelling - the
                # section predates the forge axis and would still exist with
                # every forge directory deleted.
                matches="$(grep -vE '\[github\] token_file|GH_TOKEN=github token_file' <<< "$matches" || true)"
                ;;
            */bin/dejima-config-lib.sh)
                # core.forge's schema DEFAULT - real data (today there is
                # exactly one shipped forge to default to), not a row a new
                # forge needs to edit. Its TYPE, provider:forge, is what is
                # structural, and that names no forge; github.token_file
                # (GitHub as a read-only source, independent of forge
                # selection - see the identical exception in the briefing
                # prose below) and the bare "github" section name it lives in
                # don't contain "github.com" and so never match this pattern
                # at all.
                matches="$(grep -vE ':core\.forge	provider:forge	gitea$' <<< "$matches" || true)"
                ;;
            */docker/entrypoint.sh|*/docker/docker-compose.yml)
                # Implements GitHub read-only (git's github.com credential
                # helper, and the comment on it) - a core feature independent
                # of which forge is configured, not a coupling to one. Same
                # feature the "GitHub read-only" prose exception below names.
                matches="$(grep -vE 'github\.com' <<< "$matches" || true)"
                ;;
            */hooks/sandbox-context.sh)
                # A citation of Anthropic's own devcontainer, not a forge.
                matches="$(grep -vE 'anthropics/claude-code/tree' <<< "$matches" || true)"
                ;;
        esac
        # The two scans are concatenated with a newline, so an empty one
        # leaves a blank line rather than nothing at all.
        matches="$(grep -v '^$' <<< "$matches" || true)"
        if [ -n "$matches" ]; then
            echo "$f still names a forge:"
            echo "$matches"
            fail=1
        fi
    done
    [ "$fail" -eq 0 ]
}

@test "no container mount covers the audit store" {
    # The audit now keeps retained diffs of pre-session content under
    # ~/.local/share/dejima. Everything about that is premised on the
    # container not being able to read them - so a future mount that reaches
    # it must break a test rather than silently opening the boundary.
    # ~/.local/share/nvim is mounted (a named volume); its PARENT must not be.
    run grep -nE '^\s*-\s*\$\{HOME\}/\.local/share:' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
    run grep -nE '^\s*-\s*\$\{HOME\}/\.local/share/dejima' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
    run grep -nE '^\s*-\s*\$\{HOME\}/\.local:' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
    run grep -nE '^\s*-\s*\$\{HOME\}:' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "every suite is run by CI, and the two that need their own job have one" {
    # Derived from the directory rather than a list kept here, so adding a
    # test file fails this until the workflow is told about it. A suite nobody
    # wired into CI runs nowhere, and nothing else would say so.
    #
    # Two suites are not matrix entries because they cannot be. runtime.bats
    # needs a Docker daemon; ci-runner.bats asserts on the runner itself and
    # has to run once per tier rather than once per suite. Both are checked
    # below for having a job of their own instead - "not in the matrix" must
    # not be a way to be in neither.
    local wf="$REPO_ROOT/.gitea/workflows/tests.yml"
    local f base missing=""
    for f in "$REPO_ROOT"/test/*.bats; do
        base="$(basename "$f" .bats)"
        case "$base" in runtime|ci-runner) continue ;; esac
        grep -qE "^ *- *$base\$" "$wf" || missing="$missing $base"
    done
    [ -z "$missing" ] || {
        echo "these suites are not in the sandbox matrix, so CI never runs them:$missing" >&2
        false
    }

    # runtime.bats belongs to the other job, and must not be a matrix entry:
    # that job runs on a generic runner with no Docker daemon, so it would
    # fail every time rather than testing anything.
    ! grep -qE '^ *- *runtime$' "$wf"
    grep -q 'test/runtime.bats' "$wf"

    # ci-runner.bats likewise, and once per tier: a single job would leave one
    # of the two runners unasserted, which is the thing it exists to catch.
    ! grep -qE '^ *- *ci-runner$' "$wf"
    grep -q 'test/ci-runner.bats' "$wf"
    grep -q 'DEJIMA_CI_TIER: confined' "$wf"
    grep -q 'DEJIMA_CI_TIER: privileged' "$wf"
}

# test/remote.bats used to stand in a failing exit-time audit by overwriting
# `$REPO_ROOT/bin/dejima-audit` and restoring it afterwards. The restore does
# not happen if the run is killed partway, and two runs of that file at once
# restore each other's stub, so a suite could pass while leaving the real
# audit disabled - and a file watcher looking at the tree during the window
# sees a security tool replaced by a two-line `exit 3`, which reads exactly
# like an attack.
#
# Tests get a throwaway copy to mutate instead. Redirects and removals are
# what actually went wrong, so those are what this pins; a test that finds
# some third way to write into the checkout is not covered.
@test "no test suite writes into the repository it is testing" {
    run grep -rnE '(>>?|rm +(-[a-zA-Z]+ +)*)[[:space:]]*"?\$\{?(REPO_ROOT|BATS_TEST_DIRNAME)' \
        "$REPO_ROOT"/test/*.bats
    [ "$status" -ne 0 ] || {
        echo "a test writes into the checkout; give it a copy instead:" >&2
        echo "$output" >&2
        false
    }
}

@test "the agent briefing teaches the project scope, not just global" {
    # The observed failure: an agent asked for a project-specific domain to be
    # added container-wide and globally, because --project was never named.
    grep -q -- 'dejima-allow --project' "$REPO_ROOT/bin/dejima-provider-lib.sh"
}

@test "the agent briefing and the context hook use the new argument order" {
    # A briefing that hands the operator a command the CLI now rejects is worse
    # than one that says nothing.
    run grep -nE 'dejima-allow [a-z<][^ ]* +--' \
        "$REPO_ROOT/bin/dejima-provider-lib.sh" "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -ne 0 ]
}

@test "the briefing's container placeholder is the template form, not a shell variable" {
    # _briefing_core_preamble is a quoted heredoc rendered by placeholder
    # substitution; a literal $container_id would reach the agent unexpanded.
    run grep -n 'dejima-allow --container \$container_id' "$REPO_ROOT/bin/dejima-provider-lib.sh"
    [ "$status" -ne 0 ]
    grep -q 'dejima-allow --container {{container_id}}' "$REPO_ROOT/bin/dejima-provider-lib.sh"
}

@test "README documents dejima-allow with flags before the domain" {
    grep -q 'dejima-allow --global crates.io' "$REPO_ROOT/README.md"
    run grep -nE 'dejima-allow [a-z][^ ]* +--(global|project)' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
}

@test "README documents dejima-dep with flags before the spec" {
    grep -q 'dejima-dep add --global cargo:cargo-nextest' "$REPO_ROOT/README.md"
    run grep -nE 'dejima-dep (add|remove) [a-z][^ ]* +--(global|project)' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
}

@test "README does not claim --global/--project patch a running session" {
    # A scope-flag-only call sets session_wanted=0 and never touches docker -
    # see bin/dejima-allow. Claiming otherwise sends an operator to expect a
    # live update they will not get.
    run grep -nE 'which also (updates|patches) the running session' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
    grep -q 'deliberately do not touch a running container' "$REPO_ROOT/README.md"
}

@test "README does not claim dejima-project approve reports live-session failures" {
    # approve only ever calls dejima-allow without --container (see
    # bin/dejima-project's approve case), so a failure there is a persistence
    # failure, never a live-session one.
    run grep -n 'could not apply to a running session' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
    grep -q 'never attempts to patch a running session' "$REPO_ROOT/README.md"
}

@test "README does not attribute container disambiguation to a scope flag" {
    # A --project/--global-only call sets session_wanted=0 and never reaches
    # the multiple-containers ambiguity check at all - only the bare form
    # (or bare + --container) does. Only the bare form can ever refuse on it.
    run grep -n 'scope-flag) form\|scope-flag form' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
}

# --- harness plugins: a plugin computes, core enforces ---

@test "no harness plugin touches the mount list directly" {
    # A plugin that appended to extra_mounts itself would skip the
    # guarded-store refusal emit_mount runs at the point of declaration -
    # and would skip it differently in each harness, which is how one
    # security model becomes one per harness. The plugins are trusted code,
    # so this is held at review time rather than by isolating them.
    run grep -rn 'extra_mounts' "$REPO_ROOT/bin/harness"
    [ "$status" -ne 0 ] || { echo "a plugin bypasses emit_mount:"; echo "$output"; return 1; }
}

@test "a harness plugin defines only hooks core actually calls" {
    # A function named something core never calls looks wired up and is
    # dead. Worse, a near-miss of a real hook name (harness_state_mount for
    # harness_state_mounts) reads as implemented and silently does nothing.
    local hooks f fn
    hooks="$(sed -n 's/^DEJIMA_HARNESS_HOOKS="\(.*\)"$/\1/p' \
        "$REPO_ROOT/bin/dejima-harness-lib.sh")"
    [ -n "$hooks" ] || { echo "the hook list is gone"; return 1; }
    for f in "$REPO_ROOT"/bin/harness/*.sh; do
        [ -f "$f" ] || continue
        while IFS= read -r fn; do
            [ -n "$fn" ] || continue
            case " $hooks " in
                *" $fn "*) ;;
                *) echo "$(basename "$f") defines $fn, which core never calls"; return 1 ;;
            esac
        done < <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$f" | sed 's/()$//')
    done
}

@test "every shipped harness has both a manifest and a plugin" {
    # Support is per harness and deliberate. A manifest with no plugin is a
    # half-finished integration that would present as a supported harness.
    local d name
    for d in "$REPO_ROOT"/harnesses/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        [ -f "$d/harness.conf" ] || { echo "$name has no manifest"; return 1; }
        [ -f "$REPO_ROOT/bin/harness/$name.sh" ] \
            || { echo "$name has a manifest but no plugin"; return 1; }
    done
    for d in "$REPO_ROOT"/bin/harness/*.sh; do
        [ -f "$d" ] || continue
        name="$(basename "$d" .sh)"
        [ -f "$REPO_ROOT/harnesses/$name/harness.conf" ] \
            || { echo "$name has a plugin but no manifest"; return 1; }
    done
}

@test "harness plugins are inside the trusted computing base the audit watches" {
    # They run on the host, in the launch path. Under harnesses/ they would
    # be host-executed code a session could edit in dejima's own checkout
    # without raising a CRITICAL, because tcb_snapshot covers install.sh,
    # bin/, hooks/, docker/ and test/ - and not the provider directories.
    [ -d "$REPO_ROOT/bin/harness" ] || { echo "plugins are not under bin/"; return 1; }
    run grep -rn 'harness_state_mounts\|harness_plugin_load' "$REPO_ROOT/harnesses"
    [ "$status" -ne 0 ] || { echo "plugin code under harnesses/:"; echo "$output"; return 1; }
    sed -n '/^tcb_snapshot()/,/^}/p' "$REPO_ROOT/bin/dejima-audit" | grep -q 'for dir in bin '
}

# --- the wrapper is the harness's, not Claude Code's ---

@test "the wrapper names no harness, and the image installs it under a neutral name" {
    # It is shadowed into place under the harness's own command by
    # entrypoint.sh, because the image is shared across harnesses and the
    # selection is per launch. A COPY to a fixed name would bake one
    # harness's command into every image.
    local w="$SANDBOX_DIR/harness-wrapper.sh"
    [ -f "$w" ] || { echo "the generic wrapper is gone"; return 1; }
    run grep -niE 'claude|anthropic' "$w"
    [ "$status" -ne 0 ] || { echo "the shared wrapper names a harness:"; echo "$output"; return 1; }
    grep -q 'COPY docker/harness-wrapper.sh /usr/local/bin/dejima-harness-wrapper' \
        "$SANDBOX_DIR/Dockerfile"
    run grep -n 'COPY docker/claude-wrapper' "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ] || { echo "the old fixed-name copy is back"; return 1; }
}

@test "the entrypoint refuses a harness command name that is not a bare name" {
    # It becomes a path under /usr/local/bin. A value with a slash would
    # write the symlink somewhere else entirely, and this one arrives from
    # the host as an environment variable.
    sed -n '/SANDBOX_HARNESS_COMMAND:-/,/^fi/p' "$SANDBOX_DIR/entrypoint.sh" \
        | grep -q '\*/\*'
}

@test "the no-confirm flags come from the harness manifest" {
    # R1 of the capability bar. The flag was hardcoded in the wrapper, which
    # made unattended operation a property of the image rather than of the
    # selected harness.
    grep -qE -- 'no_confirm_args\s*=\s*--dangerously-skip-permissions' \
        "$REPO_ROOT/harnesses/claude-code/harness.conf"
    grep -q 'no_confirm_args' "$REPO_ROOT/bin/dejima"
    # And a harness that names none is refused rather than run asking for
    # confirmation on every tool call, which presents as a hang.
    grep -q 'declares no no_confirm_args' "$REPO_ROOT/bin/dejima"
}

@test "core's schema holds no harness's command as a default" {
    # [core] command defaulted to the literal `claude`, so core carried one
    # harness's command name while the manifest's own `command` key was read
    # by nothing.
    run grep -nE '^core\.command\s+identifier\s+claude' "$REPO_ROOT/bin/dejima-config-lib.sh"
    [ "$status" -ne 0 ] || { echo "core still defaults to a harness command"; return 1; }
    grep -qE '^core\.command\s+\?identifier' "$REPO_ROOT/bin/dejima-config-lib.sh"
    grep -q 'SANDBOX_CMD="$SANDBOX_HARNESS_COMMAND"' "$REPO_ROOT/bin/dejima"
}

# --- guards are declared, not assumed ---

@test "every shipped harness declares which guards it can host" {
    # An absent `guards` reads as "hosts none", which for a harness that
    # hosts all four would tell the operator at every launch that four
    # protections are missing. Silence is not a valid declaration here.
    local d name g known
    known="$(sed -n 's/^DEJIMA_KNOWN_GUARDS="\(.*\)"$/\1/p' "$REPO_ROOT/bin/dejima-provider-lib.sh")"
    [ -n "$known" ] || { echo "the known-guard set is gone"; return 1; }
    for d in "$REPO_ROOT"/harnesses/*/; do
        [ -f "$d/harness.conf" ] || continue
        name="$(basename "$d")"
        grep -qE '^\s*guards\s*=' "$d/harness.conf" \
            || { echo "$name declares no guards"; return 1; }
        for g in $(sed -n 's/^\s*guards\s*=\s*//p' "$d/harness.conf"); do
            case " $known " in
                *" $g "*) ;;
                *) echo "$name declares unknown guard: $g"; return 1 ;;
            esac
        done
    done
}

@test "the guard set core knows lives with the validation that rejects a name" {
    # It was in dejima-harness-lib.sh while provider_validate_selection read
    # it from dejima-provider-lib.sh, so a caller loading only the latter -
    # providers.bats does - validated against an empty set and rejected
    # every guard there is.
    grep -q '^DEJIMA_KNOWN_GUARDS=' "$REPO_ROOT/bin/dejima-provider-lib.sh"
    run grep -n '^DEJIMA_KNOWN_GUARDS=' "$REPO_ROOT/bin/dejima-harness-lib.sh"
    [ "$status" -ne 0 ] || { echo "the set is defined in two places"; return 1; }
}

@test "core gates guard work on the declaration, not on the plugin defining a hook" {
    # A harness that forgot the declaration but implemented the hook would
    # get a guard the launch message has just said it does not have.
    grep -q 'harness_has_guard notify' "$REPO_ROOT/bin/dejima"
}

@test "install.sh installs no harness's hooks itself" {
    # Where dejima's guards go, and in what shape, is the selected harness's
    # business. install.sh knowing ~/.claude/settings.json's schema is the
    # coupling; it delegates to the harness's plugin now.
    run grep -nE '\.claude/(settings\.json|hooks)' "$REPO_ROOT/install.sh"
    [ "$status" -ne 0 ] || { echo "install.sh still writes a harness's config:"; echo "$output"; return 1; }
    grep -q 'harness_register_guards' "$REPO_ROOT/install.sh"
    grep -q '^harness_register_guards()' "$REPO_ROOT/bin/harness/claude-code.sh"
}

@test "the plugin loader does not depend on its caller's SCRIPT_DIR" {
    # bin/dejima sets it to bin/ and install.sh sets it to the repo root. A
    # library that resolves paths from one of those only works for one of
    # its callers.
    sed -n '/^harness_plugin_load()/,/^}/p' "$REPO_ROOT/bin/dejima-harness-lib.sh" \
        | grep -q 'BASH_SOURCE'
    run sed -n '/^harness_plugin_load()/,/^}/p' "$REPO_ROOT/bin/dejima-harness-lib.sh"
    [[ "$output" != *'$SCRIPT_DIR'* ]] || { echo "$output"; return 1; }
}

@test "a finding's label lives in trusted code, never in a manifest" {
    # `ack` recovers an id by stripping a fixed label from the front of a
    # finding. Those labels are a parser's grammar, and provider directories
    # are not in tcb_snapshot's list - in the self-mount case a session can
    # edit a manifest without raising a CRITICAL. So the label stays a
    # literal in code the audit does watch, which is why host-exec surfaces
    # are a plugin hook rather than a manifest key.
    grep -q 'HOST-CODE-EXECUTION' "$REPO_ROOT/bin/harness/claude-code.sh"
    run grep -rn 'HOST-CODE-EXECUTION' "$REPO_ROOT/harnesses"
    [ "$status" -ne 0 ] || { echo "a finding label is manifest data:"; echo "$output"; return 1; }
    run grep -rniE 'host_exec_paths|host_exec_label' "$REPO_ROOT/harnesses" "$REPO_ROOT/bin/dejima-provider-lib.sh"
    [ "$status" -ne 0 ] || { echo "host-exec surfaces leaked into the manifest schema:"; echo "$output"; return 1; }
}

@test "the audit resolves host-execution paths from the harness, not a hardcoded one" {
    run grep -n 'STATUSLINE_PATH' "$REPO_ROOT/bin/dejima-audit"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    grep -q 'host_exec_load' "$REPO_ROOT/bin/dejima-audit"
    grep -q '^harness_host_exec_surfaces()' "$REPO_ROOT/bin/harness/claude-code.sh"
}

@test "the provider directories are in the audit's TCB list" {
    # They hold no code, which is why they were left out. What they hold
    # decides what the next launch permits: a forge's fixed_hosts reaches
    # DEJIMA_FORGE_HOSTS, which entrypoint.sh joins into the domains
    # init-firewall.sh allowlists, so a manifest line widens the egress
    # boundary on the next run. A briefing fragment is what the next session
    # is told it may do.
    local dirs
    dirs="$(sed -n '/^tcb_snapshot()/,/^}/p' "$REPO_ROOT/bin/dejima-audit" \
        | sed -n 's/.*for dir in \(.*\); do/\1/p')"
    [ -n "$dirs" ] || { echo "the TCB directory list is gone"; return 1; }
    local d
    for d in bin hooks docker test forges workflows harnesses; do
        case " $dirs " in
            *" $d "*) ;;
            *) echo "$d is not in the TCB list: $dirs"; return 1 ;;
        esac
    done
}

@test "the transcript format is the harness's, the store is dejima's" {
    # What a compaction looks like in a transcript is a fact about the
    # harness; where the summary is kept, that nothing mounts it, and what
    # the file promises about its own provenance are dejima's.
    grep -q 'isCompactSummary' "$REPO_ROOT/bin/harness/claude-code.sh"
    run grep -n 'isCompactSummary\|compact_boundary\|\.jsonl' "$REPO_ROOT/bin/dejima-epitaph"
    [ "$status" -ne 0 ] || { echo "the transcript format is still in core:"; echo "$output"; return 1; }
    # The provenance note is dejima's promise about the artefact, so it is
    # defined once rather than phrased per harness.
    grep -q '^DEJIMA_EPITAPH_NOTE=' "$REPO_ROOT/bin/dejima-harness-lib.sh"
    run grep -c 'preserved verbatim' "$REPO_ROOT/bin/harness/claude-code.sh"
    [ "$output" -eq 0 ] || { echo "a plugin phrases the provenance note itself"; return 1; }
}

@test "conversation shipping resolves transcripts by slug, not by matching a prefix" {
    # A "<slug>-*" glob picks up this workspace's worktrees and also a
    # SIBLING project whose directory name merely extends its own (#105).
    # Every project's directory is present on the host, so nothing else
    # would catch the neighbour's conversation being shipped.
    grep -q 'workspace_slugs_sorted "$ws"' "$REPO_ROOT/bin/dejima-conversation-ship"
    run grep -nE '\$key-\*|\$\{key\}-\*' "$REPO_ROOT/bin/dejima-conversation-ship"
    [ "$status" -ne 0 ] || { echo "prefix matching is back:"; echo "$output"; return 1; }
}

@test "the container's log shipper reads nothing the session writes" {
    # It runs as root, for tamper-resistance: an oversight log the surveilled
    # user owns is one they can edit. That privilege is only safe while what
    # it parses is not session-writable, which is what this holds - dnsmasq
    # and ulogd2 output, both written by root-owned daemons.
    # Non-comment lines only: the comment there says where conversation
    # shipping went, which is worth keeping.
    run bash -c "grep -vE '^[[:space:]]*#' '$SANDBOX_DIR/log-shipper.sh' | grep -nE 'projects|[.]jsonl|transcript'"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    grep -q 'neither session-writable' "$SANDBOX_DIR/entrypoint.sh"
}

@test ".dejima.md says to cut what the code replaced, not just how it was found" {
    # "Cut how you found it" is about the discovery - which CI run, how many
    # attempts. Describing the arrangement a change replaced is a different
    # habit, and the "keep why it is shaped this way" rule invites it: a
    # previous shape is the easiest answer to that question. Both have to be
    # written down or the second keeps coming back.
    local sec
    sec="$(sed -n '/^## Write the comment that prevents the bug/,/^## /p' "$REPO_ROOT/.dejima.md")"
    grep -q 'Cut how you found it' <<< "$sec"
    grep -q 'Cut what the code replaced' <<< "$sec" \
        || { echo "the rule about a previous arrangement is gone"; return 1; }
    # And the exception, or the next pass strips the comments that exist
    # only to explain code whose purpose is the past.
    grep -qi 'exception' <<< "$sec" \
        || { echo "the rename/shim exception is gone"; return 1; }
}

# emit_mount_at is exercised directly rather than through a launch: the two
# checks below are pure path logic, and a plugin that emitted a bad target
# could only be introduced by writing one into the checkout.
_emit_mount_at() {
    bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        extra_mounts=()
        _guarded_stores() { GUARDED_STORES=(); }
        _refuse_guarded_mount() { :; }
        emit_mount_at "$@" || exit $?
        printf "%s\n" "${extra_mounts[@]}"
    ' _ "$@"
}

@test "a harness mount may name a container path different from its source" {
    # For a harness whose own keying dejima cannot safely follow: the source
    # stays keyed by something the session cannot change, and only the target
    # follows the harness.
    run _emit_mount_at /host/state /container/state
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"/host/state:/container/state"* ]] || { echo "$output"; return 1; }
    run _emit_mount_at /host/state /container/state ro
    [[ "$output" == *"/host/state:/container/state:ro"* ]] || { echo "$output"; return 1; }
}

@test "a harness mount is refused when its target shadows something the sandbox needs" {
    # The wrapper that pins the no-confirm flags, the settings layer the
    # guards are registered in, the briefing, the marker directory: a mount
    # landing on any of them replaces it.
    local p
    for p in /usr/local/bin /usr/local/bin/claude /etc/dejima-harness \
             /etc/dejima-settings.json /run/dejima-notify /; do
        run _emit_mount_at /host/state "$p"
        [ "$status" -ne 0 ] || { echo "accepted a mount over $p: $output"; return 1; }
        [[ "$output" == *"Refusing harness mount"* ]] || { echo "$p: $output"; return 1; }
    done
}

@test "a harness mount target must be absolute and free of the mount separator" {
    run _emit_mount_at /host/state relative/path
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"relative mount target"* ]] || { echo "$output"; return 1; }
    run _emit_mount_at /host/state "/has:colon"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"containing a colon"* ]] || { echo "$output"; return 1; }
}

@test "the harness domain list splits the same for both consumers of it" {
    # init-firewall.sh sources fixed-domains.sh with IFS=$'\n\t' and
    # dns-proxy.sh with the default, so an unquoted expansion hands them
    # different lists from one value - the drift that shared file exists to
    # prevent. The single-domain real manifest cannot show it, which is why
    # this uses two and reproduces init-firewall's IFS.
    local two="a.example.com b.example.com" n_fw n_dns
    n_fw="$(bash -c "IFS=\$'\\n\\t'; SANDBOX_HARNESS_DOMAINS='$two'
        source '$SANDBOX_DIR/fixed-domains.sh'; echo \${#FIXED_DOMAINS[@]}")"
    n_dns="$(bash -c "SANDBOX_HARNESS_DOMAINS='$two'
        source '$SANDBOX_DIR/fixed-domains.sh'; echo \${#FIXED_DOMAINS[@]}")"
    [ "$n_fw" = "$n_dns" ] \
        || { echo "firewall sees $n_fw entries, dns proxy sees $n_dns"; return 1; }
    # And both as separate names, not one glued element that fails the
    # firewall's DNS check fatally.
    run bash -c "IFS=\$'\\n\\t'; SANDBOX_HARNESS_DOMAINS='$two'
        source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${FIXED_DOMAINS[@]}\""
    grep -qx 'a.example.com' <<< "$output" || { echo "$output"; return 1; }
    grep -qx 'b.example.com' <<< "$output" || { echo "$output"; return 1; }
}

@test "the docs name the staging path the entrypoint actually uses" {
    # A static test already holds entrypoint.sh to the current name; nothing
    # held the docs, so they kept the old one after the rename.
    run grep -rn 'dejima-claude' "$REPO_ROOT/docs" "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    grep -q 'etc/dejima-harness' "$REPO_ROOT/docs/security.md"
}

@test "docs/providers.md lists the whole briefing placeholder whitelist" {
    # The list is what a fragment author checks a placeholder against, so one
    # missing name reads as "not available" for something that is.
    local ph
    for ph in $(sed -n 's/^_BRIEFING_WHITELIST="\(.*\)"$/\1/p' \
                "$REPO_ROOT/bin/dejima-provider-lib.sh"); do
        grep -q "\`$ph\`" "$REPO_ROOT/docs/providers.md" \
            || { echo "$ph is in the whitelist but not documented"; return 1; }
    done
}

@test "the tmux prefix the config accepts is one the page can parse" {
    # `C-space` passed the schema and was then rejected on the page, which
    # fell back to C-b silently - the outcome refusing at launch exists to
    # prevent. Both sides accept a named key in any case now.
    grep -qE "charAt\(0\)\.toUpperCase" "$REPO_ROOT/web/src/keys.js"
    grep -q 'Ss.pace' "$REPO_ROOT/bin/dejima-config-lib.sh"
}
