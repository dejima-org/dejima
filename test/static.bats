#!/usr/bin/env bats
# Fast checks that don't need Docker: catch regressions in the security
# invariants that are visible directly in the repo's files, without paying
# for an image build + container boot. See runtime.bats for everything that
# actually needs a live container.

setup() {
    SANDBOX_DIR="$BATS_TEST_DIRNAME/../docker"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
}

@test "Dockerfile never installs sudo" {
    run grep -E '^\s*sudo\s*\\?\s*$' "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ]
}

@test "Dockerfile never creates a sudoers entry" {
    run grep -i "sudoers" "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ]
}

@test "Dockerfile creates a SANDBOX_USER matching the host user, not a hardcoded node" {
    grep -qE '^ARG SANDBOX_USER=node\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ARG SANDBOX_UID=1000\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ARG SANDBOX_GID=1000\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ARG SANDBOX_HOME=/home/node\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -q 'useradd -u "$SANDBOX_UID" -g "$SANDBOX_GID" -m -d "$SANDBOX_HOME"' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ENV SANDBOX_USER=\$SANDBOX_USER\s*$' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^ENV SANDBOX_HOME=\$SANDBOX_HOME\s*$' "$SANDBOX_DIR/Dockerfile"
    # No literal "USER node" anywhere - the mid-build USER switch must use
    # the parametrized variable, not the old hardcoded name.
    run grep -E '^USER\s+node\s*$' "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ]
    grep -qE '^USER\s+\$SANDBOX_USER\s*$' "$SANDBOX_DIR/Dockerfile"
}

@test "entrypoint.sh drops privilege via SANDBOX_USER, not a literal node" {
    run grep -E 'gosu node\b' "$SANDBOX_DIR/entrypoint.sh"
    [ "$status" -ne 0 ]
    grep -q 'gosu "$SANDBOX_USER"' "$SANDBOX_DIR/entrypoint.sh"
}

@test "Playwright is installed and require()-able globally" {
    # A global npm install only puts the CLI on PATH, not the module on
    # Node's require() resolution path - NODE_PATH is what makes
    # require("playwright") work from any script, not just one with its own
    # local node_modules (see runtime.bats for the actual launch test).
    grep -q 'npm install -g playwright' "$SANDBOX_DIR/Dockerfile"
    grep -qE '^\s*ENV\s+NODE_PATH=' "$SANDBOX_DIR/Dockerfile"
}

@test "every ipset add in init-firewall.sh is duplicate-safe" {
    # Same bug class that broke firewall startup twice (718f6b7, a86fefc):
    # ipset add without -exist errors on a duplicate entry, and set -e turns
    # that into the whole firewall - and thus the whole container - failing
    # to start with no clear error surfaced to the user. Every "ipset add"
    # line must either pass -exist or already be wrapped so a failure can't
    # propagate (e.g. `|| true`).
    while IFS= read -r line; do
        case "$line" in
            *-exist*) continue ;;
            *"|| true"*) continue ;;
        esac
        echo "unsafe ipset add: $line"
        return 1
    done < <(grep "ipset add" "$SANDBOX_DIR/init-firewall.sh")
}

@test "docker-compose.yml runs an init so orphaned processes get reaped" {
    # Without this the session's own command is PID 1 and never reaps, so
    # leaked children accumulate as zombies until the pids cgroup is full
    # and the container cannot fork - see the comment on the init: line.
    grep -qE '^\s*init:\s*true\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "docker-compose.yml never mounts the Docker socket" {
    run grep -i "docker.sock" "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml never mounts host SSH/cloud credential directories" {
    # Anchored to the *source* side of a mount (right after the leading
    # "- ") - the container's own $HOME legitimately contains .ssh/known_hosts
    # as a *destination* path now that it mirrors the host's $HOME, which
    # isn't the same thing as mounting the host's real ~/.ssh directory in.
    run grep -E '^\s*-\s*\$\{HOME\}/\.(ssh|aws|gcloud|azure)(/|:)' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "~/.claude settings/CLAUDE.md/plugins are layered read-only over the read-write parent mount" {
    grep -qE '^\s*-\s*\$\{HOME\}/\.claude:\$\{HOME\}/\.claude\s*$' "$SANDBOX_DIR/docker-compose.yml"
    # settings.json specifically comes from a generated $SANDBOX_SETTINGS_FILE
    # (see below), not the real file directly - it still has to be read-only
    # in the container, just from a different, sandbox-specific source.
    grep -qE '^\s*-\s*\$\{SANDBOX_SETTINGS_FILE.*\}:\$\{HOME\}/\.claude/settings\.json:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*-\s*\$\{HOME\}/\.claude/CLAUDE\.md:.*:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*-\s*\$\{HOME\}/\.claude/plugins:.*:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "~/.claude/hooks is layered read-only over the read-write parent mount" {
    # Same persistence-path rationale as the settings/CLAUDE.md/plugins
    # overlay above, but for the directory install.sh's hook symlinks live
    # in - see docker-compose.yml's comment on this mount line. Without
    # this, a compromised session can unlink a hook symlink and drop a
    # plain malicious file in its place, which the dynamic-mount logic in
    # bin/dejima never sees (it only protects symlink targets that
    # resolve outside ~/.claude).
    grep -qE '^\s*-\s*\$\{HOME\}/\.claude/hooks:\$\{HOME\}/\.claude/hooks:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "~/.claude.json is a throwaway per-session copy, not the real file mounted directly" {
    # A plain read-only mount hangs Claude Code on startup (it does an
    # atomic write-temp-then-rename against this file even before login) -
    # the fix is a generated, discarded copy, not read-only. See
    # bin/dejima and README "Throwaway ~/.claude.json".
    grep -qE '^\s*-\s*\$\{SANDBOX_CLAUDE_JSON_FILE.*\}:\$\{HOME\}/\.claude\.json\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -q 'mktemp.*dejima-claude-json' "$REPO_ROOT/bin/dejima"
    grep -q 'rm -f "\$SANDBOX_SETTINGS_FILE" "\$SANDBOX_CLAUDE_JSON_FILE"' "$REPO_ROOT/bin/dejima"
}

@test "gitconfig is a throwaway copy in its own directory, not a single-file mount" {
    # entrypoint.sh's `gh auth setup-git` writes a credential-helper entry
    # via git's write-temp-then-rename pattern, which fails with "Device or
    # resource busy" on a single-file bind mount at ~/.gitconfig directly -
    # a real regression this guards against (Linux won't let a bind mount's
    # backing inode be replaced, only a file *within* a mounted directory
    # can be freely renamed over). Must be a directory mount, with
    # GIT_CONFIG_GLOBAL pointing git at the file inside it.
    grep -qE '^\s*-\s*\$\{SANDBOX_GITCONFIG_DIR.*\}:\$\{HOME\}/\.gitconfig-sandbox\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*GIT_CONFIG_GLOBAL:\s*\$\{HOME\}/\.gitconfig-sandbox/\.gitconfig\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -q 'mktemp -d.*gitconfig' "$REPO_ROOT/bin/dejima"
}

@test "docker-compose.yml never hardcodes /home/node - the container home is host-parametrized" {
    # ${HOME:-/home/node} (the SANDBOX_HOME build arg's own default value,
    # mirroring the Dockerfile's default) is the one legitimate exception -
    # it's a fallback expression, not a hardcoded container path.
    run bash -c "grep -v '^\s*#' '$SANDBOX_DIR/docker-compose.yml' | grep -v '\${HOME:-/home/node}' | grep '/home/node'"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml builds with a per-user image tag and passes the host identity as build args" {
    grep -qE '^\s*image:\s*\$\{SANDBOX_IMAGE:-dejima:\$\{SANDBOX_USER:-node\}\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_USER:\s*\$\{SANDBOX_USER:-node\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_UID:\s*\$\{SANDBOX_UID:-1000\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_GID:\s*\$\{SANDBOX_GID:-1000\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_HOME:\s*\$\{HOME:-/home/node\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "bin/dejima exports the host user identity for the build" {
    grep -q 'SANDBOX_USER="$(id -un)"' "$REPO_ROOT/bin/dejima"
    grep -q 'SANDBOX_UID="$(id -u)"' "$REPO_ROOT/bin/dejima"
    grep -q 'SANDBOX_GID="$(id -g)"' "$REPO_ROOT/bin/dejima"
}

@test "docker-compose.yml never hardcodes a dotfiles (or any other specific repo) mount" {
    # Hook-symlink targets are discovered dynamically at launch by
    # bin/dejima instead - see the next test. A hardcoded path here
    # would silently break for anyone whose hooks live somewhere else.
    run grep -i 'dotfiles' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "bin/dejima dynamically discovers and mounts hook-symlink targets" {
    grep -q 'readlink -f "\$entry"' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "\$real_dir:\$real_dir:ro")' "$REPO_ROOT/bin/dejima"
    grep -q '"\${extra_mounts\[@\]}"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima layers a writable lazy-lock.json over the read-only nvim config mount" {
    # SANDBOX_NVIM_CONFIG is mounted :ro, but lazy.nvim writes its lockfile
    # back into that same directory on every plugin sync - without this
    # overlay, that write fails with a read-only-filesystem error and the
    # sync aborts (a real bug: plugins never finish installing, so a
    # config's colorscheme fallback kicks in instead of the real one).
    grep -q 'mktemp.*dejima-nvim-lock' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "\$SANDBOX_NVIM_LOCKFILE:\$HOME/\.config/nvim/lazy-lock\.json")' "$REPO_ROOT/bin/dejima"
    grep -q 'rm -f .*"\${SANDBOX_NVIM_LOCKFILE:-}"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima mounts SANDBOX_EXTRA_MOUNTS entries read-only at their own path" {
    grep -q 'IFS=.:. read -ra extra_paths <<< "\$SANDBOX_EXTRA_MOUNTS"' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "\$path:\$path:ro")' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima forces sandbox.enabled to false in the generated settings.json" {
    # Claude Code's own internal per-command sandboxing is redundant on top
    # of this container and can't actually function inside it (bwrap can't
    # create a namespace here) - settings.json is read-only precisely so it
    # can't be patched from inside, so this has to happen in the generation
    # step on the host, before the container starts.
    grep -qE '\.sandbox\.enabled\s*=\s*false' "$REPO_ROOT/bin/dejima"
}

@test "Dockerfile never installs bubblewrap or socat" {
    # Nothing needs them now that sandbox.enabled is forced off - if they
    # come back, it's worth asking why before just re-adding them.
    run grep -E '^\s*(bubblewrap|socat)\s*\\?\s*$' "$SANDBOX_DIR/Dockerfile"
    [ "$status" -ne 0 ]
}

@test "sandbox-context.sh never tells the agent to worktree outside the mounted project" {
    # ../<branch> (a sibling of the mounted project) or anything under $HOME
    # lands in container-local ephemeral storage, not real host storage -
    # the worktree, and whatever work went into it, silently vanishes when
    # the session ends. Regression check for exactly this bug.
    run grep -E '(worktree add|git worktree)[^\\n]*\.\./' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -ne 0 ]
    grep -q '.worktrees/' "$REPO_ROOT/hooks/sandbox-context.sh"
}

@test "entrypoint runs as root and drops to node via gosu, not a baked-in USER node" {
    # The whole privilege-drop model depends on entrypoint.sh itself starting
    # as root (to set up the firewall) - a stray `USER node` before
    # ENTRYPOINT would silently break that.
    run tail -n 5 "$SANDBOX_DIR/Dockerfile"
    [[ "$output" == *"ENTRYPOINT"* ]]
    ! grep -qE '^\s*USER\s+node\s*$' <(tail -n 8 "$SANDBOX_DIR/Dockerfile")
}

@test "bin/dejima and bin/dejima-allow resolve their own location through symlinks" {
    # install.sh symlinks both into ~/.local/bin so they can be run by name
    # via PATH. A bare `dirname "${BASH_SOURCE[0]}"` (no readlink -f first)
    # resolves against the symlink's own directory in that case, not this
    # repo's real bin/ - a real bug hit on first use: dejima tried
    # to open ~/.local/docker/docker-compose.yml instead of this repo's.
    grep -q 'dirname "\$(readlink -f "\${BASH_SOURCE\[0\]}")"' "$REPO_ROOT/bin/dejima"
    grep -q 'dirname "\$(readlink -f "\${BASH_SOURCE\[0\]}")"' "$REPO_ROOT/bin/dejima-allow"
}

@test "bin/dejima-allow rejects a domain with shell metacharacters" {
    run "$REPO_ROOT/bin/dejima-allow" 'evil.com;touch /tmp/pwned'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not a valid domain"* ]]
}

@test "bin/dejima-allow rejects a domain with a slash (dnsmasq server= delimiter)" {
    run "$REPO_ROOT/bin/dejima-allow" 'evil.com/../etc'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not a valid domain"* ]]
}

@test "bin/dejima-allow accepts a well-formed domain (passes validation)" {
    # --container points at a name that can't exist, so this can *never*
    # reach a real running dejima session (and mutate its live
    # firewall) even if the machine running this test happens to have one -
    # it must fail at "container not found", not at validation.
    run "$REPO_ROOT/bin/dejima-allow" 'crates.io' --container dejima-test-suite-nonexistent-target
    [ "$status" -ne 0 ]
    [[ "$output" != *"Not a valid domain"* ]]
}

@test "the dedicated SSH key mount is optional, not a hard requirement" {
    grep -qE '^\s*-\s*\$\{SANDBOX_SSH_KEY_FILE:-/dev/null\}:/root/\.ssh-sandbox-key-src:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*-\s*\$\{SSH_AUTH_SOCK:-/dev/null\}:/ssh-agent\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "the dedicated SSH key source is mounted under /root, not the sandbox user's home" {
    # A mount under \$SANDBOX_HOME would be readable by the sandbox user
    # directly, since its uid now matches the host user's (see Dockerfile) -
    # /root is only reachable by root, which is all that should ever read
    # this file (see entrypoint.sh).
    run grep -E '\.ssh-sandbox-key-src' "$SANDBOX_DIR/docker-compose.yml"
    [[ "$output" != *'${HOME}'* ]]
    run grep -F 'SANDBOX_SSH_KEY_SRC=' "$SANDBOX_DIR/entrypoint.sh"
    [[ "$output" != *'SANDBOX_HOME'* ]]
    grep -qF 'SANDBOX_SSH_KEY_SRC="/root/.ssh-sandbox-key-src"' "$SANDBOX_DIR/entrypoint.sh"
}

@test "entrypoint.sh deletes the plaintext dedicated-key copy after loading it into the agent" {
    grep -q 'gosu "$SANDBOX_USER" ssh-add' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'rm -f "$SANDBOX_HOME/.ssh/sandbox-key"' "$SANDBOX_DIR/entrypoint.sh"
    ssh_add_line=$(grep -n 'gosu "$SANDBOX_USER" ssh-add' "$SANDBOX_DIR/entrypoint.sh" | head -1 | cut -d: -f1)
    rm_line=$(grep -n 'rm -f "$SANDBOX_HOME/.ssh/sandbox-key"' "$SANDBOX_DIR/entrypoint.sh" | head -1 | cut -d: -f1)
    [ "$rm_line" -gt "$ssh_add_line" ]
}

@test "bin/dejima allows a dedicated SANDBOX_SSH_KEY in place of a forwarded agent" {
    grep -q 'SANDBOX_SSH_KEY' "$REPO_ROOT/bin/dejima"
    grep -q 'export SANDBOX_SSH_KEY_FILE' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima warns when SANDBOX_SSH_KEY looks like a default personal key" {
    grep -q 'looks like a default personal SSH key' "$REPO_ROOT/bin/dejima"
    run grep -E '^\s*id_rsa\|id_ecdsa\|id_ed25519\|id_dsa\|id_ecdsa_sk\|id_ed25519_sk\)\s*$' "$REPO_ROOT/bin/dejima"
    [ "$status" -eq 0 ]
}

@test "init-firewall.sh sends GH_TOKEN on its GitHub API fetch when one is set" {
    # Unauthenticated /meta is capped at 60 requests/hour per source IP,
    # shared across every container start; exhausting it fails the launch.
    grep -q 'gh_auth=(-H "Authorization: Bearer \$GH_TOKEN")' "$SANDBOX_DIR/init-firewall.sh"
    grep -q 'curl -s \${gh_auth\[@\]+"\${gh_auth\[@\]}"} https://api.github.com/meta' "$SANDBOX_DIR/init-firewall.sh"
}

@test "ALLOW_GITHUB_PUSH defaults to 0 everywhere it's read" {
    grep -qE '^\s*ALLOW_GITHUB_PUSH:\s*\$\{ALLOW_GITHUB_PUSH:-0\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -q '\${ALLOW_GITHUB_PUSH:-0}' "$SANDBOX_DIR/init-firewall.sh"
    grep -q '\${ALLOW_GITHUB_PUSH:-0}' "$REPO_ROOT/hooks/git-push-guard.sh"
}

@test "init-firewall.sh only opens port 22 to GitHub inside the ALLOW_GITHUB_PUSH conditional" {
    # The unconditional port-443-only rule must still be present unchanged;
    # the port-22 rule must only appear inside the new if-block, never as a
    # second unconditional rule alongside it.
    grep -q -- '-A OUTPUT -p tcp --dport 443 -m set --match-set github-domains dst -j ACCEPT' "$SANDBOX_DIR/init-firewall.sh"
    port22_line=$(grep -n -- '-A OUTPUT -p tcp --dport 22 -m set --match-set github-domains dst -j ACCEPT' "$SANDBOX_DIR/init-firewall.sh" | cut -d: -f1)
    [ -n "$port22_line" ]
    if_line=$(grep -n 'ALLOW_GITHUB_PUSH:-0.*=.*1' "$SANDBOX_DIR/init-firewall.sh" | head -1 | cut -d: -f1)
    [ -n "$if_line" ]
    [ "$port22_line" -gt "$if_line" ]
}

@test "git-push-guard.sh still blocks direct pushes to main/master when ALLOW_GITHUB_PUSH=1" {
    # The host-allowlist widening must not touch the separate branch check.
    grep -q 'branch" = "main"\|branch" = "master"' "$REPO_ROOT/hooks/git-push-guard.sh"
}

@test "gitea-pr never passes the token as a command-line argument" {
    # /proc makes argv world-readable, so a token in a curl invocation is
    # visible to every other process for the life of the request - and this
    # runs alongside agents that read process listings.
    run grep -n 'curl.*Authorization: token' "$REPO_ROOT/bin/gitea-pr"
    [ "$status" -ne 0 ]
    grep -q 'curl -sS -w .*-K -' "$REPO_ROOT/bin/gitea-pr"
}

@test "dns-proxy.sh enables dnsmasq's stop-dns-rebind protection" {
    grep -qE '^stop-dns-rebind\s*$' "$SANDBOX_DIR/dns-proxy.sh"
    grep -q 'rebind-domain-ok=/\$domain/' "$SANDBOX_DIR/dns-proxy.sh"
}

@test "dns-proxy.sh refuses to start without Docker's embedded resolver, rather than falling back" {
    # The allowlist only works because every forward goes to 127.0.0.11 on
    # loopback; init-firewall.sh has no egress rule for UDP/53 anywhere else
    # on purpose. Resolving via the host's nameservers instead would be an
    # unrestricted-destination DNS channel, so absence must be fatal.
    grep -q "nameserver.*127\\\\.0\\\\.0\\\\.11" "$SANDBOX_DIR/dns-proxy.sh"
    grep -q '/etc/resolv.conf' "$SANDBOX_DIR/dns-proxy.sh"
}

@test "IPv6 blocking fails loud instead of silently swallowing errors once ip6tables is confirmed usable" {
    run grep -E 'ip6tables -P (INPUT|OUTPUT|FORWARD) DROP 2>/dev/null \|\| true' "$SANDBOX_DIR/init-firewall.sh"
    [ "$status" -ne 0 ]
    grep -q 'ip6tables -L >/dev/null 2>&1' "$SANDBOX_DIR/init-firewall.sh"
}

@test "~/.claude skills/commands/agents/output-styles are layered read-only over the read-write parent mount" {
    # Same persistence-path rationale as the hooks overlay: these carry
    # executable skill scripts / injectable command, agent, and output-style
    # prompts that a later unsandboxed host session would run or load.
    # Without an overlay (and without pre-creation, since they may not
    # exist) a compromised session can create and populate them.
    grep -qE '^\s*-\s*\$\{HOME\}/\.claude/skills:\$\{HOME\}/\.claude/skills:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*-\s*\$\{HOME\}/\.claude/commands:\$\{HOME\}/\.claude/commands:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*-\s*\$\{HOME\}/\.claude/agents:\$\{HOME\}/\.claude/agents:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*-\s*\$\{HOME\}/\.claude/output-styles:\$\{HOME\}/\.claude/output-styles:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "bin/dejima pre-creates the code-carrying ~/.claude overlay dirs" {
    grep -q 'mkdir -p "$HOME/.claude/skills" "$HOME/.claude/commands" "$HOME/.claude/agents" "$HOME/.claude/output-styles"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima overlays the workspace .git/hooks read-only when .git is a real dir" {
    grep -q 'if \[ -d "$WORKSPACE_DIR/.git/hooks" \]' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "$WORKSPACE_DIR/.git/hooks:$WORKSPACE_DIR/.git/hooks:ro")' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima reads allowed domains only from the approval store" {
    [ ! -e "$REPO_ROOT/config/env" ]
    [ ! -e "$REPO_ROOT/bin/dejima-env.sh" ]
    run grep -n 'config/env\|dejima-env' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
    grep -q 'ALLOWED_DOMAINS="$(approved_entries "$(config_root)" allowed-domains' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima snapshots before the run and compares after" {
    grep -q '"$SCRIPT_DIR/dejima-audit" snapshot "$WORKSPACE_DIR"' "$REPO_ROOT/bin/dejima"
    grep -q '"$SCRIPT_DIR/dejima-audit" compare "$WORKSPACE_DIR"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima warns when the workspace is this repo itself (TCB self-mount)" {
    grep -q 'sandbox.s own repo' "$REPO_ROOT/bin/dejima" || \
    grep -q 'TCB' "$REPO_ROOT/bin/dejima"
}

@test "compose carries the credential-proxy env plumbing, empty by default" {
    grep -qE '^\s*ANTHROPIC_BASE_URL:\s*\$\{SANDBOX_ANTHROPIC_BASE_URL:-\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*ANTHROPIC_AUTH_TOKEN:\s*\$\{SANDBOX_ANTHROPIC_AUTH_TOKEN:-\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_ANTHROPIC_PROXY_SOCKET:\s*\$\{SANDBOX_ANTHROPIC_PROXY_SOCKET:-\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "the forwarder is baked into the image and started by the entrypoint when a socket is set" {
    grep -q 'COPY docker/anthropic-proxy-forwarder.js /usr/local/bin/anthropic-proxy-forwarder.js' "$SANDBOX_DIR/Dockerfile"
    grep -q 'if \[ -n "\${SANDBOX_ANTHROPIC_PROXY_SOCKET:-}" \]' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'gosu "\$SANDBOX_USER" node /usr/local/bin/anthropic-proxy-forwarder.js' "$SANDBOX_DIR/entrypoint.sh"
}

@test "entrypoint unsets empty ANTHROPIC_* vars so a disabled proxy changes nothing" {
    grep -q 'unset ANTHROPIC_BASE_URL' "$SANDBOX_DIR/entrypoint.sh"
    grep -q 'unset ANTHROPIC_AUTH_TOKEN' "$SANDBOX_DIR/entrypoint.sh"
}

@test "bin/dejima's exit-time audit still runs when the container run fails or is interrupted" {
    local run_line
    run_line=$(grep -n 'docker compose .* run --rm' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$run_line" ]
    # The compose invocation must not be a bare command under set -e - a
    # nonzero/interrupted exit there would otherwise abort the script before
    # the audit compare and exit below ever run.
    grep -q '|| compose_status=\$?' <(sed -n "${run_line}p" "$REPO_ROOT/bin/dejima")
    sed -n "1,${run_line}p" "$REPO_ROOT/bin/dejima" | grep -q 'compose_status=0'
    tail -n "+$run_line" "$REPO_ROOT/bin/dejima" | grep -q '"\$SCRIPT_DIR/dejima-audit" compare "\$WORKSPACE_DIR"'
    tail -n "+$run_line" "$REPO_ROOT/bin/dejima" | grep -q 'exit "\$compose_status"'
}

@test "credential proxy is on by default, gated only by SANDBOX_CREDENTIAL_PROXY=0" {
    grep -q '"\${SANDBOX_CREDENTIAL_PROXY:-1}" != "0"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima masks the credentials file and mounts the proxy socket dir" {
    # The mask is what keeps the real token out of the (otherwise read-write)
    # ~/.claude mount; the socket dir is how API traffic gets back out to the
    # host-side proxy that holds the real credential.
    grep -q 'mktemp.*dejima-credentials-mask' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "\$SANDBOX_CREDENTIALS_MASK_FILE:\$HOME/\.claude/\.credentials\.json")' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "\$SANDBOX_ANTHROPIC_PROXY_DIR:\$SANDBOX_ANTHROPIC_PROXY_DIR:ro")' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima also masks the proxy's write-back staging subdirectory" {
    # _write() in bin/dejima-anthropic-proxy stages the rotated
    # credential in ~/.claude/.credentials-proxy-tmp before the atomic
    # rename - that subdirectory is inside the otherwise read-write ~/.claude
    # mount, so without its own mask a sibling temp file would be
    # container-readable for the whole write window (see proxy.bats).
    grep -q 'mktemp -d.*dejima-credentials-tmpdir-mask' "$REPO_ROOT/bin/dejima"
    grep -q 'extra_mounts+=(-v "\$SANDBOX_CREDENTIALS_TMPDIR_MASK:\$HOME/\.claude/\.credentials-proxy-tmp:ro")' "$REPO_ROOT/bin/dejima"
    grep -q '"\${SANDBOX_CREDENTIALS_TMPDIR_MASK:-}"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima refuses to launch when the proxy fails to start" {
    # Falling back to mounting the real credential would be a silent
    # security downgrade - the failure must be loud and the launch aborted.
    grep -q 'Credential proxy failed to start' "$REPO_ROOT/bin/dejima"
    grep -q 'SANDBOX_CREDENTIAL_PROXY=0' "$REPO_ROOT/bin/dejima"
}

@test "cleanup reaps the proxy and its socket dir and mask file" {
    grep -q 'kill "\$SANDBOX_ANTHROPIC_PROXY_PID"' "$REPO_ROOT/bin/dejima"
    grep -q '"\${SANDBOX_CREDENTIALS_MASK_FILE:-}"' "$REPO_ROOT/bin/dejima"
    grep -q '"\${SANDBOX_ANTHROPIC_PROXY_DIR:-}"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima warns if the proxy died before the session ended" {
    grep -q 'credential proxy exited before' "$REPO_ROOT/bin/dejima"
}

@test "docker-compose.yml pins the compose project name so dejima-allow's label filter matches" {
    # bin/dejima-allow discovers running sandboxes via the
    # com.docker.compose.project=dejima label; without an explicit
    # top-level name, compose derives the project from the compose file's
    # directory ("docker"), which varies by checkout and breaks discovery.
    grep -qE '^name: dejima\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "sandbox-context.sh gives the agent its own container ID for dejima-allow" {
    # Agents used to guess their container ID and could hand back another
    # running sandbox's ID, making dejima-allow "succeed" against
    # the wrong container. /etc/hostname inside a container is its real ID.
    grep -q '/etc/hostname' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q -- '--container' "$REPO_ROOT/hooks/sandbox-context.sh"
}

@test "bin/dejima-allow ends with a real reachability check, not just config changes" {
    # "It said allowed but the sandbox still can't reach it" was a real
    # failure mode (wrong container targeted / stale ipset) - the script
    # must verify from inside the target container and say so definitively.
    grep -q 'connect-timeout' "$REPO_ROOT/bin/dejima-allow"
    grep -q 'Verified:' "$REPO_ROOT/bin/dejima-allow"
    grep -q 'NOT reachable' "$REPO_ROOT/bin/dejima-allow"
}

@test "bin/dejima-allow's multi-container error points at the sandbox's own ID" {
    grep -q '/etc/hostname' "$REPO_ROOT/bin/dejima-allow"
}

@test "bin/dejima-allow --global no longer rewrites config/env" {
    # --global persists to the host-side approval store now (Task 3); the old
    # sed -i rewrite of config/env's ALLOWED_DOMAINS is gone for good.
    run grep -F 'config/env' "$REPO_ROOT/bin/dejima-allow"
    [ "$status" -ne 0 ]
    run grep -F 'sed -i' "$REPO_ROOT/bin/dejima-allow"
    [ "$status" -ne 0 ]
}

@test "bin/dejima mounts targets of top-level ~/.claude symlinks (statusline.sh)" {
    # settings.json's statusLine points at ~/.claude/statusline.sh, which on
    # this setup is a symlink into dotfiles - previously only the five
    # overlay subdirectories were scanned for symlinks, so the target dir
    # never got mounted and the statusline silently died in the sandbox.
    grep -q 'for overlay_dir in \. hooks skills commands agents output-styles' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima mounts ~/.claude/statusline.sh itself read-only, when present" {
    # statusline.sh is a top-level file directly on the read-write ~/.claude
    # mount (unlike settings.json/CLAUDE.md/plugins/hooks/skills/commands/
    # agents/output-styles, none of which have this gap) - settings.json's
    # statusLine.command points at it and Claude Code executes it on the
    # host. Mounting a symlink's *target* dir read-only (the test above)
    # doesn't help: the symlink/file at ~/.claude/statusline.sh itself still
    # lives on the writable mount and a compromised session can unlink it and
    # drop its own script in its place. Must be conditional on existence
    # (not every host has a statusline, and mounting a nonexistent source
    # would make Docker create a root-owned directory at the target
    # instead).
    grep -q 'extra_mounts+=(-v "\$HOME/\.claude/statusline\.sh:\$HOME/\.claude/statusline\.sh:ro")' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima refuses to launch rather than silently skip a dangling statusline.sh symlink" {
    # Plain -e follows symlinks and is false for a *dangling* one (target
    # doesn't exist, e.g. a dotfiles checkout that isn't present) - silently
    # skipping the mount in that case would reopen the exact gap the test
    # above closes. Docker also can't just attempt the mount anyway: it fails
    # deep in mount setup with an opaque "mkdir ...: file exists" (the
    # symlink already occupies that path), unconnected to the statusline for
    # the user. So this must be a hard, explicit error - same fail-loud
    # precedent as the credential proxy refusing to launch rather than
    # silently mounting the real OAuth credential.
    grep -q 'if \[ -L "\$HOME/\.claude/statusline\.sh" \] && \[ ! -e "\$HOME/\.claude/statusline\.sh" \]' "$REPO_ROOT/bin/dejima"
    grep -q "Docker can't bind-mount a dangling symlink" "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima-audit monitors the home-level ~/.claude/statusline.sh (Finding 1 compensating control)" {
    # The read-only mount above does not reliably protect statusline.sh when
    # it's a symlink (confirmed live-container gap - see test/runtime.bats
    # and bin/dejima's comment on the mount) - detection is the
    # compensating control. Full behavioral coverage (snapshot/compare
    # against real fixtures, including the symlink-swap exploit) lives in
    # test/audit.bats; this just confirms the wiring exists.
    grep -q 'STATUSLINE_PATH=' "$REPO_ROOT/bin/dejima-audit"
    grep -q 'statusline_snapshot' "$REPO_ROOT/bin/dejima-audit"
    grep -q 'HOST-CODE-EXECUTION' "$REPO_ROOT/bin/dejima-audit"
}

@test "Dockerfile installs the sandbox clipboard fallback into nvim's VIMRUNTIME plugin dir" {
    # $VIMRUNTIME/plugin, NOT /etc/xdg/nvim: lazy.nvim's performance.rtp
    # reset strips /etc/xdg from the runtimepath, but always keeps
    # $VIMRUNTIME - this must load for lazy-managed configs too.
    grep -q 'COPY docker/sandbox-clipboard.lua /usr/local/share/nvim/runtime/plugin/sandbox-clipboard.lua' "$SANDBOX_DIR/Dockerfile"
}

@test "log-shipper conversation shipping is opt-in and off by default" {
    grep -q 'SANDBOX_LOG_CONVERSATION' "$SANDBOX_DIR/log-shipper.sh"
    grep -qE 'SANDBOX_LOG_CONVERSATION: \$\{SANDBOX_LOG_CONVERSATION:-0\}' "$SANDBOX_DIR/docker-compose.yml"
}

@test "log-shipper transcript transform ships prompts/responses/tool commands, skips results/meta/thinking" {
    fixtures='{"type":"user","sessionId":"s1","isMeta":null,"message":{"role":"user","content":"fix the login bug"}}
{"type":"user","sessionId":"s1","isMeta":true,"message":{"role":"user","content":"meta noise"}}
{"type":"user","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","content":"tool output secret"}]}}
{"type":"assistant","sessionId":"s1","message":{"content":[{"type":"thinking","thinking":"hidden reasoning"},{"type":"text","text":"done, deployed the fix"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}
this line is not json'
    run bash -c "LOG_SHIPPER_LIB_ONLY=1 source '$SANDBOX_DIR/log-shipper.sh'; transform_transcript_line <<< \"\$1\"" _ "$fixtures"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"role":"user"'* ]]
    [[ "$output" == *"fix the login bug"* ]]
    [[ "$output" == *'"role":"assistant"'* ]]
    [[ "$output" == *"done, deployed the fix"* ]]
    [[ "$output" == *'"role":"tool"'* ]]
    [[ "$output" == *'ls -la'* ]]
    [[ "$output" != *"meta noise"* ]]
    [[ "$output" != *"tool output secret"* ]]
    [[ "$output" != *"hidden reasoning"* ]]
    [[ "$output" != *"not json"* ]]
}

@test "every container runtime.bats starts is attached to a user-defined network" {
    # On the default bridge there's no 127.0.0.11, so dns-proxy.sh aborts and
    # the container dies mid-startup - which used to surface as flaky,
    # sometimes vacuous tests rather than an obvious failure. See runtime.bats'
    # wait_ready comment.
    local runs networks
    runs=$(grep -cE '^\s*docker run -d' "$REPO_ROOT/test/runtime.bats")
    networks=$(grep -cE '^\s*--network ' "$REPO_ROOT/test/runtime.bats")
    [ "$runs" -gt 0 ]
    [ "$runs" -eq "$networks" ]
}

@test "runtime.bats readiness waits for the final sleep infinity, not any startup sleep" {
    # A bare `pgrep -x sleep` also matches dns-proxy.sh's dig-retry sleep and
    # entrypoint.sh's forwarder-bind sleep, both of which run before
    # init-firewall.sh has installed anything - asserting there would find
    # OUTPUT ACCEPT and no ipsets, passing egress tests for the wrong reason.
    grep -qF "pgrep -x -f 'sleep infinity'" "$REPO_ROOT/test/runtime.bats"
    run grep -nE 'docker exec.*pgrep -x sleep' "$REPO_ROOT/test/runtime.bats"
    [ "$status" -ne 0 ]
}

@test "dejima-allow's session-skip escape hatch is test-only, never a silent no-op path" {
    # DEJIMA_ALLOW_SKIP_SESSION exists so test/project.bats can
    # exercise --project persistence without a live container. It must never
    # be reachable from the documented interface.
    run grep -c 'DEJIMA_ALLOW_SKIP_SESSION' "$REPO_ROOT/bin/dejima-allow"
    [ "$output" -eq 1 ]
    run grep 'DEJIMA_ALLOW_SKIP_SESSION' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
}

@test "bin/dejima merges approved project domains into ALLOWED_DOMAINS" {
    grep -q 'dejima-project-lib.sh' "$REPO_ROOT/bin/dejima"
    grep -q 'resolve_project_store "$WORKSPACE_DIR"' "$REPO_ROOT/bin/dejima"
}

@test "bin/dejima never reads a declaration file as a grant" {
    # .dejima/ in the workspace is session-writable. It may only be
    # read by the reporting/approval path, never by the launcher deciding
    # what to allow.
    run grep -n '\.dejima/' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml image honors SANDBOX_IMAGE with today's default" {
    grep -qE '^\s*image:\s*\$\{SANDBOX_IMAGE:-dejima:\$\{SANDBOX_USER:-node\}\}\s*$' \
        "$SANDBOX_DIR/docker-compose.yml"
}

@test "bin/dejima explicitly builds the base image, pinned to the base tag on that exact line" {
    # docker-compose.yml's image: now honors $SANDBOX_IMAGE (see the test
    # above), so an unpinned `compose build claude` would inherit whatever
    # $SANDBOX_IMAGE happens to be in the caller's environment - e.g. a
    # derived tag left over from a previous project session - and rebuild
    # the base Dockerfile under that name instead of the base tag. Anchored
    # to the line immediately before the build invocation itself: the
    # fallback `SANDBOX_IMAGE="dejima:${SANDBOX_USER}"` assignment a
    # couple of lines later would satisfy a looser "does the pin appear
    # anywhere in the file" check just as well, without actually applying to
    # this build.
    local build_line
    build_line=$(grep -n 'docker compose -f "\$COMPOSE_FILE" build claude' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$build_line" ]
    run sed -n "$((build_line - 1))p" "$REPO_ROOT/bin/dejima"
    [[ "$output" == 'SANDBOX_IMAGE="dejima:${SANDBOX_USER}" \' ]]
}

@test "the derived image build never uses the workspace as its build context" {
    # A root-context build with the untrusted project as context would let a
    # session's own files influence the image it then runs in.
    run grep -n 'docker build.*"\$WORKSPACE_DIR"' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
    grep -q 'SANDBOX_DERIVED_CONTEXT' "$REPO_ROOT/bin/dejima"
}

@test "the global dependency layer is built under the -global tag, guarded by the global store" {
    # Anchored to the line immediately before the call: a file-wide grep for
    # the guard or the tag alone would pass even if they'd drifted apart.
    local call_line
    call_line=$(grep -n 'build_dep_layer "dejima:\${SANDBOX_USER}-global"' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$call_line" ]
    run sed -n "$((call_line - 1))p" "$REPO_ROOT/bin/dejima"
    [[ "$output" == 'if [ -s "$(config_root)/dependencies" ]; then' ]]
}

@test "build_dep_layer advances SANDBOX_IMAGE to the tag it just built" {
    # Without this, the second call in a global+project build would build the
    # project layer FROM the base image instead of FROM the global layer.
    grep -q 'SANDBOX_IMAGE="\$tag"' "$REPO_ROOT/bin/dejima"
}

@test "the project dependency layer is still guarded by a non-empty PROJECT_STORE" {
    local call_line
    call_line=$(grep -n 'build_dep_layer "dejima:\${SANDBOX_USER}-\$(project_slug' "$REPO_ROOT/bin/dejima" | cut -d: -f1)
    [ -n "$call_line" ]
    run sed -n "$((call_line - 1))p" "$REPO_ROOT/bin/dejima"
    [[ "$output" == 'if [ -n "$PROJECT_STORE" ] && [ -s "$PROJECT_STORE/dependencies" ]; then' ]]
}

@test "the approval store is never mounted into the container" {
    # The store is the only thing that actually grants anything, and the
    # container runs an agent with no tool-use confirmations - mounting it
    # anywhere, at any mode, would let a session widen its own next launch
    # (a read-only mount still leaks every other project's approvals).
    run grep -nE 'config/dejima|DEJIMA_CONFIG_DIR|PROJECT_STORE' \
        "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
    run grep -nE '^\s*extra_mounts\+=.*(PROJECT_STORE|config_root)' "$REPO_ROOT/bin/dejima"
    [ "$status" -ne 0 ]
}

@test "sandbox-context escapes a declared domain's dots before matching the servers file" {
    # $dom comes straight off a session-writable declaration and lands in a
    # grep BRE, where an unescaped "." matches any character: a project could
    # declare "aexample.com" and have the hook match the server= line for an
    # already-approved "a.example.com", reporting an unapproved domain as
    # allowed. Anchored to the matching line itself - the servers file is an
    # absolute path only the container has, so this can't be driven from a
    # host-side test, and a file-wide grep would be satisfied by the same
    # expression appearing anywhere else.
    run grep -n 'dnsmasq-sandbox-servers.conf' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    [[ "$output" == *'grep -q "^server=/${dom//./\\.}/"'* ]]
}

@test "sandbox-context reads its stdin payload once" {
    # jq is called more than once now (session_id and cwd); reading stdin
    # twice would silently give the second call nothing.
    grep -q 'payload=$(cat)' "$REPO_ROOT/hooks/sandbox-context.sh"
    run grep -c "jq -r '\.session_id" "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$output" -eq 1 ]
}

@test "sandbox-context probes declared dependencies and never treats them as granted" {
    grep -q 'dpkg-query' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q 'npm ls -g' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q 'pip list' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q 'cargo install --list' "$REPO_ROOT/hooks/sandbox-context.sh"
    # domains are checked against what this container actually resolves,
    # not against the host-side approval store it cannot see
    grep -q 'dnsmasq-sandbox-servers.conf' "$REPO_ROOT/hooks/sandbox-context.sh"
    grep -q 'dejima-project approve' "$REPO_ROOT/hooks/sandbox-context.sh"
}

@test "sandbox-context reports nothing when no project declarations exist" {
    local ws; ws="$(mktemp -d)"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"
    [[ "$out" != *"declares requirements"* ]]
}

@test "sandbox-context still reports a declared dependency with no trailing newline" {
    # A while/read loop fed straight from the file drops a final line that
    # has no trailing newline - not a validation rejection, just never read.
    local ws; ws="$(mktemp -d)"
    mkdir -p "$ws/.dejima"
    printf 'apt:definitely-not-installed-noeol' > "$ws/.dejima/dependencies"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"
    [[ "$out" == *"definitely-not-installed-noeol"* ]]
}

@test "sandbox-context bounds a huge declaration file instead of emitting nothing" {
    # .dejima/ is on the read-write workspace mount, so a compromised
    # session can append to it at will. Unbounded, that used to push the
    # assembled context past Linux's 128 KiB MAX_ARG_STRLEN and make jq fail
    # outright - costing every later session in the project its entire
    # briefing (sandbox notice, worktree rule, never-push-to-main rule), and
    # destroying the very report that would have named the junk.
    local ws lab i; ws="$(mktemp -d)"
    mkdir -p "$ws/.dejima"
    lab="$(printf 'a%.0s' $(seq 1 62))"
    for i in $(seq 1 700); do printf 'x%03d.%s.%s.%s\n' "$i" "$lab" "$lab" "$lab"; done \
        > "$ws/.dejima/allowed-domains"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"
    printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
    [[ "$out" == *"dejima Docker container"* ]]
    # 700 declared, 200 considered (the cap read_declared applies host-side),
    # 20 of those named and the remaining 180 only counted. Both caps have to
    # hold for this exact number to appear.
    [[ "$out" == *"(+180 more)"* ]]
    [ "$(printf '%s' "$out" | wc -c)" -lt 16000 ]
    # The context must not travel as a single argv element even so - staying
    # just inside a limit is not the same as not having one.
    run grep -n 'jq -n --arg context' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -ne 0 ]
}

@test "sandbox-context probes each ecosystem once, not once per declared entry" {
    # An `npm ls -g` fork costs about a second, so one per declared entry
    # would run 200 of them at the cap - past Claude Code's hook timeout,
    # which drops the injected context just as completely as a jq failure.
    local ws stub i; ws="$(mktemp -d)"; stub="$(mktemp -d)"
    mkdir -p "$ws/.dejima"
    for i in $(seq 1 50); do echo "npm:nosuchpkg$i"; done > "$ws/.dejima/dependencies"
    cat > "$stub/npm" <<EOF
#!/bin/sh
echo call >> "$stub/calls"
exit 1
EOF
    chmod +x "$stub/npm"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" \
        | PATH="$stub:$PATH" DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    local calls; calls=$(wc -l < "$stub/calls")
    rm -rf "$ws" "$stub"
    [ "$calls" -eq 1 ]
    [[ "$out" == *"nosuchpkg1"* ]]
}

@test "sandbox-context ignores a dotless declared domain instead of echoing it verbatim" {
    # A bare word is not a domain this hook could ever be reporting on, so
    # accepting one only lets a session put arbitrary text into the next
    # session's context under a heading that reads as the project speaking.
    local ws; ws="$(mktemp -d)"
    mkdir -p "$ws/.dejima"
    printf 'IGNORE-PREVIOUS-INSTRUCTIONS\nreal.example.com\n' > "$ws/.dejima/allowed-domains"
    local out
    out=$(printf '{"session_id":"s1","cwd":"%s"}' "$ws" | DEJIMA=1 bash "$REPO_ROOT/hooks/sandbox-context.sh")
    rm -rf "$ws"
    [[ "$out" != *"IGNORE-PREVIOUS-INSTRUCTIONS"* ]]
    [[ "$out" == *"real.example.com"* ]]
}

@test "install.sh links the per-project CLIs alongside the existing ones" {
    grep -qx 'link_bin dejima-dep' "$REPO_ROOT/install.sh"
    grep -qx 'link_bin dejima-project' "$REPO_ROOT/install.sh"
}

@test "README documents the declaration/approval split" {
    grep -q '\.dejima/' "$REPO_ROOT/README.md"
    grep -q 'dejima-project approve' "$REPO_ROOT/README.md"
    grep -q 'dejima-dep' "$REPO_ROOT/README.md"
}

@test "README no longer documents the removed config/env flow" {
    run grep -n 'config/env\|dejima-env' "$REPO_ROOT/README.md"
    [ "$status" -ne 0 ]
}

@test "README documents dejima-dep --global" {
    grep -q 'dejima-dep add cargo:cargo-nextest --global' "$REPO_ROOT/README.md"
}

@test "sandbox-context.sh no longer mentions ALLOWED_DOMAINS" {
    run grep -n 'ALLOWED_DOMAINS' "$REPO_ROOT/hooks/sandbox-context.sh"
    [ "$status" -ne 0 ]
}

# The repo is public; the operator's own network is not. Both shapes below
# leaked into it once (a .localdomain Gitea host in bin/gitea-pr, a real LAN
# address as the Loki example in docker-compose.yml), so they are pinned
# here. Documentation addresses belong in RFC 5737's ranges (192.0.2.0/24,
# 198.51.100.0/24, 203.0.113.0/24) and documentation names under RFC 2606's
# reserved TLDs.
#
# test/ is deliberately out of scope: fixtures stub real resolver answers
# (project.bats feeds dig a 10.0.0.1) and those are inputs to a test, not
# addresses an operator is being told to use.
#
# This catches address- and hostname-shaped leaks only. A personal domain
# that looks like any other public one is not mechanically distinguishable
# and still rests on review.
SCANNED_PATHS=(README.md docs docker bin hooks install.sh systemd)

@test "no private or link-local address is used as a documentation example" {
    run grep -rnIE '\b(10|127\.0\.0\.[2-9]|169\.254|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' \
        "${SCANNED_PATHS[@]/#/$REPO_ROOT/}"
    [ "$status" -ne 0 ] || {
        echo "use an RFC 5737 documentation address instead:" >&2
        echo "$output" >&2
        false
    }
}

@test "no hostname under a private-network suffix is used as a documentation example" {
    run grep -rnIE '[A-Za-z0-9-]+\.(localdomain|lan|internal|home\.arpa)\b' \
        "${SCANNED_PATHS[@]/#/$REPO_ROOT/}"
    [ "$status" -ne 0 ] || {
        echo "use an RFC 2606 reserved name (example.com, .invalid, .test) instead:" >&2
        echo "$output" >&2
        false
    }
}
