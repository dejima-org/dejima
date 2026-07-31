#!/usr/bin/env bats
# Host-side (no Docker): the exit-time audit must flag host-persistence
# changes a session could have made to the workspace, and stay silent when
# nothing changed.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    AUDIT="$REPO_ROOT/bin/dejima-audit"
    WS="$(mktemp -d)"; git -C "$WS" init -q
    git -C "$WS" config user.email t@t; git -C "$WS" config user.name t
    STATE="$(mktemp)"
    PROJDIR="$(mktemp -d)"
    export DEJIMA_AUDIT_PROJECTS_DIR="$PROJDIR"
    CURRENT_SLUG="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    STATUSLINE_DIR="$(mktemp -d)"
    export DEJIMA_AUDIT_STATUSLINE="$STATUSLINE_DIR/statusline.sh"
}
teardown() { rm -rf "$WS"; rm -f "$STATE"; rm -rf "$PROJDIR"; rm -rf "$STATUSLINE_DIR"; }

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

@test "flags a quoted !-alias as command-execution" {
    snap
    git -C "$WS" config alias.evil '!id;'
    run cmp_
    line="$(printf '%s\n' "$output" | grep 'alias.evil')"
    [[ "$line" == *"COMMAND-EXECUTION"* ]]
}

@test "flags a worktree config.worktree core.hooksPath as command-execution" {
    snap
    mkdir -p "$WS/.git/worktrees/other"
    printf '[core]\n\thooksPath = /tmp/evil\n' > "$WS/.git/worktrees/other/config.worktree"
    run cmp_
    line="$(printf '%s\n' "$output" | grep 'core.hooksPath')"
    [[ "$line" == *"COMMAND-EXECUTION"* ]]
}

@test "reports a single modified .mcp.json exactly once" {
    echo '{}' > "$WS/.mcp.json"; snap
    echo '{"mcpServers":{}}' > "$WS/.mcp.json"
    run cmp_
    count="$(printf '%s\n' "$output" | grep -c 'workspace file:.*\.mcp\.json')"
    [ "$count" -eq 1 ]
}

@test "flags a cross-project write under ~/.claude/projects" {
    mkdir -p "$PROJDIR/-some-other-project"
    echo x > "$PROJDIR/-some-other-project/file1"
    snap
    echo y > "$PROJDIR/-some-other-project/file2"; touch -d '+1 hour' "$PROJDIR/-some-other-project/file2"
    run cmp_
    [[ "$output" == *"CROSS-PROJECT history/memory write: -some-other-project"* ]]
}

@test "does not flag the current project's own projects slug" {
    mkdir -p "$PROJDIR/$CURRENT_SLUG"
    echo x > "$PROJDIR/$CURRENT_SLUG/file1"
    snap
    echo y > "$PROJDIR/$CURRENT_SLUG/file2"; touch -d '+1 hour' "$PROJDIR/$CURRENT_SLUG/file2"
    run cmp_
    [[ "$output" != *"CROSS-PROJECT"* ]]
}

@test "does not flag a worktree child's projects slug" {
    mkdir -p "$PROJDIR/${CURRENT_SLUG}--worktrees-featurex"
    echo x > "$PROJDIR/${CURRENT_SLUG}--worktrees-featurex/file1"
    snap
    echo y > "$PROJDIR/${CURRENT_SLUG}--worktrees-featurex/file2"; touch -d '+1 hour' "$PROJDIR/${CURRENT_SLUG}--worktrees-featurex/file2"
    run cmp_
    [[ "$output" != *"CROSS-PROJECT"* ]]
}

@test "silent when no projects changed" {
    mkdir -p "$PROJDIR/-some-other-project"
    echo x > "$PROJDIR/-some-other-project/file1"
    snap
    run bash -c '"$0" compare "$1" "$2" 2>&1' "$AUDIT" "$WS" "$STATE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "flags core.pager as command-execution" {
    snap
    git -C "$WS" config core.pager 'evil'
    run cmp_
    line="$(printf '%s\n' "$output" | grep 'core.pager')"
    [[ "$line" == *"COMMAND-EXECUTION"* ]]
}

@test "flags diff.external as command-execution" {
    snap
    git -C "$WS" config diff.external 'evil'
    run cmp_
    line="$(printf '%s\n' "$output" | grep 'diff.external')"
    [[ "$line" == *"COMMAND-EXECUTION"* ]]
}

@test "flags include.path as command-execution (config indirection)" {
    snap
    git -C "$WS" config include.path '/tmp/evil.gitconfig'
    run cmp_
    line="$(printf '%s\n' "$output" | grep 'include.path')"
    [[ "$line" == *"COMMAND-EXECUTION"* ]]
}

@test "flags a planted symlink under .claude/" {
    mkdir -p "$WS/.claude"
    snap
    ln -s /etc/passwd "$WS/.claude/evil"
    run cmp_
    [[ "$output" == *".claude/evil"* ]]
}

@test "TCB: flags a change under bin/ when workspace is the audit's own repo root" {
    mkdir -p "$WS/bin"
    echo x > "$WS/bin/x"
    echo x > "$WS/install.sh"
    export DEJIMA_AUDIT_REPO_ROOT="$(readlink -f "$WS")"
    snap
    echo changed > "$WS/bin/x"
    run cmp_
    [[ "$output" == *"TCB (sandbox self) modified: bin/x"* ]]
}

@test "TCB: does not flag changes when the workspace is not the audit's own repo root" {
    mkdir -p "$WS/bin"
    echo x > "$WS/bin/x"
    # DEJIMA_AUDIT_REPO_ROOT is left unset here, so it defaults to
    # this repo's real root - $WS (a scratch dir) is not that, so the TCB
    # section stays empty even though a same-named file changes.
    snap
    echo changed > "$WS/bin/x"
    run cmp_
    [[ "$output" != *"TCB"* ]]
}

@test "silent when statusline.sh is absent (no host statusline configured)" {
    snap
    run cmp_
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "flags a plain regular-file statusline.sh replaced with different content" {
    printf '#!/bin/sh\necho original\n' > "$DEJIMA_AUDIT_STATUSLINE"
    snap
    printf '#!/bin/sh\necho pwned\n' > "$DEJIMA_AUDIT_STATUSLINE"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
    [[ "$output" == *"statusline.sh"* ]]
}

@test "flags the confirmed exploit: a symlink statusline.sh swapped for a regular file" {
    # This is the CONFIRMED Finding-1 gap: bin/dejima's read-only
    # mount onto ~/.claude/statusline.sh does not reliably survive when
    # statusline.sh is a symlink (the common case, e.g. into a dotfiles
    # checkout) - runc resolves the bind-mount destination through the
    # symlink, leaving the symlink dentry itself on the writable ~/.claude
    # mount and still replaceable (confirmed against a live container - see
    # test/runtime.bats). Detection here is the compensating control.
    local target_dir; target_dir="$(mktemp -d)"
    printf '#!/bin/sh\necho original\n' > "$target_dir/statusline.sh"
    ln -s "$target_dir/statusline.sh" "$DEJIMA_AUDIT_STATUSLINE"
    snap
    rm -f "$DEJIMA_AUDIT_STATUSLINE"
    printf '#!/bin/sh\necho pwned\n' > "$DEJIMA_AUDIT_STATUSLINE"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
    [[ "$output" == *"statusline.sh"* ]]
    rm -rf "$target_dir"
}

@test "flags a statusline.sh symlink repointed to a different target, even if the target's content is identical" {
    local target_a target_b; target_a="$(mktemp -d)"; target_b="$(mktemp -d)"
    printf '#!/bin/sh\necho same\n' > "$target_a/statusline.sh"
    printf '#!/bin/sh\necho same\n' > "$target_b/statusline.sh"
    ln -s "$target_a/statusline.sh" "$DEJIMA_AUDIT_STATUSLINE"
    snap
    ln -sf "$target_b/statusline.sh" "$DEJIMA_AUDIT_STATUSLINE"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
    rm -rf "$target_a" "$target_b"
}

@test "does not flag statusline.sh when nothing about it changed" {
    printf '#!/bin/sh\necho original\n' > "$DEJIMA_AUDIT_STATUSLINE"
    snap
    run cmp_
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "flags .envrc as host code execution, not a plain file change" {
    snap
    echo 'export X=1' > "$WS/.envrc"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
    [[ "$output" == *".envrc"* ]]
}

@test "flags .claude/settings.local.json as host code execution" {
    snap
    mkdir -p "$WS/.claude"; echo '{}' > "$WS/.claude/settings.local.json"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
}

@test "flags .mcp.json as host code execution" {
    echo '{}' > "$WS/.mcp.json"; snap
    echo '{"a":1}' > "$WS/.mcp.json"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
}

@test "flags .vscode/tasks.json as host code execution" {
    snap
    mkdir -p "$WS/.vscode"; echo '{}' > "$WS/.vscode/tasks.json"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
}

@test "does not flag an ordinary .claude file as host code execution" {
    snap
    mkdir -p "$WS/.claude"; echo 'notes' > "$WS/.claude/CLAUDE.md"
    run cmp_
    [[ "$output" == *"CLAUDE.md"* ]]
    [[ "$output" != *"HOST-CODE-EXECUTION"* ]]
}

@test "prints CRITICAL findings after WARNING findings" {
    snap
    echo 'export X=1' > "$WS/.envrc"                                  # CRITICAL
    mkdir -p "$WS/.vscode"; echo '{}' > "$WS/.vscode/settings.json"   # WARNING
    run cmp_
    crit_line=$(printf '%s\n' "$output" | grep -n "HOST-CODE-EXECUTION" | head -1 | cut -d: -f1)
    warn_line=$(printf '%s\n' "$output" | grep -n "settings.json" | head -1 | cut -d: -f1)
    [ "$crit_line" -gt "$warn_line" ]
}

@test "lists a WARNING-tier file without marking it as host code execution" {
    snap
    mkdir -p "$WS/.vscode"; echo '{}' > "$WS/.vscode/settings.json"
    run cmp_
    [[ "$output" == *".vscode/settings.json"* ]]
    [[ "$output" != *"HOST-CODE-EXECUTION"*".vscode/settings.json"* ]]
}

@test "caps the CRITICAL block at 10 entries" {
    mkdir -p "$WS/.git/hooks"; snap
    for i in $(seq 1 40); do echo "#!/bin/sh" > "$WS/.git/hooks/h$i"; done
    run cmp_
    [ "$(printf '%s\n' "$output" | grep -c '^  ! ')" -le 10 ]
}

@test "overflow past the CRITICAL cap prints below the list and reads as an alarm" {
    mkdir -p "$WS/.git/hooks"; snap
    for i in $(seq 1 40); do echo "#!/bin/sh" > "$WS/.git/hooks/h$i"; done
    run cmp_
    [[ "$output" == *"ABNORMAL"* ]]
    last_crit=$(printf '%s\n' "$output" | grep -n '^  ! ' | tail -1 | cut -d: -f1)
    overflow=$(printf '%s\n' "$output" | grep -n "ABNORMAL" | head -1 | cut -d: -f1)
    [ "$overflow" -gt "$last_crit" ]
}

@test "caps the WARNING block at 5 entries" {
    mkdir -p "$WS/.vscode"; snap
    for i in $(seq 1 20); do echo x > "$WS/.vscode/f$i"; done
    run cmp_
    [ "$(printf '%s\n' "$output" | grep -c '^  - ')" -le 5 ]
}

@test "overflow past the WARNING cap prints a counted line below the list" {
    mkdir -p "$WS/.vscode"; snap
    for i in $(seq 1 20); do echo x > "$WS/.vscode/f$i"; done
    run cmp_
    [[ "$output" == *"further change(s) not shown."* ]]
    last_warn=$(printf '%s\n' "$output" | grep -n '^  - ' | tail -1 | cut -d: -f1)
    overflow=$(printf '%s\n' "$output" | grep -n '^  + ' | head -1 | cut -d: -f1)
    [ "$overflow" -gt "$last_warn" ]
}

@test "the last line of the report is the verdict, not a border" {
    snap
    echo 'export X=1' > "$WS/.envrc"
    run cmp_
    last=$(printf '%s\n' "$output" | grep -v '^$' | tail -1)
    [[ "$last" != *"====="* ]]
    [[ "$last" == *"dejima:"* ]]
    [[ "$last" == *"1 CRITICAL"* ]]
}

@test "the verdict line reports no critical findings when only WARNING-tier changes exist" {
    snap
    mkdir -p "$WS/.vscode"; echo '{}' > "$WS/.vscode/settings.json"
    run cmp_
    last=$(printf '%s\n' "$output" | grep -v '^$' | tail -1)
    [[ "$last" != *"====="* ]]
    [[ "$last" == *"dejima:"* ]]
    [[ "$last" == *"no critical findings"* ]]
}

@test "strips terminal escapes from a planted config value" {
    snap
    git -C "$WS" config core.pager "$(printf 'less\033[2Jgotcha')"
    run cmp_
    [[ "$output" != *$'\033'* ]]
    [[ "$output" == *"core.pager"* ]]
}

@test "strips terminal escapes from a planted path" {
    snap
    mkdir -p "$WS/.claude"
    touch "$WS/.claude/$(printf 'evil\033[2Jfile')"
    run cmp_
    [[ "$output" != *$'\033'* ]]
    [[ "$output" == *".claude/evil"* ]]
}
