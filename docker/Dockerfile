# What belongs in here is what the sandbox itself needs, plus the editor and
# browser tooling that has no route through the dependency mechanism. Language
# toolchains and per-project utilities do have one - `dejima-dep`, including
# tarball: for a release archive - so they are declared by the projects that
# want them rather than carried by every sandbox on the host. Anything added
# below is added for every project, forever, with no review anywhere.
FROM node:22

# Timestamps inside the container match the ones outside it. Validated rather
# than trusted: an unknown zone leaves the container silently on UTC, and a log
# line an hour out of step with the operator's own is harder to distrust than a
# build that refused. /etc/localtime covers everything that reads the system
# zone; TZ in the environment covers what consults it directly, Node among them.
ARG TZ=Etc/UTC
RUN [ -f "/usr/share/zoneinfo/$TZ" ] || { echo "unknown timezone: $TZ" >&2; exit 1; }; \
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && \
  echo "$TZ" > /etc/timezone
ENV TZ="$TZ"

# What a session is expected to have without installing anything: git and a
# forge client, tools to read and search a tree, an editor, the network tools
# the egress policy is written against, and enough of a toolchain to build a
# small thing. Sorted, so adding one is a one-line diff rather than a judgement
# about where it goes.
#
# nftables rather than iptables and ipset. One tool covers both packet
# filtering and the named address sets the policy needs; one inet table covers
# v4 and v6, so an allowlist cannot cover one family and silently ignore the
# other; sets take CIDR intervals directly; and a whole ruleset loads as a
# single transaction, so the namespace is never left half-filtered. See
# docker/egress-policy.
#
# dnsmasq-base rather than dnsmasq: the binary without the init script, service
# user and default configuration, none of which apply - there is no init system
# here to run them, and egress-policy generates the configuration per launch.
#
# No CIDR aggregation package. Collapsing a list of ranges is a few lines of the
# Python standard library, which is here anyway, and the packaged option
# predates IPv6 - see docker/cidr-collapse.
#
# bash-completion rather than a shell framework: the session shell is the base
# image's bash, configured by this image in /etc/bash.bashrc.d rather than by an
# installer fetched at build time. See the shell section below.
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
  bash-completion \
  bind9-dnsutils \
  build-essential \
  dnsmasq-base \
  fd-find \
  fzf \
  gh \
  git \
  gnupg2 \
  iproute2 \
  jq \
  less \
  libcap2-bin \
  nano \
  nftables \
  openssh-client \
  openssl \
  procps \
  python3 \
  python3-pip \
  ripgrep \
  ulogd2 \
  ulogd2-json \
  unzip \
  xz-utils \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && ln -s "$(command -v fdfind)" /usr/local/bin/fd

# Deliberately NOT set: DEVCONTAINER, or any other variable announcing this as
# a generic development container. It is not one - it is a sandbox with an
# egress firewall and no path back to root - and tools change behaviour when
# they see such a flag, on an assumption about their environment that does not
# hold here. What a harness actually needs to know is below, and says the thing
# that is true.

# Lets the harness, and the SessionStart hook it runs, know it is inside this
# container rather than directly on the host.
ENV DEJIMA=1

# Dedicated unprivileged user for ulogd2 (see firewall-up.sh) - the ulogd2
# Debian package doesn't create one of its own. ulogd2 opens its log/output
# files and the NFLOG netlink socket before dropping to this user, so it
# doesn't need to own anything itself.
RUN useradd -r -s /usr/sbin/nologin ulogd

# The account the DNS forwarder drops to, and nothing else ever runs as.
# Permission to speak to a resolver outside this network namespace is a uid
# match in the packet filter (docker/egress-policy), so this account IS that
# permission: anything else running as it would inherit the one route out that
# the name allowlist exists to close.
#
# `nobody` would be the obvious choice and is the wrong one. It is where every
# unprivileged program lands when it drops privilege without having an account
# of its own, so a permission keyed to it is a permission granted to all of
# them. Created here rather than by a package, so nothing else can be given it.
RUN useradd -r -M -s /usr/sbin/nologin egress-resolver

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

# Where globally installed Node CLIs go: this image's own later stages, and an
# operator's declared npm dependencies at launch. Both have to work as the
# sandbox user, which has no sudo and never will, so the prefix has to be a
# directory that user owns.
#
# A directory of its own rather than a subdirectory of a shared one, because
# "owned by the sandbox user" and "put here by npm" then describe the same set
# of files. Under /usr/local/share they do not: Neovim unpacks into
# /usr/local/share/nvim, and one careless -R would hand the session write access
# to the editor's own runtime.
RUN mkdir -p /opt/node-tools/bin /opt/node-tools/lib/node_modules && \
  chown -R $SANDBOX_USER:$SANDBOX_USER /opt/node-tools

# Shell history, on a named volume (docker-compose.yml) so a session started
# tomorrow sees what was typed today. Created here so the directory exists with
# the right owner and mode even on a run with nothing mounted over it - Docker
# seeds a fresh named volume from what is already at the mount path, ownership
# included, so this is also what keeps the volume writable by that user rather
# than root. The shell that reads it is configured below.
RUN mkdir -p /var/opt/shell-history && \
  touch /var/opt/shell-history/.bash_history && \
  chown -R $SANDBOX_USER:$SANDBOX_USER /var/opt/shell-history && \
  chmod 0700 /var/opt/shell-history

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

# The working directory an isolated session gets instead of a project mount.
# Outside $SANDBOX_HOME on purpose: bin/dejima still reads this path on the
# HOST for a few things (an origin URL, a self-hosting check), so a path the
# operator might plausibly have - ~/work - would have those read a real
# directory of theirs. Nothing on a host is at /dejima.
RUN mkdir -p /dejima/work && \
  chown -R $SANDBOX_USER:$SANDBOX_USER /dejima

# Pre-create the nvim data/state/cache dirs owned by the sandbox user,
# since they're mounted as named volumes in docker-compose.yml: Docker
# seeds a fresh named volume from whatever already exists at the mount
# path in the image, ownership included, so this is what keeps those
# volumes writable by that user instead of defaulting to root.
RUN mkdir -p $SANDBOX_HOME/.local/share/nvim $SANDBOX_HOME/.local/state/nvim $SANDBOX_HOME/.cache/nvim && \
  chown -R $SANDBOX_USER:$SANDBOX_USER $SANDBOX_HOME/.local $SANDBOX_HOME/.cache

# Everything from here to the `USER root` below runs as the sandbox user, so
# that global npm installs land in the prefix that user owns.
USER $SANDBOX_USER

ENV NPM_CONFIG_PREFIX=/opt/node-tools
# Appended, not prepended. /usr/local/bin holds the harness wrapper, which
# shadows the harness's real binary to pin the no-confirm, settings and
# briefing flags - and the real binary is npm-installed, so putting this
# directory first would let it win and drop every one of those flags silently.
ENV PATH=$PATH:/opt/node-tools/bin

# The session shell is the base image's own bash. It is what the sandbox user's
# account is already set to, and configuring it costs this image one file
# instead of a package and an installer downloaded at build time.
#
# That download is the reason, not the package. A build-time fetch of a script
# that is then executed is a supply-chain surface, and this image is a security
# boundary: whatever it installs runs in every sandbox on the host, forever,
# with no review anywhere. What a prompt framework would have set up is written
# out in session-bashrc.sh instead, where it can be read.
ENV SHELL=/bin/bash

# Anything that spawns an editor - `git commit` with no message, an interactive
# rebase - reads these. Unset, git falls back to whatever /usr/bin/editor points
# at, and an unattended session that lands in a modal editor it cannot name the
# exit key for will sit there until something kills it. nano prints its own.
ENV EDITOR=nano
ENV VISUAL=nano
ENV PAGER=less

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
COPY docker/session-bashrc.sh /etc/bash.bashrc.d/10-session.bash
COPY docker/fixed-domains.sh /usr/local/bin/
COPY docker/caps-lib.sh /usr/local/bin/
COPY docker/egress-policy /usr/local/sbin/egress-policy
COPY docker/dns-lookup-log /usr/local/sbin/dns-lookup-log
COPY docker/cidr-collapse /usr/local/bin/cidr-collapse
COPY docker/firewall-up.sh /usr/local/bin/
COPY docker/filter-entrypoint.sh /usr/local/bin/
COPY docker/log-shipper.sh /usr/local/bin/
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
# The policy both of those apply, and that the two hooks beside them apply to
# the same command from the other side. One copy, so a bypass is fixed once.
COPY docker/guard-lib.sh /usr/local/lib/dejima/guard-lib.sh
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

# What makes a globally installed package resolvable from a script in any
# directory. Both of Node's resolvers find a bare specifier by walking
# node_modules directories upwards from the importing file, and every path
# bottoms out at /, so one here is visible everywhere - including from a
# directory with no dependency tree of its own.
#
# It is worth a line because of how the failure reads without it. An agent
# writing `import { chromium } from "playwright"` gets ERR_MODULE_NOT_FOUND,
# concludes the image has no browser, and describes what a page should look
# like instead of going and seeing.
RUN ln -s /opt/node-tools/lib/node_modules /node_modules

# Source the snippet directory from the system rc file, so every interactive
# bash gets it, and from the sandbox user's own ~/.bashrc, so it is applied
# after the Debian skeleton rc file rather than being undone by it. The guard on
# the append keeps a rebuild on a changed base from adding the loop twice.
RUN grep -q 'bash.bashrc.d' /etc/bash.bashrc || \
    printf '\nfor __rc in /etc/bash.bashrc.d/*.bash; do\n  [ -r "$__rc" ] && . "$__rc"\ndone\nunset __rc\n' >> /etc/bash.bashrc; \
  printf '%s\n' \
    '# The sandbox shell configuration this image installs. Sourced here as well' \
    '# as from /etc/bash.bashrc so it is applied last, after the Debian defaults.' \
    '[ -r /etc/bash.bashrc.d/10-session.bash ] && . /etc/bash.bashrc.d/10-session.bash' \
    > "$SANDBOX_HOME/.bashrc" && \
  chown "$SANDBOX_USER:$SANDBOX_USER" "$SANDBOX_HOME/.bashrc"

RUN chmod +x /usr/local/sbin/egress-policy /usr/local/sbin/dns-lookup-log /usr/local/bin/cidr-collapse /usr/local/bin/firewall-up.sh /usr/local/bin/filter-entrypoint.sh /usr/local/bin/log-shipper.sh /usr/local/bin/entrypoint.sh /usr/local/bin/dejima-harness-wrapper /usr/local/lib/dejima/git-guard.sh /usr/local/lib/dejima/forge-guard.sh /usr/local/lib/dejima/dejima-briefing-render.sh /usr/local/lib/dejima/hooks/*.sh && \
  echo 'export PATH="$PATH:/opt/node-tools/bin"' > /etc/profile.d/node-tools-path.sh

# Last instruction that changes the filesystem, and it has to stay last: it
# removes every setuid bit, setgid bit and file capability in the image and
# fails the build if one survives, which only holds for what already exists
# when it runs. A derived per-project layer runs it again at its own end, for
# the packages it installs after this point - see bin/dejima-project-lib.sh.
COPY docker/strip-privilege-bits.sh /usr/local/sbin/strip-privilege-bits
RUN chmod +x /usr/local/sbin/strip-privilege-bits && /usr/local/sbin/strip-privilege-bits

# Entrypoint runs as root (no USER node here) so it can set up the firewall
# directly, with no sudo/setuid escalation path available to node at any
# point afterward. It drops to node itself via gosu before execing
# SANDBOX_CMD, which bin/dejima sets from the selected harness's manifest.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
