# Based on the official Anthropic reference dev container:
# https://github.com/anthropics/claude-code/tree/main/.devcontainer
FROM node:22

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools, iptables/ipset (for the egress firewall),
# openssh-client (for git-over-ssh and agent forwarding), and the toolchain
# nvim's plugin config (config/nvim, telescope/treesitter/mason) expects.
#
# Deliberately NOT installing bubblewrap/socat: those exist to let Claude
# Code's own internal per-command sandboxing (~/.claude/settings.json's
# "sandbox" block) and /remote-control run, but that inner sandbox is
# redundant on top of this container - it can't even function inside it
# anyway (bwrap can't create a namespace here, and fixing that would need
# privilege escalation approaching --privileged, undoing this container's
# own hardening). bin/claude-sandbox mounts a settings.json copy with
# sandbox.enabled forced to false, so there's nothing here to satisfy.
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  openssh-client \
  procps \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  dnsmasq \
  ulogd2 \
  ulogd2-json \
  nano \
  vim \
  ripgrep \
  fd-find \
  build-essential \
  python3 \
  python3-pip \
  python3-venv \
  xz-utils \
  bats \
  cowsay \
  fortune-mod \
  fortunes-min \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && ln -s "$(command -v fdfind)" /usr/local/bin/fd

# cowsay/cowthink/fortune install to /usr/games on Debian, which isn't on
# PATH by default - config/nvim's start-screen header (plugins/ui.lua) shells
# out to them by bare name. Set via ENV (not a profile.d script) so it's
# picked up by every process unconditionally, including nvim's non-login
# subprocess spawns, which wouldn't source /etc/profile.d.
ENV PATH=/usr/games:$PATH

# Replace the base image's built-in `node` user (uid/gid 1000,
# $HOME=/home/node) with one matching the host user who runs
# bin/claude-sandbox - so absolute paths under $HOME (dotfiles, and
# ~/.claude/plugins/installed_plugins.json's own installPath bookkeeping,
# which Claude Code resolves as a literal host-absolute string rather than
# relative to whatever $HOME happens to be) resolve identically inside and
# outside the container, instead of needing a one-off dual-mount for every
# individual thing that assumes the real host path. Defaults below
# reproduce today's node/1000/1000//home/node exactly, so a build that
# never overrides them (bin/claude-sandbox always does; the test suite
# never does) exercises this same rename path rather than a separate,
# untested one.
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

# Ensure the sandbox user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R $SANDBOX_USER:$SANDBOX_USER /usr/local/share

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $SANDBOX_USER /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Disable non-essential network traffic (telemetry/error reporting) so the
# firewall allowlist can stay small.
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Lets Claude Code (and the SessionStart hook in ~/.claude/hooks) know it's
# running inside this container rather than directly on the host.
ENV CLAUDE_SANDBOX=1

# Dedicated unprivileged user for ulogd2 (see entrypoint.sh) - unlike
# dnsmasq, the ulogd2 Debian package doesn't create one of its own. ulogd2
# opens its log/output files and the NFLOG netlink socket before dropping to
# this user, so it doesn't need to own anything itself.
RUN useradd -r -s /usr/sbin/nologin ulogd

# Create the ssh directory and set permissions. The project directory itself
# is bind-mounted at runtime at its real host path (see docker-compose.yml),
# not a fixed /workspace, so it can share ~/.claude project/session history
# with the host. ~/.claude is bind-mounted too, not baked in here.
RUN mkdir -p $SANDBOX_HOME/.ssh && \
  chown -R $SANDBOX_USER:$SANDBOX_USER $SANDBOX_HOME/.ssh && \
  chmod 700 $SANDBOX_HOME/.ssh

# Pre-create the nvim data/state/cache dirs owned by the sandbox user,
# since they're mounted as named volumes in docker-compose.yml: Docker
# seeds a fresh named volume from whatever already exists at the mount
# path in the image, ownership included, so this is what keeps those
# volumes writable by that user instead of defaulting to root.
RUN mkdir -p $SANDBOX_HOME/.local/share/nvim $SANDBOX_HOME/.local/state/nvim $SANDBOX_HOME/.cache/nvim && \
  chown -R $SANDBOX_USER:$SANDBOX_USER $SANDBOX_HOME/.local $SANDBOX_HOME/.cache

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# gosu lets entrypoint.sh (root) drop to the node user for the actual
# session after setting up the firewall, without leaving any setuid/sudo
# escalation path available to node afterward. Verified against the
# published SHA256SUMS since it runs as root.
ARG GOSU_VERSION=1.19
RUN ARCH=$(dpkg --print-architecture) && \
  wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${ARCH}" && \
  wget -O /tmp/gosu.sha256sums "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/SHA256SUMS" && \
  grep -E "gosu-${ARCH}\$" /tmp/gosu.sha256sums | sed "s#gosu-${ARCH}#/usr/local/bin/gosu#" | sha256sum -c - && \
  rm /tmp/gosu.sha256sums && \
  chmod +x /usr/local/bin/gosu

# Install the latest stable Neovim release. Debian's packaged version is too
# old for this config's plugins (blink.cmp etc. need a recent Neovim), so
# fetch the current release from GitHub directly rather than pinning a
# version that may go stale.
RUN asset_url=$(curl -fsSL https://api.github.com/repos/neovim/neovim/releases/latest \
    | jq -r '[.assets[] | select(.name | test("linux.*x86_64.*\\.tar\\.gz$"))][0].browser_download_url') && \
  wget -O nvim.tar.gz "$asset_url" && \
  tar -C /usr/local --strip-components=1 -xzf nvim.tar.gz && \
  rm nvim.tar.gz

# Install the latest stable Go toolchain. go.dev's own release JSON gives
# both the download URL and a SHA256 per file, verified below since this
# runs as root - same pattern as gosu above. `go build`/`go mod download`
# need proxy.golang.org and sum.golang.org reachable at runtime - see
# fixed-domains.sh.
RUN ARCH=$(dpkg --print-architecture) && \
  release_json=$(curl -fsSL 'https://go.dev/dl/?mode=json') && \
  filename=$(echo "$release_json" | jq -r --arg arch "$ARCH" \
    '[.[] | select(.stable == true)][0].files[] | select(.os == "linux" and .arch == $arch and .kind == "archive") | .filename') && \
  sha256=$(echo "$release_json" | jq -r --arg arch "$ARCH" \
    '[.[] | select(.stable == true)][0].files[] | select(.os == "linux" and .arch == $arch and .kind == "archive") | .sha256') && \
  wget -O go.tar.gz "https://go.dev/dl/${filename}" && \
  echo "${sha256}  go.tar.gz" | sha256sum -c - && \
  tar -C /usr/local -xzf go.tar.gz && \
  rm go.tar.gz
ENV PATH=$PATH:/usr/local/go/bin

# System libraries Chromium needs (fonts, libnss, libatk, etc.) for
# Playwright, installed here since it needs apt/root - the actual
# `playwright` package and browser binary install as node, further down,
# so they land in node's own npm prefix/cache correctly.
ARG PLAYWRIGHT_VERSION=1.61.1
RUN npx -y playwright@${PLAYWRIGHT_VERSION} install-deps chromium

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

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

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

# Copy and set up firewall + DNS-proxy + entrypoint scripts, the gitea-pr
# helper from this repo's bin/ directory, and the claude wrapper that pins
# --dangerously-skip-permissions. The launched application itself
# (SANDBOX_CMD, default `claude`) and any editor config for it are supplied
# at runtime, not baked into the image - see docker-compose.yml/entrypoint.sh.
COPY docker/fixed-domains.sh /usr/local/bin/
COPY docker/dns-proxy.sh /usr/local/bin/
COPY docker/init-firewall.sh /usr/local/bin/
COPY docker/log-shipper.sh /usr/local/bin/
COPY docker/ulogd.conf /etc/ulogd-sandbox.conf
COPY docker/entrypoint.sh /usr/local/bin/
COPY docker/anthropic-proxy-forwarder.js /usr/local/bin/anthropic-proxy-forwarder.js
COPY docker/claude-wrapper.sh /usr/local/bin/claude
COPY bin/gitea-pr /usr/local/bin/gitea-pr

USER root
RUN chmod +x /usr/local/bin/dns-proxy.sh /usr/local/bin/init-firewall.sh /usr/local/bin/log-shipper.sh /usr/local/bin/entrypoint.sh /usr/local/bin/gitea-pr /usr/local/bin/claude && \
  echo 'export PATH="$PATH:/usr/local/share/npm-global/bin"' > /etc/profile.d/npm-global-path.sh

# Entrypoint runs as root (no USER node here) so it can set up the firewall
# directly, with no sudo/setuid escalation path available to node at any
# point afterward. It drops to node itself via gosu before execing
# SANDBOX_CMD (default `claude` - see entrypoint.sh).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
