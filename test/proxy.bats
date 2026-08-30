#!/usr/bin/env bats
# Host-side (no Docker): the credential-injecting proxy must strip the
# container's placeholder token, inject the real one, stream SSE unbuffered,
# and (see the refresh tests added later) own OAuth refresh + write-back.

PLACEHOLDER="sandbox-credential-proxy-placeholder"

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    PROXY="$REPO_ROOT/bin/dejima-credential-proxy"
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

# The Anthropic arrangement, spelled the way bin/dejima spells it. The proxy
# itself now defaults none of this (#171), so a test that omitted a flag would
# be exercising a configuration no launch produces - which is why these are
# here in full rather than left to defaults, and why static.bats pins that
# bin/dejima still passes the same set.
start_proxy() {
    "$PROXY" --socket "$SOCK" --credentials "$CREDS" \
        --upstream "http://127.0.0.1:$PORT" \
        --credential-kind anthropic-oauth \
        --oauth-endpoint "http://127.0.0.1:$PORT/v1/oauth/token" \
        --oauth-client-id "9d1c250a-e61b-44d9-88ed-5944d1962f5e" \
        --auth-header Authorization \
        --auth-format "Bearer {token}" \
        --strip-header x-api-key \
        --ensure-header "anthropic-beta=oauth-2025-04-20" "$@" 2>"$TD/stderr" &
    PROXY_PID=$!
    for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
    [ -S "$SOCK" ]
}

pcurl() {  # curl through the proxy socket; extra curl args pass through
    curl -s --unix-socket "$SOCK" -H "Authorization: Bearer $PLACEHOLDER" "$@"
}

teardown() {
    kill "${PROXY_PID:-}" "${FAKE_PID:-}" "${FWD_PID:-}" 2>/dev/null || true
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

@test "the client's header block reaches upstream with its own casing and order" {
    # The container half of this sandbox exists to make the session look like
    # a stock install. If the proxy rewrote the request into CPython's house
    # style on its way out, that fingerprint would simply move from the client
    # to the wire, where the API sees it instead. Sent in a deliberately
    # un-CPython shape: mixed casing, and a header after the one the proxy has
    # to rewrite, so a rewrite that reorders shows up here.
    start_proxy
    run pcurl -H "Content-Type: application/json" -H "Anthropic-Version: 2023-06-01" \
        -H "X-Stainless-Lang: js" -d '{}' http://proxy/v1/messages
    [ "$status" -eq 0 ]
    names="$(jq -r '.header_lines[][0]' <<<"$output")"
    grep -qx 'Content-Type' <<<"$names"
    grep -qx 'Anthropic-Version' <<<"$names"
    grep -qx 'X-Stainless-Lang' <<<"$names"
    # Position, not just presence: Authorization keeps the slot curl gave it,
    # ahead of the three above, rather than being appended after them.
    auth_at="$(jq -r '[.header_lines[][0] | ascii_downcase] | index("authorization")' <<<"$output")"
    type_at="$(jq -r '[.header_lines[][0] | ascii_downcase] | index("content-type")' <<<"$output")"
    [ "$auth_at" -lt "$type_at" ]
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer real-access-token" ]
}

@test "no Accept-Encoding is invented for a client that sent none" {
    # http.client's putrequest() adds `Accept-Encoding: identity` whenever the
    # caller passed none - a CPython tell that no browser or Node client
    # sends. curl sends no accept-encoding unless asked, so upstream must see
    # none at all.
    start_proxy
    run pcurl -d '{}' http://proxy/v1/messages
    [ "$(jq -r '[.header_lines[][0] | ascii_downcase | select(. == "accept-encoding")] | length' <<<"$output")" = "0" ]
    # ...and a client that does send one keeps its own value, unaltered.
    run pcurl -H "Accept-Encoding: gzip, deflate" -d '{}' http://proxy/v1/messages
    [ "$(jq -r '.headers["accept-encoding"]' <<<"$output")" = "gzip, deflate" ]
}

@test "repeated headers survive as repeats instead of collapsing to the last" {
    # Rebuilding the block through a dict silently keeps only the last value.
    start_proxy
    run pcurl -H "X-Dup: one" -H "X-Dup: two" -d '{}' http://proxy/v1/messages
    [ "$(jq -r '[.header_lines[] | select(.[0] | ascii_downcase == "x-dup") | .[1]] | join("|")' <<<"$output")" = "one|two" ]
}

@test "the injected token is sent once even when the client repeats its placeholder" {
    # The replacement is per-header-name, not per-occurrence: a duplicated
    # Authorization must not become two copies of the real token.
    start_proxy
    run curl -s --unix-socket "$SOCK" -H "Authorization: Bearer $PLACEHOLDER" \
        -H "Authorization: Bearer $PLACEHOLDER" -d '{}' http://proxy/v1/messages
    [ "$(jq -r '[.header_lines[] | select(.[0] | ascii_downcase == "authorization")] | length' <<<"$output")" = "1" ]
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer real-access-token" ]
    [[ "$output" != *"$PLACEHOLDER"* ]]
}

@test "an anthropic-beta that already carries the OAuth value is forwarded untouched" {
    # Re-joining a list that needs no change would normalize the client's
    # spacing - the same class of tell as the casing. This is the common case
    # in the tls transport, where Claude Code sends the header itself.
    start_proxy
    run pcurl -H "anthropic-beta: oauth-2025-04-20, context-1m-2025-08-07" \
        -d '{}' http://proxy/v1/messages
    [ "$(jq -r '.headers["anthropic-beta"]' <<<"$output")" = "oauth-2025-04-20, context-1m-2025-08-07" ]
}

@test "a bodyless request gains no Content-Length the client never sent" {
    start_proxy
    run pcurl http://proxy/v1/models
    [ "$(jq -r '[.header_lines[][0] | ascii_downcase | select(. == "content-length")] | length' <<<"$output")" = "0" ]
}

@test "a chunked request is de-framed into a Content-Length upstream" {
    # The proxy has to buffer to inject the token, so chunked framing cannot
    # survive - but the length it declares must match what it forwards, and
    # the hop-by-hop Transfer-Encoding must not travel with it.
    start_proxy
    run curl -s --unix-socket "$SOCK" -H "Transfer-Encoding: chunked" \
        -H "Authorization: Bearer $PLACEHOLDER" \
        -d '{"hello":1}' http://proxy/v1/messages
    [ "$(jq -r '.body' <<<"$output")" = '{"hello":1}' ]
    [ "$(jq -r '.headers["content-length"]' <<<"$output")" = "11" ]
    [ "$(jq -r '.headers["transfer-encoding"] // "absent"' <<<"$output")" = "absent" ]
}

@test "Host is rewritten for the upstream, in place" {
    # It must name the upstream, not the socket the container reached - but it
    # is replaced where the client put it rather than dropped and re-added,
    # which is what keeps the rest of the block in order.
    start_proxy
    run pcurl -d '{}' http://proxy/v1/messages
    [ "$(jq -r '.headers.host' <<<"$output")" = "127.0.0.1:$PORT" ]
    [ "$(jq -r '[.header_lines[][0] | ascii_downcase] | index("host")' <<<"$output")" = "0" ]
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

@test "refresh never leaves a plaintext temp file directly in the credentials directory" {
    write_creds 60
    start_proxy
    run pcurl -d '{}' http://proxy/v1/messages
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer refreshed-access-token" ]
    # only the real credentials file itself (and the dedicated staging
    # subdirectory) should exist directly in $TD - no sibling tmpXXXXXX file
    # from the write-back. Race-free: this runs after pcurl returned, by
    # which point _write's rename has already completed.
    leftover="$(find "$TD" -mindepth 1 -maxdepth 1 -name 'tmp*' -not -path "$TD/.credentials-proxy-tmp*")"
    [ -z "$leftover" ]
    # and confirm the write actually staged in the dedicated subdirectory
    # (not just that no tmp file is left directly in $TD - the old, vulnerable
    # code also cleaned up after itself via os.replace, so that alone passes
    # even pre-fix).
    [ -d "$TD/.credentials-proxy-tmp" ]
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
    run timeout 5 "$PROXY" --socket "$SOCK" --credentials "$CREDS" \
        --upstream "http://127.0.0.1:$PORT" --credential-kind anthropic-oauth \
        --oauth-endpoint "http://127.0.0.1:$PORT/v1/oauth/token" \
        --oauth-client-id probe
    # 1, not just nonzero: an argument mistake exits 2, and this test would
    # otherwise pass on one while proving nothing about the expiry check.
    [ "$status" -eq 1 ]
    [[ "$output" == *"log in"* ]]
    [ ! -S "$SOCK" ]
}

@test "forwarder bridges TCP to the proxy's unix socket" {
    start_proxy
    SANDBOX_ANTHROPIC_PROXY_SOCKET="$SOCK" SANDBOX_ANTHROPIC_PROXY_PORT=18399 \
        SANDBOX_ANTHROPIC_TRANSPORT=loopback \
        node "$REPO_ROOT/docker/credential-proxy-forwarder.js" &
    FWD_PID=$!
    ok=""
    for _ in $(seq 1 50); do
        if curl -s -o /dev/null http://127.0.0.1:18399/echo; then ok=1; break; fi
        sleep 0.1
    done
    [ -n "$ok" ]
    run curl -s -H "Authorization: Bearer $PLACEHOLDER" -d '{}' http://127.0.0.1:18399/v1/messages
    kill "$FWD_PID" 2>/dev/null || true
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer real-access-token" ]
}

@test "a client that disappears mid-stream is not reported as a crash" {
    # Interrupting a streaming reply, or exiting with requests in flight,
    # closes the container side mid-response; the proxy then takes an EPIPE
    # writing the rest. socketserver's default handler dumps a full traceback
    # for that, onto the same terminal the session is using. Expected
    # condition, nothing to deliver, nothing to fix - so it must stay quiet.
    start_proxy
    timeout 0.7 curl -s --unix-socket "$SOCK" http://proxy/sse >/dev/null 2>&1 || true
    sleep 3
    run cat "$TD/stderr"
    [[ "$output" != *"Traceback"* ]]
    [[ "$output" != *"BrokenPipeError"* ]]
    [ -z "$output" ]
}

@test "a genuine handler failure is still reported with its traceback" {
    # The suppression has to be specific to the client going away. A real
    # fault - here a chunk length that isn't hex, which blows up _read_body -
    # must still surface in full, or this trades noise for blindness.
    start_proxy
    python3 - "$SOCK" <<'PYEOF'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(b"POST /v1/messages HTTP/1.1\r\nHost: proxy\r\n"
          b"Transfer-Encoding: chunked\r\n\r\nNOTHEX\r\n")
s.close()
PYEOF
    sleep 1
    run cat "$TD/stderr"
    [[ "$output" == *"Traceback"* ]]
    [[ "$output" == *"ValueError"* ]]
}

@test "HEAD and OPTIONS are proxied upstream, not rejected with a 501" {
    # The proxy stands in for api.anthropic.com, so the method set it accepts
    # has to be the API's, not whichever do_* handlers happen to be defined.
    start_proxy
    run bash -c 'curl -s -o /dev/null -w "%{http_code}" --unix-socket "$1" -X OPTIONS http://proxy/v1/messages' _ "$SOCK"
    [ "$output" = "200" ]
    run bash -c 'curl -s -o /dev/null -w "%{http_code}" --unix-socket "$1" -I http://proxy/v1/messages' _ "$SOCK"
    [ "$output" = "200" ]
    run cat "$TD/stderr"
    [[ "$output" != *"501"* ]]
}

# The forwarder is the container-side half of the chain. In tls mode it
# terminates TLS for api.anthropic.com on loopback so Claude Code needs no
# ANTHROPIC_BASE_URL at all, then pipes raw bytes into the same unix socket
# the loopback mode uses - the host proxy cannot tell the two apart.
start_forwarder() {  # start_forwarder <transport> <port>; extra env passes through
    SANDBOX_ANTHROPIC_PROXY_SOCKET="$SOCK" \
    SANDBOX_ANTHROPIC_TRANSPORT="$1" \
    SANDBOX_ANTHROPIC_PROXY_PORT="$2" \
    SANDBOX_ANTHROPIC_TLS_CERT="$TD/cert.pem" \
    SANDBOX_ANTHROPIC_TLS_KEY="$TD/key.pem" \
        node "$REPO_ROOT/docker/credential-proxy-forwarder.js" 2>"$TD/fwd-stderr" &
    FWD_PID=$!
    for _ in $(seq 1 50); do
        (exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

make_cert() {
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$TD/key.pem" -out "$TD/cert.pem" \
        -subj "/CN=api.anthropic.com" \
        -addext "subjectAltName=DNS:api.anthropic.com" >/dev/null 2>&1
}

@test "forwarder tls mode: https to api.anthropic.com reaches the proxy, which injects the real token" {
    make_cert
    start_proxy
    start_forwarder tls 18443
    # --resolve is what stands in for the container's /etc/hosts entry: the
    # name must really be api.anthropic.com for certificate verification to
    # be a meaningful check, not a hostname the test picked to be easy.
    run curl -s --cacert "$TD/cert.pem" \
        --resolve "api.anthropic.com:18443:127.0.0.1" \
        -X POST "https://api.anthropic.com:18443/v1/messages" -d '{}'
    kill "$FWD_PID" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *'"authorization": "Bearer real-access-token"'* ]]
    # No Authorization header was sent at all - the proxy supplied it. This is
    # the auth fingerprint closing: no placeholder token in the container.
    [[ "$output" != *"$PLACEHOLDER"* ]]
}

@test "forwarder tls mode pins ALPN to http/1.1 so the client cannot negotiate h2" {
    # The upstream is a Python http.server, which speaks only HTTP/1.1: an h2
    # negotiation would deliver frames it cannot parse, and the byte pipe has
    # no HTTP awareness to catch it.
    make_cert
    start_proxy
    start_forwarder tls 18444
    run openssl s_client -connect 127.0.0.1:18444 -alpn h2,http/1.1 \
        -servername api.anthropic.com -CAfile "$TD/cert.pem" </dev/null
    kill "$FWD_PID" 2>/dev/null || true
    [[ "$output" == *"ALPN protocol: http/1.1"* ]]
}

@test "forwarder loopback mode serves plaintext http on the port it is given" {
    start_proxy
    start_forwarder loopback 18445
    run curl -s -X POST "http://127.0.0.1:18445/v1/messages" -d '{}'
    kill "$FWD_PID" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *'"authorization": "Bearer real-access-token"'* ]]
}

@test "forwarder tls mode refuses to start without a cert, rather than silently downgrading" {
    start_proxy
    # `run env ...`, not a `VAR=x run ...` prefix: an assignment prefixed to a
    # shell *function* persists in the calling shell rather than scoping to
    # the call, so it would leak into every later test in this file.
    #
    # The -u pair makes this about the code rather than where it runs (#56).
    # "No cert configured" used to be expressed by not setting the variables,
    # which only holds where nothing else did - entrypoint.sh exports both
    # into every tls-transport session, so a suite run inside a dejima
    # container inherited real paths, the guard never fired, and the
    # fall-through hit EADDRINUSE on :443 and was reported as this assertion
    # failing. Unsetting states the precondition instead of assuming it.
    #
    # The port override is belt-and-braces: the cert check precedes the listen
    # today, so a fall-through lands on an unused port if that ever changes.
    run env -u SANDBOX_ANTHROPIC_TLS_CERT -u SANDBOX_ANTHROPIC_TLS_KEY \
        SANDBOX_ANTHROPIC_PROXY_SOCKET="$SOCK" SANDBOX_ANTHROPIC_TRANSPORT=tls \
        SANDBOX_ANTHROPIC_PROXY_PORT=18398 \
        node "$REPO_ROOT/docker/credential-proxy-forwarder.js"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SANDBOX_ANTHROPIC_TLS_CERT"* ]]
}

@test "an oversized request body is refused rather than read into host RAM" {
    # The client here is the sandboxed session and this runs on the host as
    # the operator's user, so the body is session-controlled input with no
    # bound of its own. Every other session-controlled size in the repo is
    # capped; this was the one that was not.
    start_proxy
    local big
    big="$TD/big"
    # Just over the 32MiB cap, declared honestly in Content-Length.
    head -c $((32 * 1024 * 1024 + 1024)) /dev/zero | tr '\0' 'a' > "$big"
    run pcurl -o /dev/null -w '%{http_code}' -X POST \
        --data-binary "@$big" -H 'Content-Type: application/json' \
        "http://localhost/v1/messages"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "413" ] || { echo "expected 413, got $output"; return 1; }
    # And the refusal says so on the host, where the operator can see it.
    grep -q 'refused a request body' "$TD/stderr" \
        || { echo "nothing logged: $(cat "$TD/stderr")"; return 1; }
    # Nothing reached upstream: a body half-forwarded is worse than a refusal.
    grep -q 'aaaa' "$TD/upstream-body" 2>/dev/null \
        && { echo "an oversized body was forwarded upstream"; return 1; }
    return 0
}

@test "a normal-sized request body still passes through" {
    # The cap must be far above anything real. A conversation with attachments
    # is the biggest thing a Messages request carries.
    start_proxy
    local body
    body="$TD/normal"
    head -c $((2 * 1024 * 1024)) /dev/zero | tr '\0' 'b' > "$body"
    run pcurl -o /dev/null -w '%{http_code}' -X POST \
        --data-binary "@$body" -H 'Content-Type: application/json' \
        "http://localhost/v1/messages"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "200" ] || { echo "a 2MiB body was refused with $output"; return 1; }
}

# --- provider-generic behaviour (#171) ---------------------------------------
#
# The proxy no longer knows a provider's name: upstream, credential kind, auth
# header and shape, what to strip and what to ensure are all arguments. These
# exercise the second kind - a static key, which is what an OpenAI-compatible
# hosted provider has - and the parts of the shape a provider can move.

# A static-key proxy against the same fake upstream. $1.. are extra flags.
# Startup refusals run the proxy in the FOREGROUND and expect it to exit, so
# every one of them is bounded by `timeout`. Without it, a check that stopped
# refusing does not fail the test - the proxy starts, serves forever, and the
# test hangs until the whole suite is killed, which reports as no result rather
# than as a wrong one. Found by mutating two of these and watching them time
# out instead of going red.
start_static() {
    printf 'sk-test-static-key\n' > "$TD/key"
    chmod 600 "$TD/key"
    "$PROXY" --socket "$SOCK" --credentials "$TD/key" \
        --upstream "http://127.0.0.1:$PORT" \
        --credential-kind static "$@" 2>"$TD/stderr" &
    PROXY_PID=$!
    for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
    [ -S "$SOCK" ]
}

@test "a static key is injected, and the placeholder never reaches upstream" {
    start_static
    run pcurl -d '{"hello":1}' http://proxy/v1/chat/completions
    [ "$status" -eq 0 ]
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer sk-test-static-key" ]
    [[ "$output" != *"$PLACEHOLDER"* ]]
    [ "$(jq -r '.body' <<<"$output")" = '{"hello":1}' ]
}

@test "a static key file's trailing newline does not reach the header" {
    # Written by an editor or a shell redirection as often as by a tool. A
    # newline in a header value is not cosmetic: it would be rejected or split
    # the block.
    start_static
    run pcurl -d '{}' http://proxy/v1/chat/completions
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer sk-test-static-key" ]
}

@test "a static credential is never refreshed, so a 401 is reported once" {
    # Refreshing needs somewhere to refresh against, and a static key has
    # none. Retrying would send the same bytes and turn one rejection into
    # two, which reads as a flapping upstream rather than a wrong key.
    # The same route the OAuth retry test uses: 401 on the first call, echo
    # after. An OAuth credential refreshes and the second call succeeds; a
    # static one has nowhere to refresh against, so the 401 is what the
    # session sees.
    start_static
    run pcurl -o /dev/null -w '%{http_code}' -d '{}' http://proxy/echo-401-once
    [ "$output" = "401" ]
    # And no refresh was attempted anywhere, which the fake counts for us.
    [ "$(curl -s "http://127.0.0.1:$PORT/oauth-hits")" = "0" ]
}

@test "the auth header and its format are the provider's, not Bearer by fiat" {
    # A provider that wants its key in a header of its own, unprefixed, needs
    # no code here. Asserted together because the pair is the shape.
    start_static --auth-header x-goog-api-key --auth-format '{token}'
    run pcurl -d '{}' http://proxy/v1/chat/completions
    [ "$(jq -r '.headers["x-goog-api-key"]' <<<"$output")" = "sk-test-static-key" ]
    # And the client's own Authorization placeholder is left alone rather than
    # silently rewritten: it is not this provider's auth header. Stripping it
    # is a separate declaration, which the next test covers.
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer $PLACEHOLDER" ]
}

@test "a header named in strip-header does not travel beside the injected one" {
    start_static --auth-header x-goog-api-key --auth-format '{token}' \
        --strip-header authorization
    run pcurl -d '{}' http://proxy/v1/chat/completions
    [ "$(jq -r '.headers.authorization // "absent"' <<<"$output")" = "absent" ]
    [ "$(jq -r '.headers["x-goog-api-key"]' <<<"$output")" = "sk-test-static-key" ]
}

@test "the auth header cannot be stripped out from under itself" {
    # Naming it in both places is a provider's mistake, and the safe reading
    # is that the credential still goes: dropping it would send an
    # unauthenticated request and report the provider's 401 as the fault.
    #
    # Position as well as presence, because presence alone does not
    # distinguish the two paths. A stripped-then-re-added header arrives at
    # the END of the block from the supplied-names pass; a replaced one keeps
    # the slot the client gave it. Both send the credential, and only one of
    # them leaves the request looking like the client wrote it - which is the
    # property the whole header-emission dance exists for.
    start_static --strip-header authorization
    run pcurl -H "Content-Type: application/json" -H "X-Stainless-Lang: js" \
        -d '{}' http://proxy/v1/chat/completions
    [ "$(jq -r '.headers.authorization' <<<"$output")" = "Bearer sk-test-static-key" ]
    local auth_at type_at
    auth_at="$(jq -r '[.header_lines[][0] | ascii_downcase] | index("authorization")' <<<"$output")"
    type_at="$(jq -r '[.header_lines[][0] | ascii_downcase] | index("content-type")' <<<"$output")"
    [ "$auth_at" -lt "$type_at" ] \
        || { echo "Authorization moved to position $auth_at, after Content-Type at $type_at"; return 1; }
}

@test "no ensure-header means none is invented" {
    # anthropic-beta is one provider's requirement. A proxy that added it
    # anyway would put an Anthropic tell on every other provider's wire.
    start_static
    run pcurl -d '{}' http://proxy/v1/chat/completions
    [ "$(jq -r '.headers["anthropic-beta"] // "absent"' <<<"$output")" = "absent" ]
}

@test "an unusable static key is fatal at startup, before the socket exists" {
    : > "$TD/key"
    run timeout 5 "$PROXY" --socket "$SOCK" --credentials "$TD/key" \
        --upstream "http://127.0.0.1:$PORT" --credential-kind static
    [ "$status" -eq 1 ]
    [[ "$output" == *"empty"* ]]
    [ ! -S "$SOCK" ]
}

@test "a key carrying a control character is refused rather than sanitised" {
    # A key that needs sanitising was pasted wrong. Trimming it would send
    # mangled bytes and report the provider's rejection as the fault.
    printf 'sk-good\x1bbad\n' > "$TD/key"
    run timeout 5 "$PROXY" --socket "$SOCK" --credentials "$TD/key" \
        --upstream "http://127.0.0.1:$PORT" --credential-kind static
    [ "$status" -eq 1 ]
    [[ "$output" == *"control character"* ]]
    [ ! -S "$SOCK" ]
}

@test "an auth-format with no token placeholder is refused" {
    # It would start, answer requests, and send every one of them without a
    # credential. Refusing at parse time is the difference between a
    # configuration error and a silently unauthenticated session.
    printf 'k\n' > "$TD/key"
    run timeout 5 "$PROXY" --socket "$SOCK" --credentials "$TD/key" \
        --upstream "http://127.0.0.1:$PORT" --credential-kind static \
        --auth-format 'Bearer'
    [ "$status" -eq 2 ]
    [[ "$output" == *"{token}"* ]]
    [ ! -S "$SOCK" ]
}

@test "anthropic-oauth without its endpoint or client id is refused" {
    write_creds 7200
    run timeout 5 "$PROXY" --socket "$SOCK" --credentials "$CREDS" \
        --upstream "http://127.0.0.1:$PORT" --credential-kind anthropic-oauth
    [ "$status" -eq 2 ]
    [[ "$output" == *"oauth-endpoint"* ]]
    [ ! -S "$SOCK" ]
}
