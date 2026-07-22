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
if [ -z "$LOKI_URL" ]; then
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

ship_stream "claude-sandbox-dns" /var/log/dnsmasq.log &
ship_stream "claude-sandbox-net" /var/log/ulogd.json &

wait
