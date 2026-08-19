# Harness plugin: Claude Code.
#
# Sourced by bin/dejima through harness_plugin_load when [core] harness names
# this harness. Part of the trusted computing base - see the interface notes
# in bin/dejima-harness-lib.sh for why plugins live here and why they are
# sourced rather than invoked.
#
# What is here is what could not be stated as a manifest value. The paths
# themselves come from the manifest ([harness.claude-code] projects_dir); the
# reason this is code is the pairing in the second block, which resolves one
# directory tree through the filenames of another.

# Registers the waiting/done notification handlers into dejima's settings
# layer, in the shape Claude Code reads them.
#
# Claude Code merges hook entries across settings layers rather than letting
# the higher one replace the lower, so these are added to whatever the
# operator already has rather than displacing it. $HOME is left unexpanded
# for Claude Code to resolve at hook-run time - inside the container, not
# here - matching the convention install.sh already uses.
#
# Written through a temp file and renamed: the destination is the settings
# layer bin/dejima is about to mount, and a jq that failed partway would
# otherwise leave the session with a truncated one.
harness_register_notify() {
    local settings="$1" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/dejima-settings-remote.XXXXXX.json")"
    if jq '.hooks.Notification = ((.hooks.Notification // []) + [{"matcher": "", "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/dejima-notify.sh waiting"}]}])
      | .hooks.Stop = ((.hooks.Stop // []) + [{"matcher": "", "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/dejima-notify.sh done"}]}])' \
        "$settings" > "$tmp"; then
        mv "$tmp" "$settings"
    else
        rm -f "$tmp"
        echo "warning: could not register the notification hooks; remote access" >&2
        echo "will not be told when this session wants attention." >&2
    fi
}

# The per-project and per-session state this harness keeps on the host, and
# which parts of it this workspace is entitled to see.
harness_state_mounts() {
    local ws="$1" projects slug sid
    projects="$(harness_config_get projects_dir)"
    [ -n "$projects" ] || return 0

    # projects/, one slug at a time: the tree is every project's transcripts
    # and memory, and memory is loaded into context at session start, so a
    # write into another slug is background a future session there believes
    # (#104). projects/ itself stays container-local, so an unmounted slug is
    # still writable and just does not survive - which is how Claude Code
    # creates a slug it does not find. Existing slugs only, apart from the
    # workspace's own, so a checkout full of worktrees does not litter the
    # host with empty directories for worktrees nothing has run in.
    mkdir -p "$projects/$(ws_slug "$ws")"
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        [ -d "$projects/$slug" ] || continue
        emit_mount "$projects/$slug"
    done < <(workspace_slugs_sorted "$ws")

    # file-history, same shape, sharper reason: `<session>/<hash>@v1` is a
    # verbatim copy of an edited file, so the tree is other projects' source
    # rather than a record of it, and it was writable - tampering there puts
    # chosen content into a later restore. Keyed by session id, so there is
    # no slug to match on; workspace_session_ids resolves it through the
    # transcript names. The starting session's id cannot be known yet, so its
    # directory is container-local: undo history for it is lost if it is
    # resumed on the host.
    #
    # The pairing is why the plugin is code, and the split is the design in
    # miniature: both directories are statable, so both are manifest keys.
    # What cannot be stated is the rule that a name in one selects an entry
    # in the other, so that is here.
    local history
    history="$(harness_config_get file_history_dir)"
    [ -n "$history" ] || return 0
    mkdir -p "$history"
    while IFS= read -r sid; do
        [ -n "$sid" ] || continue
        [ -d "$history/$sid" ] || continue
        emit_mount "$history/$sid"
    done < <(workspace_session_ids "$projects" "$ws")
}

# Puts dejima's guard hooks where Claude Code will find them: symlinked into
# ~/.claude/hooks, and registered in ~/.claude/settings.json. Run by
# install.sh, not at launch - this writes the operator's own config, and the
# operator is who decides to install.
#
# $1 is the repo root, $2 the directory to move a displaced file into. Every
# change is printed as it happens, because it is someone's real config.
#
# Each guard is gated on the harness having declared it: a harness declares
# what it can host (see `guards` in its manifest), and registering something
# it did not declare would contradict the launch message that says so.
harness_register_guards() {
    local repo="$1" backup="$2" settings="$HOME/.claude/settings.json"

    mkdir -p "$HOME/.claude/hooks"

    _link_hook() {
        local name="$1" src="$repo/hooks/$1" dest="$HOME/.claude/hooks/$1"
        if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$src")" ]; then
            echo "Skipping: $name already linked to this repo's copy"
            return
        fi
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            mkdir -p "$backup"
            echo "Moving: existing ~/.claude/hooks/$name to $backup/$name"
            mv "$dest" "$backup/$name"
        fi
        echo "Linking: $name ($src -> $dest)"
        ln -s "$src" "$dest"
    }

    # Not a guard: this is R3, the briefing's delivery mechanism, and a
    # session without it does not know it is in a sandbox.
    _link_hook sandbox-context.sh
    harness_has_guard push-guard  && _link_hook git-push-guard.sh
    harness_has_guard merge-guard && _link_hook merge-guard.sh

    # Symlink from before the gitea-merge-guard.sh -> merge-guard.sh rename
    # points at a hooks/ path that no longer exists. Only remove it if it is
    # actually dangling, so an operator's own file at this name is left alone.
    local old_merge_guard="$HOME/.claude/hooks/gitea-merge-guard.sh"
    if [ -L "$old_merge_guard" ] && [ ! -e "$old_merge_guard" ]; then
        echo "Removing: dangling pre-rename symlink $old_merge_guard"
        rm -f "$old_merge_guard"
    fi

    # Linked so it exists at a stable path for the read-only ~/.claude/hooks
    # mount, but deliberately NOT registered below: bin/dejima registers it
    # per session, into a throwaway settings copy, and only when remote
    # access is configured. Registering it here would fire it for every
    # unsandboxed host session too, where it has no marker directory to
    # write to.
    harness_has_guard notify && _link_hook dejima-notify.sh

    # deny-dangerous-bash.sh is the one hook that is NOT sandbox-gated: it
    # has no DEJIMA check, so it applies to the operator's own host sessions
    # as well. That is deliberate, and it is why it may already be owned by
    # another install (dotfiles, say) - only claim it if nothing else
    # provides it, so this repo works standalone without clobbering an
    # existing setup.
    if harness_has_guard bash-deny; then
        local deny_dest="$HOME/.claude/hooks/deny-dangerous-bash.sh"
        if [ -e "$deny_dest" ] || [ -L "$deny_dest" ]; then
            echo "Skipping: deny-dangerous-bash.sh already present at $deny_dest (leaving it as-is)"
        else
            echo "Linking: deny-dangerous-bash.sh ($repo/hooks/deny-dangerous-bash.sh -> $deny_dest)"
            ln -s "$repo/hooks/deny-dangerous-bash.sh" "$deny_dest"
        fi
    fi
    echo

    if [ ! -f "$settings" ]; then
        echo "Creating $settings"
        echo '{}' > "$settings"
    fi

    # The registration that went with the symlink removed above. Two things
    # depend on it going: Claude Code reports a missing hook command on every
    # session start while it points at a path that no longer exists, and -
    # until the dedupe below stopped matching it - it also stood in for the
    # registration it was renamed from, so `_register merge-guard.sh` skipped
    # and the merge guard was registered nowhere at all. Dropped only when
    # the path it names is gone, so an operator's own file at that name keeps
    # its registration, matching the symlink check above.
    if [ ! -e "$old_merge_guard" ] && jq -e --arg s "/gitea-merge-guard.sh" \
        '[.hooks.PreToolUse[]?.hooks[]?.command // empty] | any(endswith($s))' \
        "$settings" >/dev/null 2>&1; then
        echo "Removing: stale pre-rename gitea-merge-guard.sh registration from $settings"
        local stale_tmp; stale_tmp=$(mktemp)
        jq --arg s "/gitea-merge-guard.sh" \
            '.hooks.PreToolUse = ((.hooks.PreToolUse // [])
                | map(.hooks = ((.hooks // []) | map(select((.command // "") | endswith($s) | not))))
                | map(select((.hooks | length) > 0)))' \
            "$settings" > "$stale_tmp" && mv "$stale_tmp" "$settings"
    fi

    _register() {
        local event="$1" matcher="$2" script_name="$3" description="$4"
        # endswith on the leading slash, not test(): test() is an unanchored
        # regex, so a hook whose name merely ends in another's - which is what
        # a rename like gitea-merge-guard.sh -> merge-guard.sh produces - read
        # as already registered, and the new hook was silently never added.
        if jq -e --arg s "/$script_name" \
            "[.hooks.${event}[]?.hooks[]?.command // empty] | any(endswith(\$s))" \
            "$settings" >/dev/null 2>&1; then
            echo "Skipping: $script_name already registered as a $event hook"
            return
        fi
        echo "Registering $script_name as a $event hook in $settings ($description)"
        local tmp
        tmp=$(mktemp)
        jq --arg matcher "$matcher" --arg cmd "\$HOME/.claude/hooks/$script_name" \
            ".hooks.${event} = ((.hooks.${event} // []) + [{\"matcher\": \$matcher, \"hooks\": [{\"type\": \"command\", \"command\": \$cmd}]}])" \
            "$settings" > "$tmp" && mv "$tmp" "$settings"
    }

    _register SessionStart "startup|resume|clear|compact" sandbox-context.sh \
        "injects sandbox context on session start"
    harness_has_guard push-guard && _register PreToolUse Bash git-push-guard.sh \
        "blocks pushes outside the allowed host(s)/branches"
    harness_has_guard merge-guard && _register PreToolUse Bash merge-guard.sh \
        "blocks the configured forge's merge command inside the sandbox"
    harness_has_guard bash-deny && _register PreToolUse Bash deny-dangerous-bash.sh \
        "blocks obviously destructive Bash commands"
    echo
    return 0
}

# What Claude Code causes to run on the HOST, unsandboxed.
#
# settings.json's statusLine.command names a script the host executes on
# every session, so a session that can write that file has a path onto the
# host that no container boundary sees. bin/dejima stages the file rather
# than mounting over it, because a :ro mount landing on a symlink - the
# common case - protects the target and leaves the link replaceable;
# detecting a change here is the compensating control for that.
#
# The namespace and leaf together form the id a baseline stores
# ("statusline:statusline.sh"), so neither may change while anyone has
# approvals recorded. The label is the fixed prefix `ack` strips to recover
# that id, which is why it lives here as a literal rather than in the
# manifest - see the host-exec notes in bin/dejima-harness-lib.sh.
harness_host_exec_surfaces() {
    local p
    p="$(harness_config_get statusline_path)"
    emit_host_exec statusline statusline.sh "$p" \
        "HOST-CODE-EXECUTION statusline.sh changed (runs UNSANDBOXED on the host via settings.json statusLine.command): "
}

# The operator's own Claude Code configuration, carried into the session.
#
# Three classes, and the difference is what a session may do to each:
#
#   read-write - state the session produces that has to outlive it. All
#     directories, which is what makes them safe: a directory bind mount
#     cannot detach the way a single-file one does, because a rename replaces
#     an entry *within* the mounted directory rather than the mount point
#     itself (#47, #48).
#   read-only - anything that RUNS. A session that could write these would be
#     installing a hook, skill or plugin for the next session on the host to
#     execute, which is the persistence dejima closes everywhere else.
#   read-only, scanned - the same, plus following symlinks out: an entry in
#     hooks/ or skills/ is routinely a link into a dotfiles checkout, and the
#     target has to be mounted for the link to resolve inside the container.
#     bin/dejima refuses a target overlapping a guarded store (#15).
#
# projects/ and file-history/ are deliberately absent: they are mounted an
# entry at a time by harness_state_mounts above, because the whole tree is
# every project's (#104).
harness_config_dirs() {
    local d
    for d in backups tasks plans sessions; do
        emit_config_dir "$HOME/.claude/$d"
    done
    emit_config_dir "$HOME/.claude/plugins" ro
    for d in hooks skills commands agents output-styles; do
        emit_config_dir "$HOME/.claude/$d" ro scan
    done
}

# Config carried in as copies rather than mounts - see the staged-config
# notes in bin/dejima-harness-lib.sh for why these three are not mounted at
# their real paths.
#
# statusline.sh is here as well as in harness_host_exec_surfaces above, and
# the two are the same file for opposite reasons: staging keeps a session
# from reaching the host's copy, and the audit catches a change to it made
# some other way.
harness_staged_config() {
    # Emitted whether or not the host has each one. Whether a file exists,
    # and what a dangling symlink means, are core's to decide - filtering
    # here would skip a dangling one silently, which is the case that must
    # refuse rather than quietly leave the session without the file.
    local f
    for f in settings.json CLAUDE.md statusline.sh; do
        emit_staged_config "$HOME/.claude/$f" ".claude/$f"
    done
}

# Compaction summaries out of this harness's transcripts.
#
# Claude Code writes line-delimited JSON, one record per line, with the
# summary carried on a record flagged isCompactSummary and the metadata about
# the compaction on a compact_boundary record immediately before it. python3
# rather than sed: the payload contains embedded newlines, and it is already
# a hard dependency (install.sh refuses without it).
#
# $1 is the directory of transcripts for one project, $2 where to write. The
# count written goes to stdout; bin/dejima-epitaph owns everything around
# this - the store, which slugs belong to the workspace, the 0700 directory,
# and clearing one that stayed empty.
#
# Keyed on the summary record's own uuid: `save` runs on every exit, and a
# session compacted three times has three epitaphs, two of which an earlier
# run already wrote. The name is the timestamp first so a directory listing
# reads as a timeline.
harness_extract_epitaphs() {
    local dir="$1" out="$2" f total=0 n
    for f in "$dir"/*.jsonl; do
        [ -f "$f" ] || continue
        n="$(python3 - "$f" "$out" "$DEJIMA_EPITAPH_NOTE" <<'PY'
import json, os, sys

path, out, note = sys.argv[1], sys.argv[2], sys.argv[3]
pending = None   # metadata from the compact_boundary that precedes a summary
written = 0

for line in open(path, errors="replace"):
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        rec = json.loads(line)
    except ValueError:
        continue

    if rec.get("subtype") == "compact_boundary":
        pending = rec.get("compactMetadata") or {}
        continue

    if not rec.get("isCompactSummary"):
        continue

    body = rec.get("message", {}).get("content")
    if isinstance(body, list):
        body = "\n".join(p.get("text", "") for p in body if isinstance(p, dict))
    if not isinstance(body, str) or not body.strip():
        pending = None
        continue

    uid = rec.get("uuid") or ""
    stamp = (rec.get("timestamp") or "").replace(":", "").replace("-", "")[:15]
    name = "%s-%s.md" % (stamp or "unknown", uid[:8] or "nouuid")
    dest = os.path.join(out, name)
    if os.path.exists(dest):
        pending = None
        continue

    meta = pending or {}
    head = [
        "# Epitaph",
        "",
        "- session: %s" % (rec.get("sessionId") or "unknown"),
        "- at: %s" % (rec.get("timestamp") or "unknown"),
        "- trigger: %s" % (meta.get("trigger") or "unknown"),
    ]
    if meta.get("preTokens") is not None:
        head.append("- tokens: %s before, %s after"
                    % (meta.get("preTokens"), meta.get("postTokens")))
    head += ["", note, "", "---", ""]
    tmp = dest + ".part"
    os.makedirs(out, exist_ok=True)
    with open(tmp, "w") as fh:
        fh.write("\n".join(head) + body.rstrip() + "\n")
    os.chmod(tmp, 0o600)
    os.rename(tmp, dest)
    written += 1
    pending = None

print(written)
PY
)" || n=0
        total=$((total + ${n:-0}))
    done
    printf '%s' "$total"
}

# Transcript lines in, conversation log lines out. Reads stdin, writes stdout.
#
# Ships prompts, assistant text, and tool *invocations* (name and input) -
# never tool outputs or thinking blocks, which dominate volume and were not
# asked for. `fromjson?` so a torn or garbage line is skipped rather than
# killing the stream. The session id stays inside the line rather than
# becoming a Loki label, because a per-session label would blow up
# cardinality.
harness_transform_transcript() {
    jq -Rc '
        def clip(n): if length > n then .[:n] + "...[truncated]" else . end;
        fromjson?
        | select(.isMeta != true)
        | .sessionId as $s
        | if .type == "user" then
            (.message.content
                | if type == "string" then .
                  else ([.[]? | select(.type == "text") | .text] | join("\n"))
                  end)
            | select(length > 0)
            | {session: $s, role: "user", text: clip(16000)}
          elif .type == "assistant" then
            (.message.content[]?
                | if .type == "text" then
                    {session: $s, role: "assistant", text: (.text | clip(16000))}
                  elif .type == "tool_use" then
                    {session: $s, role: "tool", tool: .name, input: (.input | tojson | clip(2000))}
                  else empty
                  end)
          else empty
          end
    ' 2>/dev/null
}
