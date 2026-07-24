#!/usr/bin/env bats
# Host-side (no Docker): the exit-time audit must flag host-persistence
# changes a session could have made to the workspace, and stay silent when
# nothing changed.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    AUDIT="$REPO_ROOT/bin/claude-sandbox-audit"
    WS="$(mktemp -d)"; git -C "$WS" init -q
    git -C "$WS" config user.email t@t; git -C "$WS" config user.name t
    STATE="$(mktemp)"
}
teardown() { rm -rf "$WS"; rm -f "$STATE"; }

snap() { "$AUDIT" snapshot "$WS" "$STATE"; }
cmp_() { "$AUDIT" compare "$WS" "$STATE" 2>&1; }

@test "no changes -> no output, exit 0" {
    snap
    run bash -c '"$0" compare "$1" "$2" 2>&1' "$AUDIT" "$WS" "$STATE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "flags a newly-added core.hooksPath" {
    snap
    git -C "$WS" config core.hooksPath /tmp/evil
    run cmp_
    [[ "$output" == *"core.hooksPath"* ]]
}

@test "flags a newly-added !-alias" {
    snap
    git -C "$WS" config alias.pwn '!touch /tmp/x'
    run cmp_
    [[ "$output" == *"alias.pwn"* ]]
}

@test "lists a benign config change but does not flag it as command-execution" {
    snap
    git -C "$WS" config user.name changed
    run cmp_
    [[ "$output" == *"user.name"* ]]
    [[ "$output" != *"COMMAND-EXECUTION"* ]] || [[ "$output" != *"user.name"*"COMMAND-EXECUTION"* ]]
}

@test "flags a new file under .claude/" {
    snap
    mkdir -p "$WS/.claude"; echo x > "$WS/.claude/settings.local.json"
    run cmp_
    [[ "$output" == *".claude/settings.local.json"* ]]
}

@test "flags a modified .mcp.json" {
    echo '{}' > "$WS/.mcp.json"; snap
    echo '{"mcpServers":{}}' > "$WS/.mcp.json"
    run cmp_
    [[ "$output" == *".mcp.json"* ]]
}

@test "flags a planted .git/hooks/pre-commit" {
    snap
    echo '#!/bin/sh' > "$WS/.git/hooks/pre-commit"; chmod +x "$WS/.git/hooks/pre-commit"
    run cmp_
    [[ "$output" == *"pre-commit"* ]]
}
