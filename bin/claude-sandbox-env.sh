#!/bin/bash
# Sourceable helper for bin/claude-sandbox. Parses ALLOWED_DOMAINS out of the
# repo's config/env WITHOUT executing the file: config/env sits inside this
# repo, which is itself a mountable (and thus writable-from-inside)
# workspace, so `source`-ing it would let a compromised self-mounted session
# plant arbitrary host shell for the next launch to run. Read the one value
# we actually persist there, validate it, and hand it back as a string.

# Echoes a validated ALLOWED_DOMAINS value (space-separated domain list) from
# the given file, or empty string if absent/unparseable. Never executes file
# contents.
parse_allowed_domains_env() {
    local file="$1" line value
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        # strip leading whitespace; skip blanks and comments
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        # accept only:  [export ]ALLOWED_DOMAINS=VALUE  or  ="VALUE"
        case "$line" in
            'export ALLOWED_DOMAINS='*) value="${line#export ALLOWED_DOMAINS=}" ;;
            'ALLOWED_DOMAINS='*)        value="${line#ALLOWED_DOMAINS=}" ;;
            *) continue ;;
        esac
        # strip a single pair of surrounding double quotes, if present
        if [ "${value#\"}" != "$value" ] && [ "${value%\"}" != "$value" ]; then
            value="${value#\"}"; value="${value%\"}"
        fi
        # reject anything with shell-active characters - a domain list never
        # legitimately contains these, and rejecting keeps a loosened writer
        # from smuggling something executable back in downstream.
        case "$value" in
            *['$`;&|()<>'$'\n''\']*) value=""; continue ;;
        esac
        printf '%s' "$value"
        return 0
    done < "$file"
    return 0
}
