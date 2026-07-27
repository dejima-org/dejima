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

# Every container this file starts must go on network_name(), never the
# default bridge: dns-proxy.sh forwards allowlisted names to Docker's
# embedded resolver at 127.0.0.11, which only exists on a user-defined
# network (compose gives the real sandbox one). On the default bridge the
# container gets the host's nameservers instead, dnsmasq has nowhere to
# forward, and startup dies in dns-proxy.sh - see its own check for this.
#
# Readiness is the *final* `sleep infinity` (entrypoint.sh's
# SANDBOX_TEST_MODE exec), matched exactly. A bare `pgrep -x sleep` also
# matches the short-lived sleeps of the startup sequence itself
# (dns-proxy.sh's dig-retry loop, entrypoint.sh's forwarder-bind wait), and
# a test that proceeds on one of those asserts against a container whose
# firewall hasn't been installed yet - which silently turns egress
# assertions into vacuous passes, since everything is still reachable at
# that point. Waiting for `sleep infinity` means the whole startup sequence
# (DNS proxy, firewall, ipsets, logging, forwarder bind) has completed.
wait_ready() {
    local container="$1"
    for _ in $(seq 1 60); do
        if docker exec "$container" pgrep -x -f 'sleep infinity' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "container $container never reached the post-entrypoint sleep - startup log:" >&2
    docker logs "$container" >&2
    return 1
}

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
        -e ANTHROPIC_BASE_URL= \
        -e ANTHROPIC_AUTH_TOKEN= \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null

    wait_ready "$container"
}

teardown_file() {
    docker rm -f "$(container_name)" >/dev/null 2>&1 || true
    docker network rm "$(network_name)" >/dev/null 2>&1 || true
}

teardown() {
    docker rm -f "claude-sandbox-test-override-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rmi "claude-sandbox-test-override:$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-sshkey-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-ghpush-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-claudejson-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-rebind-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-overlays-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-proxy-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-proxy-mask-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-statusline-regular-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-statusline-symlink-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-derived-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rmi "claude-sandbox-test-derived:$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
    docker rm -f "claude-sandbox-test-ctxreq-$(basename "$BATS_FILE_TMPDIR")" >/dev/null 2>&1 || true
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
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$test_image" >/dev/null

    wait_ready "$test_container"

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

    wait_ready "$test_container"

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

@test "~/.claude.json mount is a discarded per-session copy - a write inside the container never reaches the host source it was seeded from" {
    # In the real bin/claude-sandbox flow, the file mounted at
    # ~/.claude.json is always a *generated* per-session copy (see
    # SANDBOX_CLAUDE_JSON_FILE in bin/claude-sandbox), never the real
    # ~/.claude.json - so nothing written to it in the container, including
    # Claude Code's own atomic write-temp-then-rename on startup, can ever
    # reach the real file. host_copy here stands in for that real file: it's
    # seeded with the same content as the mounted file but never mounted
    # itself, so it can only change if something actually writes back to the
    # real source - which must not happen.
    local test_container="claude-sandbox-test-claudejson-$(basename "$BATS_FILE_TMPDIR")"
    local mounted_copy="$BATS_TEST_TMPDIR/claude.json"
    local host_copy="$BATS_TEST_TMPDIR/claude-json-original.json"

    echo '{"marker": "test-value"}' > "$mounted_copy"
    chmod 666 "$mounted_copy"
    cp "$mounted_copy" "$host_copy"

    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -v "$mounted_copy:/home/node/.claude.json" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null

    wait_ready "$test_container"

    # Simulate the write Claude Code itself does against this path at
    # startup (before login even completes - see docker-compose.yml's
    # comment on this mount).
    run docker exec -u node "$test_container" sh -c 'echo "{\"marker\": \"changed-by-container\"}" > $HOME/.claude.json'
    [ "$status" -eq 0 ]

    run docker exec -u node "$test_container" cat /home/node/.claude.json
    [[ "$output" == *"changed-by-container"* ]]

    run cat "$host_copy"
    [[ "$output" == *"test-value"* ]]
    [[ "$output" != *"changed-by-container"* ]]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
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
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -e ALLOW_GITHUB_PUSH=1 \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null

    wait_ready "$test_container"

    run docker exec "$test_container" timeout 5 bash -c "cat < /dev/null > /dev/tcp/github.com/22"
    [ "$status" -eq 0 ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
}

@test "GITEA_SSH_HOST is exempted from stop-dns-rebind, other allowed domains are not" {
    local test_container="claude-sandbox-test-rebind-$(basename "$BATS_FILE_TMPDIR")"
    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -e GITEA_SSH_HOST=gitea.internal.example \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null

    wait_ready "$test_container"

    run docker exec "$test_container" grep -c '^stop-dns-rebind$' /etc/dnsmasq-sandbox.conf
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]

    run docker exec "$test_container" grep 'rebind-domain-ok=/gitea.internal.example/' /etc/dnsmasq-sandbox.conf
    [ "$status" -eq 0 ]

    run docker exec "$test_container" grep 'rebind-domain-ok=/registry.npmjs.org/' /etc/dnsmasq-sandbox.conf
    [ "$status" -ne 0 ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
}

@test "the code-carrying ~/.claude overlay dirs are read-only inside the container" {
    local test_container="claude-sandbox-test-overlays-$(basename "$BATS_FILE_TMPDIR")"
    local src; src="$(mktemp -d)"
    mkdir -p "$src/skills" "$src/commands" "$src/agents"
    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -v "$src/skills:/home/node/.claude/skills:ro" \
        -v "$src/commands:/home/node/.claude/commands:ro" \
        -v "$src/agents:/home/node/.claude/agents:ro" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null
    wait_ready "$test_container"
    for d in skills commands agents; do
        run docker exec -u node "$test_container" bash -c "touch /home/node/.claude/$d/pwned 2>&1"
        [ "$status" -ne 0 ]
        [[ "$output" == *"Read-only file system"* ]]
    done
    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$src"
}

@test "statusline.sh read-only mount blocks replacement when it's a plain regular file" {
    # Companion to the overlay-dirs test above, but for bin/claude-sandbox's
    # narrower statusline.sh-onto-itself mount (see its comment there) rather
    # than a whole subdirectory. This test does NOT use bin/claude-sandbox or
    # docker-compose.yml directly - it builds the same mount shape by hand: a
    # whole ~/.claude directory bind-mounted read-write (docker-compose.yml's
    # own ~/.claude mount), with statusline.sh itself bind-mounted read-only
    # back onto its own path on top, source and destination the same literal
    # path exactly as bin/claude-sandbox constructs it (container HOME
    # matches host HOME - see Dockerfile). This shared container isn't reused
    # for this (it has no ~/.claude mount at all - see setup_file).
    local test_container="claude-sandbox-test-statusline-regular-$(basename "$BATS_FILE_TMPDIR")"
    local dotclaude; dotclaude="$(mktemp -d)"
    printf '#!/bin/sh\necho original\n' > "$dotclaude/statusline.sh"
    chmod +x "$dotclaude/statusline.sh"

    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -v "$dotclaude:/home/node/.claude" \
        -v "$dotclaude/statusline.sh:/home/node/.claude/statusline.sh:ro" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null
    wait_ready "$test_container"

    # A `rm` on a bind-mounted file fails from ordinary mount-point-busy
    # semantics regardless of the :ro flag, so `rm -f X && echo pwned > X`
    # alone doesn't prove anything about read-only enforcement - the `&&`
    # short-circuits before the write it was meant to test ever runs, so
    # this would pass identically even without `:ro`. The write that
    # actually depends on the read-only flag is an in-place overwrite that
    # never unlinks the file first.
    run docker exec -u node "$test_container" sh -c \
        'echo pwned > /home/node/.claude/statusline.sh'
    [ "$status" -ne 0 ]

    run docker exec -u node "$test_container" sh -c \
        'truncate -s 0 /home/node/.claude/statusline.sh'
    [ "$status" -ne 0 ]

    run docker exec -u node "$test_container" cat /home/node/.claude/statusline.sh
    [[ "$output" == *"original"* ]]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$dotclaude"
}

@test "statusline.sh read-only mount does NOT protect it when it's a symlink (Finding 1 - confirmed gap, see bin/claude-sandbox-audit)" {
    # Same mount shape as the plain-regular-file test above, except
    # statusline.sh on the host is a symlink into a separately-mounted
    # directory - the common real setup
    # (~/.claude/statusline.sh -> ~/dotfiles/statusline.sh). The parent
    # ~/.claude mount is established first (same order docker-compose.yml
    # uses), so by the time the more-specific statusline.sh mount below is
    # processed, the destination path already has that symlink sitting on
    # it - and bind-mount destination resolution (runc's SecureJoin) follows
    # symlinks within the rootfs. This CONFIRMS the mount resolves through
    # the symlink to the target directory (already read-only via the
    # separate target_dir mount below, mirroring bin/claude-sandbox's own
    # symlink-target scan) instead of binding to the symlink dentry itself -
    # so the symlink dentry stays a perfectly ordinary, writable entry on
    # the read-write ~/.claude mount, with no mountpoint-busy protection
    # either. This test is a characterization test of that CONFIRMED,
    # known, deliberately-documented limitation (see bin/claude-sandbox and
    # README "Security notes"), not an aspiration: it asserts the
    # replacement SUCCEEDS. The compensating control is detection, not
    # prevention - bin/claude-sandbox-audit hashes the symlink's target
    # string and reports a changed/repointed statusline.sh as a
    # host-code-execution finding after the session exits (see
    # test/audit.bats). If this test ever starts FAILING, that means
    # Docker/runc changed destination-symlink resolution and this gap may
    # have closed - that would be good news worth investigating and acting
    # on (tightening the comments/audit accordingly), not a regression to
    # "fix" back to the old behavior.
    local test_container="claude-sandbox-test-statusline-symlink-$(basename "$BATS_FILE_TMPDIR")"
    local target_dir dotclaude
    target_dir="$(mktemp -d)"
    printf '#!/bin/sh\necho original\n' > "$target_dir/statusline.sh"
    chmod +x "$target_dir/statusline.sh"
    dotclaude="$(mktemp -d)"
    ln -s "$target_dir/statusline.sh" "$dotclaude/statusline.sh"

    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -v "$dotclaude:/home/node/.claude" \
        -v "$target_dir:$target_dir:ro" \
        -v "$dotclaude/statusline.sh:/home/node/.claude/statusline.sh:ro" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null
    wait_ready "$test_container"

    run docker exec -u node "$test_container" sh -c \
        'rm -f /home/node/.claude/statusline.sh && echo pwned > /home/node/.claude/statusline.sh'
    [ "$status" -eq 0 ]

    run docker exec -u node "$test_container" cat /home/node/.claude/statusline.sh
    [[ "$output" == *"pwned"* ]]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$target_dir" "$dotclaude"
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

@test "empty ANTHROPIC_* env vars are unset before the session command runs" {
    # Compose always sends the pair (possibly empty); entrypoint.sh must
    # unset empties so a disabled proxy is indistinguishable from today.
    # /proc/1/environ is the post-entrypoint exec'd process's environment.
    # Must read as -u node (matching dexec's convention below): once
    # entrypoint.sh's gosu drops privilege, the kernel clears that
    # process's dumpable flag, and root (docker exec's default, lacking
    # CAP_SYS_PTRACE here) can no longer read another uid's environ at
    # all - reading as the same uid the process actually runs as is what
    # every other /proc/1/environ read in this file already does.
    run docker exec -u node "$(container_name)" sh -c "tr '\0' '\n' < /proc/1/environ | grep -c '^ANTHROPIC' || true"
    [ "$output" = "0" ]
}

@test "credential proxy chain: loopback -> forwarder -> unix socket -> host proxy injects the real token" {
    TD="$BATS_TEST_TMPDIR"
    python3 "$BATS_TEST_DIRNAME/fixtures/fake-anthropic.py" > "$TD/port" &
    FAKE_PID=$!
    for _ in $(seq 1 50); do [ -s "$TD/port" ] && break; sleep 0.1; done
    cat > "$TD/credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"real-access-token","refreshToken":"r","expiresAt":$((($(date +%s) + 7200) * 1000)),"refreshTokenExpiresAt":$((($(date +%s) + 86400) * 1000)),"scopes":[],"subscriptionType":"max","rateLimitTier":"default"}}
EOF
    "$BATS_TEST_DIRNAME/../bin/claude-sandbox-anthropic-proxy" \
        --socket "$TD/proxy.sock" --credentials "$TD/credentials.json" \
        --upstream "http://127.0.0.1:$(cat "$TD/port")" &
    PROXY_PID=$!
    for _ in $(seq 1 50); do [ -S "$TD/proxy.sock" ] && break; sleep 0.1; done

    container="claude-sandbox-test-proxy-$(basename "$BATS_FILE_TMPDIR")"
    docker run -d --name "$container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -e SANDBOX_ANTHROPIC_PROXY_SOCKET="$TD/proxy.sock" \
        -e ANTHROPIC_AUTH_TOKEN=sandbox-credential-proxy-placeholder \
        -v "$TD:$TD" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null
    # This test depends on the forwarder having already bound port 18300;
    # wait_ready covers that, since entrypoint.sh waits for the bind itself
    # before reaching the `sleep infinity` wait_ready matches on.
    wait_ready "$container"

    run docker exec "$container" node -e '
        fetch("http://127.0.0.1:18300/v1/messages", {method: "POST",
            headers: {authorization: "Bearer sandbox-credential-proxy-placeholder"},
            body: "{}"})
          .then(r => r.text()).then(t => { console.log(t); })
          .catch(e => { console.error(e); process.exit(1); })'
    status_chain=$status; output_chain=$output

    # the real token never appears in the container environment - read as
    # -u node, matching the test above: root can't see another uid's
    # environ once gosu has dropped privilege (dumpable flag cleared).
    run docker exec -u node "$container" sh -c "tr '\0' '\n' < /proc/1/environ | grep -c real-access-token || true"
    env_hits=$output

    docker rm -f "$container" >/dev/null 2>&1 || true
    kill "$PROXY_PID" "$FAKE_PID" 2>/dev/null || true

    [ "$status_chain" -eq 0 ]
    [[ "$output_chain" == *'"authorization": "Bearer real-access-token"'* ]]
    [[ "$output_chain" != *"sandbox-credential-proxy-placeholder"* ]]
    [ "$env_hits" = "0" ]
}

@test "credential mask: ~/.claude/.credentials.json in-container is empty, never the real token (the actual bin/claude-sandbox mask mechanism)" {
    # Unlike the proxy-chain test above (which hand-builds a docker run to
    # exercise the proxy's HTTP path), this test reuses the exact masking
    # mechanism bin/claude-sandbox itself uses at launch (see
    # SANDBOX_CREDENTIALS_MASK_FILE there): a real ~/.claude directory
    # bind-mounted read-write, with an empty file layered read-write on top
    # at .credentials.json specifically - the same "more specific mount wins"
    # trick as the other ~/.claude overlays. This is the check the design
    # spec asked for: the real credential file's content must never be
    # visible at that path inside the container.
    TD="$BATS_TEST_TMPDIR"
    mkdir -p "$TD/dotclaude"
    cat > "$TD/dotclaude/.credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"real-access-token","refreshToken":"real-refresh-token","expiresAt":$((($(date +%s) + 7200) * 1000)),"refreshTokenExpiresAt":$((($(date +%s) + 86400) * 1000)),"scopes":[],"subscriptionType":"max","rateLimitTier":"default"}}
EOF
    chmod -R 666 "$TD/dotclaude/.credentials.json"
    chmod 777 "$TD/dotclaude"
    mask_file="$TD/mask"
    : > "$mask_file"
    chmod 666 "$mask_file"

    container="claude-sandbox-test-proxy-mask-$(basename "$BATS_FILE_TMPDIR")"
    docker run -d --name "$container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -v "$TD/dotclaude:/home/node/.claude" \
        -v "$mask_file:/home/node/.claude/.credentials.json" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null
    wait_ready "$container"

    run docker exec -u node "$container" cat /home/node/.claude/.credentials.json
    status_creds=$status; output_creds=$output

    docker rm -f "$container" >/dev/null 2>&1 || true

    [ "$status_creds" -eq 0 ]
    [ -z "$output_creds" ]
    [[ "$output_creds" != *"real-access-token"* ]]
    [[ "$output_creds" != *"real-refresh-token"* ]]
}

@test "mid-session allowed domains get ongoing ipset tracking, not a one-time snapshot" {
    # Simulate the container-side half of bin/claude-sandbox-allow for a
    # domain that wasn't allowed at startup (SIGHUP also clears dnsmasq's
    # cache, so subsequent digs are really forwarded, not cached).
    # SIGHUP-to-reload is asynchronous - give dnsmasq a moment to actually
    # reload servers-file and flush its cache before digging (see the
    # existing "ipset stays in sync" test above for the same convention).
    dexec bash -c 'echo "server=/example.org/127.0.0.11" >> /etc/dnsmasq-sandbox-servers.conf && kill -HUP "$(cat /var/run/dnsmasq-sandbox.pid)"'
    sleep 0.5
    ip=$(dexec dig +short A example.org | grep -Em1 '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    sleep 0.5
    [ -n "$ip" ]
    # The resolution itself must have populated the ipset (wildcard ipset=).
    dexec ipset test allowed-domains "$ip"
    # Simulate a CDN edge rotating away and back: drop the IP, clear the
    # dnsmasq cache, resolve again - the wildcard must re-add it with no
    # claude-sandbox-allow involvement. This is exactly the case that used
    # to break ("allowed but blocked again minutes later").
    dexec ipset del allowed-domains "$ip"
    dexec bash -c 'kill -HUP "$(cat /var/run/dnsmasq-sandbox.pid)"'
    sleep 0.5
    ip2=$(dexec dig +short A example.org | grep -Em1 '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    sleep 0.5
    [ -n "$ip2" ]
    dexec ipset test allowed-domains "$ip2"
}

@test "github resolutions land only in github-domains, never the port-unrestricted allowed-domains" {
    # The wildcard ipset=/#/allowed-domains must NOT swallow GitHub names:
    # dnsmasq picks the longest matching ipset= domain, so the explicit
    # github-domains lines win, keeping GitHub restricted to port 443
    # (read-only; SSH push physically unreachable).
    ip=$(dexec dig +short A github.com | grep -Em1 '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    [ -n "$ip" ]
    run dexec ipset test allowed-domains "$ip"
    [ "$status" -ne 0 ]
    dexec ipset test github-domains "$ip"
}

@test "nvim falls back to the sandbox OSC 52 clipboard provider" {
    # nvim 0.11+'s OSC 52 auto-detection needs a DA1/XTGETTCAP terminal
    # handshake that never completes through the docker tty, leaving
    # "clipboard: No provider" for any config without its own provider.
    run dexec_node nvim --headless "+lua io.stdout:write(vim.g.clipboard and vim.g.clipboard.name or 'unset')" "+q"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sandbox-osc52"* ]]
}

@test "a user-configured clipboard provider beats the sandbox fallback" {
    # --cmd runs before plugins, standing in for a user config that sets
    # g:clipboard (e.g. dotfiles' clipboard-copy via SANDBOX_EXTRA_MOUNTS).
    run dexec_node nvim --headless \
        --cmd "lua vim.g.clipboard = {name = 'user-provider', copy = {}, paste = {}}" \
        "+lua io.stdout:write(vim.g.clipboard.name)" "+q"
    [ "$status" -eq 0 ]
    [[ "$output" == *"user-provider"* ]]
    [[ "$output" != *"sandbox-osc52"* ]]
}

@test "session context reports declared-but-missing project requirements" {
    local ws; ws="$(mktemp -d)"
    mkdir -p "$ws/.claude-sandbox"
    printf 'apt:definitely-not-installed\n' > "$ws/.claude-sandbox/dependencies"
    printf 'declared-not-allowed.example\n' > "$ws/.claude-sandbox/allowed-domains"
    chmod -R 755 "$ws"

    local test_container="claude-sandbox-test-ctxreq-$(basename "$BATS_FILE_TMPDIR")"
    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        -v "$ws:$ws" \
        -v "$BATS_TEST_DIRNAME/../hooks/sandbox-context.sh:/usr/local/bin/sandbox-context.sh:ro" \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$IMAGE" >/dev/null
    wait_ready "$test_container"

    # -w is deliberately an unrelated directory, not "$ws": if cwd extraction
    # from the payload broke and silently fell back to $PWD, running with
    # -w "$ws" would still find the declarations and pass regardless.
    run docker exec -u node -w /tmp "$test_container" \
        bash -c 'printf "{\"session_id\":\"s1\",\"cwd\":\"'"$ws"'\"}" | CLAUDE_SANDBOX=1 /usr/local/bin/sandbox-context.sh'
    [ "$status" -eq 0 ]
    [[ "$output" == *"definitely-not-installed"* ]]
    [[ "$output" == *"declared-not-allowed.example"* ]]
    [[ "$output" == *"claude-sandbox-project approve"* ]]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    rm -rf "$ws"
}

@test "a derived project image gets the package and keeps the base privilege posture" {
    local derived="claude-sandbox-test-derived:$(basename "$BATS_FILE_TMPDIR")"
    local test_container="claude-sandbox-test-derived-$(basename "$BATS_FILE_TMPDIR")"
    local ctx; ctx="$(mktemp -d)"
    local store; store="$(mktemp -d)"
    local df; df="$(mktemp)"
    printf 'apt:cowsay\n' > "$store/dependencies"
    bash -c 'source "$1"; generate_derived_dockerfile "$2" "$3"' \
        _ "$BATS_TEST_DIRNAME/../bin/claude-sandbox-project-lib.sh" "$IMAGE" "$store" > "$df"
    docker build -q -t "$derived" -f "$df" "$ctx" >&2

    # The image's own config, not the running container: `docker run` below
    # passes --entrypoint explicitly (this file's convention), which would
    # override the image's ENTRYPOINT and mask its absence - so that run
    # succeeding doesn't prove generate_derived_dockerfile's own ENTRYPOINT
    # line survived. Checked here, straight off the build.
    run docker inspect -f '{{json .Config.Entrypoint}}' "$derived"
    [[ "$output" == *"/usr/local/bin/entrypoint.sh"* ]]

    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$derived" >/dev/null
    wait_ready "$test_container"

    run docker exec "$test_container" dpkg-query -W -f='${Status}' cowsay
    [[ "$output" == *"install ok installed"* ]]

    # the hardening assertions that matter must hold on a derived image too
    run docker exec -u node "$test_container" sudo -n true
    [ "$status" -ne 0 ]
    run docker exec -u node "$test_container" iptables -L
    [ "$status" -ne 0 ]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    docker rmi "$derived" >/dev/null 2>&1 || true
    rm -rf "$ctx" "$store" "$df"
}

@test "a global dependency layer is shared: the project layer builds FROM it and the container gets both packages" {
    local global_tag="claude-sandbox-test-global:$(basename "$BATS_FILE_TMPDIR")"
    local derived="claude-sandbox-test-derived-global:$(basename "$BATS_FILE_TMPDIR")"
    local test_container="claude-sandbox-test-derived-global-$(basename "$BATS_FILE_TMPDIR")"
    local ctx; ctx="$(mktemp -d)"
    local global_store; global_store="$(mktemp -d)"
    local project_store; project_store="$(mktemp -d)"
    local global_df; global_df="$(mktemp)"
    local project_df; project_df="$(mktemp)"
    printf 'apt:cowsay\n' > "$global_store/dependencies"
    printf 'apt:sl\n' > "$project_store/dependencies"

    bash -c 'source "$1"; generate_derived_dockerfile "$2" "$3"' \
        _ "$BATS_TEST_DIRNAME/../bin/claude-sandbox-project-lib.sh" "$IMAGE" "$global_store" > "$global_df"
    docker build -q -t "$global_tag" -f "$global_df" "$ctx" >&2

    # The project layer builds FROM the global tag, not $IMAGE - this is the
    # layering bin/claude-sandbox does when both scopes have approved deps.
    bash -c 'source "$1"; generate_derived_dockerfile "$2" "$3"' \
        _ "$BATS_TEST_DIRNAME/../bin/claude-sandbox-project-lib.sh" "$global_tag" "$project_store" > "$project_df"
    docker build -q -t "$derived" -f "$project_df" "$ctx" >&2

    docker run -d --name "$test_container" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        --network "$(network_name)" \
        -e SANDBOX_TEST_MODE=1 \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "$derived" >/dev/null
    wait_ready "$test_container"

    run docker exec "$test_container" dpkg-query -W -f='${Status}' cowsay
    [[ "$output" == *"install ok installed"* ]]
    run docker exec "$test_container" dpkg-query -W -f='${Status}' sl
    [[ "$output" == *"install ok installed"* ]]

    docker rm -f "$test_container" >/dev/null 2>&1 || true
    docker rmi "$derived" "$global_tag" >/dev/null 2>&1 || true
    rm -rf "$ctx" "$global_store" "$project_store" "$global_df" "$project_df"
}

@test "live end-to-end: claude -p through the real proxy (RUN_LIVE_API=1 only)" {
    [ "${RUN_LIVE_API:-0}" = "1" ] || skip "set RUN_LIVE_API=1 to hit the real API"
    TD="$BATS_TEST_TMPDIR"
    "$BATS_TEST_DIRNAME/../bin/claude-sandbox-anthropic-proxy" \
        --socket "$TD/proxy.sock" --credentials "$HOME/.claude/.credentials.json" &
    PROXY_PID=$!
    for _ in $(seq 1 50); do [ -S "$TD/proxy.sock" ] && break; sleep 0.1; done
    SANDBOX_ANTHROPIC_PROXY_SOCKET="$TD/proxy.sock" SANDBOX_ANTHROPIC_PROXY_PORT=18399 \
        node "$BATS_TEST_DIRNAME/../docker/anthropic-proxy-forwarder.js" &
    FWD_PID=$!
    sleep 0.5
    run env ANTHROPIC_BASE_URL=http://127.0.0.1:18399 \
        ANTHROPIC_AUTH_TOKEN=sandbox-credential-proxy-placeholder \
        claude -p 'Reply with exactly: proxy-ok'
    kill "$PROXY_PID" "$FWD_PID" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"proxy-ok"* ]]
}
