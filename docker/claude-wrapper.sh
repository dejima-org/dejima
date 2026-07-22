#!/bin/bash
# Shadows the real `claude` binary (installed under npm-global/bin, later on
# PATH) so every invocation - interactive shell, or claudecode.nvim's
# terminal - runs with --dangerously-skip-permissions, without callers
# needing to know that.
exec /usr/local/share/npm-global/bin/claude --dangerously-skip-permissions "$@"
