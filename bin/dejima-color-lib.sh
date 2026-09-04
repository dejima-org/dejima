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

# One palette, and it is the terminal's own.
#
# gruvbox is dejima's brand, and the values below ARE gruvbox on a gruvbox
# terminal - every colour here is an ANSI slot that a gruvbox theme fills with
# the exact hex the marks use (bright green #b8bb26, bright yellow #fabd2f,
# bright red #fb4934, bright blue #83a598, bright black #928374). What it does
# not do is hardcode them.
#
# It used to, in dejima-tui-lib.sh, and that broke on any terminal whose
# background dejima does not control. Measured against a light background:
# light1 #ebdbb2 - the colour the session picker drew project names in - came
# out at 1.21:1, bright yellow at 1.49:1, bright green at 1.82:1. Nothing in
# the palette cleared 3:1 on both a dark and a light background, because a
# palette drawn for #282828 cannot.
#
# An indexed colour cannot have that problem: the theme's author chose it
# against their own background. So dejima gets its brand on the terminals set
# up for it, and legibility on the rest, and those are the same decision.
#
# The one place dejima keeps exact hexes is web/src/page.css, where it sets
# the background itself and so owns both sides of the contrast.
#
# Empty unless the fd is a colour-capable terminal, which keeps machine
# interfaces (dejima-attach --list, which ttyd feeds run ids back from)
# parseable and is how the bats suite reads these scripts.
color_init() {
    local fd="${1:-1}"
    C_RESET=""; C_CRIT=""; C_WARN=""; C_INFO=""; C_PATH=""
    C_KEY=""; C_DIM=""; C_ADD=""; C_DEL=""; C_OK=""
    C_OFF=""; C_BOLD=""; C_BADGE=""; C_TEXT=""; C_MUTED=""; C_SUBTLE=""
    C_RULE=""; C_ERR=""; C_LINK=""
    # Glyphs ride the same switch rather than a separate UTF-8 probe. Not
    # because no-colour implies no-UTF-8, but because the two terminals this
    # has to stay readable on - a $TERM the host has no entry for, and a pipe -
    # are exactly the ones that mangle box drawing, and one flag is easier to
    # reason about than two.
    GLYPH_SEP='|'; GLYPH_BAR='|'; GLYPH_DOT='*'; GLYPH_RULE='-'
    [ -t "$fd" ] || return 0
    [ -z "${NO_COLOR+x}" ] || return 0
    case "${TERM:-}" in ''|dumb) return 0 ;; esac

    C_RESET=$'\033[0m'
    C_OFF="$C_RESET"        # the pickers' name for it
    C_BOLD=$'\033[1m'
    C_KEY="$C_BOLD"         # bold - the keystroke an operator has to press
    # Default foreground, deliberately empty. This was light1 #ebdbb2, which
    # is gruvbox's own foreground - so on a gruvbox terminal it is what the
    # terminal already draws with, and on a light one it was invisible.
    C_TEXT=""
    C_DIM=$'\033[2m'
    C_SUBTLE="$C_DIM"       # dark4 receded; dim recedes against any background
    C_RULE="$C_DIM"         # dark2, ditto
    C_MUTED=$'\033[90m'     # bright black - gruvbox gray_245 #928374
    C_OK=$'\033[92m'        # bright green - gruvbox #b8bb26
    C_ADD="$C_OK"
    C_WARN=$'\033[93m'      # bright yellow - gruvbox #fabd2f
    C_ERR=$'\033[91m'       # bright red - gruvbox #fb4934
    C_DEL="$C_ERR"
    C_CRIT=$'\033[1;91m'    # bold bright red - runs unsandboxed host code
    C_INFO=$'\033[96m'      # bright cyan - gruvbox aqua #8ec07c
    C_LINK=$'\033[94m'      # bright blue - gruvbox #83a598
    C_PATH=$'\033[1;96m'    # bold - the file or key a finding is about
    # No ANSI slot is orange, and gruvbox's #fe8019 is the wordmark's colour.
    # Bold bright yellow is the nearest thing every terminal has, and it is
    # the accent rather than the brand exactly.
    C_BADGE=$'\033[1;93m'
    GLYPH_SEP='▏'; GLYPH_BAR='▏'; GLYPH_DOT='●'; GLYPH_RULE='─'
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
