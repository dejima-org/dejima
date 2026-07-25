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
    # bin/claude-sandbox never sees (it only protects symlink targets that
    # resolve outside ~/.claude).
    grep -qE '^\s*-\s*\$\{HOME\}/\.claude/hooks:\$\{HOME\}/\.claude/hooks:ro\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "~/.claude.json is a throwaway per-session copy, not the real file mounted directly" {
    # A plain read-only mount hangs Claude Code on startup (it does an
    # atomic write-temp-then-rename against this file even before login) -
    # the fix is a generated, discarded copy, not read-only. See
    # bin/claude-sandbox and README "Throwaway ~/.claude.json".
    grep -qE '^\s*-\s*\$\{SANDBOX_CLAUDE_JSON_FILE.*\}:\$\{HOME\}/\.claude\.json\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -q 'mktemp.*claude-sandbox-claude-json' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'rm -f "\$SANDBOX_SETTINGS_FILE" "\$SANDBOX_CLAUDE_JSON_FILE"' "$REPO_ROOT/bin/claude-sandbox"
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
    grep -q 'mktemp -d.*gitconfig' "$REPO_ROOT/bin/claude-sandbox"
}

@test "docker-compose.yml never hardcodes /home/node - the container home is host-parametrized" {
    # ${HOME:-/home/node} (the SANDBOX_HOME build arg's own default value,
    # mirroring the Dockerfile's default) is the one legitimate exception -
    # it's a fallback expression, not a hardcoded container path.
    run bash -c "grep -v '^\s*#' '$SANDBOX_DIR/docker-compose.yml' | grep -v '\${HOME:-/home/node}' | grep '/home/node'"
    [ "$status" -ne 0 ]
}

@test "docker-compose.yml builds with a per-user image tag and passes the host identity as build args" {
    grep -qE '^\s*image:\s*claude-sandbox:\$\{SANDBOX_USER:-node\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_USER:\s*\$\{SANDBOX_USER:-node\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_UID:\s*\$\{SANDBOX_UID:-1000\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_GID:\s*\$\{SANDBOX_GID:-1000\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
    grep -qE '^\s*SANDBOX_HOME:\s*\$\{HOME:-/home/node\}\s*$' "$SANDBOX_DIR/docker-compose.yml"
}

@test "bin/claude-sandbox exports the host user identity for the build" {
    grep -q 'SANDBOX_USER="$(id -un)"' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'SANDBOX_UID="$(id -u)"' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'SANDBOX_GID="$(id -g)"' "$REPO_ROOT/bin/claude-sandbox"
}

@test "docker-compose.yml never hardcodes a dotfiles (or any other specific repo) mount" {
    # Hook-symlink targets are discovered dynamically at launch by
    # bin/claude-sandbox instead - see the next test. A hardcoded path here
    # would silently break for anyone whose hooks live somewhere else.
    run grep -i 'dotfiles' "$SANDBOX_DIR/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "bin/claude-sandbox dynamically discovers and mounts hook-symlink targets" {
    grep -q 'readlink -f "\$entry"' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'extra_mounts+=(-v "\$real_dir:\$real_dir:ro")' "$REPO_ROOT/bin/claude-sandbox"
    grep -q '"\${extra_mounts\[@\]}"' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox layers a writable lazy-lock.json over the read-only nvim config mount" {
    # SANDBOX_NVIM_CONFIG is mounted :ro, but lazy.nvim writes its lockfile
    # back into that same directory on every plugin sync - without this
    # overlay, that write fails with a read-only-filesystem error and the
    # sync aborts (a real bug: plugins never finish installing, so a
    # config's colorscheme fallback kicks in instead of the real one).
    grep -q 'mktemp.*claude-sandbox-nvim-lock' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'extra_mounts+=(-v "\$SANDBOX_NVIM_LOCKFILE:\$HOME/\.config/nvim/lazy-lock\.json")' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'rm -f .*"\${SANDBOX_NVIM_LOCKFILE:-}"' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox mounts SANDBOX_EXTRA_MOUNTS entries read-only at their own path" {
    grep -q 'IFS=.:. read -ra extra_paths <<< "\$SANDBOX_EXTRA_MOUNTS"' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'extra_mounts+=(-v "\$path:\$path:ro")' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox forces sandbox.enabled to false in the generated settings.json" {
    # Claude Code's own internal per-command sandboxing is redundant on top
    # of this container and can't actually function inside it (bwrap can't
    # create a namespace here) - settings.json is read-only precisely so it
    # can't be patched from inside, so this has to happen in the generation
    # step on the host, before the container starts.
    grep -qE '\.sandbox\.enabled\s*=\s*false' "$REPO_ROOT/bin/claude-sandbox"
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

@test "bin/claude-sandbox and bin/claude-sandbox-allow resolve their own location through symlinks" {
    # install.sh symlinks both into ~/.local/bin so they can be run by name
    # via PATH. A bare `dirname "${BASH_SOURCE[0]}"` (no readlink -f first)
    # resolves against the symlink's own directory in that case, not this
    # repo's real bin/ - a real bug hit on first use: claude-sandbox tried
    # to open ~/.local/docker/docker-compose.yml instead of this repo's.
    grep -q 'dirname "\$(readlink -f "\${BASH_SOURCE\[0\]}")"' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'dirname "\$(readlink -f "\${BASH_SOURCE\[0\]}")"' "$REPO_ROOT/bin/claude-sandbox-allow"
}

@test "bin/claude-sandbox-allow rejects a domain with shell metacharacters" {
    run "$REPO_ROOT/bin/claude-sandbox-allow" 'evil.com;touch /tmp/pwned'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not a valid domain"* ]]
}

@test "bin/claude-sandbox-allow rejects a domain with a slash (dnsmasq server= delimiter)" {
    run "$REPO_ROOT/bin/claude-sandbox-allow" 'evil.com/../etc'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not a valid domain"* ]]
}

@test "bin/claude-sandbox-allow accepts a well-formed domain (passes validation)" {
    # --container points at a name that can't exist, so this can *never*
    # reach a real running claude-sandbox session (and mutate its live
    # firewall) even if the machine running this test happens to have one -
    # it must fail at "container not found", not at validation.
    run "$REPO_ROOT/bin/claude-sandbox-allow" 'crates.io' --container claude-sandbox-test-suite-nonexistent-target
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

@test "bin/claude-sandbox allows a dedicated SANDBOX_SSH_KEY in place of a forwarded agent" {
    grep -q 'SANDBOX_SSH_KEY' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'export SANDBOX_SSH_KEY_FILE' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox warns when SANDBOX_SSH_KEY looks like a default personal key" {
    grep -q 'looks like a default personal SSH key' "$REPO_ROOT/bin/claude-sandbox"
    run grep -E '^\s*id_rsa\|id_ecdsa\|id_ed25519\|id_dsa\|id_ecdsa_sk\|id_ed25519_sk\)\s*$' "$REPO_ROOT/bin/claude-sandbox"
    [ "$status" -eq 0 ]
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

@test "dns-proxy.sh enables dnsmasq's stop-dns-rebind protection" {
    grep -qE '^stop-dns-rebind\s*$' "$SANDBOX_DIR/dns-proxy.sh"
    grep -q 'rebind-domain-ok=/\$domain/' "$SANDBOX_DIR/dns-proxy.sh"
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

@test "bin/claude-sandbox pre-creates the code-carrying ~/.claude overlay dirs" {
    grep -q 'mkdir -p "$HOME/.claude/skills" "$HOME/.claude/commands" "$HOME/.claude/agents" "$HOME/.claude/output-styles"' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox overlays the workspace .git/hooks read-only when .git is a real dir" {
    grep -q 'if \[ -d "$WORKSPACE_DIR/.git/hooks" \]' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'extra_mounts+=(-v "$WORKSPACE_DIR/.git/hooks:$WORKSPACE_DIR/.git/hooks:ro")' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox parses config/env instead of sourcing it" {
    run grep -E 'source "\$REPO_ROOT/config/env"' "$REPO_ROOT/bin/claude-sandbox"
    [ "$status" -ne 0 ]
    grep -q 'parse_allowed_domains_env "$REPO_ROOT/config/env"' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'source "$SCRIPT_DIR/claude-sandbox-env.sh"' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox snapshots before the run and compares after" {
    grep -q '"$SCRIPT_DIR/claude-sandbox-audit" snapshot "$WORKSPACE_DIR"' "$REPO_ROOT/bin/claude-sandbox"
    grep -q '"$SCRIPT_DIR/claude-sandbox-audit" compare "$WORKSPACE_DIR"' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox warns when the workspace is this repo itself (TCB self-mount)" {
    grep -q 'sandbox.s own repo' "$REPO_ROOT/bin/claude-sandbox" || \
    grep -q 'TCB' "$REPO_ROOT/bin/claude-sandbox"
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

@test "bin/claude-sandbox's exit-time audit still runs when the container run fails or is interrupted" {
    local run_line
    run_line=$(grep -n 'docker compose .* run --rm --build' "$REPO_ROOT/bin/claude-sandbox" | cut -d: -f1)
    [ -n "$run_line" ]
    # The compose invocation must not be a bare command under set -e - a
    # nonzero/interrupted exit there would otherwise abort the script before
    # the audit compare and exit below ever run.
    grep -q '|| compose_status=\$?' <(sed -n "${run_line}p" "$REPO_ROOT/bin/claude-sandbox")
    sed -n "1,${run_line}p" "$REPO_ROOT/bin/claude-sandbox" | grep -q 'compose_status=0'
    tail -n "+$run_line" "$REPO_ROOT/bin/claude-sandbox" | grep -q '"\$SCRIPT_DIR/claude-sandbox-audit" compare "\$WORKSPACE_DIR"'
    tail -n "+$run_line" "$REPO_ROOT/bin/claude-sandbox" | grep -q 'exit "\$compose_status"'
}

@test "credential proxy is on by default, gated only by SANDBOX_CREDENTIAL_PROXY=0" {
    grep -q '"\${SANDBOX_CREDENTIAL_PROXY:-1}" != "0"' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox masks the credentials file and mounts the proxy socket dir" {
    # The mask is what keeps the real token out of the (otherwise read-write)
    # ~/.claude mount; the socket dir is how API traffic gets back out to the
    # host-side proxy that holds the real credential.
    grep -q 'mktemp.*claude-sandbox-credentials-mask' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'extra_mounts+=(-v "\$SANDBOX_CREDENTIALS_MASK_FILE:\$HOME/\.claude/\.credentials\.json")' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'extra_mounts+=(-v "\$SANDBOX_ANTHROPIC_PROXY_DIR:\$SANDBOX_ANTHROPIC_PROXY_DIR")' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox refuses to launch when the proxy fails to start" {
    # Falling back to mounting the real credential would be a silent
    # security downgrade - the failure must be loud and the launch aborted.
    grep -q 'Credential proxy failed to start' "$REPO_ROOT/bin/claude-sandbox"
    grep -q 'SANDBOX_CREDENTIAL_PROXY=0' "$REPO_ROOT/bin/claude-sandbox"
}

@test "cleanup reaps the proxy and its socket dir and mask file" {
    grep -q 'kill "\$SANDBOX_ANTHROPIC_PROXY_PID"' "$REPO_ROOT/bin/claude-sandbox"
    grep -q '"\${SANDBOX_CREDENTIALS_MASK_FILE:-}"' "$REPO_ROOT/bin/claude-sandbox"
    grep -q '"\${SANDBOX_ANTHROPIC_PROXY_DIR:-}"' "$REPO_ROOT/bin/claude-sandbox"
}

@test "bin/claude-sandbox warns if the proxy died before the session ended" {
    grep -q 'credential proxy exited before' "$REPO_ROOT/bin/claude-sandbox"
}
