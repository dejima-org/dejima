#!/usr/bin/env bash
# The small terminal interface dejima-attach and dejima-allow share.
#
# Two tools ask an operator to pick one running session out of several, and
# both had to be readable on whatever terminal the operator happened to be
# holding. This is the part that does not depend on which of them is asking:
# the palette, the heading, and the prompt.
#
# What is NOT here is the row. Each tool lists a different thing from a
# different source - the registry of remote-enabled sessions on one side,
# `docker ps` on the other - so the columns are the tool's own, measured by
# the tool against its own data.
#
# Sourced, never run.

# The names are carried so a wrong hex is catchable by reading.
#
# Truecolor only: a terminal without it, or tmux without `Tc`, approximates
# 38;2 to its nearest colour rather than printing the escape, so the fallback
# already exists one layer down.
#
# Empty unless stdout is a colour-capable terminal, which keeps --list a
# machine interface (ttyd feeds run ids back in) and is also how the bats
# suite reads this script.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    C_OFF=$'\033[0m'; C_BOLD=$'\033[1m'
    C_BADGE=$'\033[38;2;254;128;25m'    # bright_orange #fe8019, the wordmark
    C_TEXT=$'\033[38;2;235;219;178m'    # light1        #ebdbb2
    C_MUTED=$'\033[38;2;146;131;116m'   # gray_245      #928374
    C_SUBTLE=$'\033[38;2;124;111;100m'  # dark4         #7c6f64
    C_RULE=$'\033[38;2;80;73;69m'       # dark2         #504945, separator
    C_OK=$'\033[38;2;184;187;38m'       # bright_green  #b8bb26, success
    C_WARN=$'\033[38;2;250;189;47m'     # bright_yellow #fabd2f, warning
    C_ERR=$'\033[38;2;251;73;52m'       # bright_red    #fb4934, error
    C_LINK=$'\033[38;2;131;165;152m'    # bright_blue   #83a598
    GLYPH_BAR='▏'; GLYPH_DOT='●'; GLYPH_RULE='─'
else
    C_OFF=""; C_BOLD=""; C_BADGE=""; C_TEXT=""; C_MUTED=""; C_SUBTLE=""
    C_RULE=""; C_OK=""; C_WARN=""; C_ERR=""; C_LINK=""
    # Glyphs ride the same switch rather than a separate UTF-8 probe. Not
    # because no-colour implies no-UTF-8, but because the two terminals this
    # has to stay readable on - a $TERM the host has no entry for, and a pipe -
    # are exactly the ones that mangle box drawing, and one flag is easier to
    # reason about than two.
    GLYPH_BAR='|'; GLYPH_DOT='*'; GLYPH_RULE='-'
fi

# The rule under the heading, the width of the heading itself. Built rather
# than written out because the heading is now the caller's: two literals kept
# next to two headings stay in step only while nobody adds a third.
#
# A loop rather than `tr`, which is byte-oriented and would shred a 3-byte box
# drawing character into three copies of nothing.
tui_rule() {
    local n="$1" i out=""
    for ((i = 0; i < n; i++)); do out+="$GLYPH_RULE"; done
    printf '%s' "$out"
}

# "dejima | <subtitle>", underlined to its own width.
# A blank screen to draw a front door on, scrollback included.
#
# The picker is reached by navigating to it - the web toolbar's SESS button is
# a full page load - and it drew on top of whatever the previous session had
# left on screen, so the rows arrived interleaved with the tail of the session
# just left. Over SSH it was invisible, because a fresh connection to the
# forced command usually starts on an empty screen (#213).
#
# 3J as well as 2J: without it a swipe up on a phone lands in the middle of
# the previous session's output, which is the same confusion one gesture away.
#
# Its own function rather than part of tui_banner, because dejima-allow's
# picker must NOT do this: that one is a prompt inside a shell the operator is
# already using, and wiping their scrollback to ask one question is worse than
# the interleaving this fixes.
#
# Rides the same switch as the colour and the glyphs, for the reason stated
# above them: one flag is easier to reason about than two, and the terminals
# that mangle box drawing are the ones these bytes should not reach either. So
# NO_COLOR turns this off as well - a reading of it this file has already
# committed to, and the alternative is a picker that answers to two different
# ideas of "plain".
tui_clear() {
    [ -n "$C_OFF" ] || return 0
    printf '\033[H\033[2J\033[3J'
}

tui_banner() {
    local subtitle="$1"
    printf '\n  %s%sdejima%s %s%s%s %s%s%s\n' \
        "$C_BOLD" "$C_BADGE" "$C_OFF" "$C_SUBTLE" "$GLYPH_BAR" "$C_OFF" \
        "$C_MUTED" "$subtitle" "$C_OFF"
    # 6 for the wordmark, 3 for the bar and the spaces either side.
    printf '  %s%s%s\n\n' "$C_RULE" "$(tui_rule $((9 + ${#subtitle})))" "$C_OFF"
}

# Asks for one of 1..$1 and leaves it in TUI_CHOICE. $2 is the verb the
# prompt opens with. Exits the caller outright on anything meaning "not this
# time" - q, an empty line, or no terminal to read from.
#
# The answer comes back in a variable rather than on stdout because those
# exits have to be the caller's. In `$(tui_pick ...)` the function runs in a
# subshell, where `exit 0` ends the subshell and hands the caller an empty
# string it would then use as an index.
#
# Numbered rather than arrow-driven: phone soft keyboards handle digits far
# better than arrow keys, and dejima-attach is the phone's entry point.
TUI_CHOICE=""
tui_pick() {
    local count="$1" verb="$2" choice
    TUI_CHOICE=""
    printf '\n  %s%s%s %s[1-%d, q to quit]%s: ' \
        "$C_MUTED" "$verb" "$C_OFF" "$C_TEXT" "$count" "$C_OFF"
    # `|| exit 0`, because a read that cannot happen is not a refusal: with no
    # controlling terminal (`ssh -T`, or an SSH app that requests no pty) this
    # returns nonzero immediately, and exiting 1 with nothing printed reads as
    # a broken front door.
    read -r choice || exit 0
    case "$choice" in
        q|Q|'') exit 0 ;;
        *[!0-9]*) echo "Not a number." >&2; exit 1 ;;
    esac
    # Normalized to base 10 once, here, because the range check and the
    # subscript the caller does with this do not read a number the same way:
    # `[` is POSIX test and decimal-only, while $(( )) reads a leading zero as
    # OCTAL. Without this, "010" - which a phone keypad makes easy to type -
    # passes the check as 10 and indexes as 8, and the caller acts on a
    # DIFFERENT session than the one picked, with nothing printed to say so.
    #
    # It fixes the two ugly shapes as well. "09" is a value here rather than
    # the "invalid octal constant" arithmetic error it is to $(( )); and a
    # number past int64 wraps to one the range check can answer for, where
    # `[ 99999999999999999999999 -gt 11 ]` instead exits 2 with "integer
    # expression expected" - which makes the `if` false, so "Out of range."
    # is never printed and the caller dies on an unbound element.
    choice="$((10#$choice))"
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo "Out of range." >&2
        exit 1
    fi
    TUI_CHOICE="$choice"
}
