#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Behavioral checks against a live container running the real entrypoint.sh
# (SANDBOX_TEST_MODE=1 - see entrypoint.sh - runs the actual DNS
# proxy/firewall/logging setup, then execs `sleep infinity` as node instead
# of nvim so the suite can attach). One container is shared across the whole
# file (setup_file/teardown_file, not setup/teardown) since spinning up a
# fresh one per test would make this suite too slow to actually get run.
#
# Needs Docker. Set SKIP_BUILD=1 to reuse whatever claude-sandbox:latest is
# already built, for fast iteration - the default is to always rebuild, so a
# stale image can't produce a false pass.
#
# Safety: every iptables/ipset/ip6tables mutation below happens inside the
# test container's own network namespace (no --network host, no bind mounts
# of host paths) - none of it touches the host's real firewall state, same
# as any other container. Container/network names are derived from
# BATS_FILE_TMPDIR (a directory bats itself guarantees is unique per run and
# stable across setup_file/every test/teardown_file in this file), so a
# stray real container or network can never collide with, and get torn down
# by, this suite. Don't derive these from $$ instead - bats reruns this
# file's top-level code in a fresh subshell per test, so $$ (unlike
# BATS_FILE_TMPDIR) is a *different* value in every test, setup_file, and
# teardown_file, silently pointing them at containers that don't match.

IMAGE=claude-sandbox:latest

container_name() { echo "claude-sandbox-test-$(basename "$BATS_FILE_TMPDIR")"; }
network_name() { echo "claude-sandbox-test-net-$(basename "$BATS_FILE_TMPDIR")"; }

setup_file() {
    SANDBOX_DIR="$BATS_TEST_DIRNAME/../docker"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    local container network
    container=$(container_name)
    network=$(network_name)

    if [ "${SKIP_BUILD:-0}" != "1" ]; then
        docker build -q -t "$IMAGE" -f "$SANDBOX_DIR/Dockerfile" "$REPO_ROOT" >&2
    fi

    docker rm -f "$container" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    docker network create "$network" >/dev/null

    # No GITEA_*/GH_TOKEN/LOKI_URL: this suite only asserts the default
    # allowlist and enforcement, which shouldn't depend on any of them.
    docker run -d --name "$container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$network" \
        -e SANDBOX_TEST_MODE=1 \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null

    for _ in $(seq 1 60); do
        # pgrep -x sleep also transiently matches entrypoint.sh's own `sleep
        # 0.5` (used for its ulogd readiness check) before the real, final
        # `sleep infinity` - harmless here, since by the time *either* sleep
        # runs, dns-proxy.sh/init-firewall.sh have already fully completed
        # (they're earlier, sequential steps under set -e).
        if docker exec "$container" pgrep -x sleep >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    echo "container never reached the post-entrypoint sleep - startup log:" >&2
    docker logs "$container" >&2
    return 1
}

teardown_file() {
    docker rm -f "$(container_name)" >/dev/null 2>&1 || true
    docker network rm "$(network_name)" >/dev/null 2>&1 || true
}

teardown() {
    docker rm -f "claude-sandbox-test-override-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rmi "claude-sandbox-test-override:$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-sshkey-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
}

dexec() {
    docker exec "$(container_name)" "$@"
}

dexec_node() {
    docker exec -u node "$(container_name)" "$@"
}

@test "the container's user actually matches overridden SANDBOX_USER/UID/GID/HOME build args, not just the defaults" {
    local test_image="claude-sandbox-test-override:$(basename "$BATS_FILE_TMPDIR")"
    local test_container="claude-sandbox-test-override-$(basename "$BATS_FILE_TMPDIR")"
    local sandbox_dir="$BATS_TEST_DIRNAME/../docker"
    local repo_root="$BATS_TEST_DIRNAME/.."

    docker build -q -t "$test_image" \
        --build-arg SANDBOX_USER=testuser \
        --build-arg SANDBOX_UID=1234 \
        --build-arg SANDBOX_GID=1234 \
        --build-arg SANDBOX_HOME=/home/testuser \
        -f "$sandbox_dir/Dockerfile" "$repo_root" >&2

    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        -e SANDBOX_TEST_MODE=1 \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$test_image" >/dev/null

    for _ in $(seq 1 60); do
        if docker exec "$test_container" pgrep -x sleep >/dev/null 2>&1; then break; fi
        sleep 1
    done

    run docker exec -u testuser "$test_container" whoami
    [ "$status" -eq 0 ]
    [ "$output" = "testuser" ]

    run docker exec -u testuser "$test_container" printenv HOME
    [ "$status" -eq 0 ]
    [ "$output" = "/home/testuser" ]

    run docker exec -u testuser "$test_container" id -u
    [ "$output" = "1234" ]
}

@test "a dedicated SANDBOX_SSH_KEY loads into its own in-container agent with no forwarded socket at all" {
    local key_dir test_container
    key_dir="$BATS_TEST_TMPDIR"
    ssh-keygen -t ed25519 -N '' -f "$key_dir/testkey" >/dev/null

    test_container="claude-sandbox-test-sshkey-$(basename "$BATS_FILE_TMPDIR")"
    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -v "$key_dir/testkey:/root/.ssh-sandbox-key-src:ro" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null

    for _ in $(seq 1 60); do
        if docker exec "$test_container" pgrep -x sleep >/dev/null 2>&1; then break; fi
        sleep 1
    done

    # A fresh `docker exec` is a sibling of PID 1, not a descendant of the
    # exec chain entrypoint.sh set SSH_AUTH_SOCK in, so it doesn't inherit
    # that export the way a real session's nvim/terminal children would
    # (nvim itself *is* that same process, continued via exec, not a
    # separate one) - read the value back out of PID 1's own environment
    # instead of assuming docker exec sees it.
    run docker exec -u node "$test_container" sh -c '
        export SSH_AUTH_SOCK=$(cat /proc/1/environ | tr "\0" "\n" | grep ^SSH_AUTH_SOCK= | cut -d= -f2-)
        ssh-add -l
    '
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run docker exec -u node "$test_container" test -e /home/node/.ssh/sandbox-key
    [ "$status" -ne 0 ]

    # The regression this guards against: /root/.ssh-sandbox-key-src is the
    # bind-mounted original, still present for the container's whole life
    # (unlike the deleted copy above, this can't be rm'd from inside). If
    # it were reachable by the sandbox user, that user's uid matching the
    # host's (see Dockerfile) would make the raw key directly readable,
    # defeating the point of only ever exposing it via the agent socket.
    run docker exec -u node "$test_container" cat /root/.ssh-sandbox-key-src
    [ "$status" -ne 0 ]
}

@test "IPv6 is fully blocked" {
    run dexec ip6tables -L OUTPUT -n
    [[ "$output" == *"policy DROP"* ]]
}

@test "a non-allowlisted domain is refused by the DNS proxy, not just left to fail later" {
    run dexec dig definitely-not-on-the-allowlist.example.org
    [[ "$output" == *"status: REFUSED"* ]]
}

@test "an allowlisted domain resolves via the DNS proxy" {
    run dexec dig +short api.anthropic.com
    [ -n "$output" ]
}

@test "a non-allowlisted destination is unreachable" {
    run dexec curl --connect-timeout 5 -s -o /dev/null https://example.com
    [ "$status" -ne 0 ]
}

@test "GitHub is reachable on port 443" {
    run dexec curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" https://api.github.com/zen
    [ "$status" -eq 0 ]
}

@test "GitHub is NOT reachable on port 22 (push transport is physically absent)" {
    run dexec timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22"
    [ "$status" -ne 0 ]
}

@test "ALLOW_GITHUB_PUSH=1 opens port 22 to GitHub" {
    local test_container="claude-sandbox-test-ghpush-$(basename "$BATS_FILE_TMPDIR")"
    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        -e SANDBOX_TEST_MODE=1 \
        -e ALLOW_GITHUB_PUSH=1 \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null

    for _ in $(seq 1 60); do
        if docker exec "$test_container" pgrep -x sleep >/dev/null 2>&1; then break; fi
        sleep 1
    done

    run docker exec "$test_container" timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22"
    [ "$status" -eq 0 ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
}

@test "node cannot run iptables directly" {
    run dexec_node iptables -L
    [ "$status" -ne 0 ]
}

@test "node cannot re-run init-firewall.sh to widen the allowlist" {
    run dexec_node /usr/local/bin/init-firewall.sh
    [ "$status" -ne 0 ]
}

@test "node has no working sudo" {
    # `run !` rather than checking $status: this fails with 127 (command
    # not found) today since sudo isn't installed at all, not some other
    # nonzero code - both are "no working sudo," and pinning to one exact
    # code would make the test brittle to which specific way that stays true.
    run ! dexec_node sudo -n true
}

@test "the real running node process has NET_ADMIN/NET_RAW stripped, not just the bounding set" {
    run dexec cat /proc/1/status
    [ "$status" -eq 0 ]
    cap_eff=$(echo "$output" | awk '/^CapEff:/ {print $2}')
    [ "$cap_eff" = "0000000000000000" ]
}

@test "ulogd2 runs as its own unprivileged user, not root" {
    run dexec ps -eo user,comm
    [[ "$output" == *"ulogd    ulogd"* ]] || [[ "$output" == *$'\nulogd '* ]]
    ! [[ "$output" == *$'\nroot     ulogd'* ]]
}

@test "the ipset stays in sync with fresh (non-cached) DNS answers, not just the boot-time snapshot" {
    ip=$(dexec dig +short pypi.org | head -1)
    [ -n "$ip" ]
    dexec ipset del allowed-domains "$ip"
    run dexec ipset test allowed-domains "$ip"
    [ "$status" -ne 0 ]

    # SIGHUP clears dnsmasq's answer cache, forcing a genuine upstream
    # re-forward on the next query instead of a cache hit - only a fresh
    # forward triggers dnsmasq's --ipset= tracking (see dns-proxy.sh).
    dexec bash -c 'kill -HUP "$(cat /var/run/dnsmasq-sandbox.pid)"'
    sleep 0.5
    dexec dig +short pypi.org >/dev/null
    sleep 0.5
    run dexec ipset test allowed-domains "$ip"
    [ "$status" -eq 0 ]
}

@test "Playwright/Chromium actually launches and renders, not just installs" {
    dexec_node bash -c 'cat > /tmp/pw-launch-test.js <<'"'"'EOF'"'"'
const { chromium } = require("playwright");
(async () => {
  const browser = await chromium.launch({});
  const page = await browser.newPage();
  await page.setContent("<h1>ok</h1>");
  const text = await page.textContent("h1");
  if (text !== "ok") throw new Error("unexpected content: " + text);
  await browser.close();
  console.log("PLAYWRIGHT_LAUNCH_OK");
})();
EOF'
    run dexec_node node /tmp/pw-launch-test.js
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLAYWRIGHT_LAUNCH_OK"* ]]
}

@test "the firewall applies to Playwright's browser traffic, not just curl/git" {
    # The whole point of pre-baking the browser at build time is that a
    # session never needs new network access for it - confirm the egress
    # allowlist actually governs what the browser itself can reach, the same
    # as every other tool in the container.
    dexec_node bash -c 'cat > /tmp/pw-firewall-test.js <<'"'"'EOF'"'"'
const { chromium } = require("playwright");
(async () => {
  const browser = await chromium.launch({});
  const page = await browser.newPage();
  try {
    await page.goto("http://example.com", { timeout: 5000 });
    console.log("REACHED_BLOCKED_DOMAIN");
  } catch (e) {
    console.log("BLOCKED_AS_EXPECTED");
  }
  await browser.close();
})();
EOF'
    run dexec_node node /tmp/pw-firewall-test.js
    [[ "$output" == *"BLOCKED_AS_EXPECTED"* ]]
    ! [[ "$output" == *"REACHED_BLOCKED_DOMAIN"* ]]
}
