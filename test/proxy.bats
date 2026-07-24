#!/usr/bin/env bats
# Host-side (no Docker): the credential-injecting proxy must strip the
# container's placeholder token, inject the real one, stream SSE unbuffered,
# and (see the refresh tests added later) own OAuth refresh + write-back.

PLACEHOLDER="sandbox-credential-proxy-placeholder"

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    PROXY="$REPO_ROOT/bin/claude-sandbox-anthropic-proxy"
    TD="$(mktemp -d)"
    SOCK="$TD/proxy.sock"
    CREDS="$TD/credentials.json"
    python3 "$BATS_TEST_DIRNAME/fixtures/fake-anthropic.py" > "$TD/port" &
    FAKE_PID=$!
    for _ in $(seq 1 50); do [ -s "$TD/port" ] && break; sleep 0.1; done
    [ -s "$TD/port" ]
    PORT="$(cat "$TD/port")"
    write_creds 7200
}

# write_creds <seconds-until-access-token-expiry>
write_creds() {
    cat > "$CREDS" <<EOF
{"claudeAiOauth":{"accessToken":"real-access-token","refreshToken":"real-refresh-token","expiresAt":$((($(date +%s) + $1) * 1000)),"refreshTokenExpiresAt":$((($(date +%s) + 86400) * 1000)),"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default"}}
EOF
    chmod 600 "$CREDS"
}

start_proxy() {
    "$PROXY" --socket "$SOCK" --credentials "$CREDS" \
        --upstream "http://127.0.0.1:$PORT" \
        --oauth-endpoint "http://127.0.0.1:$PORT/v1/oauth/token" "$@" &
    PROXY_PID=$!
    for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
    [ -S "$SOCK" ]
}

pcurl() {  # curl through the proxy socket; extra curl args pass through
    curl -s --unix-socket "$SOCK" -H "Authorization: Bearer $PLACEHOLDER" "$@"
}

teardown() {
    kill "${PROXY_PID:-}" "${FAKE_PID:-}" 2>/dev/null || true
    rm -rf "$TD"
}

@test "strips the placeholder and injects the real Bearer token" {
    start_proxy
    run pcurl -d '{"hello":1}' http://proxy/v1/messages
    [ "$status" -eq 0 ]
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer real-access-token" ]
    [[ "$output" != *"$PLACEHOLDER"* ]]
    [ "$(jq -r '.body' <<<"$output")" = '{"hello":1}' ]
}

@test "strips x-api-key too" {
    start_proxy
    run pcurl -H "x-api-key: $PLACEHOLDER" -d '{}' http://proxy/v1/messages
    [ "$(jq -r '.headers["x-api-key"] // "absent"' <<<"$output")" = "absent" ]
}

@test "adds the OAuth beta value, merging with an existing anthropic-beta header" {
    start_proxy
    run pcurl -H "anthropic-beta: context-1m-2025-08-07" -d '{}' http://proxy/v1/messages
    beta="$(jq -r '.headers["anthropic-beta"]' <<<"$output")"
    [[ "$beta" == *"context-1m-2025-08-07"* ]]
    [[ "$beta" == *"oauth-2025-04-20"* ]]
}

@test "passes upstream status and body through unchanged" {
    start_proxy
    run bash -c 'curl -s -o "$1/body" -w "%{http_code}" --unix-socket "$2" http://proxy/status-503' _ "$TD" "$SOCK"
    [ "$output" = "503" ]
    [ "$(cat "$TD/body")" = "upstream-error" ]
}

@test "merges anthropic-beta sent in non-lowercase casing instead of duplicating it" {
    start_proxy
    run pcurl -H "Anthropic-Beta: context-1m-2025-08-07" -d '{}' http://proxy/v1/messages
    beta="$(jq -r '.headers["anthropic-beta"] // .headers["Anthropic-Beta"] // "MISSING"' <<<"$output")"
    [[ "$beta" == *"context-1m-2025-08-07"* ]]
    [[ "$beta" == *"oauth-2025-04-20"* ]]
    # exactly one beta header reached the fixture, not two
    count="$(jq '[.headers | keys[] | select(ascii_downcase == "anthropic-beta")] | length' <<<"$output")"
    [ "$count" -eq 1 ]
}

@test "SSE: full stream is delivered" {
    start_proxy
    run curl -sN --max-time 5 --unix-socket "$SOCK" http://proxy/sse
    [[ "$output" == *"data: first"* ]]
    [[ "$output" == *"data: second"* ]]
}

@test "SSE: first event arrives before upstream finishes (unbuffered)" {
    # Fixture sends "first" immediately, then sleeps 2s before "second".
    # Reading for only 1s must therefore yield "first" - if the proxy
    # buffered the whole response, we'd get nothing here.
    start_proxy
    run bash -c 'curl -sN --max-time 1 --unix-socket "$1" http://proxy/sse || true' _ "$SOCK"
    [[ "$output" == *"data: first"* ]]
    [[ "$output" != *"data: second"* ]]
}

@test "near-expiry access token triggers refresh, write-back, and use of the new token" {
    write_creds 60   # < default 300s margin
    start_proxy
    run pcurl -d '{}' http://proxy/v1/messages
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer refreshed-access-token" ]
    [ "$(jq -r '.claudeAiOauth.refreshToken' "$CREDS")" = "rotated-refresh-token" ]
    # sibling keys preserved, perms kept private, expiry advanced
    [ "$(jq -r '.claudeAiOauth.subscriptionType' "$CREDS")" = "max" ]
    [ "$(stat -c %a "$CREDS")" = "600" ]
    [ "$(jq -r '.claudeAiOauth.expiresAt' "$CREDS")" -gt "$((($(date +%s) + 7200) * 1000))" ]
    [ "$(curl -s "http://127.0.0.1:$PORT/oauth-hits")" = "1" ]
}

@test "the refresh request carries the stored refresh token and the pinned client id" {
    write_creds 60
    start_proxy
    run pcurl -d '{}' http://proxy/v1/messages
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer refreshed-access-token" ]
    last="$(curl -s "http://127.0.0.1:$PORT/oauth-last")"
    [ "$(jq -r '.grant_type' <<<"$last")" = "refresh_token" ]
    [ "$(jq -r '.refresh_token' <<<"$last")" = "real-refresh-token" ]
    [ "$(jq -r '.client_id' <<<"$last")" = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" ]
}

@test "upstream 401 triggers one refresh-and-retry" {
    start_proxy   # token far from expiry - only the 401 forces refresh
    run pcurl -d '{}' http://proxy/echo-401-once
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer refreshed-access-token" ]
    [ "$(curl -s "http://127.0.0.1:$PORT/oauth-hits")" = "1" ]
}

@test "an externally-refreshed credentials file is used without a redundant refresh" {
    write_creds 60
    start_proxy
    # simulate host-side Claude Code refreshing first
    sed -i 's/real-access-token/externally-refreshed-token/; s/"expiresAt":[0-9]*/"expiresAt":'"$((($(date +%s) + 7200) * 1000))"'/' "$CREDS"
    run pcurl -d '{}' http://proxy/v1/messages
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer externally-refreshed-token" ]
    [ "$(curl -s "http://127.0.0.1:$PORT/oauth-hits")" = "0" ]
}

@test "credentials file going malformed mid-session yields 502 and the proxy survives" {
    start_proxy
    echo 'not json' > "$CREDS"
    run bash -c 'curl -s -o /dev/null -w "%{http_code}" --unix-socket "$1" -d "{}" http://proxy/v1/messages' _ "$SOCK"
    [ "$output" = "502" ]
    write_creds 7200
    run pcurl -d '{}' http://proxy/v1/messages
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer real-access-token" ]
}

@test "an already-expired refresh token is fatal at startup, before the socket exists" {
    write_creds 7200
    sed -i 's/"refreshTokenExpiresAt":[0-9]*/"refreshTokenExpiresAt":1000/' "$CREDS"
    run "$PROXY" --socket "$SOCK" --credentials "$CREDS" --upstream "http://127.0.0.1:$PORT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"log in"* ]]
    [ ! -S "$SOCK" ]
}
