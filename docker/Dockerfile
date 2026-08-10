# Loosely inspired by the general shape of Anthropic's public reference dev
# container (https://github.com/anthropics/claude-code/tree/main/.devcontainer),
# substantially extended and reworked for this project's own sandboxing model
# (parametrized SANDBOX_USER, DNS proxy + ulogd2 logging, gosu-based privilege
# drop, nvim/Playwright/tree-sitter toolchain, gitea-pr helper, etc).
#
# What belongs in here is what the sandbox itself needs, plus the editor and
# browser tooling that has no route through the dependency mechanism. Language
# toolchains and per-project utilities do have one - `dejima-dep`, including
# tarball: for a release archive - so they are declared by the projects that
# want them rather than carried by every sandbox on the host. Anything added
# below is added for every project, forever, with no review anywhere.
FROM node:22

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools, iptables/ipset (for the egress firewall),
# openssh-client (for git-over-ssh and agent forwarding), and the toolchain a
# typical nvim plugin set (telescope/treesitter/mason) expects, since
# SANDBOX_NVIM_CONFIG can point a session's editor at one.
#
# Deliberately NOT installing bubblewrap/socat: those exist to let Claude
# Code's own internal per-command sandboxing (~/.claude/settings.json's
# "sandbox" block) and /remote-control run, but that inner sandbox is
# redundant on top of this container - it can't even function inside it
# anyway (bwrap can't create a namespace here, and fixing that would need
# privilege escalation approaching --privileged, undoing this container's
# own hardening). bin/dejima mounts a settings.json copy with
# sandbox.enabled forced to false, so there's nothing here to satisfy.
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  openssh-client \
  procps \
  fzf \
  zsh \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  openssl \
  dnsmasq \
  ulogd2 \
  ulogd2-json \
  nano \
  ripgrep \
  fd-find \
  build-essential \
  python3 \
  python3-pip \
  xz-utils \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && ln -s "$(command -v fdfind)" /usr/local/bin/fd

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Disable non-essential network traffic (telemetry/error reporting) so the
# firewall allowlist can stay small.
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Lets Claude Code (and the SessionStart hook in ~/.claude/hooks) know it's
# running inside this container rather than directly on the host.
ENV DEJIMA=1

# Dedicated unprivileged user for ulogd2 (see entrypoint.sh) - unlike
# dnsmasq, the ulogd2 Debian package doesn't create one of its own. ulogd2
# opens its log/output files and the NFLOG netlink socket before dropping to
# this user, so it doesn't need to own anything itself.
RUN useradd -r -s /usr/sbin/nologin ulogd

# Every fetch from here down retries, and none is single-shot. What matters
# isn't the odds of a particular download failing, it's the odds of any of
# them failing - and without retries a single blip anywhere throws away the
# whole build.
#
# These steps deliberately sit *above* the SANDBOX_* ARGs, not below. Nothing
# between here and `USER` needs the sandbox user to exist yet - they all
# install system-wide as root - so keeping them ahead of the ARGs means a
# build that overrides one (test/runtime.bats does, and so does any host
# whose uid isn't 1000) still reuses every layer down to this point instead
# of re-running all of it. That single ordering was most of the cost of the
# override rebuild: it was 1169s of a 1379s test run, for a difference that
# amounts to one useradd.
# gosu lets entrypoint.sh (root) drop to the node user for the actual
# session after setting up the firewall, without leaving any setuid/sudo
# escalation path available to node afterward. Verified against the
# published SHA256SUMS since it runs as root.
ARG GOSU_VERSION=1.19
RUN ARCH=$(dpkg --print-architecture) && \
  wget --tries=3 --timeout=30 --waitretry=5 --retry-connrefused \
    -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${ARCH}" && \
  wget --tries=3 --timeout=30 --waitretry=5 --retry-connrefused \
    -O /tmp/gosu.sha256sums "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/SHA256SUMS" && \
  grep -E "gosu-${ARCH}\$" /tmp/gosu.sha256sums | sed "s#gosu-${ARCH}#/usr/local/bin/gosu#" | sha256sum -c - && \
  rm /tmp/gosu.sha256sums && \
  chmod +x /usr/local/bin/gosu

# Install the latest stable Neovim release. Debian's packaged version is too
# old for this config's plugins (blink.cmp etc. need a recent Neovim), so
# fetch the current release from GitHub directly rather than pinning a
# version that may go stale.
RUN asset_url=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --max-time 60 \
    https://api.github.com/repos/neovim/neovim/releases/latest \
    | jq -r '[.assets[] | select(.name | test("linux.*x86_64.*\\.tar\\.gz$"))][0].browser_download_url') && \
  wget --tries=3 --timeout=30 --waitretry=5 --retry-connrefused \
    -O nvim.tar.gz "$asset_url" && \
  tar -C /usr/local --strip-components=1 -xzf nvim.tar.gz && \
  rm nvim.tar.gz

# No Go toolchain here. A Go project declares one:
#
#   dejima-dep add --global tarball:go@<sha256>:https://go.dev/dl/go<ver>.linux-amd64.tar.gz
#
# and gets a pinned toolchain in the version it actually wants, rather than
# whatever this image was built with. Shipping a language runtime is not the
# same decision as every sandbox on the host carrying one - and the module
# proxy it needs (proxy.golang.org, sum.golang.org) is an approval too, for
# the same reason.

# System libraries Chromium needs (fonts, libnss, libatk, etc.) for
# Playwright, installed here since it needs apt/root - the actual
# `playwright` package and browser binary install as node, further down,
# so they land in node's own npm prefix/cache correctly.
ARG PLAYWRIGHT_VERSION=1.61.1
RUN npx -y playwright@${PLAYWRIGHT_VERSION} install-deps chromium

# Replace the base image's built-in `node` user (uid/gid 1000,
# $HOME=/home/node) with one matching the host user who runs
# bin/dejima - so absolute paths under $HOME (dotfiles, and
# ~/.claude/plugins/installed_plugins.json's own installPath bookkeeping,
# which Claude Code resolves as a literal host-absolute string rather than
# relative to whatever $HOME happens to be) resolve identically inside and
# outside the container, instead of needing a one-off dual-mount for every
# individual thing that assumes the real host path. Defaults below
# reproduce today's node/1000/1000//home/node exactly, so a build that
# never overrides them (bin/dejima always does; the test suite
# never does) exercises this same rename path rather than a separate,
# untested one.
#
# As late as it can go: everything an override invalidates is below this
# line, so the cheaper this block is to reach, the cheaper an override is.
ARG SANDBOX_USER=node
ARG SANDBOX_UID=1000
ARG SANDBOX_GID=1000
ARG SANDBOX_HOME=/home/node
RUN userdel -r node 2>/dev/null; \
  groupdel node 2>/dev/null; \
  groupadd -g "$SANDBOX_GID" "$SANDBOX_USER" && \
  useradd -u "$SANDBOX_UID" -g "$SANDBOX_GID" -m -d "$SANDBOX_HOME" -s /bin/bash "$SANDBOX_USER"
ENV SANDBOX_USER=$SANDBOX_USER
ENV SANDBOX_HOME=$SANDBOX_HOME

# Ensure the sandbox user has access to /usr/local/share. The recursion is
# scoped to npm-global rather than applied to the whole directory, which is
# what this used to do: Neovim now unpacks into /usr/local/share/nvim above
# this line rather than below it, and recursing from the parent would hand
# the sandbox user Neovim's runtime files. /usr/local/share itself is still
# chowned, so anything that expected to create entries in it still can.
RUN mkdir -p /usr/local/share/npm-global && \
  chown $SANDBOX_USER:$SANDBOX_USER /usr/local/share && \
  chown -R $SANDBOX_USER:$SANDBOX_USER /usr/local/share/npm-global

# Persist bash history. The env vars that actually wire history up to this
# file are set below via zsh-in-docker's -a flag.
RUN mkdir /commandhistory && \
  touch /commandhistory/.bash_history && \
  chown -R $SANDBOX_USER /commandhistory

# Create the ssh directory and set permissions. The project directory itself
# is bind-mounted at runtime at its real host path (see docker-compose.yml),
# not a fixed /workspace, so it can share ~/.claude project/session history
# with the host.
#
# ~/.claude itself is baked in here rather than bind-mounted (see the mount
# inventory in docker-compose.yml): only enumerated paths *inside* it come
# from the host, and Docker creates the parents of a mount point root-owned
# if they don't already exist - which would leave the sandbox user unable to
# write the caches and history it keeps directly in ~/.claude.
# projects/ is in that list for the same reason one level down: it is no
# longer mounted itself, only individual slug directories inside it, so
# without this Docker creates it root-owned while setting those up and the
# session cannot write a slug of its own.
RUN mkdir -p $SANDBOX_HOME/.ssh $SANDBOX_HOME/.claude $SANDBOX_HOME/.claude/projects && \
  chown -R $SANDBOX_USER:$SANDBOX_USER $SANDBOX_HOME/.ssh $SANDBOX_HOME/.claude && \
  chmod 700 $SANDBOX_HOME/.ssh $SANDBOX_HOME/.claude

# Pre-create the nvim data/state/cache dirs owned by the sandbox user,
# since they're mounted as named volumes in docker-compose.yml: Docker
# seeds a fresh named volume from whatever already exists at the mount
# path in the image, ownership included, so this is what keeps those
# volumes writable by that user instead of defaulting to root.
RUN mkdir -p $SANDBOX_HOME/.local/share/nvim $SANDBOX_HOME/.local/state/nvim $SANDBOX_HOME/.cache/nvim && \
  chown -R $SANDBOX_USER:$SANDBOX_USER $SANDBOX_HOME/.local $SANDBOX_HOME/.cache

# Set up non-root user
USER $SANDBOX_USER

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
# A global npm install only puts a package's CLI on PATH, not its module on
# Node's require() resolution path - NODE_PATH is what makes `require
# ("playwright")` work from any script anywhere, not just the project's own
# node_modules (which it likely doesn't have without its own npm install).
ENV NODE_PATH=/usr/local/share/npm-global/lib/node_modules

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme, git/fzf oh-my-zsh plugins, fzf's own key
# bindings, and wiring HISTFILE to the persisted /commandhistory volume -
# see https://github.com/deluan/zsh-in-docker for the installer's own flags.
#
# Downloaded to a file and then run, rather than upstream's documented
# `sh -c "$(wget -O- ...)"`. In that form a failed download substitutes to an
# empty string, `sh -c ""` exits 0, and the build goes green having installed
# no zsh config at all - the failure only surfaces much later, as a shell that
# is mysteriously unconfigured. Two steps make the download's exit status the
# build's exit status.
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN wget --tries=3 --timeout=30 --waitretry=5 --retry-connrefused \
    -O /tmp/zsh-in-docker.sh \
    "https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh" && \
  sh /tmp/zsh-in-docker.sh \
  -p fzf \
  -p git \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -x && \
  rm /tmp/zsh-in-docker.sh

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Install the tree-sitter CLI, which nvim-treesitter (plugins/treesitter.lua)
# needs to install/update parsers. Pinned below latest: newer tree-sitter-cli
# prebuilds require glibc >=2.39, which this (Debian 12 bookworm) image
# doesn't have.
RUN npm install -g tree-sitter-cli@0.24.7

# Playwright, for testing frontend changes against a locally-running dev
# server - localhost traffic never goes through the egress firewall, so
# this needs no allowlist changes for that. System deps were already
# installed as root above; this installs the npm package and downloads the
# matching Chromium build into node's own cache, both at build time so a
# session never needs network access for either.
#
# Chromium's own internal process sandbox is questionable here: it launches
# without --no-sandbox and without error, but its setuid sandbox helper
# (chrome_sandbox) isn't actually setuid-root in this image, and this host
# has the same unprivileged-userns restriction that broke bubblewrap - so
# its namespace-based isolation almost certainly isn't active either, it's
# just not hard-failing the way bubblewrap did. Not treated as a real
# security boundary either way: this container is already the boundary that
# matters, and a compromised session already has full `node`-level bash
# access, which a Chromium exploit couldn't exceed regardless of whichever
# of its own internal sandbox layers happen to be active.
RUN npm install -g playwright@${PLAYWRIGHT_VERSION} && \
  npx playwright install chromium

# Copy and set up firewall + DNS-proxy + entrypoint scripts, every forge's
# CLI helpers, and the claude wrapper that pins
# --dangerously-skip-permissions. The launched application itself
# (SANDBOX_CMD, default `claude`) and any editor config for it are supplied
# at runtime, not baked into the image - see docker-compose.yml/entrypoint.sh.
COPY docker/fixed-domains.sh /usr/local/bin/
COPY docker/dns-proxy.sh /usr/local/bin/
COPY docker/init-firewall.sh /usr/local/bin/
COPY docker/log-shipper.sh /usr/local/bin/
COPY docker/ulogd.conf /etc/ulogd-sandbox.conf
# Into $VIMRUNTIME/plugin, not /etc/xdg/nvim - see the file's own comment.
COPY docker/sandbox-clipboard.lua /usr/local/share/nvim/runtime/plugin/sandbox-clipboard.lua
COPY docker/entrypoint.sh /usr/local/bin/
COPY docker/anthropic-proxy-forwarder.js /usr/local/bin/anthropic-proxy-forwarder.js
COPY docker/claude-wrapper.sh /usr/local/bin/claude
# Back to root before the first RUN that writes outside /home/node. The npm
# installs above run as node deliberately; COPY writes as root regardless of
# USER, so the copies above are unaffected, but the install(1) below is a RUN
# and would inherit node and fail on /usr/local/bin.
USER root

# Every forge's CLIs, not just the selected one: a forge CLI is inert without
# its API URL and token, and an image that is identical regardless of which
# forge is configured is one less thing for the exit audit to explain.
COPY forges/ /tmp/forges/
RUN find /tmp/forges -type f -path '*/bin/*' -exec install -m 755 {} /usr/local/bin/ \; \
    && rm -rf /tmp/forges

RUN chmod +x /usr/local/bin/dns-proxy.sh /usr/local/bin/init-firewall.sh /usr/local/bin/log-shipper.sh /usr/local/bin/entrypoint.sh /usr/local/bin/claude && \
  echo 'export PATH="$PATH:/usr/local/share/npm-global/bin"' > /etc/profile.d/npm-global-path.sh

# Entrypoint runs as root (no USER node here) so it can set up the firewall
# directly, with no sudo/setuid escalation path available to node at any
# point afterward. It drops to node itself via gosu before execing
# SANDBOX_CMD (default `claude` - see entrypoint.sh).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
