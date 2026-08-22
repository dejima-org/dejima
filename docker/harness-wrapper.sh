#!/bin/bash
# Shadows the selected harness's real binary on PATH, so every invocation -
# the entrypoint's, an interactive shell's, an editor plugin's terminal -
# runs with the flags dejima requires, without any caller needing to know
# that.
#
# Installed by entrypoint.sh under the harness's own command name rather than
# COPYed to a fixed one at build time: the image is shared across harnesses
# and the selection is per launch, so which name to shadow is only known once
# the container starts.
#
# Every value here comes from the selected harness's manifest, resolved on
# the host (see bin/dejima) and passed in as environment. Nothing about any
# one harness is written down in this file.
#
#   SANDBOX_HARNESS_REAL      the real binary this shadows
#   SANDBOX_HARNESS_ARGS      the no-confirm flags, without which the agent
#                             stops to ask and the arrangement becomes a
#                             worse way of running it on the host
#   SANDBOX_HARNESS_SETTINGS  how this harness is told to read dejima's own
#                             settings layer, if it reads one at all
#
# The settings layer arrives as an extra layer rather than as a mount over
# the harness's own config file (docker-compose.yml, #47). That only holds if
# every entry point passes it, which is what shadowing the binary buys.
# /etc/dejima-settings.json is absent when a container is started without
# bin/dejima, as test/runtime.bats does, so its flag stays conditional on the
# file rather than on the manifest key alone.
#
# Word-split deliberately: both carry flags, which have no spaces, and an
# array is what exec needs. A harness whose flags need quoting has outgrown
# this and should say so in its plugin.
set -u

if [ -z "${SANDBOX_HARNESS_REAL:-}" ] || [ ! -x "${SANDBOX_HARNESS_REAL:-}" ]; then
    echo "dejima: no harness binary at '${SANDBOX_HARNESS_REAL:-<unset>}'." >&2
    echo "dejima: command_path in the harness manifest is what names it." >&2
    exit 127
fi

args=()
# shellcheck disable=SC2206
[ -n "${SANDBOX_HARNESS_ARGS:-}" ] && args=(${SANDBOX_HARNESS_ARGS})

settings=()
# shellcheck disable=SC2206
[ -n "${SANDBOX_HARNESS_SETTINGS:-}" ] && [ -f /etc/dejima-settings.json ] \
    && settings=(${SANDBOX_HARNESS_SETTINGS})

# The briefing, for a harness that takes it as an argument. Two elements: the
# flag the manifest names, then the rendered text as a single value - NOT
# word-split like the two above, because this is prose rather than flags.
#
# Here rather than only in the entrypoint's own invocation, for the reason the
# settings layer is: an interactive shell, an editor plugin or a nested run
# starts the harness too, and a session that reaches the model without its
# briefing does not know it is sandboxed. Conditional on the file so a
# container started without bin/dejima - as test/runtime.bats does - still
# runs the harness rather than failing on a path nothing wrote.
briefing=()
# shellcheck disable=SC2206
[ -n "${SANDBOX_HARNESS_BRIEFING_ARGS:-}" ] && [ -n "${DEJIMA_BRIEFING_RENDERED:-}" ] \
    && [ -f "$DEJIMA_BRIEFING_RENDERED" ] \
    && briefing=(${SANDBOX_HARNESS_BRIEFING_ARGS} "$(cat "$DEJIMA_BRIEFING_RENDERED")")

exec "$SANDBOX_HARNESS_REAL" \
    ${args[@]+"${args[@]}"} ${settings[@]+"${settings[@]}"} \
    ${briefing[@]+"${briefing[@]}"} "$@"
