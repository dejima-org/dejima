# Harness plugin: Cline.
#
# Sourced by bin/dejima through harness_plugin_load when [core] harness names
# this harness. Part of the trusted computing base - see the interface notes
# in bin/dejima-harness-lib.sh for why plugins live here and why they are
# sourced rather than invoked.
#
# Smaller than Claude Code's, and the shape of what is missing is the point:
# Cline registers no hook that can refuse a tool call, so there are no guards
# to install and nothing to check for having been installed. What is left is
# the two things a harness has to get right - where its state goes, and what
# credential it runs on - plus the fact that both of those are one directory
# here rather than a tree keyed by project.

# This workspace's Cline state directory on the host.
#
# One directory per workspace slug, the way epitaph.dir and audit.dir already
# work, and not a slice of the operator's own ~/.cline/data. That is forced by
# how Cline keys its state: sessions live at <data>/sessions/<session-id>/ with
# one sessions.db indexing all of them, and the project a session belonged to
# is a field inside the record rather than a directory above it. There is no
# per-project subtree to mount, so mounting the operator's data directory would
# put every project's transcripts in every session - which is #104 exactly.
# Giving each workspace its own data directory is what closes it, and it is why
# R4 is the requirement Cline clears most cleanly rather than least.
_cline_state_dir() {
    local root
    root="$(harness_config_get state_dir)"
    [ -n "$root" ] || return 1
    printf '%s/%s' "$root" "$(ws_slug "$1")"
}

# The same path, for the resume command in this harness's briefing fragment.
# The briefing needs it because a session resumed on the host will not find
# itself in ~/.cline/data, and no static template could name it: it depends on
# the workspace.
harness_briefing_state_dir() {
    _cline_state_dir "$1" 2>/dev/null || true
}

# Which endpoints a session may be pointed at, and why the answer is not "any".
#
# Absent base_url means Anthropic: Cline is configured with the real hostname
# and a placeholder key, and dejima's in-container terminator and host-side
# proxy supply the real credential, exactly as they do for Claude Code. The
# credential never enters the container.
#
# A base_url means a self-hosted endpoint, and it has to be one reachable
# without a credential - the Docker host, or something on the sandbox's own
# network. That restriction is R5 and not a network one: a hosted provider
# would need an API key inside the container, and dejima has no proxy that
# could hold one back on its behalf. An endpoint that needs no key has nothing
# to withhold, which is why an open-weight model served locally is supported
# today and api.openai.com is not.
#
# Two ways an endpoint qualifies, and neither is about the URL's syntax.
#
# A literal loopback or RFC 1918 address is host-local by construction. The
# octets are compared as numbers rather than matched as text - `10.*` would
# accept the hostname 10.example.com as readily as the network - and a dotted
# quad is never written into this file, because that is how an operator's real
# LAN address leaks into a public repo.
#
# A NAME qualifies when the operator has already allowlisted it, through
# `dejima-allow --project` or `--global`. That is the same set that decides
# what the container can reach at all, so an endpoint failing this check is
# one the session could not have connected to anyway. Requiring a literal
# address instead was too strict by half: a model server on someone's own
# network normally has a name, and refusing it made the local-endpoint path -
# the reason this harness is provider-agnostic at all - unusable for the
# ordinary case.
#
# What neither branch is doing is protecting the model credential. dejima
# writes a placeholder into providers.json on this path whatever the endpoint
# is, so no real credential enters the container either way. What this decides
# is whether the configuration can WORK: an endpoint that needs a key would
# get the placeholder and fail, and saying so at launch beats an auth error
# three layers down. Pointing it somewhere is the operator's call, bounded by
# an allowlist entry they made deliberately.
_cline_host_local() {
    local url="$1" host a b
    host="${url#*://}"
    host="${host%%/*}"
    host="${host%%\?*}"
    host="${host##*@}"
    # Strip a :port, but not the colons of a bracketed IPv6 literal.
    case "$host" in
        \[*\]*) host="${host%%\]*}"; host="${host#\[}" ;;
        *:*)    host="${host%:*}" ;;
    esac
    case "$host" in
        localhost|::1) return 0 ;;
    esac
    # Four numeric octets means an address; anything else is a name, and is
    # decided by the allowlist below rather than refused here.
    local -a oct=()
    local numeric=1 o
    IFS=. read -ra oct <<< "$host"
    for o in "${oct[@]}"; do
        case "$o" in ''|*[!0-9]*) numeric=0; break ;; esac
        [ "$o" -le 255 ] || { numeric=0; break; }
    done
    if [ "${#oct[@]}" -eq 4 ] && [ "$numeric" -eq 1 ]; then
        a="${oct[0]}" b="${oct[1]}"
        # Loopback, and the three private ranges. The last of these is where
        # Docker's own bridge gateway sits, which is how a container reaches a
        # model server running on the host.
        [ "$a" -eq 127 ] && return 0
        [ "$a" -eq 10 ] && return 0
        { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; } && return 0
        { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } && return 0
        return 1
    fi
    _cline_host_allowlisted "$host"
}

# Whether the operator has allowlisted this name, project or global. Read
# through approved_entries so it is the same store, the same validator and the
# same answer bin/dejima uses when it builds the container's allowlist - a
# second reader of that file would be a second thing to keep in step.
_cline_host_allowlisted() {
    local host="$1" store entry
    for store in "$(config_root)" "${PROJECT_STORE:-}"; do
        [ -n "$store" ] || continue
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            [ "$entry" = "$host" ] && return 0
        done < <(approved_entries "$store" allowed-domains 2>/dev/null)
    done
    return 1
}

# The provider configuration the session runs with, and the three conditions
# that make a launch wrong: no model, a credential mode with no path through,
# and an endpoint whose key dejima would have to put in the container.
#
# $1 is the override file core owns for harnesses that take one on the command
# line. Cline does not - it reads a JSON file at a fixed place inside its data
# directory - so that argument is unused here and the file is written into the
# state directory instead, before it is mounted. Returning nonzero stops the
# launch.
#
# Rewritten every launch on purpose. A session can edit this file (it is inside
# a read-write mount, and Cline rewrites it itself on its own schedule anyway),
# so it is not a control while a session is running - the firewall is what
# bounds where a repointed endpoint could reach. What rewriting buys is that a
# repointing cannot persist into the next session.
harness_prepare_config() {
    local state model base_url settings
    state="$(_cline_state_dir "$WORKSPACE_DIR")" || {
        echo "harness.cline: state_dir is not set, so there is nowhere to keep" >&2
        echo "this project's Cline state. Set it in [harness.cline]." >&2
        return 1
    }

    model="$(harness_config_get model)"
    if [ -z "$model" ]; then
        echo "harness.cline: no model is configured." >&2
        echo "Cline has no default worth dejima choosing for you, and any id" >&2
        echo "shipped here would go stale with the next Cline release. Set one:" >&2
        echo "" >&2
        echo "  [harness.cline]" >&2
        echo "  model = claude-haiku-4-5-20251001" >&2
        echo "" >&2
        echo "\`cline auth\` outside the sandbox lists what your provider offers." >&2
        return 1
    fi

    base_url="$(harness_config_get base_url)"

    # The Anthropic path is the credential proxy's path, and it only works in
    # the shape that was actually tested: the proxy on, terminating TLS for
    # api.anthropic.com in-container, with Cline configured for the real
    # hostname and a placeholder key.
    #
    # With the proxy off, Claude Code mounts the operator's real credential -
    # a downgrade this repository documents and accepts. There is no
    # equivalent here: the credential Cline would need is in the operator's
    # own providers.json, which is exactly the file dejima declines to mount,
    # and writing a placeholder anyway would produce an auth failure whose
    # cause is three layers away. The loopback transport is the same story
    # from the other end - it hands the harness a base URL and a token through
    # the environment, which Cline does not read for provider selection
    # (CLINE_PROVIDER and CLINE_MODEL were tried and ignored).
    #
    # Both refuse rather than start something that will fail confusingly, and
    # both have the same way out: point base_url at a model you serve.
    if [ -z "$base_url" ]; then
        local why=""
        [ "$(config_get_bool credentials proxy)" = "1" ] \
            || why="[credentials] proxy is off"
        [ -n "$why" ] || [ "$(config_get credentials transport)" = "tls" ] \
            || why="[credentials] transport is loopback"
        if [ -n "$why" ]; then
            echo "harness.cline: $why, and cline has no way to reach Anthropic" >&2
            echo "without the TLS terminator the proxy puts in front of it." >&2
            echo "Its credential lives in the providers.json dejima declines to" >&2
            echo "mount, so there is nothing to fall back to - unlike claude-code," >&2
            echo "which mounts the real credential in that mode." >&2
            echo "" >&2
            echo "Either turn the proxy back on with the default tls transport," >&2
            echo "or set [harness.cline] base_url to a model you serve yourself." >&2
            return 1
        fi
    fi

    if [ -n "$base_url" ] && ! _cline_host_local "$base_url"; then
        echo "harness.cline: refusing base_url $base_url." >&2
        echo "It is not a host-local endpoint, so it would need an API key" >&2
        echo "inside the container, and dejima has no proxy that can hold one" >&2
        echo "back for that provider - the model credential would stop being" >&2
        echo "something the sandbox never sees." >&2
        echo "" >&2
        echo "Supported today: leave base_url unset for Anthropic through" >&2
        echo "dejima's own credential proxy, or point it at a model you serve" >&2
        echo "yourself, which needs no key. That means a loopback or RFC 1918" >&2
        echo "address, or a host you have allowlisted:" >&2
        echo "" >&2
        echo "  bin/dejima-allow --project <path> <host>" >&2
        echo "" >&2
        echo "The allowlist is what decides whether the container can reach it" >&2
        echo "at all, so an endpoint that fails this check is one the session" >&2
        echo "could not have connected to anyway." >&2
        return 1
    fi

    settings="$state/settings"
    mkdir -p "$settings" || return 1
    # 0700: the placeholder is not a secret, but this directory is where a real
    # one would land if anything ever wrote one here by mistake.
    chmod 700 "$state" 2>/dev/null || true

    local tmp
    tmp="$(mktemp "$settings/.providers.XXXXXX")" || return 1
    if [ -n "$base_url" ]; then
        jq -n --arg m "$model" --arg u "$base_url" \
            '{version: 1, lastUsedProvider: "openai-compatible", modes: {},
              providers: {"openai-compatible": {
                settings: {provider: "openai-compatible", model: $m,
                           baseUrl: $u, apiKey: "dejima-no-credential-needed"},
                tokenSource: "manual"}}}' > "$tmp"
    else
        # The placeholder is what Cline sends; the host-side proxy replaces it
        # with the real credential on the way out. Same arrangement as Claude
        # Code's faked .credentials.json, confirmed end to end against the API.
        jq -n --arg m "$model" \
            '{version: 1, lastUsedProvider: "anthropic", modes: {},
              providers: {anthropic: {
                settings: {provider: "anthropic", model: $m,
                           apiKey: "sandbox-credential-proxy-placeholder"},
                tokenSource: "manual"}}}' > "$tmp"
    fi || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv "$tmp" "$settings/providers.json"
}

# The per-project state this harness keeps on the host.
#
# Mounted at Cline's own default location rather than at its host path, so
# nothing inside the container has to be told where its state is - the source
# is keyed by dejima's workspace slug and only the target follows the harness,
# which is what emit_mount_at is for.
harness_state_mounts() {
    local dir
    dir="$(_cline_state_dir "$1")" || return 0
    mkdir -p "$dir" || return 0
    emit_mount_at "$dir" "$HOME/.cline/data"
}

# Where this workspace's transcripts are, and which store key each belongs
# under. One "<key>\t<path>" line per file.
#
# Nothing like Claude Code's layout, which is the point of the hook. There is
# no slug nesting to walk here: the data directory is already this workspace's
# (see _cline_state_dir above), so the key is simply that workspace's own slug
# and every session under it belongs to this project by construction. The
# files are <data>/sessions/<session-id>/<session-id>.messages.json - one JSON
# document per session, keyed by an id Cline mints at run time.
#
# The .messages.json sibling rather than the <id>.json beside it: the latter is
# session metadata (pid, exit code, model), the former is the conversation.
harness_transcript_files() {
    local ws="$1" dir key f
    dir="$(_cline_state_dir "$ws")" || return 0
    key="$(ws_slug "$ws")"
    for f in "$dir"/sessions/*/*.messages.json; do
        [ -f "$f" ] || continue
        printf '%s\t%s\n' "$key" "$f"
    done
}

# Transcript in, conversation log lines out. Reads stdin, writes stdout.
#
# Ships prompts, assistant text, and tool *invocations* (name and input) -
# never tool results or the system prompt. Same policy as Claude Code's, and
# the content blocks turn out to be the same shape too (`text`, `tool_use`
# with id/name/input, `tool_result`), so this differs from that one only in
# the envelope: one JSON object with a `messages` array, rather than a line
# per record.
#
# That envelope is why the manifest says `transcript_update = rewrite`. Cline
# replaces the whole file each time it writes, so there are no complete lines
# to consume incrementally and a byte offset into it would land mid-document.
#
# A user message arrives wrapped by Cline as <user_input mode="act">...</...>.
# It is left exactly as written: the wrapper is what the model was actually
# sent, and unwrapping it here would make the log disagree with the session.
harness_transform_transcript() {
    jq -c '
        def clip(n): if length > n then .[:n] + "...[truncated]" else . end;
        .sessionId as $s
        | .messages[]?
        | .role as $r
        | .content
        | if type == "array" then .[] else {type: "text", text: (. | tostring)} end
        | if .type == "text" then
            (.text // "")
            | select(length > 0)
            | {session: $s, role: $r, text: clip(16000)}
          elif .type == "tool_use" then
            {session: $s, role: "tool", tool: .name, input: (.input | tojson | clip(2000))}
          else empty
          end
    ' 2>/dev/null
}
