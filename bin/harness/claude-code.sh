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
