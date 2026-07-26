#!/bin/bash
# Tails dns-proxy.sh's dnsmasq query log and ulogd2's NFLOG-derived JSON
# output, shipping them to Loki as raw log streams. Lets DNS lookups and
# firewall allow/reject decisions from inside the sandbox show up alongside
# the rest of the Grafana/Loki setup, labeled by job so they're easy to
# filter. No-op if LOKI_URL isn't set - logging is a bonus on top of the
# firewall/DNS-proxy enforcement, not required for either to work.
#
# Batches rather than pushing one line at a time: a burst of activity (e.g.
# npm install resolving/connecting to dozens of hosts in quick succession)
# would otherwise fire one HTTP request per line, which is both wasteful and
# a good way to get rate-limited/throttled by Loki.
set -uo pipefail  # not -e: one bad line or a Loki hiccup shouldn't kill the tailer

LOKI_URL="${LOKI_URL:-}"
# LOG_SHIPPER_LIB_ONLY=1 (test/static.bats) sources this file for its
# functions without starting any tailers - don't exit (which would kill
# the sourcing test shell) just because LOKI_URL isn't set there.
if [ -z "$LOKI_URL" ] && [ "${LOG_SHIPPER_LIB_ONLY:-0}" != "1" ]; then
    exit 0
fi

BATCH_MAX_LINES=20
BATCH_MAX_SECONDS=2

ship_stream() {
    local job="$1" file="$2"
    local -a batch=() batch_ts=()
    local last_flush now line

    flush() {
        [ "${#batch[@]}" -eq 0 ] && return
        local i raw=""
        for i in "${!batch[@]}"; do
            raw+="${batch_ts[$i]}"$'\t'"${batch[$i]}"$'\n'
        done
        local values payload
        values=$(printf '%s' "$raw" | jq -R -s '
            split("\n") | map(select(length > 0))
            | map(split("\t") | [.[0], (.[1:] | join("\t"))])
        ')
        payload=$(jq -n --arg job "$job" --argjson values "$values" \
            '{streams: [{stream: {job: $job, source: "claude-sandbox"}, values: $values}]}')
        curl -s -o /dev/null --max-time 5 -H "Content-Type: application/json" \
            -XPOST "$LOKI_URL/loki/api/v1/push" -d "$payload" || true
        batch=()
        batch_ts=()
        last_flush=$(date +%s)
    }

    last_flush=$(date +%s)
    tail -F -n0 "$file" 2>/dev/null | while true; do
        if IFS= read -r -t "$BATCH_MAX_SECONDS" line; then
            batch+=("$line")
            batch_ts+=("$(date +%s%N)")
        fi
        now=$(date +%s)
        if [ "${#batch[@]}" -ge "$BATCH_MAX_LINES" ] || [ $((now - last_flush)) -ge "$BATCH_MAX_SECONDS" ]; then
            flush
        fi
    done
}

# Claude Code transcript JSONL -> compact conversation log lines. Ships
# prompts, assistant text, and tool *invocations* (name + input) - never
# tool outputs or thinking blocks, which dominate volume and weren't asked
# for. jq -R + fromjson? so a torn/garbage line is skipped instead of
# killing the whole stream. Session ID stays inside the line rather than
# becoming a Loki label (per-session labels would blow up cardinality).
transform_transcript_line() {
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

# Polls this workspace's transcript files and feeds new content through the
# transform into a local spool file (shipped by ship_stream below). Polling
# with per-file byte offsets rather than tail -F: session files appear
# dynamically (new sessions, /clear, subagents), and inotify tooling isn't
# installed. Matching on the workspace's project-key prefix (cwd with
# non-alphanumerics mapped to "-", same scheme Claude Code uses) also
# catches worktrees under the workspace and subagent transcripts, while
# excluding concurrent *host* sessions in other projects that share the
# mounted ~/.claude.
watch_transcripts() {
    local LC_ALL=C  # byte-accurate ${#...} for the offset arithmetic below
    local dir="$SANDBOX_HOME/.claude/projects"
    local out=/var/log/claude-conversation.log
    local key f size cur chunk complete
    key=$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9-]/-/g')
    touch "$out"
    declare -A offset
    while true; do
        for f in "$dir/$key"/*.jsonl "$dir/$key-"*/*.jsonl; do
            [ -f "$f" ] || continue
            size=$(stat -c %s "$f" 2>/dev/null) || continue
            cur=${offset[$f]:-0}
            if [ "$size" -gt "$cur" ]; then
                # trailing printf x / strip-x preserves the chunk's final
                # newline through command substitution (which eats it)
                chunk=$(tail -c +$((cur + 1)) "$f" | head -c $((size - cur)); printf x)
                chunk=${chunk%x}
                # Only consume whole lines - a line still mid-write gets
                # picked up complete on a later pass instead of being torn.
                complete=${chunk%"${chunk##*$'\n'}"}
                if [ -n "$complete" ]; then
                    printf '%s' "$complete" | transform_transcript_line >> "$out"
                    offset[$f]=$((cur + ${#complete}))
                fi
            fi
        done
        sleep 3
    done
}

if [ "${LOG_SHIPPER_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

ship_stream "claude-sandbox-dns" /var/log/dnsmasq.log &
ship_stream "claude-sandbox-net" /var/log/ulogd.json &

# Conversation shipping is opt-in on top of LOKI_URL: prompts/responses/
# tool commands are session *content*, a different sensitivity class than
# DNS names and firewall verdicts.
if [ "${SANDBOX_LOG_CONVERSATION:-0}" = "1" ]; then
    watch_transcripts &
    ship_stream "claude-sandbox-conversation" /var/log/claude-conversation.log &
fi

wait
