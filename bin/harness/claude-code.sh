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

# Registers the `done` notification handler into dejima's settings layer, in
# the shape Claude Code reads them.
#
# Stop only, though the hook and the host-side watcher both understand
# `waiting` as well. Claude Code raises Notification when it needs permission
# to run something and when the prompt has sat idle, and a dejima session runs
# with permission prompts off - so the first never happens, and what is left
# is a timer that expires shortly after the Stop it follows. Registering both
# put two pushes on the operator's phone for one event, a minute apart, the
# second saying nothing the first had not. `waiting` stays in the enum for a
# harness that can say it without having stopped first.
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
# Where dejima's own hooks live inside the container. Baked into the image
# (see docker/Dockerfile) rather than reached through the ~/.claude/hooks
# mount, because that mount is the operator's configuration and dejima should
# not have to write to it to make its own sandbox work.
DEJIMA_HOOK_DIR=/usr/local/lib/dejima/hooks

harness_register_notify() {
    local settings="$1" tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/dejima-settings-remote.XXXXXX.json")"
    if jq '.hooks.Stop = ((.hooks.Stop // []) + [{"matcher": "", "hooks": [{"type": "command", "command": "'"$DEJIMA_HOOK_DIR"'/dejima-notify.sh done"}]}])' \
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

    # Each installed plugin version, read-only. Here rather than in a hook of
    # its own because this is the hook core calls to collect mounts, and the
    # plugin tree is state this harness keeps on the host like the two above.
    _plugin_version_mounts
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
    local repo="$1" settings="$HOME/.claude/settings.json"

    # Registers nothing. Every hook dejima uses is baked into the image and
    # registered per launch into the sandbox's own --settings overlay, so
    # installing dejima writes nothing to the operator's Claude Code config.
    #
    # What is left is taking back what older versions of this function put
    # there. The hook is kept rather than deleted because "what a harness
    # needs on the host" is a real question a future one may answer
    # differently; for Claude Code the answer is now nothing.

    # Symlink from before the gitea-merge-guard.sh -> merge-guard.sh rename
    # points at a hooks/ path that no longer exists. Only remove it if it is
    # actually dangling, so an operator's own file at this name is left alone.
    local old_merge_guard="$HOME/.claude/hooks/gitea-merge-guard.sh"
    if [ -L "$old_merge_guard" ] && [ ! -e "$old_merge_guard" ]; then
        echo "Removing: dangling pre-rename symlink $old_merge_guard"
        rm -f "$old_merge_guard"
    fi



    # No settings.json is created here either: a file dejima writes nothing
    # into is a file it has no business bringing into existence.
    [ -f "$settings" ] || return 0

    # The registration that went with the symlink removed above. Two things
    # depend on it going: Claude Code reports a missing hook command on every
    # session start while it points at a path that no longer exists, and -
    # until the dedupe below stopped matching it - it also stood in for the
    # registration it was renamed from, so the merge guard's own registration
    # was skipped and it was registered nowhere at all. Dropped only when
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

    # An upgrade has to take back what an older install.sh put here, or the
    # claim above is only true of a fresh one. Removed by name and only when
    # the symlink points into THIS repo: an operator's own file at one of
    # these names is theirs.
    local moved dest
    for moved in sandbox-context.sh git-push-guard.sh merge-guard.sh dejima-notify.sh \
                 deny-dangerous-bash.sh; do
        dest="$HOME/.claude/hooks/$moved"
        if [ -L "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$repo/hooks/$moved")" ]; then
            echo "Removing: $moved from ~/.claude/hooks (the sandbox registers its own now)"
            rm -f "$dest"
        fi
        # And its registration, matched the same endswith way _register does.
        local ev
        for ev in SessionStart PreToolUse Stop; do
            if jq -e --arg s "/$moved" \
                "[.hooks.${ev}[]?.hooks[]?.command // empty] | any(endswith(\$s))" \
                "$settings" >/dev/null 2>&1; then
                echo "Removing: $moved's $ev registration from $settings"
                local mv_tmp; mv_tmp=$(mktemp)
                jq --arg s "/$moved" \
                    ".hooks.${ev} = ((.hooks.${ev} // [])
                        | map(.hooks = ((.hooks // []) | map(select((.command // \"\") | endswith(\$s) | not))))
                        | map(select((.hooks | length) > 0)))" \
                    "$settings" > "$mv_tmp" && mv "$mv_tmp" "$settings"
            fi
        done
    done
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
    # plugins/ is deliberately absent, and used to be here read-only. See
    # harness_seed below: the tree is partly the operator's install and partly
    # Claude Code's own bookkeeping, and mounting all of it read-only stopped
    # the bookkeeping without protecting anything.
    for d in hooks skills commands agents output-styles; do
        emit_config_dir "$HOME/.claude/$d" ro scan
    done
}

# The plugin tree: which parts of it the session may write, and why the answer
# is not "none".
#
# ~/.claude/plugins was mounted read-only, with the rest of the config
# directories that hold something executable. That was the wrong shape, and
# the symptom was a plugin that would not load. The tree is two things at
# once:
#
#   marketplaces/<name>/       the catalogue checkout, and the plugin sources
#   cache/<name>/<plugin>/<v>/ each installed version, materialised
#   installed_plugins.json     what is installed, and at which version
#   known_marketplaces.json    where those came from
#   plugin-catalog-cache.json  the catalogue, resolved
#
# Claude Code updates a plugin by materialising the new version alongside the
# old, at cache/<marketplace>/<plugin>/<newversion>/, and then rewriting the
# registry. Read-only, it can do neither: the update fails and the plugin is
# left at a version the catalogue no longer matches, which is what "the plugin
# does not load" turns out to mean. The only way out was to run Claude Code on
# the host and restart the container.
#
# Mounting it read-only protected nothing, either. The concern for hooks/ and
# skills/ is that a session writing them installs something the HOST will
# execute next time. A copy has no such path: the session writes its own copy,
# which goes away with the container.
#
# So: everything the harness rewrites is seeded as a writable copy, and only
# the version directories - the bulk, and already-materialised code - stay
# read-only mounts of the host's. That keeps the 400-odd megabytes of an
# installed MCP server out of a per-launch copy while leaving the session able
# to add a version beside them.
harness_seed() {
    local plugins="$HOME/.claude/plugins" f mkt plug ver

    # Small, and all of it rewritten in place by Claude Code.
    for f in installed_plugins.json known_marketplaces.json \
             plugin-catalog-cache.json .last_inuse_sweep; do
        emit_seed_from "$plugins/$f" ".claude/plugins/$f"
    done
    # The catalogue checkout and per-plugin data. Copied rather than mounted
    # so a refresh in-session works; a few megabytes, against a mount that
    # would make the refresh fail.
    emit_seed_from "$plugins/marketplaces" ".claude/plugins/marketplaces"
    emit_seed_from "$plugins/data" ".claude/plugins/data"

    # The levels above an installed version, created empty and owned by the
    # session. Docker makes a bind mount's missing parents root-owned, so
    # without these the session could read every mounted version and write no
    # new one beside them - which is the failure this whole hook is about.
    emit_seed_dir ".claude/plugins/cache"
    [ -d "$plugins/cache" ] || return 0
    for mkt in "$plugins/cache"/*/; do
        [ -d "$mkt" ] || continue
        emit_seed_dir ".claude/plugins/cache/$(basename "$mkt")"
        for plug in "$mkt"*/; do
            [ -d "$plug" ] || continue
            emit_seed_dir ".claude/plugins/cache/$(basename "$mkt")/$(basename "$plug")"
        done
    done
}

# Each installed plugin version, mounted read-only at its own path.
#
# The bulk of the tree by far - one MCP server's node_modules is most of it -
# and none of it is rewritten: an update writes a NEW version directory rather
# than changing an existing one, which is what makes mounting these safe and
# copying them wasteful. harness_seed above owns the writable levels between
# them.
_plugin_version_mounts() {
    local plugins="$HOME/.claude/plugins" mkt plug ver
    [ -d "$plugins/cache" ] || return 0
    for mkt in "$plugins/cache"/*/; do
        [ -d "$mkt" ] || continue
        for plug in "$mkt"*/; do
            [ -d "$plug" ] || continue
            for ver in "$plug"*/; do
                [ -d "$ver" ] || continue
                emit_mount "${ver%/}" ro
            done
        done
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
# The two config files the sandbox needs to exist, the one condition that
# makes a session start wrong, and the override layer - all Claude Code's
# shape, none of it core's business.
#
# $1 is where to write the override. dejima owns the file: it is a throwaway
# the session cannot reach, mounted at a container-local path. Returning
# nonzero stops the launch.
harness_prepare_config() {
    local overlay="$1" settings="$HOME/.claude/settings.json" settings_error


    # Nothing is created on the host. A settings.json or CLAUDE.md the
    # operator does not have is not one dejima should make on their machine so
    # that it has something to copy - harness_staged_config asks for an empty
    # one in the CONTAINER instead, which is where it is needed.

    # Claude Code ignores a settings.json it cannot parse, wholesale and with
    # only a startup warning, so a stray edit on the host costs the sandbox
    # every permission, hook and plugin the operator configured - including
    # skipDangerousModePermissionPrompt, which is why the first visible
    # symptom is an unexpected bypass-mode warning rather than anything
    # mentioning settings. The file is staged verbatim, so nothing else parses
    # it before the session reads it - check here, where the fix is at hand.
    # Absent is not unparseable: there is simply nothing to stage.
    if [ -f "$settings" ] && ! settings_error="$(jq . "$settings" 2>&1 >/dev/null)"; then
        echo "$settings is not valid JSON:" >&2
        echo "  $settings_error" >&2
        echo "Claude Code would ignore it entirely and the sandbox would start with" >&2
        echo "none of your settings. Fix it, then retry." >&2
        return 1
    fi

    # Claude Code's own per-command sandboxing is redundant here and cannot
    # work anyway - bwrap can't create a namespace without privileges that
    # would undo this container's hardening - and a session can't be trusted
    # to turn it off itself. The override reaches Claude Code as an extra
    # --settings layer (the manifest's settings_args) above
    # ~/.claude/settings.json, which holds only what the sandbox overrides;
    # the operator's hooks, permissions and plugins still apply from there.
    #
    # And dejima's own hooks, registered HERE rather than in the operator's
    # ~/.claude/settings.json. Claude Code merges this layer with theirs, so
    # their hooks still run - proven by the one dejima deliberately leaves on
    # the host, deny-dangerous-bash.sh, which fires inside a container while
    # being registered only there.
    #
    # Registering them here is what lets install.sh stop writing to a config
    # that is not dejima's. The scripts are baked into the image, so a session
    # cannot unlink a guard the way it could one staged into a directory it
    # owns.
    jq -n '{sandbox: {enabled: false}}' > "$overlay"
    _register_overlay_hook() {  # <event> <matcher> <script>
        local event="$1" matcher="$2" script="$3" tmp
        tmp="$(mktemp "${TMPDIR:-/tmp}/dejima-overlay.XXXXXX.json")" || return 1
        if jq --arg m "$matcher" --arg c "$DEJIMA_HOOK_DIR/$script" \
            ".hooks.${event} = ((.hooks.${event} // []) +
                [{\"matcher\": \$m, \"hooks\": [{\"type\": \"command\", \"command\": \$c}]}])" \
            "$overlay" > "$tmp"; then
            mv "$tmp" "$overlay"
        else
            rm -f "$tmp"
            echo "warning: could not register $script; it will not run this session." >&2
        fi
    }
    # R3: without this a session is not told it is in a sandbox at all, which
    # is why it is registered whether or not any guard is declared.
    _register_overlay_hook SessionStart "startup|resume|clear|compact" sandbox-context.sh
    harness_has_guard push-guard  && _register_overlay_hook PreToolUse Bash git-push-guard.sh
    harness_has_guard merge-guard && _register_overlay_hook PreToolUse Bash merge-guard.sh
    harness_has_guard bash-deny   && _register_overlay_hook PreToolUse Bash deny-dangerous-bash.sh
    return 0
}

harness_staged_config() {
    # Emitted whether or not the host has each one. Whether a file exists,
    # and what a dangling symlink means, are core's to decide - filtering
    # here would skip a dangling one silently, which is the case that must
    # refuse rather than quietly leave the session without the file.
    # settings.json and CLAUDE.md are asked to exist even when the host has
    # none: Claude Code reads both, and an empty one reads the same as a file
    # the operator never made. statusline.sh is not - an empty one would be
    # installed executable and run as the status line.
    emit_staged_config "$HOME/.claude/settings.json" ".claude/settings.json" ensure-json
    emit_staged_config "$HOME/.claude/CLAUDE.md" ".claude/CLAUDE.md" ensure
    emit_staged_config "$HOME/.claude/statusline.sh" ".claude/statusline.sh"
}

# Where this workspace's transcripts are, and which store key each belongs
# under. One "<key>\t<path>" line per file.
#
# This is the layout knowledge that used to sit in bin/dejima-epitaph and
# bin/dejima-conversation-ship directly: the `projects_dir` key name, the
# <dir>/<slug>/ nesting and the .jsonl extension are all Claude Code's, and a
# second harness keys its transcripts nothing like this. What those two tools
# keep is what is dejima's - the store, the batching, the Loki push, and the
# rule that a key must be a slug this workspace actually owns.
#
# Through dejima-slug-lib, never by matching a slug prefix: slugs cannot
# distinguish a worktree under this workspace from a SIBLING project whose
# directory name merely extends its own, so a "<slug>-*" glob would reach the
# neighbour's transcripts too (#105). Every project's directory is present in
# projects/, so nothing else would catch it.
harness_transcript_files() {
    local ws="$1" projects slug f
    projects="$(harness_config_get projects_dir)"
    [ -n "$projects" ] || return 0
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        for f in "$projects/$slug"/*.jsonl; do
            [ -f "$f" ] || continue
            printf '%s\t%s\n' "$slug" "$f"
        done
    done < <(workspace_slugs_sorted "$ws")
}

# Which sessions still have a transcript on disk, as "<key>\t<session-id>"
# lines. `dejima-epitaph list` matches an epitaph's own session id against
# this to say whether resuming the real session is still on offer, and it has
# no way to work that out for itself: the id is in the filename here and is
# the directory name for the next harness.
#
# $1 is a workspace, or absent for every key this harness holds transcripts
# under - which is what `list --all` needs, since a store key is a slug and a
# slug does not resolve back to a path.
harness_live_sessions() {
    local ws="${1:-}" projects key f d
    projects="$(harness_config_get projects_dir)"
    [ -n "$projects" ] || return 0
    if [ -n "$ws" ]; then
        while IFS=$'\t' read -r key f; do
            [ -n "$f" ] || continue
            printf '%s\t%s\n' "$key" "$(basename "$f" .jsonl)"
        done < <(harness_transcript_files "$ws")
        return 0
    fi
    for d in "$projects"/*/; do
        [ -d "$d" ] || continue
        key="$(basename "$d")"
        for f in "$d"/*.jsonl; do
            [ -f "$f" ] || continue
            printf '%s\t%s\n' "$key" "$(basename "$f" .jsonl)"
        done
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
# $1 is ONE transcript file, $2 where to write. The count written goes to
# stdout; bin/dejima-epitaph owns everything around this - the store, which
# slugs belong to the workspace, the 0700 directory, and clearing one that
# stayed empty. It owns the iteration too, because which files exist is
# harness_transcript_files' answer above rather than a directory shape this
# could glob.
#
# Keyed on the summary record's own uuid: `save` runs on every exit, and a
# session compacted three times has three epitaphs, two of which an earlier
# run already wrote. The name is the timestamp first so a directory listing
# reads as a timeline.
harness_extract_epitaphs() {
    local f="$1" out="$2"
    [ -f "$f" ] || { printf '0'; return 0; }
    python3 - "$f" "$out" "$DEJIMA_EPITAPH_NOTE" <<'PY'
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

# harness_guards_registered is deliberately not defined.
#
# It read the operator's own ~/.claude/settings.json and named any of dejima's
# hooks missing from it, because that is where install.sh used to put them and
# "install.sh never run with a harness set" was a real way to get a session
# with no briefing and no guards.
#
# Nothing is written there now: the hooks are baked into the image and
# registered per launch into dejima's own --settings overlay, so an absent
# registration in the operator's file is the correct state rather than a
# broken one. Left defined, it named all four as not in force on every launch
# of a host that had never run the old installer - and told the operator to
# run ./install.sh, which strips exactly those registrations, making the
# message permanent.
#
# There is nothing to put in its place. What the overlay carries is composed
# fresh each launch from the manifest, so reading it back would be asking
# dejima whether it did what it just did; which guards the harness cannot host
# at all is the manifest's, and harness_report_guards already says it.
#
# The hook itself stays in the plugin interface. What a harness needs wired on
# the host is a real question, and a future one may answer it differently.
