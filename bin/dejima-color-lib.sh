#!/bin/bash
# Terminal colour, shared by bin/dejima and bin/dejima-audit.
#
# Shared rather than duplicated because the two are one surface to the
# operator: the launcher's "unacknowledged CRITICAL" warning and the audit
# review it sends them to must agree about what red means, or the colour is
# decoration instead of information.
#
# Nothing here decides WHAT to highlight - that belongs with the text. It
# decides only whether colour is safe to emit at all, and provides the names.
#
# Off unless the stream being written to is a terminal, so a redirected
# report or a piped test never receives escape sequences: the audit's output
# is read back by tests and, in the reports it writes, by future runs.
# NO_COLOR (any value, https://no-color.org) and TERM=dumb both turn it off
# as well.
#
# The variables are always DEFINED, empty when colour is off, so callers
# interpolate them unconditionally and no call site needs an if.
# Session-authored text on its way to the operator's terminal. A planted value
# containing C0 escapes can scroll, clear or overwrite what is being read; C1
# controls and Unicode bidi overrides/isolates (U+202A-U+202E, U+2066-U+2069)
# reverse or reorder the displayed text without touching the bytes an operator
# would grep for. Stripped at the display boundary, after all parsing and
# TAB-splitting is done.
#
# Two forms, because the rule differs. A field is one line, so every C0 byte
# goes - including LF, which is what keeps a planted newline from forging a
# second row. A body is many lines, and applying the field rule to one would
# fold a whole epitaph onto a single line, so there LF and TAB survive and
# nothing else does. CR goes either way: it is the overwrite-this-line trick.
_sanitize_c1_bidi() {
    LC_ALL=C sed $'s/\xc2[\x80-\x9f]//g; s/\xe2\x80[\xaa-\xae]//g; s/\xe2\x81[\xa6-\xa9]//g'
}

sanitize() {
    printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | _sanitize_c1_bidi
}

# Reads the text on stdin rather than taking it as an argument: the callers
# are whole files, and a body large enough to be worth keeping is not worth
# passing through argv.
sanitize_body() {
    LC_ALL=C tr -d '\000-\010\013-\037\177' | _sanitize_c1_bidi
}

color_init() {
    local fd="${1:-1}"
    C_RESET=""; C_CRIT=""; C_WARN=""; C_INFO=""; C_PATH=""
    C_KEY=""; C_DIM=""; C_ADD=""; C_DEL=""; C_OK=""
    [ -t "$fd" ] || return 0
    [ -z "${NO_COLOR+x}" ] || return 0
    case "${TERM:-}" in ''|dumb) return 0 ;; esac
    C_RESET=$'\033[0m'
    C_CRIT=$'\033[1;31m'    # bold red - runs unsandboxed host code
    C_WARN=$'\033[33m'      # yellow
    C_INFO=$'\033[36m'      # cyan
    C_PATH=$'\033[1;36m'    # bold cyan - the file or key a finding is about
    C_KEY=$'\033[1m'        # bold - the keystroke an operator has to press
    C_DIM=$'\033[2m'        # dim - the audit's own framing around content
    C_ADD=$'\033[32m'       # green - a diff's added lines
    C_DEL=$'\033[31m'       # red - a diff's removed lines
    C_OK=$'\033[32m'        # green
}

# The colour for a tier name, so the mapping lives in one place rather than
# at each site that prints one.
tier_color() {
    case "$1" in
        CRITICAL) printf '%s' "$C_CRIT" ;;
        WARNING)  printf '%s' "$C_WARN" ;;
        *)        printf '%s' "$C_INFO" ;;
    esac
}
