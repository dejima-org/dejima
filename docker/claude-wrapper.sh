#!/bin/bash
# Shadows the real `claude` binary (installed under npm-global/bin, later on
# PATH) so every invocation - interactive shell, or claudecode.nvim's
# terminal - runs with --dangerously-skip-permissions, without callers
# needing to know that.
#
# The sandbox's settings overrides arrive the same way: as an extra
# --settings layer rather than by mounting over ~/.claude/settings.json (see
# docker-compose.yml and #47). That only holds if every entry point passes
# the flag, and shadowing the binary is what makes it true for the
# invocations the entrypoint never sees. The file is absent when a container
# is started without bin/dejima, as test/runtime.bats does.
settings=()
[ -f /etc/dejima-settings.json ] && settings=(--settings /etc/dejima-settings.json)

exec /usr/local/share/npm-global/bin/claude --dangerously-skip-permissions "${settings[@]}" "$@"
