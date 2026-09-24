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
    SANDBOX_CREDENTIAL_PROXY_SOCKET="$SOCK" SANDBOX_CREDENTIAL_PROXY_PORT=18399 \
        SANDBOX_CREDENTIAL_TRANSPORT=loopback \
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
    SANDBOX_CREDENTIAL_PROXY_SOCKET="$SOCK" \
    SANDBOX_CREDENTIAL_TRANSPORT="$1" \
    SANDBOX_CREDENTIAL_PROXY_PORT="$2" \
    SANDBOX_CREDENTIAL_TLS_CERT="$TD/cert.pem" \
    SANDBOX_CREDENTIAL_TLS_KEY="$TD/key.pem" \
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
    run env -u SANDBOX_CREDENTIAL_TLS_CERT -u SANDBOX_CREDENTIAL_TLS_KEY \
        SANDBOX_CREDENTIAL_PROXY_SOCKET="$SOCK" SANDBOX_CREDENTIAL_TRANSPORT=tls \
        SANDBOX_CREDENTIAL_PROXY_PORT=18398 \
        node "$REPO_ROOT/docker/credential-proxy-forwarder.js"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SANDBOX_CREDENTIAL_TLS_CERT"* ]]
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

# --- backend-generic behaviour (#171) ----------------------------------------
#
# The proxy knows no backend's name: upstream, credential kind, auth
# header and shape, what to strip and what to ensure are all arguments. These
# exercise the second kind - a static key, which is what an OpenAI-compatible
# hosted backend has - and the parts of the shape a backend can move.

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

@test "the auth header and its format are the backend's, not Bearer by fiat" {
    # A backend that wants its key in a header of its own, unprefixed, needs
    # no code here. Asserted together because the pair is the shape.
    start_static --auth-header x-goog-api-key --auth-format '{token}'
    run pcurl -d '{}' http://proxy/v1/chat/completions
    [ "$(jq -r '.headers["x-goog-api-key"]' <<<"$output")" = "sk-test-static-key" ]
    # And the client's own Authorization placeholder is left alone rather than
    # silently rewritten: it is not this backend's auth header. Stripping it
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
    # Naming it in both places is a backend's mistake, and the safe reading
    # is that the credential still goes: dropping it would send an
    # unauthenticated request and report the backend's 401 as the fault.
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
    # anthropic-beta is one backend's requirement. A proxy that added it
    # anyway would put an Anthropic tell on every other backend's wire.
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
    # mangled bytes and report the backend's rejection as the fault.
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

# The proxy is the only thing that sees both the request the session made and
# the answer the API gave. It forwarded a rejection verbatim and recorded
# nothing, so a session that spun and then errored left the operator with
# nothing to act on - reported from a real cline launch against the anthropic
# backend.

@test "an upstream rejection is recorded, and still reaches the session whole" {
    start_proxy --log "$TD/proxy.log"
    run pcurl -i "http://localhost/status-503"
    [ "$status" -eq 0 ]
    # /status-503 answers without a Content-Length. The first version read the
    # body only where upstream declared a small one, and the first real
    # rejection it met - a rate limiter - recorded the status and nothing
    # else, which is the half an operator cannot act on.
    # Byte for byte: what the session sees is what the API said, not the
    # proxy's summary of it.
    [[ "$output" == *"503"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"upstream-error"* ]] \
        || { echo "the body did not reach the client: $output"; return 1; }
    [ -s "$TD/proxy.log" ] || { echo "nothing was recorded"; return 1; }
    grep -q '503' "$TD/proxy.log" || { echo "$(cat "$TD/proxy.log")"; return 1; }
    grep -q 'upstream-error' "$TD/proxy.log" \
        || { echo "recorded the status without the reason: $(cat "$TD/proxy.log")"; return 1; }
}

@test "a request the API accepted records nothing at all" {
    # The success path must stay silent, and must not read the body to decide:
    # logging every request would put the operator's traffic in a file and
    # would buffer a streaming response to do it.
    start_proxy --log "$TD/proxy.log"
    run pcurl "http://localhost/v1/messages" -d '{"model":"x"}'
    [ "$status" -eq 0 ]
    [ ! -s "$TD/proxy.log" ] \
        || { echo "a successful request was logged: $(cat "$TD/proxy.log")"; return 1; }
}

@test "with no log file the diagnostics still go somewhere" {
    # A proxy run by hand has no file to read afterwards, so stderr is right
    # there. Losing the message because no --log was passed would make the
    # by-hand case the one with no diagnostics.
    start_proxy
    run pcurl "http://localhost/status-503"
    [ "$status" -eq 0 ]
    grep -q '503' "$TD/stderr" \
        || { echo "nothing on stderr: $(cat "$TD/stderr")"; return 1; }
}

@test "a rate limiter's retry-after is named, not left among the headers" {
    # Three 429s four seconds apart is what a real launch produced, and the
    # actionable part of one is not in the body.
    start_proxy --log "$TD/proxy.log"
    run pcurl -i "http://localhost/status-429"
    [ "$status" -eq 0 ]
    grep -q 'retry-after=41' "$TD/proxy.log" \
        || { echo "$(cat "$TD/proxy.log")"; return 1; }
    # The identifier Anthropic support asks for. A real rate-limited call came
    # back with a body of {"message":"Error"} - the word Error and nothing
    # else - so on that response this is the only actionable thing there is.
    grep -q 'request-id=req_011CehAZUPXFbQGikXfM3Mp6' "$TD/proxy.log" \
        || { echo "no request id: $(cat "$TD/proxy.log")"; return 1; }
    # And not the ids that name the operator's org. This line gets pasted
    # into bug reports.
    grep -qi 'workspace\|organization' "$TD/proxy.log" \
        && { echo "an account identifier reached the log"; return 1; }
    grep -q 'rate_limit_error' "$TD/proxy.log" \
        || { echo "the body did not reach the log: $(cat "$TD/proxy.log")"; return 1; }
    # And the client still gets both.
    [[ "$output" == *"retry-after: 41"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"rate_limit_error"* ]] || { echo "$output"; return 1; }
}

@test "a compressed rejection is logged as text, not as bytes" {
    # The client's own Accept-Encoding is forwarded verbatim, so a harness
    # that asks for gzip gets a compressed error body - and the first version
    # of this logging wrote those bytes out, which reached the operator as
    # mojibake and a bash warning about a null byte in a command
    # substitution. Reported from a real launch.
    start_proxy --log "$TD/proxy.log"
    run pcurl -i --compressed "http://localhost/status-429-gzip"
    [ "$status" -eq 0 ]
    grep -q 'slow down' "$TD/proxy.log" \
        || { echo "the message did not survive decompression: $(cat "$TD/proxy.log")"; return 1; }
    # Nothing unprintable reaches the file at all. This is the half that has
    # to hold whatever the encoding: upstream text landing on the operator's
    # terminal is what dejima-audit already refuses to do unescaped.
    [ -z "$(tr -d '\11\12\15\40-\176' < "$TD/proxy.log")" ] \
        || { echo "unprintable bytes reached the log"; od -c "$TD/proxy.log" | head -3; return 1; }
    # And the client still received the compressed bytes untouched.
    [[ "$output" == *"slow down"* ]] || { echo "$output"; return 1; }
}

@test "an encoding the stdlib cannot read says so rather than printing bytes" {
    # br and zstd have no stdlib decoder. Naming the encoding is more use than
    # the bytes, and the bytes are the thing this exists to keep off a
    # terminal.
    run python3 -c '
import sys; sys.path.insert(0, "'"$REPO_ROOT"'/bin")
import importlib.util, importlib.machinery
# The proxy has no .py suffix, so the loader has to be named rather than
# inferred from the extension.
loader = importlib.machinery.SourceFileLoader("p", "'"$REPO_ROOT"'/bin/dejima-credential-proxy")
spec = importlib.util.spec_from_loader("p", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
print(m._readable(b"\x1f\x8b\x00\x01\x02", "br"))
print(m._readable(b"\x00\x01\x02not gzip at all", "gzip"))
print(m._readable(b"plain \x00\x07text", ""))
'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"br-encoded"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"undecodable"* ]] || { echo "$output"; return 1; }
    # Control characters become spaces rather than being dropped, so a
    # message is not silently re-joined into a different one. The exact run
    # length is not the point; that none of them survives is.
    [[ "$output" == *"plain"*"text"* ]] || { echo "$output"; return 1; }
}

@test "brotli is read when the host can, and named when it cannot" {
    # What a Node client actually negotiates. gzip was the first guess and
    # the real one came back br - so the encoding this could not read was the
    # common case, not an edge.
    #
    # Optional on purpose: this runs on the host as the operator, and a
    # diagnostic is not worth a hard dependency. So the test asserts whichever
    # half this host can demonstrate, and the note has to name the fix.
    run python3 -c '
import sys, importlib.util, importlib.machinery
l = importlib.machinery.SourceFileLoader("p", "'"$REPO_ROOT"'/bin/dejima-credential-proxy")
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("p", l)); l.exec_module(m)
try:
    import brotli as b
except ImportError:
    try:
        import brotlicffi as b
    except ImportError:
        b = None
if b is None:
    print("ABSENT " + m._readable(b"\x1b\x0e\x00\xf8\x25", "br"))
else:
    print("PRESENT " + m._readable(b.compress(b"slow down"), "br"))
'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    case "$output" in
        PRESENT*) [[ "$output" == *"slow down"* ]] \
                      || { echo "a decoder was available and the message did not survive: $output"; return 1; } ;;
        ABSENT*)  [[ "$output" == *"br-encoded"* ]] \
                      || { echo "$output"; return 1; }
                  # Naming the encoding is not enough on its own: the operator
                  # is one install away from the message, and the line has to
                  # say so.
                  [[ "$output" == *"brotli"* ]] \
                      || { echo "the note does not say what would fix it: $output"; return 1; } ;;
        *) echo "unexpected: $output"; return 1 ;;
    esac
    # Either way, no bytes.
    [ -z "$(printf '%s' "$output" | tr -d '\11\12\15\40-\176')" ] \
        || { echo "unprintable output survived"; return 1; }
}

@test "nothing unprintable reaches the diagnostics file, whatever wrote it" {
    # Asserted at the sink rather than on one producer. bin/dejima prints this
    # file to the operator's terminal after a session ends, so it carries text
    # an upstream API chose and - through the request path and exception
    # messages - text the session chose. Filtering it where it is written
    # covers a producer added later; filtering it in one formatter does not.
    #
    # CPython refuses a control character in a URL today, in two places, and
    # reprs what it refuses. That is a coincidence this should not rest on.
    run python3 -c '
import importlib.util, importlib.machinery, tempfile, os
l = importlib.machinery.SourceFileLoader("p", "'"$REPO_ROOT"'/bin/dejima-credential-proxy")
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("p", l)); l.exec_module(m)
d = tempfile.mkdtemp(); f = os.path.join(d, "log")
m._diag(f, "path=/v1/\x1b[2J\x1b[1;31mred\x1b[0m\x07 null=\x00 tab=\t")
raw = open(f, "rb").read()
print("BYTES", sum(1 for b in raw if b < 32 and b != 10))
print(raw.decode().strip())
'
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"BYTES 0"* ]] \
        || { echo "control bytes reached the file: $output"; return 1; }
    # And the text around them survives, so a sanitised line is still a
    # readable one rather than a row of spaces.
    [[ "$output" == *"path=/v1/"* ]] && [[ "$output" == *"red"* ]] \
        || { echo "$output"; return 1; }
}

@test "a refresh the provider rejects names the login that fixes it, in the session" {
    # What an overnight session meets in the morning: the access token has
    # expired, the refresh token with it, and the provider answers the refresh
    # with invalid_grant. That is not transient and no amount of retrying or
    # waiting improves it - the operator has to log in on the host.
    #
    # The session is where the failure is met and the host terminal is behind a
    # window the agent cannot read, so "see host terminal" costs a trip to find
    # one sentence. This message is written in the proxy rather than taken from
    # the provider's response, which is what makes it safe to send.
    write_creds -60
    start_proxy
    curl -s "http://127.0.0.1:$PORT/oauth-reject" >/dev/null

    run pcurl -o /dev/null -w '%{http_code}' -X POST --data '{}' http://x/v1/messages
    [ "$output" = 502 ] || { echo "status was $output"; return 1; }

    run pcurl -X POST --data '{}' http://x/v1/messages
    [[ "$output" == *"log in again"* ]] \
        || { echo "the session was not told how to fix it: $output"; return 1; }
    [[ "$output" == *"on the host"* ]] \
        || { echo "the session was not told where to fix it: $output"; return 1; }

    # The provider's own bytes stay on the host, which is the rule this is
    # working within rather than around.
    [[ "$output" != *"invalid_grant"* ]] \
        || { echo "an upstream response body reached the session: $output"; return 1; }
    grep -q 'invalid_grant' "$TD/stderr" \
        || { echo "the host log lost the detail:"; cat "$TD/stderr"; return 1; }

    # And the host log carries the remedy as well as the detail. The exit audit
    # prints the last line of this file when a session ends, so an operator who
    # was away while it failed reads it there - which is where this was found
    # wanting: it showed the provider's error code and nothing to do about it.
    # The LAST line specifically. bin/dejima's exit audit prints that one when a
    # session ends, so it is what an operator who was away while it failed reads
    # without going looking - and it was the provider's error code with no
    # remedy in it, which is what sent one looking in the first place.
    run tail -n 1 "$TD/stderr"
    [[ "$output" == *"log in again"* ]] \
        || { echo "the last host line is not the actionable one: $output"; return 1; }
    [[ "$output" != *"HTTP 400"* ]] \
        || { echo "the last host line still leads with the provider's answer: $output"; return 1; }
}

# The exit audit in bin/dejima reads this log. Extracted and driven here rather
# than restated, and fed logs this proxy actually wrote, because the two live in
# different files and the classification only works if they agree about what a
# line looks like.
run_exit_audit() {  # <proxy log>
    C_WARN='' C_RESET='' SANDBOX_CREDENTIAL_PROXY_LOG="$1" bash -c '
        C_WARN=""; C_RESET=""
        SANDBOX_CREDENTIAL_PROXY_LOG="$1"
        '"$(sed -n '/_audit_counts="\$(awk/,/unset _audit_counts _audit_last/p' \
              "$REPO_ROOT/bin/dejima")"'
    ' _ "$1" 2>&1
}

@test "the exit audit does not report a credential failure as the API answering" {
    # An overnight expiry logs no upstream status, because no request was made -
    # the credential could not be loaded. Announcing "the model API answered
    # with an error" there sends an operator to check the provider, and the
    # retry caveat invites them to hope it succeeded anyway. Neither is true,
    # and the line the proxy leaves last is an instruction rather than a status.
    write_creds -60
    start_proxy
    curl -s "http://127.0.0.1:$PORT/oauth-reject" >/dev/null
    pcurl -o /dev/null -X POST --data '{}' http://x/v1/messages || true

    run run_exit_audit "$TD/stderr"
    [[ "$output" != *"model API answered with an error"* ]] \
        || { echo "reported as the API answering: $output"; return 1; }
    [[ "$output" != *"may still have succeeded"* ]] \
        || { echo "invited a retry that cannot succeed: $output"; return 1; }
    [[ "$output" == *"could not authenticate"* ]] \
        || { echo "did not say what happened: $output"; return 1; }
    [[ "$output" == *"log in again"* ]] \
        || { echo "did not carry the remedy: $output"; return 1; }
}

@test "an upstream that answered with errors is still reported as one" {
    # The control: the audit's original purpose has to survive the split.
    start_proxy
    pcurl -o /dev/null "http://localhost/status-429"
    pcurl -o /dev/null "http://localhost/status-429"

    run run_exit_audit "$TD/stderr"
    [[ "$output" == *"model API answered with an error"* ]] \
        || { echo "an upstream error stopped being reported as one: $output"; return 1; }
    [[ "$output" == *"2 x HTTP 429"* ]] \
        || { echo "the grouping by status is gone: $output"; return 1; }
    [[ "$output" == *"may still have succeeded"* ]] \
        || { echo "the retry caveat is gone from the case it is about: $output"; return 1; }
}

@test "a request that never reached the upstream is reported as neither case" {
    # `upstream request failed` carries no status - nothing answered - and no
    # credential failed either. Classified by "no status lines anywhere", it
    # read as an authentication failure, sending an operator to log in again
    # over a connection problem.
    start_proxy --upstream "http://127.0.0.1:1"
    pcurl -o /dev/null -X POST --data '{}' http://x/v1/messages || true

    run run_exit_audit "$TD/stderr"
    [[ "$output" != *"could not authenticate"* ]] \
        || { echo "a connection failure read as an authentication failure: $output"; return 1; }
    [[ "$output" != *"model API answered with an error"* ]] \
        || { echo "reported as the API answering: $output"; return 1; }
    [[ "$output" == *"credential proxy reported a problem"* ]] \
        || { echo "the failure went unreported: $output"; return 1; }
    [[ "$output" == *"upstream request failed"* ]] \
        || { echo "the line itself is missing: $output"; return 1; }
}

@test "upstream text saying 'answered 503' cannot fabricate a status count" {
    # The refresh failure's detail line carries up to 200 bytes of the token
    # endpoint's response body - text the upstream chose. Counted wherever
    # `answered N` appeared, that body minted "1 x HTTP 503" for a session
    # that made no request, and brought the retry caveat with it. The count
    # is anchored to the proxy's own `upstream answered N for` lines.
    write_creds -60
    start_proxy
    curl -s "http://127.0.0.1:$PORT/oauth-reject?say=the+upstream+answered+503+today" >/dev/null
    pcurl -o /dev/null -X POST --data '{}' http://x/v1/messages || true

    run run_exit_audit "$TD/stderr"
    [[ "$output" != *"model API answered with an error"* ]] \
        || { echo "an upstream string was counted as an API answer: $output"; return 1; }
    [[ "$output" != *"HTTP 503"* ]] \
        || { echo "a status count was minted from body text: $output"; return 1; }
    [[ "$output" == *"could not authenticate"* ]] \
        || { echo "the real failure went unreported: $output"; return 1; }
    [[ "$output" == *"answered 503 today"* ]] \
        || { echo "the detail line is not shown: $output"; return 1; }
}

@test "a negative Content-Length is refused rather than read to EOF" {
    # The cap exists because this runs on the host as the operator's own user.
    # int() accepts a negative, a negative passes a `> MAX` test, and a buffered
    # reader takes read(-1) as "to EOF" - so `Content-Length: -1` read an
    # unbounded body into host RAM past the cap. A non-numeric value raised out
    # past the types handle_error knows and put a traceback on the terminal.
    start_proxy

    run curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" \
        -H "Authorization: Bearer $PLACEHOLDER" -H 'Content-Length: -1' \
        -X POST --data 'x' http://x/v1/messages
    [ "$output" = 413 ] \
        || { echo "a negative Content-Length was not refused: $output"; return 1; }

    # A value that is not a number is left alone: it still raises, because the
    # test above for narrow error suppression uses exactly that fault to prove
    # the suppression is specific to a client going away. This fix is about the
    # value that passes the cap and then reads to EOF, not about input tidiness.

    # And an ordinary request still works, so the check did not close the door.
    run pcurl -o /dev/null -w '%{http_code}' -X POST --data '{}' http://x/v1/messages
    [ "$output" = 200 ] || { echo "a normal request was refused: $output"; return 1; }
}
