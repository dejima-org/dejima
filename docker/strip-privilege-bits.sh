#!/bin/sh
# Remove every setuid bit, setgid bit and file capability in the image, then
# prove none is left.
#
# The session user has no sudo and no capabilities, and entrypoint.sh drops to
# it through gosu, which lowers privilege rather than raising it. A setuid
# binary or a file capability is the one shape an escalation out of that could
# take, so the image must contain neither - and no_new_privs, which the
# container also sets, is a second lock on the same door rather than a reason to
# skip this one.
#
# Nothing here needs its bits. su, mount, passwd, chsh, ssh-keysign and
# unix_chkpwd are of no use to an unattended non-root session that authenticates
# to nothing, and each is a well-worn step in an escape.
#
# The one with a visible consequence is utempter, setgid utmp, which terminal
# multiplexers call to record a login. Its failure is not fatal to them - tmux
# carries on without the record - and the cost is that `who` and `w` inside the
# container stop listing sessions. Worth saying because that looks like a fault
# rather than a decision.
#
# Run as the LAST instruction of a complete image, after every stage that
# installs anything: the base image's own final stage, and again at the end of
# a derived per-project layer, which installs apt packages of its own after the
# base image is finished (bin/dejima-project-lib.sh). Run earlier it would only
# cover what existed at that point, and a package installed afterwards could
# reintroduce a privileged binary with nothing to notice.
#
# The verification is why this is a build step rather than a package list:
# adding a dependency that ships a setuid binary fails the build instead of
# quietly widening the image.
#
# `--check` runs the verification alone, changing nothing. It exists so a test
# against a running container asserts the property by running this code rather
# than by restating it - in particular the root list below, which is the part
# most easily got wrong.
set -eu

check_only=false
if [ "${1:-}" = "--check" ]; then
    check_only=true
elif [ "$#" -gt 0 ]; then
    echo "usage: ${0##*/} [--check]" >&2
    exit 2
fi

# Real filesystems only. /proc, /sys and /dev are mounted during a build and
# have nothing to strip; -xdev keeps find out of them, and getcap has no
# equivalent flag, so it is pointed at the directories that can hold binaries.
roots=""
for d in /bin /boot /etc /home /lib /lib32 /lib64 /libx32 /opt /root /sbin /srv /usr /var; do
    [ -d "$d" ] && roots="$roots $d"
done

if ! $check_only; then
    # shellcheck disable=SC2086
    find $roots -xdev -type f -perm /6000 -exec chmod -s {} +

    # getcap prints "<path> <capabilities>"; strip the capabilities from each
    # file it names. A failure here is left to fail the script: a capability
    # that cannot be removed is exactly the thing this exists to catch.
    # shellcheck disable=SC2086
    getcap -r $roots 2>/dev/null | cut -d' ' -f1 | while read -r f; do
        setcap -r "$f"
    done
fi

# shellcheck disable=SC2086
remaining="$(find $roots -xdev -type f -perm /6000; getcap -r $roots 2>/dev/null)"
if [ -n "$remaining" ]; then
    printf 'privileged bits remain:\n%s\n' "$remaining" >&2
    exit 1
fi

printf 'no setuid, setgid or file-capability binaries remain\n'
