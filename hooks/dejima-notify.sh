#!/usr/bin/env bash
# Notification/Stop hook, registered ONLY into the throwaway settings.json
# copy bin/dejima generates for a session that has remote access enabled -
# never into the operator's real settings.json by install.sh. That copy is
# mounted read-only (see docker-compose.yml), so a session cannot
# unregister its own hook.
#
# It writes one empty file whose NAME is its entire meaning. No content, no
# stdin, no network. The host-side watcher composes the whole notification
# from host data, so not one byte from inside the sandbox reaches the
# operator's phone. Anything more expressive here would be an injection
# channel into a device that sits outside the sandbox - see README "Remote
# access" on why the phone is the thing being protected.
set -euo pipefail

# A whitelist, not a filter: an unrecognized event creates nothing at all.
# Sanitizing an arbitrary name into a marker would make the file name a
# channel the sandbox controls, which is the one thing this hook must not be.
case "${1:-}" in
    waiting|done) ;;
    *) exit 0 ;;
esac

# Absent outside a remote-enabled session, and the directory is a bind mount
# that only exists there. Exit quietly rather than fail: a hook that errored
# in an ordinary sandbox would surface on every notification, and there is
# nothing for it to do. Never created here either - the host owns that
# directory's lifetime (bin/dejima makes it and rm -rf's it on exit).
[ -n "${DEJIMA_NOTIFY_DIR:-}" ] || exit 0
[ -d "$DEJIMA_NOTIFY_DIR" ] || exit 0

: > "$DEJIMA_NOTIFY_DIR/$1"
