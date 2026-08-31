#!/usr/bin/env bats
# Behavioural tests for bin/dejima-conversation-ship: the shipper is run
# against a real transcript and a real HTTP endpoint, and what arrives is what
# is asserted on.
#
# The alternative - grepping the script for the string that implements a
# property - is brittle in both directions, and this component is the session
# oversight log. A `final_flush` that flushed nothing would satisfy a grep for
# `final_flush`; a rename of it would fail one while changing no behaviour.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    CONFIG_DIR="$(mktemp -d)"
    export DEJIMA_CONFIG_DIR="$CONFIG_DIR"
    WS="$(mktemp -d)"
    PROJECTS="$(mktemp -d)"
    LOKI_LOG="$(mktemp)"
    SHIP_PID=""
    LOKI_PID=""
    unset LOKI_URL SANDBOX_LOG_CONVERSATION 2>/dev/null || true
}

teardown() {
    [ -z "$SHIP_PID" ] || kill "$SHIP_PID" 2>/dev/null || true
    [ -z "$LOKI_PID" ] || kill "$LOKI_PID" 2>/dev/null || true
    rm -rf "$CONFIG_DIR" "$WS" "$PROJECTS" "$LOKI_LOG"
}

# A real HTTP server standing in for Loki, appending each pushed body to a
# file. Real because the shipper reaches it with curl: a stub that replaced
# curl would stop testing the thing that formats and sends the payload.
# The server binds port 0 itself and reports what it got, rather than a helper
# picking a free port and handing the number over.
#
# That handover was a race, and `bats --jobs` is what makes it fire: the helper
# bound port 0, read the number, CLOSED the socket, and only then did the
# server bind it. Another test starting in that window takes the same port, and
# the loser dies with "Address already in use" - but the readiness probe below
# still succeeds, because something IS listening on that port. The test then
# ships to the other test's Loki, finds its own log empty, and reports the
# failure as a lost transcript. Seen in CI, not locally: it needs enough cores
# for two tests to be in that window at once.
start_loki() {
    local portfile="$BATS_TEST_TMPDIR/loki-port"
    rm -f "$portfile"
    python3 - "$portfile" "$LOKI_LOG" <<'EOF' &
import sys, os
from http.server import BaseHTTPRequestHandler, HTTPServer

portfile, path = sys.argv[1], sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(path, "ab") as f:
            f.write(body + b"\n")
        self.send_response(204)
        self.end_headers()
    def log_message(self, *a):
        pass

srv = HTTPServer(("127.0.0.1", 0), H)
# Written only once the socket is bound and listening, and atomically, so the
# shell can never read a half-written number or one for a socket that is gone.
tmp = portfile + ".tmp"
with open(tmp, "w") as f:
    f.write(str(srv.server_address[1]))
os.replace(tmp, portfile)
srv.serve_forever()
EOF
    LOKI_PID=$!
    local i
    for i in $(seq 1 100); do
        if [ -s "$portfile" ]; then
            LOKI_PORT="$(cat "$portfile")"
            return 0
        fi
        # A server that died on startup will never write the file, and waiting
        # the full timeout for a process that is already gone only delays the
        # real message.
        kill -0 "$LOKI_PID" 2>/dev/null || break
        sleep 0.1
    done
    echo "the fake Loki never came up" >&2
    return 1
}

write_config() {
    cat > "$CONFIG_DIR/config" <<EOF
[core]
harness = claude-code
[logging]
loki_url = http://127.0.0.1:$LOKI_PORT
conversation = ${1:-on}
[harness.claude-code]
projects_dir = $PROJECTS
EOF
}

# The transcript directory this workspace's conversation lands in. Derived the
# same way the shipper derives it rather than spelled out, so a change to the
# slug scheme moves both together.
slug_dir() {
    local slug
    slug="$(bash -c 'source "$1"; workspace_slugs_sorted "$2"' _ \
        "$REPO_ROOT/bin/dejima-slug-lib.sh" "$WS" | head -1)"
    printf '%s/%s' "$PROJECTS" "$slug"
}

say() {
    printf '{"type":"user","sessionId":"s1","message":{"content":"%s"}}\n' "$1"
}

start_ship() {
    "$REPO_ROOT/bin/dejima-conversation-ship" "$WS" &
    SHIP_PID=$!
}

# What reached the endpoint, as plain text.
shipped() { cat "$LOKI_LOG"; }

await_shipped() {
    local i
    for i in $(seq 1 60); do
        grep -q "$1" "$LOKI_LOG" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}

# Blocks until the shipper has finished a poll and is asleep between polls.
# The two SIGTERM tests below need exactly that state - the trap installed, one
# scan done - and both used to state it by sleeping for a second. That is a
# statement about the machine rather than about the shipper: under load the
# startup that precedes the trap takes longer than the sleep, the TERM lands
# before there is a trap to catch it, and the process dies flushing nothing.
# The nap is a child `sleep` of the shipper, which makes the state observable.
await_napping() {
    local i
    for i in $(seq 1 200); do
        pgrep -P "$SHIP_PID" -x sleep >/dev/null 2>&1 && return 0
        sleep 0.05
    done
    echo "the shipper never reached its first nap" >&2
    return 1
}

@test "a line is shipped to Loki while the session runs" {
    start_loki
    write_config
    mkdir -p "$(slug_dir)"
    start_ship
    say "hello from the session" >> "$(slug_dir)/s1.jsonl"
    await_shipped "hello from the session" || { echo "never arrived: $(shipped)"; return 1; }
    # Through jq, not a substring: the payload's whitespace is curl's business
    # and the labels are Loki's, so an assertion on the formatting would fail
    # on a reformat that changed nothing that matters.
    run jq -r '.streams[0].stream.job' <<< "$(shipped)"
    [ "$output" = "dejima-conversation" ] || {
        echo "the stream is not labelled for Loki: $(shipped)"; return 1; }
}

# The two loss paths a SIGTERM without a trap produces. bin/dejima kills this
# immediately after the container exits, and the tail of a transcript is the
# part worth having - it is usually the agent's final answer.
@test "a batch too large for an argv argument still ships" {
    # A single argument is capped at 128 KiB (MAX_ARG_STRLEN). The payload used
    # to be passed to jq and then to curl that way, so a batch of long lines
    # failed with "argument list too long" and was dropped silently - the
    # shipper keeps running, and only the conversation goes missing.
    #
    # Not a remote possibility: the transform clips a message at sixteen
    # kilobytes and the batch holds twenty, so any harness whose tool results
    # are large produces this as a matter of course. Found running Cline.
    start_loki
    write_config
    mkdir -p "$(slug_dir)"
    local big
    big="$(head -c 60000 /dev/zero | tr '\0' 'x')"
    local i
    for i in 1 2 3 4 5; do
        say "chunk-$i-$big" >> "$(slug_dir)/s1.jsonl"
    done
    start_ship
    # The marker is at the START of one of those lines, so finding it means the
    # whole oversized batch was accepted rather than one small line sneaking
    # through beside a dropped one.
    await_shipped "chunk-5-" || { echo "an oversized batch never arrived"; return 1; }
    run jq -r '.streams[0].stream.job' <<< "$(shipped | head -1)"
    [ "$output" = "dejima-conversation" ] || { echo "malformed payload: $output"; return 1; }
}

@test "a batched line survives the kill that ends the session" {
    start_loki
    write_config
    mkdir -p "$(slug_dir)"
    start_ship
    # Written before the first poll, so the poll reads it into the batch; the
    # kill then lands while the shipper is asleep with it still in there,
    # because the batch interval has not elapsed since it started.
    say "already batched" >> "$(slug_dir)/s1.jsonl"
    await_napping
    kill -TERM "$SHIP_PID"
    wait "$SHIP_PID" 2>/dev/null || true
    SHIP_PID=""
    [[ "$(shipped)" == *"already batched"* ]] || {
        echo "the in-memory batch was discarded: $(shipped)"; return 1; }
}

@test "a line written after the last poll survives the kill too" {
    start_loki
    write_config
    mkdir -p "$(slug_dir)"
    start_ship
    # Written after a poll has already run and killed before the next one, so
    # nothing has read it yet: only the trap's own rescan can find it. A
    # final_flush that flushed the batch without rescanning would pass the test
    # above and fail this one.
    await_napping
    say "the final answer" >> "$(slug_dir)/s1.jsonl"
    kill -TERM "$SHIP_PID"
    wait "$SHIP_PID" 2>/dev/null || true
    SHIP_PID=""
    [[ "$(shipped)" == *"the final answer"* ]] || {
        echo "the unread tail was lost: $(shipped)"; return 1; }
}

@test "a half-written line is not shipped torn" {
    start_loki
    write_config
    mkdir -p "$(slug_dir)"
    start_ship
    # No trailing newline: the record is still being written.
    printf '{"type":"user","sessionId":"s1","message":{"content":"partial line' \
        >> "$(slug_dir)/s1.jsonl"
    sleep 2
    [[ "$(shipped)" != *"partial"* ]] || {
        echo "a torn line shipped: $(shipped)"; return 1; }
    # And completing it ships the whole record, rather than leaving it stuck.
    printf '"}}\n' >> "$(slug_dir)/s1.jsonl"
    await_shipped "partial line" || { echo "the completed line never shipped: $(shipped)"; return 1; }
}

@test "a sibling project whose name extends this one is not shipped" {
    # Slugs cannot tell a worktree under this workspace from a sibling whose
    # directory name merely extends it, so a "<slug>-*" glob ships the
    # neighbour's conversation as well (#105). Every project on the host has a
    # directory here, so nothing else would catch it.
    start_loki
    write_config
    mkdir -p "$(slug_dir)"
    local sibling
    sibling="$(slug_dir)-other"
    mkdir -p "$sibling"
    say "the neighbour's private conversation" >> "$sibling/s9.jsonl"
    start_ship
    say "this workspace's own line" >> "$(slug_dir)/s1.jsonl"
    await_shipped "this workspace's own line" || { echo "nothing shipped at all"; return 1; }
    [[ "$(shipped)" != *"neighbour"* ]] || {
        echo "another project's conversation shipped: $(shipped)"; return 1; }
}

@test "conversation = off ships nothing and exits without waiting" {
    start_loki
    write_config off
    mkdir -p "$(slug_dir)"
    say "should never leave the host" >> "$(slug_dir)/s1.jsonl"
    run "$REPO_ROOT/bin/dejima-conversation-ship" "$WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    sleep 1
    [ ! -s "$LOKI_LOG" ] || { echo "shipped with the opt-in off: $(shipped)"; return 1; }
}

@test "no loki_url ships nothing, even with conversation on" {
    start_loki
    write_config
    sed -i '/^loki_url/d' "$CONFIG_DIR/config"
    mkdir -p "$(slug_dir)"
    say "nowhere to send this" >> "$(slug_dir)/s1.jsonl"
    run "$REPO_ROOT/bin/dejima-conversation-ship" "$WS"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -s "$LOKI_LOG" ]
}

@test "the shipper stops when the process that started it is gone" {
    # bin/dejima reaps this on a normal exit; a SIGKILLed bin/dejima runs no
    # trap, and without the parent check this would poll an ended session for
    # the life of the login session.
    start_loki
    write_config
    mkdir -p "$(slug_dir)"
    # A parent that exits immediately, leaving the shipper orphaned.
    local marker="$CONFIG_DIR/ship.pid"
    bash -c "\"\$1\" \"\$2\" & echo \$! > \"\$3\"" _ \
        "$REPO_ROOT/bin/dejima-conversation-ship" "$WS" "$marker"
    local pid i
    pid="$(cat "$marker")"
    for i in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
    done
    kill "$pid" 2>/dev/null || true
    echo "the orphaned shipper was still polling after 30s"
    return 1
}

# --- the rewrite update model ------------------------------------------------
#
# Claude Code appends a line per record, so the shipper reads forward from a
# byte offset. Cline replaces the whole file every time it writes, where an
# offset would land in the middle of a JSON document. The manifest says which,
# and these exercise the second path against a transcript shaped like the ones
# Cline actually produces.

CLINE_STATE=""

write_cline_config() {
    CLINE_STATE="$(mktemp -d)"
    cat > "$CONFIG_DIR/config" <<EOF
[core]
harness = cline
[logging]
loki_url = http://127.0.0.1:$LOKI_PORT
conversation = on
[harness.cline]
state_dir = $CLINE_STATE
model = m
EOF
}

# Where Cline's plugin looks: <state_dir>/<slug>/sessions/<id>/<id>.messages.json
cline_session_file() {
    local slug
    slug="$(bash -c 'source "$1"; ws_slug "$2"' _ \
        "$REPO_ROOT/bin/dejima-slug-lib.sh" "$WS")"
    printf '%s/%s/sessions/sess-1/sess-1.messages.json' "$CLINE_STATE" "$slug"
}

# The whole file, rewritten, carrying $@ as successive user messages - which is
# how Cline writes: never an append.
cline_write() {
    local f; f="$(cline_session_file)"
    mkdir -p "$(dirname "$f")"
    python3 - "$f" "$@" <<'EOF'
import json, sys
path, texts = sys.argv[1], sys.argv[2:]
json.dump({"version": 1, "sessionId": "sess-1",
           "messages": [{"role": "user", "content": [{"type": "text", "text": t}]}
                        for t in texts]}, open(path, "w"))
EOF
}

@test "a rewritten transcript ships only the records that are new" {
    start_loki
    write_cline_config
    cline_write "first thing said"
    start_ship
    await_shipped "first thing said" || { echo "never arrived: $(shipped)"; return 1; }
    # Rewritten whole, with the earlier message still in it. A byte offset
    # would ship the tail of a JSON document; the count of records already
    # sent is what makes this work.
    sleep 1
    cline_write "first thing said" "second thing said"
    await_shipped "second thing said" || { echo "the new record never arrived: $(shipped)"; return 1; }
    run grep -c "first thing said" "$LOKI_LOG"
    [ "$output" -eq 1 ] || { echo "the earlier record shipped again ($output times)"; return 1; }
}

@test "a transcript that has not changed is not shipped again" {
    start_loki
    write_cline_config
    cline_write "said once"
    start_ship
    await_shipped "said once" || { echo "never arrived: $(shipped)"; return 1; }
    # Several poll intervals with no write at all.
    sleep 4
    run grep -c "said once" "$LOKI_LOG"
    [ "$output" -eq 1 ] || { echo "an unchanged transcript was re-shipped ($output times)"; return 1; }
}

@test "a harness that cannot say where its transcripts are ships nothing" {
    # Both hooks are required and neither is assumed. Without them the shipper
    # exits rather than guessing at a layout - which is what it used to do,
    # since the layout was written into it.
    start_loki
    write_cline_config
    # A config naming cline but with no state_dir resolves no transcripts.
    sed -i 's#^state_dir = .*#state_dir =#' "$CONFIG_DIR/config"
    cline_write "should not ship"
    "$REPO_ROOT/bin/dejima-conversation-ship" "$WS" &
    SHIP_PID=$!
    sleep 3
    run grep -c "should not ship" "$LOKI_LOG"
    [ "$output" -eq 0 ] || { echo "shipped without a resolvable layout: $(shipped)"; return 1; }
}

@test "the tail survives a kill even when the harness declares an optional key with no default" {
    # #284, and it is worth pinning by SHAPE rather than by the key that
    # exposed it. Any optional keyspec with an empty default in the selected
    # harness's `keys` used to make final_flush's config lookup fail: it
    # re-resolves the transcript paths from the SIGTERM handler, and bash
    # reports 128+n for commands completing while it delivers a signal, so a
    # perfectly valid manifest was rejected and the tail - usually the agent's
    # final answer, which is the whole reason final_flush exists - was dropped
    # with no error the operator would ever see.
    #
    # Nothing shipped for claude-code had that shape until #171 added one, so
    # this adds one of its own rather than depending on a real key keeping it.
    # A provider root of its own, so the shipped manifests are not edited and
    # a concurrent run is unaffected.
    local proot="$BATS_TEST_TMPDIR/proot"
    mkdir -p "$proot"
    # Loudly: a partial copy here produces exactly the symptom this test is
    # about - a lookup that fails - and swallowing the error would report the
    # fixture's fault as the code's.
    cp -a "$REPO_ROOT/forges" "$REPO_ROOT/workflows" "$REPO_ROOT/harnesses" \
          "$REPO_ROOT/providers" "$proot/" \
        || { echo "could not build the probe provider root"; return 1; }
    local axis
    for axis in forges workflows harnesses providers; do
        [ -d "$proot/$axis" ] || { echo "the probe provider root has no $axis/"; return 1; }
    done
    sed -i 's/^keys \( *\)=/keys \1= probe_only_key:?identifier/' \
        "$proot/harnesses/claude-code/harness.conf"
    grep -q 'probe_only_key:?identifier' "$proot/harnesses/claude-code/harness.conf" \
        || { echo "the probe key was not injected"; return 1; }
    export DEJIMA_PROVIDER_ROOT="$proot"

    start_loki
    write_config
    mkdir -p "$(slug_dir)"
    start_ship

    # Wait for the shipper to be demonstrably running rather than sleeping at
    # it. A fixed sleep is a second race on a loaded machine: if the process
    # is still starting when the signal arrives, the handler runs before the
    # key schema has been resolved, which fails for the ORIGINAL #284 reason
    # and would read as this fix not working.
    say "a first line" >> "$(slug_dir)/s1.jsonl"
    await_shipped "a first line" || { echo "the shipper never started"; return 1; }

    say "the final answer" >> "$(slug_dir)/s1.jsonl"
    kill -TERM "$SHIP_PID"
    wait "$SHIP_PID" 2>/dev/null || true
    SHIP_PID=""
    [[ "$(shipped)" == *"the final answer"* ]] \
        || { echo "the unread tail was lost: $(shipped)"; return 1; }
    # And the lookup did not merely survive - it never failed. That message
    # reaching an operator's terminal is the visible half of this bug.
    [[ "$(shipped)" != *"unknown config key"* ]] || { echo "$(shipped)"; return 1; }
}
