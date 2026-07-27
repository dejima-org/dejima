#!/bin/bash
# Sourceable helper for the per-project config tooling (bin/claude-sandbox,
# claude-sandbox-allow, claude-sandbox-dep, claude-sandbox-project).
#
# Two kinds of file are involved and they are NOT equally trusted:
#
#   .claude-sandbox/{allowed-domains,dependencies} in the project - a
#   DECLARATION. The project directory is bind-mounted read-write, so a
#   compromised session can write these. They grant nothing; they are read
#   only to compare against reality and suggest a command for the user to
#   run. Parsed, never sourced - same reason bin/claude-sandbox-env.sh
#   refuses to source config/env.
#
#   ~/.config/claude-sandbox/projects/<slug>/* - an APPROVAL. Written only
#   by the CLIs, which only the user runs, and never mounted into the
#   container. This is the only thing that actually grants anything.

CLAUDE_SANDBOX_MAX_DECLARED=200

# Same expression bin/claude-sandbox-allow validates with - a declared
# domain has to survive being written into a dnsmasq server=/domain/ line.
valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,62}\.)*[a-zA-Z0-9-]{1,63}$ ]]
}

# <ecosystem>:<name>. The character class is deliberately narrow: an
# approved spec gets interpolated into a generated Dockerfile RUN line, so
# anything shell-active here would be a root-context injection at build.
valid_dep_spec() {
    [[ "$1" =~ ^(apt|npm|pip|cargo):[A-Za-z0-9._+-]+$ ]]
}

# read_declared <file> <validator-fn>
# Prints "ok <entry>" / "rejected <entry>" per entry, plus a final
# "truncated <total>" when the cap kicked in. Invalid entries are reported
# rather than dropped - a project declaring something malformed should be
# visibly refused, not silently ignored.
read_declared() {
    local file="$1" validator="$2" line count=0 total=0
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        total=$((total + 1))
        [ "$count" -ge "$CLAUDE_SANDBOX_MAX_DECLARED" ] && continue
        count=$((count + 1))
        if "$validator" "$line"; then
            printf 'ok %s\n' "$line"
        else
            printf 'rejected %s\n' "$line"
        fi
    done < "$file"
    if [ "$total" -gt "$CLAUDE_SANDBOX_MAX_DECLARED" ]; then
        printf 'truncated %s\n' "$total"
    fi
    return 0
}
