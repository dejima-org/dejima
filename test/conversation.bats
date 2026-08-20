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
start_loki() {
    LOKI_PORT="$(python3 - <<'EOF'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
EOF
)"
    python3 - "$LOKI_PORT" "$LOKI_LOG" <<'EOF' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, path = int(sys.argv[1]), sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(path, "ab") as f:
            f.write(body + b"\n")
        self.send_response(204)
        self.end_headers()
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
    LOKI_PID=$!
    local i
    for i in $(seq 1 50); do
        (exec 3<>/dev/tcp/127.0.0.1/"$LOKI_PORT") 2>/dev/null && return 0
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
@test "a batched line survives the kill that ends the session" {
    start_loki
    write_config
    mkdir -p "$(slug_dir)"
    start_ship
    # Long enough for one poll to read the line into the batch, short enough
    # that the 2s batch interval has not flushed it on its own.
    say "already batched" >> "$(slug_dir)/s1.jsonl"
    sleep 1
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
    # Written and killed inside one poll interval, so nothing has read it yet:
    # only the trap's own rescan can find it. A final_flush that flushed the
    # batch without rescanning would pass the test above and fail this one.
    sleep 1
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
