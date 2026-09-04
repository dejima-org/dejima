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

# Install basic development tools, iptables/ipset (for the egress firewall),
# openssh-client (for git-over-ssh and agent forwarding), and the toolchain a
# typical nvim plugin set (telescope/treesitter/mason) expects, since
# SANDBOX_NVIM_CONFIG can point a session's editor at one.
#
# Deliberately NOT installing bubblewrap/socat: they exist to let a harness's
# own internal per-command sandboxing run, and that inner sandbox is redundant
# on top of this container - it cannot even function inside it anyway (bwrap
# cannot create a namespace here, and fixing that would need privilege
# escalation approaching --privileged, undoing this container's own
# hardening). Whichever harness has one, its plugin's harness_prepare_config
# turns it off in the override layer, so there is nothing here to satisfy.
# Claude Code's is the "sandbox" block in settings.json.
#
# libcap2-bin is capsh, which entrypoint.sh uses to hand the session a
# container it holds no capabilities in. It was already here as a dependency of
# iproute2; a security control resting on another package's dependency graph is
# one an unrelated package change removes.
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
  libcap2-bin \
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

# Lets the harness, and the SessionStart hook it runs, know it is inside this
# container rather than directly on the host.
ENV DEJIMA=1

# Dedicated unprivileged user for ulogd2 (see entrypoint.sh) - unlike
# dnsmasq, the ulogd2 Debian package doesn't create one of its own. ulogd2
# opens its log/output files and the NFLOG netlink socket before dropping to
# this user, so it doesn't need to own anything itself.
RUN useradd -r -s /usr/sbin/nologin ulogd

# Every fetch from here down retries. What matters is not the odds of one
# download failing but of ANY of them failing, and without retries a single
# blip discards the whole build.
#
# These steps sit ABOVE the SANDBOX_* ARGs on purpose: nothing here needs the
# sandbox user, so a build overriding a uid (runtime.bats, and any host not
# on 1000) still reuses every layer to this point. That ordering alone was
# most of the cost of an override rebuild, for a difference amounting to one
# useradd.
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
# bin/dejima - so absolute paths under $HOME resolve identically inside and
# outside the container, instead of needing a one-off dual-mount for every
# individual thing that assumes the real host path. Harnesses do assume it:
# Claude Code's installed_plugins.json records an installPath it resolves as a
# literal host-absolute string rather than relative to whatever $HOME is. Defaults below
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
# scoped to npm-global: Neovim unpacks into /usr/local/share/nvim above this
# line, and recursing from the parent would hand the sandbox user Neovim's
# runtime files. /usr/local/share itself is still
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
# not a fixed /workspace, so a harness keying its project or session history
# on the working directory resolves to the same key inside and outside.
#
# Only .ssh here. The directories a harness keeps state in are that harness's,
# declared as `image_dirs` in its manifest and created in its own image layer -
# this image is shared by every harness and must name none of them. The reason
# they have to exist at all is the same either way: only enumerated paths
# inside them come from the host, and Docker creates the parents of a mount
# point root-owned if they are not already there, which would leave the
# sandbox user unable to write the state it keeps beside them.
RUN mkdir -p $SANDBOX_HOME/.ssh && \
  chown $SANDBOX_USER:$SANDBOX_USER $SANDBOX_HOME/.ssh && \
  chmod 700 $SANDBOX_HOME/.ssh

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

# No harness here. The image is shared by every project on the host, and
# baking one harness into it means every sandbox carries it whether or not it
# is the one selected - and a second harness could only ever be added to the
# same shared image, never chosen between. The selected harness installs into
# a layer on top instead, from the `install` spec in its own manifest, the
# same way an approved dependency does (bin/dejima, build_harness_layer).
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
# Chromium's own process sandbox is probably not active here: it launches
# without error, but chrome_sandbox is not setuid-root in this image and the
# unprivileged-userns restriction that broke bubblewrap applies, so it just
# fails softer than bubblewrap did. Not treated as a boundary either way -
# the container is the boundary, and a session already has node-level shell
# access that a Chromium exploit could not exceed.
RUN npm install -g playwright@${PLAYWRIGHT_VERSION} && \
  npx playwright install chromium

# Copy and set up firewall + DNS-proxy + entrypoint scripts, every forge's
# CLI helpers, and the harness wrapper that pins whichever no-confirm flags
# the selected harness needs. The wrapper is installed under a neutral name:
# the image is shared across harnesses and the selection is per launch, so
# entrypoint.sh is what links it into place as the harness's own command.
# The launched application itself (SANDBOX_CMD) and any editor config for it
# are supplied at runtime, not baked into the image - see
# docker-compose.yml/entrypoint.sh.
COPY docker/fixed-domains.sh /usr/local/bin/
COPY docker/caps-lib.sh /usr/local/bin/
COPY docker/dns-proxy.sh /usr/local/bin/
COPY docker/init-firewall.sh /usr/local/bin/
COPY docker/firewall-up.sh /usr/local/bin/
COPY docker/filter-entrypoint.sh /usr/local/bin/
COPY docker/log-shipper.sh /usr/local/bin/
COPY docker/ulogd.conf /etc/ulogd-sandbox.conf
# Into $VIMRUNTIME/plugin, not /etc/xdg/nvim - see the file's own comment.
COPY docker/sandbox-clipboard.lua /usr/local/share/nvim/runtime/plugin/sandbox-clipboard.lua
COPY docker/entrypoint.sh /usr/local/bin/
COPY docker/credential-proxy-forwarder.js /usr/local/bin/credential-proxy-forwarder.js
COPY docker/harness-wrapper.sh /usr/local/bin/dejima-harness-wrapper
# The two guards that do not need the harness's help. git-guard shadows git on
# PATH; forge-guard is linked over a forge CLI by entrypoint.sh when a workflow
# blocks one of its subcommands. Both are copied in unconditionally and cost
# nothing until something puts them on PATH.
COPY docker/git-guard.sh /usr/local/lib/dejima/git-guard.sh
COPY docker/forge-guard.sh /usr/local/lib/dejima/forge-guard.sh
# The briefing renderer, which every harness needs and no harness owns. Baked
# in rather than reached through the ~/.claude/hooks mount, because that mount
# is Claude Code's configuration: sandbox-context.sh calls this, and so does
# entrypoint.sh, which renders the briefing before the session starts - to
# hand to the harness as an argument, or to write to a file it reads.
COPY hooks/dejima-briefing-render.sh /usr/local/lib/dejima/dejima-briefing-render.sh
# dejima's own hooks, for the same reason and one more: they are registered
# into the sandbox's --settings overlay rather than into the operator's
# ~/.claude/settings.json, so nothing has to be written to a host config to
# make the sandbox work. Baked rather than mounted from the checkout because a
# guard whose script can change under a running session is not one.
#
COPY hooks/deny-dangerous-bash.sh /usr/local/lib/dejima/hooks/deny-dangerous-bash.sh
COPY hooks/sandbox-context.sh /usr/local/lib/dejima/hooks/sandbox-context.sh
COPY hooks/git-push-guard.sh /usr/local/lib/dejima/hooks/git-push-guard.sh
COPY hooks/merge-guard.sh /usr/local/lib/dejima/hooks/merge-guard.sh
COPY hooks/dejima-notify.sh /usr/local/lib/dejima/hooks/dejima-notify.sh
# Back to root before the first RUN that writes outside /home/node. The npm
# installs above run as node deliberately; COPY writes as root regardless of
# USER, so the copies above are unaffected, but the install(1) below is a RUN
# and would inherit node and fail on /usr/local/bin.
USER root

# Every forge's CLIs, not just the selected one: a forge CLI is inert without
# its API URL and token, and an image that is identical regardless of which
# forge is configured is one less thing for the exit audit to explain.
COPY forges/ /tmp/forges/
COPY docker/install-forge-bins.sh /tmp/install-forge-bins.sh
RUN bash /tmp/install-forge-bins.sh /tmp/forges /usr/local/lib/dejima/forge /usr/local/bin \
    && rm -rf /tmp/forges /tmp/install-forge-bins.sh

# The other half of NODE_PATH, which only ever applied to require(): ESM
# resolution ignores it entirely and walks up from the importing file looking
# for node_modules, so `import { chromium } from "playwright"` fails from
# every directory a script is likely to be written in while require() of the
# same package succeeds. At the root, that walk always ends here.
#
# It is worth a line because of how the failure reads. An agent writing the
# modern form gets ERR_MODULE_NOT_FOUND, concludes the image has no browser,
# and describes what a page should look like instead of going and seeing.
RUN ln -s /usr/local/share/npm-global/lib/node_modules /node_modules

RUN chmod +x /usr/local/bin/dns-proxy.sh /usr/local/bin/init-firewall.sh /usr/local/bin/firewall-up.sh /usr/local/bin/filter-entrypoint.sh /usr/local/bin/log-shipper.sh /usr/local/bin/entrypoint.sh /usr/local/bin/dejima-harness-wrapper /usr/local/lib/dejima/git-guard.sh /usr/local/lib/dejima/forge-guard.sh /usr/local/lib/dejima/dejima-briefing-render.sh /usr/local/lib/dejima/hooks/*.sh && \
  echo 'export PATH="$PATH:/usr/local/share/npm-global/bin"' > /etc/profile.d/npm-global-path.sh

# Entrypoint runs as root (no USER node here) so it can set up the firewall
# directly, with no sudo/setuid escalation path available to node at any
# point afterward. It drops to node itself via gosu before execing
# SANDBOX_CMD, which bin/dejima sets from the selected harness's manifest.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
