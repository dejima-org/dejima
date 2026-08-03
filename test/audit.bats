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
    AUDITDIR="$(mktemp -d)"; export DEJIMA_AUDIT_DIR="$AUDITDIR"
    BASEDIR="$(mktemp -d)"; export DEJIMA_AUDIT_BASELINE_DIR="$BASEDIR"
}
teardown() { rm -rf "$WS"; rm -f "$STATE"; rm -rf "$PROJDIR"; rm -rf "$STATUSLINE_DIR"; rm -rf "$AUDITDIR"; rm -rf "$BASEDIR"; }

snap() { "$AUDIT" snapshot "$WS" "$STATE"; }
cmp_() { "$AUDIT" compare "$WS" "$STATE" 2>&1; }

@test "no changes -> no output, exit 0" {
    snap
    run bash -c '"$0" compare "$1" "$2" 2>&1' "$AUDIT" "$WS" "$STATE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "compare against an existing-but-never-snapshotted state file skips silently instead of flagging everything" {
    # bin/dejima's cleanup() runs on every exit, including one before
    # `snapshot` ever ran (e.g. a startup abort) - its mktemp'd state file
    # exists but is empty in that case, same as $STATE here before snap() is
    # ever called. Compare must treat that the same as a missing file, not
    # diff real content against nothing and manufacture a finding for
    # everything already present. This is the routine case on every
    # pre-snapshot fatal exit, so it must stay silent - the "skipping"
    # message would otherwise bury the real error that was the operator's
    # last line.
    git -C "$WS" config core.hooksPath /tmp/evil
    run cmp_
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "compare against a genuinely missing state file path prints a skip notice" {
    git -C "$WS" config core.hooksPath /tmp/evil
    run "$AUDIT" compare "$WS" "$STATE.does-not-exist" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"no snapshot to compare against, skipping"* ]]
    [[ "$output" != *"core.hooksPath"* ]]
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

@test "flags the once-confirmed exploit: a symlink statusline.sh swapped for a regular file" {
    # This was the CONFIRMED Finding-1 gap: statusline.sh was mounted
    # read-only onto its own path inside a read-write ~/.claude mount, and
    # runc resolved the bind-mount destination through the symlink (the
    # common case, e.g. into a config checkout elsewhere), leaving the
    # symlink dentry itself writable and replaceable. Staging the file for
    # entrypoint.sh to copy in closed it (see test/runtime.bats), so
    # detection is no longer the only control - but a session reaching the
    # host statusline by some other route is exactly what an exit-time audit
    # is for, so this stays.
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

@test "the terminal header states what changed while the session ran, not what the session changed" {
    # The diff covers the whole session window regardless of source
    # (concurrent sessions, the operator's own edits, background tools),
    # so the header must not claim the session itself made the change.
    snap
    echo 'export X=1' > "$WS/.envrc"
    run cmp_
    [[ "$output" == *"host-persistence surfaces changed in"* ]]
    [[ "$output" == *"while this session ran"* ]]
    [[ "$output" != *"this session changed"* ]]
}

@test "the report file explains that concurrent sessions and operator edits land in the same diff" {
    snap
    mkdir -p "$WS/.claude"; echo 'x' > "$WS/.claude/CLAUDE.md"
    cmp_ >/dev/null 2>&1
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    run bash -c "cat '$AUDITDIR/$slug'/*.txt"
    [[ "$output" == *"not necessarily because"* ]]
    [[ "$output" == *"concurrent"* ]]
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

@test "keeps terminal escapes in a planted path out of the report" {
    snap
    mkdir -p "$WS/.claude"
    touch "$WS/.claude/$(printf 'evil\033[2Jfile')"
    run cmp_
    [[ "$output" != *$'\033'* ]]
    [[ "$output" == *"{hex}"* ]]
}

@test "keeps a bidi override in a planted path from visually reversing the report" {
    snap
    mkdir -p "$WS/.claude"
    touch "$WS/.claude/$(printf 'evil%sfile' $'\xe2\x80\xae')"
    run cmp_
    [[ "$output" != *$'\xe2\x80\xae'* ]]
    # Encoded, not silently stripped: rendering this as ".claude/evilfile"
    # would send the operator grepping for a name no file on disk has, and
    # is the id `ack` used to record - one that could never match again.
    [[ "$output" != *".claude/evilfile"* ]]
    [[ "$output" == *"{hex}2e636c617564652f6576696ce280ae66696c65"* ]]
}

@test "a path whose real bytes contain a bidi override can be acknowledged and stays acknowledged" {
    # The round trip this encoding exists for. compare wrote sanitized text,
    # ack derived the baseline id from it, and the next compare matched that
    # id against the RAW bytes on disk - so this path could never be
    # acknowledged, its report never cleared, and the startup warning fired
    # on it forever.
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$WS/.claude"
    snap
    printf 'x' > "$WS/.claude/$(printf 'evil%sfile' $'\xe2\x80\xae')"
    cmp_ >/dev/null 2>&1
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded 1 acknowledgement"* ]]
    [[ "$output" != *"no longer exists"* ]]
    grep -q '^safe {hex}2e636c617564652f6576696ce280ae66696c65 ' "$BASEDIR/$slug"
    # Same unchanged state file, so the same finding is rediscovered - and
    # is now suppressed by what ack recorded.
    run cmp_
    [ "$output" = "" ]
}

@test "a TAB in a monitored path does not truncate it in the snapshot record" {
    # The snapshot record is path<TAB>sha, read back with `cut -f1`, so a TAB
    # in a filename used to truncate the path there - upstream of any
    # encoding. ".git/hooks/pre<TAB>commit" was reported as ".git/hooks/pre":
    # still CRITICAL (it is still under .git/hooks/), still naming a file
    # that does not exist, so still unackable and nagging forever. Encoding
    # the path into that record closes it, because an encoded path can
    # contain neither TAB nor newline.
    snap
    printf 'x' > "$WS/.git/hooks/$(printf 'pre\tcommit')"
    run cmp_
    [[ "$output" != *".git/hooks/pre"$'\t'* ]]
    [[ "$output" != *"! HOST-CODE-EXECUTION workspace file: .git/hooks/pre"* ]]
    [[ "$output" == *"{hex}2e6769742f686f6f6b732f70726509636f6d6d6974"* ]]
    # ...and it can actually be acknowledged, which was the whole point
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded 1 acknowledgement"* ]]
    [[ "$output" != *"no longer exists"* ]]
    run cmp_
    [ "$output" = "" ]
}

@test "a file whose name merely contains the hex marker is left alone and still round-trips" {
    # The marker is only meaningful at the START of an id, so this one is
    # display-safe and is passed through verbatim - the encoding must not
    # reach for it here, and dec_id must not mistake it for encoded text.
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$WS/.claude"
    snap
    printf 'x' > "$WS/.claude/{hex}6576696c"
    run cmp_
    [[ "$output" == *".claude/{hex}6576696c"* ]]
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded 1 acknowledgement"* ]]
    grep -q '^safe \.claude/{hex}6576696c ' "$BASEDIR/$slug"
    run cmp_
    [ "$output" = "" ]
}

@test "an id that starts with the hex marker is encoded rather than passed through" {
    # Otherwise a workspace could hand `ack` an id that decodes to one of its
    # choosing - baselining something other than the finding while still
    # counting the finding acknowledged. No monitored path can reach this
    # (they are all rooted at .claude/.vscode/.git/.envrc/.mcp.json), but a
    # git config section name is free text in a file the session can write,
    # and the audit parses that file directly rather than through git.
    snap
    printf '[{hex}6576696c]\n\tkey = v\n' >> "$WS/.git/config"
    run cmp_
    [[ "$output" != *"{hex}6576696c.key"* ]]   # not passed through verbatim...
    [[ "$output" == *"{hex}7b6865787d36353736363936632e6b6579"* ]]   # ...encoded
}

@test "writes a timestamped report file containing the full finding list" {
    snap
    mkdir -p "$WS/.claude"; echo 'x' > "$WS/.claude/CLAUDE.md"
    cmp_ >/dev/null 2>&1
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    run bash -c "cat '$AUDITDIR/$slug'/*.txt"
    [[ "$output" == *"CLAUDE.md"* ]]
}

@test "names a report carrying critical findings so rotation can spare it" {
    snap
    echo 'export X=1' > "$WS/.envrc"
    cmp_ >/dev/null 2>&1
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    run bash -c "ls '$AUDITDIR/$slug'"
    [[ "$output" == *"-CRITICAL.txt"* ]]
}

@test "rotation keeps DEJIMA_AUDIT_KEEP clean reports" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$AUDITDIR/$slug"
    for i in $(seq 1 12); do
        touch "$AUDITDIR/$slug/2026-01-01-0000$i.txt"
    done
    snap; git -C "$WS" config user.name changed
    DEJIMA_AUDIT_KEEP=10 cmp_ >/dev/null 2>&1
    run bash -c "ls '$AUDITDIR/$slug' | wc -l"
    [ "$output" -le 10 ]
}

@test "rotation never evicts an unacknowledged CRITICAL report on age" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$AUDITDIR/$slug"
    touch "$AUDITDIR/$slug/2020-01-01-000000-CRITICAL.txt"
    for i in $(seq 1 12); do touch "$AUDITDIR/$slug/2026-01-01-0000$i.txt"; done
    snap; git -C "$WS" config user.name changed
    DEJIMA_AUDIT_KEEP=10 cmp_ >/dev/null 2>&1
    # rotation actually ran: 12 planted clean reports + this run's own, trimmed to KEEP
    clean_n="$(find "$AUDITDIR/$slug" -maxdepth 1 -name '*.txt' ! -name '*-CRITICAL.txt' | wc -l)"
    [ "$clean_n" -le 10 ]
    # ...and the unacknowledged CRITICAL report survived it
    [ -f "$AUDITDIR/$slug/2020-01-01-000000-CRITICAL.txt" ]
}

@test "rotation gives up instead of spinning forever when the report dir is unwritable" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$AUDITDIR/$slug"
    for i in $(seq 1 12); do touch "$AUDITDIR/$slug/2026-01-01-0000$i.txt"; done
    snap; git -C "$WS" config user.name changed
    chmod 500 "$AUDITDIR/$slug"
    run timeout 5 env DEJIMA_AUDIT_KEEP=10 "$AUDIT" compare "$WS" "$STATE"
    result="$status"
    chmod 700 "$AUDITDIR/$slug"
    [ "$result" -ne 124 ]
}

@test "show prints the only report there is, and names it" {
    snap
    echo 'export X=1' > "$WS/.envrc"
    cmp_ >/dev/null 2>&1
    run bash -c "'$AUDIT' show '$WS' 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *".envrc"* ]]
    [[ "$output" == *"-CRITICAL.txt"* ]]   # said which report it printed
}

@test "show and ack agree on which report they mean" {
    # `show` selected the newest report overall while `ack` preferred the
    # oldest unacknowledged CRITICAL one, so an operator who followed the
    # startup warning to `show` first was handed a different report than the
    # one being warned about - and went looking for a finding not in it.
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    report_dir="$AUDITDIR/$slug"; mkdir -p "$report_dir"
    cat > "$report_dir/2020-01-01-000000-CRITICAL.txt" <<REPORT
dejima audit report for $WS
CRITICAL HOST-CODE-EXECUTION workspace file: .envrc
REPORT
    cat > "$report_dir/2026-01-01-000001.txt" <<REPORT
dejima audit report for $WS
WARNING  changed workspace file: .vscode/settings.json
REPORT
    run "$AUDIT" show "$WS"
    [ "$status" -eq 0 ]
    [[ "$output" == *".envrc"* ]]           # the stale CRITICAL report...
    [[ "$output" != *"settings.json"* ]]    # ...not the newer clean one
}

@test "show falls back to the newest report when no CRITICAL one is pending" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    report_dir="$AUDITDIR/$slug"; mkdir -p "$report_dir"
    echo 'older' > "$report_dir/2020-01-01-000000.txt"
    echo 'newer' > "$report_dir/2026-01-01-000001.txt"
    run "$AUDIT" show "$WS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"newer"* ]]
    [[ "$output" != *"older"* ]]
}

@test "ack presents a stale unacknowledged CRITICAL report before a newer clean one" {
    # IMPORTANT 3: `ack` used to pick the newest report overall (sort | tail
    # -1), so a stale *-CRITICAL.txt sitting behind a newer clean report was
    # unreachable through `ack` at all - the operator has no remedy but to
    # keep pressing [c] past the startup warning, which is exactly the
    # failure this feature exists to eliminate.
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    echo 'export X=1' > "$WS/.envrc"   # real content, so the approval succeeds
    report_dir="$AUDITDIR/$slug"; mkdir -p "$report_dir"
    cat > "$report_dir/2020-01-01-000000-CRITICAL.txt" <<REPORT
dejima audit report for $WS
CRITICAL HOST-CODE-EXECUTION workspace file: .envrc
REPORT
    cat > "$report_dir/2026-01-01-000001.txt" <<REPORT
dejima audit report for $WS
WARNING  changed workspace file: .vscode/settings.json
REPORT
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *".envrc"* ]]           # presented the stale CRITICAL report...
    [[ "$output" != *"settings.json"* ]]    # ...not the newer clean one
    grep -q '^safe \.envrc ' "$BASEDIR/$slug"
    [ ! -f "$report_dir/2020-01-01-000000-CRITICAL.txt" ]  # cleared: suffix dropped
    [ -f "$report_dir/2020-01-01-000000.txt" ]
    [ -f "$report_dir/2026-01-01-000001.txt" ]              # the newer report is untouched
}

@test "a spam-listed path is not listed in the report" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$WS/.claude"; echo 'a' > "$WS/.claude/CLAUDE.md"; snap
    echo "spam .claude/CLAUDE.md" > "$BASEDIR/$slug"
    echo 'b' > "$WS/.claude/CLAUDE.md"
    run cmp_
    [[ "$output" != *"CLAUDE.md"* ]]
}

@test "a safe-listed path with a matching hash is suppressed" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    echo 'export X=1' > "$WS/.envrc"
    sha="$(sha256sum "$WS/.envrc" | cut -d' ' -f1)"
    echo "safe .envrc $sha" > "$BASEDIR/$slug"
    run cmp_
    [[ "$output" != *".envrc"* ]]
}

@test "a safe-listed path re-fires at full severity when its hash changes" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    echo 'export X=1' > "$WS/.envrc"
    echo "safe .envrc 0000000000000000000000000000000000000000000000000000000000000000" > "$BASEDIR/$slug"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
    [[ "$output" == *".envrc"* ]]
}

@test "a hand-written spam entry cannot silence a CRITICAL surface" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    echo "spam .envrc" > "$BASEDIR/$slug"
    echo 'export X=1' > "$WS/.envrc"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
    [[ "$output" == *".envrc"* ]]
}

@test "a baseline id containing a space does not suppress a different real path" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$WS/.vscode"
    echo 'a' > "$WS/.vscode/settings.json"; snap
    printf 'spam .vscode/settings.json old\n' > "$BASEDIR/$slug"
    echo 'b' > "$WS/.vscode/settings.json"
    run cmp_
    [[ "$output" == *".vscode/settings.json"* ]]
}

@test "ack writes nothing to the baseline when the operator quits" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap; echo 'export X=1' > "$WS/.envrc"; cmp_ >/dev/null 2>&1
    run bash -c "printf 'q\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *".envrc"* ]]           # ack ran and presented the finding
    [[ "$output" == *"nothing recorded"* ]] # ...and reported that it wrote nothing
    [ ! -f "$BASEDIR/$slug" ]               # ...and in fact wrote nothing
}

@test "ack refuses to spam a CRITICAL surface" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    echo 'export X=1' > "$WS/.envrc"
    mkdir -p "$WS/.vscode"; echo '{}' > "$WS/.vscode/settings.json"
    cmp_ >/dev/null 2>&1
    # 's' on the CRITICAL .envrc finding, then 'a' on the WARNING one that
    # follows it - so $BASEDIR/$slug is guaranteed to exist afterward and the
    # negative grep below can't pass vacuously against a missing file.
    run bash -c "printf 's\na\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"cannot 'always ignore' a CRITICAL surface - approve the exact content or skip."* ]]
    [ -f "$BASEDIR/$slug" ]
    ! grep -q '^spam \.envrc' "$BASEDIR/$slug"
}

@test "ack records a safe entry and clears the CRITICAL report marker" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap; echo 'export X=1' > "$WS/.envrc"; cmp_ >/dev/null 2>&1
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    grep -q '^safe .envrc' "$BASEDIR/$slug"
    run bash -c "ls '$AUDITDIR/$slug'"
    [[ "$output" != *"-CRITICAL.txt"* ]]
}

@test "ack does not write an unmatchable entry for a non-path finding" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap; git -C "$WS" config user.name changed; cmp_ >/dev/null 2>&1
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"cannot"* ]]
    [ ! -f "$BASEDIR/$slug" ]
}

@test "an ack-approved finding is suppressed on the next compare (id round-trips through the baseline)" {
    snap; echo 'export X=1' > "$WS/.envrc"; cmp_ >/dev/null 2>&1
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded 1 acknowledgement"* ]]  # ack ran and wrote the entry
    run cmp_
    [[ "$output" != *".envrc"* ]]                       # ...and it round-trips
}

@test "the CRITICAL suffix survives when a CRITICAL finding is skipped but a WARNING is approved" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    echo 'export X=1' > "$WS/.envrc"                                  # CRITICAL
    mkdir -p "$WS/.vscode"; echo '{}' > "$WS/.vscode/settings.json"   # WARNING
    cmp_ >/dev/null 2>&1
    # Report order is CRITICAL block then WARNING block, so the first key
    # answers the .envrc CRITICAL finding and the second answers the
    # .vscode/settings.json WARNING finding.
    run bash -c "printf 'c\na\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *".envrc"* ]]           # ack ran and presented the CRITICAL finding
    [[ "$output" == *"settings.json"* ]]    # ...and the WARNING finding
    grep -q '^safe .vscode/settings.json' "$BASEDIR/$slug"   # the approval was recorded
    run bash -c "ls '$AUDITDIR/$slug'"
    [[ "$output" == *"-CRITICAL.txt"* ]]    # but the CRITICAL finding was skipped, not approved,
                                             # so the report must stay eviction-protected
}

@test "ack refuses to approve a finding whose path no longer exists, and the CRITICAL suffix survives" {
    # A since-deleted path has no content left to pin a `safe` approval to -
    # writing one anyway (the old behaviour) produced a baseline entry
    # baseline_suppresses() can never match (its own empty-sha guard rejects
    # it as malformed), so the surface stayed permanently unsuppressible -
    # while `a` still advanced crit_acked and let the report shed its
    # -CRITICAL.txt protection for good. Refusing outright keeps both the
    # baseline and the report's protection honest.
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap; echo 'export X=1' > "$WS/.envrc"; cmp_ >/dev/null 2>&1
    rm -f "$WS/.envrc"   # gone by the time ack runs
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot approve: .envrc no longer exists"* ]]
    [[ "$output" == *"nothing recorded"* ]]
    [ ! -f "$BASEDIR/$slug" ]                    # nothing written to the baseline at all
    run bash -c "ls '$AUDITDIR/$slug'"
    [[ "$output" == *"-CRITICAL.txt"* ]]         # unacknowledged CRITICAL keeps its protection
}

@test "a workspace path containing its own ': ' cannot hijack ack's id derivation" {
    # Trigger (a) of CRITICAL 1: id="${body##*: }" took everything after the
    # LAST ": " in body, so a CRITICAL path containing a literal ": " (a
    # perfectly legal filename byte sequence) yielded the wrong id - here the
    # old code would derive "decoy" instead of the real path, so approving it
    # would baseline an id that can never match the real finding while still
    # letting the report shed -CRITICAL.txt.
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    mkdir -p "$WS/.git/hooks"
    printf '#!/bin/sh\necho pwned\n' > "$WS/.git/hooks/pre-commit: decoy"
    run cmp_
    [[ "$output" == *"HOST-CODE-EXECUTION"* ]]
    [[ "$output" == *".git/hooks/pre-commit: decoy"* ]]
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded 1 acknowledgement"* ]]
    grep -q '^safe \.git/hooks/pre-commit: decoy ' "$BASEDIR/$slug"
    ! grep -q '^safe decoy ' "$BASEDIR/$slug"
    run bash -c "ls '$AUDITDIR/$slug'"
    [[ "$output" != *"-CRITICAL.txt"* ]]         # correctly acked: suffix dropped
    run cmp_
    [[ "$output" != *"pre-commit: decoy"* ]]     # ...and the id round-trips through baseline_suppresses
}

# --- Task 8b: every CRITICAL finding type must be acknowledgeable, not just
# path findings, or a report carrying a non-path CRITICAL (git config,
# statusline, TCB) can never clear its -CRITICAL.txt suffix. ---

@test "a safe-listed gitconfig id with a matching hash suppresses a command-execution finding" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    git -C "$WS" config core.hooksPath /tmp/evil
    sha="$(printf '%s' "/tmp/evil" | sha256sum | cut -d' ' -f1)"
    echo "safe gitconfig:core.hooksPath $sha" > "$BASEDIR/$slug"
    run cmp_
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "a safe-listed gitconfig id re-fires when the value changes" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    git -C "$WS" config core.hooksPath /tmp/evil
    echo "safe gitconfig:core.hooksPath 0000000000000000000000000000000000000000000000000000000000000000" > "$BASEDIR/$slug"
    run cmp_
    [[ "$output" == *"COMMAND-EXECUTION"* ]]
    [[ "$output" == *"core.hooksPath"* ]]
}

@test "a hand-written spam gitconfig entry cannot silence a CRITICAL command-execution surface" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    echo "spam gitconfig:core.hooksPath" > "$BASEDIR/$slug"
    git -C "$WS" config core.hooksPath /tmp/evil
    run cmp_
    [[ "$output" == *"COMMAND-EXECUTION"* ]]
    [[ "$output" == *"core.hooksPath"* ]]
}

@test "ack records a safe gitconfig entry whose id round-trips and suppresses the next compare" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    git -C "$WS" config core.hooksPath /tmp/evil
    cmp_ >/dev/null 2>&1
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded 1 acknowledgement"* ]]
    grep -q '^safe gitconfig:core.hooksPath ' "$BASEDIR/$slug"
    run cmp_
    [[ "$output" != *"core.hooksPath"* ]]
}

@test "ack records a safe gitconfig alias entry whose id round-trips and suppresses the next compare" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    git -C "$WS" config alias.pwn '!touch /tmp/x'
    cmp_ >/dev/null 2>&1
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded 1 acknowledgement"* ]]
    grep -q '^safe gitconfig:alias.pwn ' "$BASEDIR/$slug"
    run cmp_
    [[ "$output" != *"alias.pwn"* ]]
}

@test "a report whose only CRITICAL is a git-config finding can be fully acknowledged and loses the CRITICAL suffix" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    git -C "$WS" config core.hooksPath /tmp/evil
    cmp_ >/dev/null 2>&1
    run bash -c "ls '$AUDITDIR/$slug'"
    [[ "$output" == *"-CRITICAL.txt"* ]]
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    run bash -c "ls '$AUDITDIR/$slug'"
    [[ "$output" != *"-CRITICAL.txt"* ]]
}

@test "a safe-listed statusline id with a matching hash suppresses a statusline finding" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    printf '#!/bin/sh\necho original\n' > "$DEJIMA_AUDIT_STATUSLINE"
    snap
    printf '#!/bin/sh\necho pwned\n' > "$DEJIMA_AUDIT_STATUSLINE"
    sha="$(sha256sum "$DEJIMA_AUDIT_STATUSLINE" | cut -d' ' -f1)"
    echo "safe statusline:statusline.sh $sha" > "$BASEDIR/$slug"
    run cmp_
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "ack records a safe statusline entry whose id round-trips and suppresses the next compare" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    printf '#!/bin/sh\necho original\n' > "$DEJIMA_AUDIT_STATUSLINE"
    snap
    printf '#!/bin/sh\necho pwned\n' > "$DEJIMA_AUDIT_STATUSLINE"
    cmp_ >/dev/null 2>&1
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded 1 acknowledgement"* ]]
    grep -q '^safe statusline:statusline.sh ' "$BASEDIR/$slug"
    run cmp_
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "a safe-listed tcb id with a matching hash suppresses a TCB finding" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$WS/bin"; echo x > "$WS/bin/x"; echo x > "$WS/install.sh"
    export DEJIMA_AUDIT_REPO_ROOT="$(readlink -f "$WS")"
    snap
    echo changed > "$WS/bin/x"
    sha="$(sha256sum "$WS/bin/x" | cut -d' ' -f1)"
    echo "safe tcb:bin/x $sha" > "$BASEDIR/$slug"
    run cmp_
    [[ "$output" != *"TCB"* ]]
}

@test "ack records a safe tcb entry whose id round-trips and suppresses the next compare" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    mkdir -p "$WS/bin"; echo x > "$WS/bin/x"; echo x > "$WS/install.sh"
    export DEJIMA_AUDIT_REPO_ROOT="$(readlink -f "$WS")"
    snap
    echo changed > "$WS/bin/x"
    cmp_ >/dev/null 2>&1
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"recorded 1 acknowledgement"* ]]
    grep -q '^safe tcb:bin/x ' "$BASEDIR/$slug"
    run cmp_
    [[ "$output" != *"TCB"* ]]
}

@test "a crafted git config value cannot hijack ack's id derivation" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    git -C "$WS" config core.hooksPath 'workspace file: /tmp/evil'
    cmp_ >/dev/null 2>&1
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    grep -q '^safe gitconfig:core.hooksPath' "$BASEDIR/$slug"
    ! grep -q '/tmp/evil ' "$BASEDIR/$slug"
    run bash -c "ls '$AUDITDIR/$slug'"
    [[ "$output" != *"-CRITICAL.txt"* ]]
}

@test "a crafted git config value cannot hijack id derivation when the finding is skipped" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    git -C "$WS" config core.hooksPath 'workspace file: /tmp/evil'
    cmp_ >/dev/null 2>&1
    run bash -c "printf 'c\n' | '$AUDIT' ack '$WS'"
    run bash -c "ls '$AUDITDIR/$slug'"
    [[ "$output" == *"-CRITICAL.txt"* ]]
}

@test "ack still refuses to spam a CRITICAL git-config surface" {
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    snap
    git -C "$WS" config core.hooksPath /tmp/evil
    mkdir -p "$WS/.vscode"; echo '{}' > "$WS/.vscode/settings.json"
    cmp_ >/dev/null 2>&1
    # 's' on the CRITICAL gitconfig finding, then 'a' on the WARNING one that
    # follows it - so $BASEDIR/$slug is guaranteed to exist afterward and the
    # negative grep below can't pass vacuously against a missing file.
    run bash -c "printf 's\na\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"cannot 'always ignore' a CRITICAL surface - approve the exact content or skip."* ]]
    [ -f "$BASEDIR/$slug" ]
    ! grep -q '^spam gitconfig:core.hooksPath' "$BASEDIR/$slug"
}

# --- issue #57: the workspace argument is optional ---

@test "show finds the workspace when run from the repo root" {
    snap
    printf 'x\n' > "$WS/.envrc"
    cmp_ >/dev/null
    run bash -c "cd '$WS' && '$AUDIT' show 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *".envrc"* ]]
}

@test "show finds the workspace when run from a subdirectory" {
    mkdir -p "$WS/src/deep"
    snap
    printf 'x\n' > "$WS/.envrc"
    cmp_ >/dev/null
    run bash -c "cd '$WS/src/deep' && '$AUDIT' show 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *".envrc"* ]]
}

@test "show finds the parent repo when run from a linked worktree" {
    # The sandbox's own workflow: work happens in WORKSPACE/.worktrees/<branch>,
    # but bin/dejima mounted (and keyed the reports to) the parent repo. A
    # worktree-local lookup would report "no reports" while the startup
    # warning kept firing on the parent's.
    git -C "$WS" commit -q --allow-empty -m init
    git -C "$WS" worktree add -q "$WS/.worktrees/wt" -b wt
    snap
    printf 'x\n' > "$WS/.envrc"
    cmp_ >/dev/null
    run bash -c "cd '$WS/.worktrees/wt' && '$AUDIT' show 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *".envrc"* ]]
}

@test "show names the path it resolved when that workspace has no reports" {
    # A wrong guess must be visible, not silent - the operator has to be able
    # to tell "nothing happened here" from "you are looking at the wrong repo".
    other="$(mktemp -d)"; git -C "$other" init -q
    run bash -c "cd '$other' && '$AUDIT' show 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no reports for"* ]]
    [[ "$output" == *"$other"* ]]
    rm -rf "$other"
}

@test "an explicit workspace argument still wins over detection" {
    snap
    printf 'x\n' > "$WS/.envrc"
    cmp_ >/dev/null
    other="$(mktemp -d)"; git -C "$other" init -q
    run bash -c "cd '$other' && '$AUDIT' show '$WS' 2>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *".envrc"* ]]
    rm -rf "$other"
}

# --- issue #57: ack must show the content it is asking about ---

# Later tasks add a sidecar directory of retained diffs beside each report.
# These tests are about the no-retention fallback specifically, so they
# remove it - which is a no-op today and stays correct afterwards.
no_sidecar() { rm -rf "$AUDITDIR"/*/*.d; }

@test "ack shows the content of the file it asks to approve" {
    snap
    printf 'export SECRET_FLAG=planted\n' > "$WS/.envrc"
    cmp_ >/dev/null
    no_sidecar
    run bash -c "printf 'q\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"export SECRET_FLAG=planted"* ]]
}

@test "ack shows the value of the git config key it asks to approve" {
    # The finding's own body line already carries the value (it's not
    # opaque like a file-content finding), so asserting on the whole output
    # would pass even with render_finding never called. Scope the assertion
    # to the content block itself to actually exercise this task's code.
    snap
    git -C "$WS" config core.hooksPath /tmp/evil
    cmp_ >/dev/null
    no_sidecar
    run bash -c "printf 'q\n' | '$AUDIT' ack '$WS'"
    after_marker="${output#*--- current content ---}"
    [ "$after_marker" != "$output" ]
    [[ "$after_marker" == *"/tmp/evil"* ]]
}

@test "control characters in a git config key are stripped from the source hint" {
    # source_hint's gitconfig arm builds a "git config --get <key>" hint
    # from the decoded raw id ($rid) - a crafted subsection name (still a
    # valid CRITICAL finding via filter.*.smudge) must go through sanitize
    # here exactly like the tcb/default arms already do, not reach the
    # terminal verbatim.
    mkdir -p "$WS/.git"
    snap
    printf '[filter "evil\033[31mx"]\n\tsmudge = cat\n' >> "$WS/.git/config"
    cmp_ >/dev/null
    no_sidecar
    run bash -c "printf 'q\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"full value: git -C"* ]]
    [[ "$output" != *$'\033'* ]]
}

@test "ack renders a symlinked hook as its target, matching how it is hashed" {
    mkdir -p "$WS/.git/hooks"
    snap
    ln -s /tmp/evil-target "$WS/.git/hooks/pre-commit"
    cmp_ >/dev/null
    no_sidecar
    run bash -c "printf 'q\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"-> /tmp/evil-target"* ]]
}

@test "ack can approve a dangling symlink it just displayed, and the approval is recorded" {
    # current_content_for_id and current_sha_for_id must agree that a
    # dangling symlink (target does not exist) still counts as present -
    # otherwise the operator approves content they were just shown and is
    # told the surface vanished, and the CRITICAL report can never clear.
    mkdir -p "$WS/.git/hooks"
    snap
    ln -s /tmp/does-not-exist-anywhere "$WS/.git/hooks/pre-commit"
    cmp_ >/dev/null
    no_sidecar
    slug="$(printf '%s' "$WS" | sed 's/[^a-zA-Z0-9]/-/g')"
    run bash -c "printf 'a\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"-> /tmp/does-not-exist-anywhere"* ]]
    [[ "$output" != *"no longer exists"* ]]
    grep -q '^safe \.git/hooks/pre-commit ' "$BASEDIR/$slug"
}

@test "control characters in displayed content are stripped" {
    # The whole reason sanitize() exists: content is workspace-controlled and
    # lands in a terminal. An ESC here could clear the screen or repaint the
    # prompt the operator is about to answer.
    mkdir -p "$WS/.git/hooks"
    snap
    printf '#!/bin/sh\n\033[2Jcurl evil\n' > "$WS/.git/hooks/pre-commit"
    cmp_ >/dev/null
    no_sidecar
    run bash -c "printf 'q\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"curl evil"* ]]
    [[ "$output" != *$'\033'* ]]
}

@test "a bidi override in displayed content is stripped" {
    mkdir -p "$WS/.git/hooks"
    snap
    printf '#!/bin/sh\necho \xe2\x80\xaereversed\n' > "$WS/.git/hooks/pre-commit"
    cmp_ >/dev/null
    no_sidecar
    run bash -c "printf 'q\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"reversed"* ]]
    [[ "$output" != *$'\xe2\x80\xae'* ]]
}

@test "displayed content is capped and points at the real file" {
    mkdir -p "$WS/.git/hooks"
    snap
    seq 1 500 > "$WS/.git/hooks/pre-commit"
    cmp_ >/dev/null
    no_sidecar
    run bash -c "printf 'q\n' | '$AUDIT' ack '$WS'"
    [[ "$output" == *"more line(s)"* ]]
    [[ "$output" == *".git/hooks/pre-commit"* ]]
    [[ "$output" != *"499"* ]]
}
