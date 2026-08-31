#!/usr/bin/env python3
"""Drives bin/dejima-tty-suspend the way a user drives Ctrl-Z, and reports.

Ctrl-Z cannot be tested by sending a signal: the whole question is whether the
terminal turns that keystroke INTO a signal, or passes it through as a byte.
That needs a real terminal, and a real job-control shell to suspend a job and
bring it back - the kernel discards SIGTSTP sent to an orphaned process group,
which is what a launcher started any other way ends up in.

So: a pty, an interactive shell on it, and a stand-in for the container run
that does the one thing that matters here - put the terminal in raw mode and
proxy keystrokes onward. Docker is not available where these tests run, and is
not what is being tested; the terminal handling is.

Usage: tty-suspend-harness.py <helper-script> <shell>
Prints one "PASS <name>" or "FAIL <name> <detail>" per line, and exits nonzero
if any failed.
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

HELPER = os.path.abspath(sys.argv[1])
SHELL = sys.argv[2] if len(sys.argv) > 2 else "bash"
# Required, not defaulted. The fallback was "/tmp", and the three paths below
# are then fixed names in a world-writable directory that this fixture goes on
# to WRITE and EXECUTE. Every bats caller passes a directory, so nothing
# shipped ever took that branch - but this runs on CI hosts, and a predictable
# executed path is not a thing to leave lying around for the one caller that
# forgets (#249).
WORK = os.environ.get("TTY_SUSPEND_WORK")
if not WORK:
    sys.exit("tty-suspend-harness: set TTY_SUSPEND_WORK to a directory of its own")
RECEIVED = os.path.join(WORK, "received")
LAUNCHER = os.path.join(WORK, "launcher.sh")
CONTAINER = os.path.join(WORK, "container.py")

# A stand-in for `docker compose run`: raw mode, then proxy stdin onward.
# "Onward" is a file, which is what lets a test see whether a keystroke reached
# the container or was turned into a signal before it could.
open(CONTAINER, "w").write('''#!/usr/bin/env python3
import fcntl, os, signal, struct, sys, termios, tty
fd = 0
saved = termios.tcgetattr(fd)

def _size():
    return struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\\0" * 8))[:2]

# Redraws only when the dimensions ACTUALLY moved, which is what both shipped
# harnesses do. Measured on a pty, bytes written in a fixed window after each
# kind of poke:
#
#                    idle   same-size SIGWINCH   size changed and back
#   Claude Code         0                    0                    3337
#   Cline               0                    0                   17810
#   nvim (control)      0                 3356                    6724
#
# The first version of this stand-in redrew on the bare signal, like nvim. That
# is the one behaviour the programs dejima actually runs do not have, so the
# suite could not see that the resume poke was a no-op for both of them.
_last = [_size()]

def _on_winch(*a):
    now = _size()
    if now == _last[0]:
        return
    _last[0] = now
    sys.stdout.write("CONTAINER-REDRAW\\r\\n")
    sys.stdout.flush()

signal.signal(signal.SIGWINCH, _on_winch)
# The finding of #179, as something a test can observe: the client survives
# SIGSTOP and does not survive SIGTSTP, so the launcher has to start it with
# SIGTSTP already ignored. Read back rather than caught - installing a handler
# would REPLACE the inherited SIG_IGN and defeat the very thing being checked,
# which is what the first version of this did.
_ign = 0
for _line in open("/proc/self/status"):
    if _line.startswith("SigIgn"):
        _ign = int(_line.split()[1], 16)
if _ign & (1 << (signal.SIGTSTP - 1)):
    sys.stdout.write("CONTAINER-TSTP-IGNORED\\r\\n")
    sys.stdout.flush()
tty.setraw(fd)
# What a full-screen harness does on startup, and does not undo on a suspend.
sys.stdout.write("\\033[?25l")
sys.stdout.write("CONTAINER-ATTACHED\\r\\n"); sys.stdout.flush()
open(%r, "wb").close()
try:
    while True:
        try:
            b = os.read(fd, 1)
        except OSError:
            break
        if not b:
            break
        with open(%r, "ab") as fh:
            fh.write(b)
        if b == b"\\x1a":
            # What a harness that implements Ctrl-Z does, and why the byte
            # reaching the container is fatal: it stops itself, and there is no
            # job-control shell in a container to continue it.
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
            sys.stdout.write("CONTAINER-SUSPENDED-ITSELF\\r\\n"); sys.stdout.flush()
            os.kill(os.getpid(), signal.SIGSTOP)
            tty.setraw(fd)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, saved)
''' % (RECEIVED, RECEIVED))

# dejima's shape: background children in one process group, the helper, then
# the container run in the foreground.
# TTY_SUSPEND_NO_HELPER leaves the helper out, which is dejima before this
# existed. It is the control: a harness that cannot see the bug cannot be
# trusted to see the fix either.
HELPER_EXPECTED = not os.environ.get("TTY_SUSPEND_NO_HELPER")
start_helper = '"%s" &\nhelper=$!' % HELPER if HELPER_EXPECTED else ""
# bin/dejima's shape: the client inherits SIGTSTP ignored and is started with
# the terminal, and the keystroke is converted into an explicit SIGSTOP for it
# before the launcher stops itself. Without the conversion the client is the
# one thing that must not be stopped by a catchable signal.
open(LAUNCHER, "w").write('''#!/bin/bash
sleep 300 &
sleep 300 &
%s
trap '' TSTP
python3 %s < /dev/tty &
client=$!
trap - TSTP
on_tstp() {
    kill -STOP "$client" 2>/dev/null || true
    printf '\\033[?25h' > /dev/tty 2>/dev/null || true
    trap - TSTP
    kill -TSTP $$
    trap on_tstp TSTP
    kill -CONT "$client" 2>/dev/null || true
}
trap on_tstp TSTP
while kill -0 "$client" 2>/dev/null; do
    wait "$client" && break
    case "$?" in 146|148) continue ;; esac
    break
done
kill "${helper:-0}" 2>/dev/null || true
echo LAUNCHER-DONE
''' % (start_helper, CONTAINER))

# 77 means "no terminal to test with", which bats turns into a skip. A machine
# that cannot allocate a pty cannot answer the question either way, and a
# failure there would say something untrue about the code.
try:
    master, slave = pty.openpty()
except OSError as exc:
    sys.stderr.write("no pty available: %s\n" % exc)
    sys.exit(77)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
    if slave > 2:
        os.close(slave)
    os.close(master)
    # LC_ALL=C so the shell's job-control notice is the "Stopped" this expects.
    # Left to the environment it is whatever locale the runner happens to have,
    # and the assertion then fails on a translated message with nothing about
    # the terminal handling having changed (#249).
    env = dict(os.environ, PS1="PROMPT> ", LC_ALL="C", LANG="C")
    args = [SHELL, "--norc", "-i"] if "bash" in SHELL else [SHELL, "-f", "-i"]
    os.execvpe(SHELL, args, env)
os.close(slave)

seen = []
failures = []
transcript_all = ""


def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 0.05)
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                return
            if not chunk:
                return
            text = chunk.decode("utf-8", "replace")
            seen.append(text)
            global transcript_all
            transcript_all += text


def expect(text, timeout=8.0):
    """Wait for text to appear in output since the last call to forget()."""
    end = time.time() + timeout
    while time.time() < end:
        if text in "".join(seen):
            return True
        pump(0.1)
    return text in "".join(seen)


def forget():
    del seen[:]


def send(s):
    os.write(master, s.encode())
    pump(0.3)


def lflag():
    return termios.tcgetattr(master)[3]


def reclaimed():
    """True once dejima-tty-suspend has taken ^Z back from the container's raw mode.

    Read off the pty rather than inferred from output, and specific enough to
    mean only the helper. Raw mode has ISIG off; a plain shell has ISIG on with
    intr at ^C. Only the helper leaves ISIG on, susp at ^Z, and intr undefined
    - which is the whole of what it does, so this is the feature's precondition
    stated exactly.
    """
    attrs = termios.tcgetattr(master)
    cc = attrs[6]
    return bool(attrs[3] & termios.ISIG) \
        and cc[termios.VSUSP] == b"\x1a" \
        and cc[termios.VINTR] == b"\x00"


def await_reclaim(timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        if reclaimed():
            return True
        pump(0.05)
    return reclaimed()


def raw_restored():
    """True once the resumed client has put the terminal back into raw mode."""
    flags = lflag()
    return not (flags & termios.ICANON) and not (flags & termios.ECHO)


def await_raw(timeout=15.0):
    """Wait for that, rather than reading the flags at a fixed moment after fg.

    `fg` returns as soon as the job is continued; the client sets raw mode some
    scheduling later. Sampling the flags right after fg was timing the machine,
    and on a loaded one it read the shell's own canonical mode and reported it
    as a failure to restore - the same shape as the reclaim wait above.
    """
    end = time.time() + timeout
    while time.time() < end:
        if raw_restored():
            return True
        pump(0.05)
    return raw_restored()


def received():
    try:
        with open(RECEIVED, "rb") as fh:
            return fh.read()
    except FileNotFoundError:
        return b""


def check(name, ok, detail=""):
    print(("PASS " + name) if ok else ("FAIL %s %s" % (name, detail)))
    if not ok:
        failures.append(name)


try:
    pump(1.0)
    forget()
    send("bash %s\n" % LAUNCHER)
    check("the container run attached", expect("CONTAINER-ATTACHED"))

    for cycle in (1, 2):
        # Wait for the helper to hold the terminal before typing at it (#262).
        #
        # CONTAINER-ATTACHED is printed by the stand-in immediately after it
        # sets raw mode, so it marks the START of the window this feature
        # exists to close, not the end. The helper only acts once it has POLLED
        # the terminal and seen -isig, so between those two moments ^Z is still
        # the byte 0x1a. Sending into that window put the byte in the container
        # and failed `nothing-reached-the-container` - the security assertion -
        # on a machine where nothing was wrong but the scheduling.
        #
        # Waiting for the precondition rather than lengthening the deadline
        # after it: with the terminal provably converting ^Z to a signal before
        # anything is typed, that check can no longer fail for timing reasons
        # at all, which is the point. A longer timeout would only have narrowed
        # the window.
        #
        # Skipped without the helper, where the byte reaching the container is
        # the expected result and this would never come true.
        if HELPER_EXPECTED:
            check("cycle%d-suspend-char-reclaimed" % cycle, await_reclaim(),
                  "dejima-tty-suspend never took ^Z back from raw mode")
        before = received()
        forget()
        send("\x1a")
        stopped = expect("Stopped", 5.0) or expect("suspended", 0.5)
        check("cycle%d-suspends-the-job" % cycle, stopped)
        check("cycle%d-nothing-reached-the-container" % cycle,
              received() == before, repr(received()[-8:]))
        forget()
        send("echo SHELL-ALIVE-%d\n" % cycle)
        check("cycle%d-shell-usable-while-suspended" % cycle,
              expect("SHELL-ALIVE-%d" % cycle, 5.0))
        forget()
        send("fg\n")
        restored = await_raw()
        flags = lflag()
        check("cycle%d-raw-mode-restored" % cycle, restored,
              "ICANON=%s ECHO=%s" % (bool(flags & termios.ICANON), bool(flags & termios.ECHO)))
        check("cycle%d-redraw-poked" % cycle, expect("CONTAINER-REDRAW", 15.0))
        check("cycle%d-session-alive" % cycle, "LAUNCHER-DONE" not in "".join(seen))

    before = received()
    send("typed\n")
    pump(0.8)
    check("input-reaches-the-resumed-session", received() != before)

    before = received()
    send("\x03")
    pump(0.8)
    check("ctrl-c-still-reaches-the-session", received().endswith(b"\x03"),
          repr(received()[-4:]))

    # The finding, asserted: the client is stopped by SIGSTOP, which it cannot
    # observe, and never by SIGTSTP, which it cannot survive.
    # A suspended session must not leave the prompt with an invisible cursor:
    # the harness hid it and a suspend is not an exit, so somebody has to.
    check("the-cursor-is-shown-again-when-suspended",
          "\033[?25h" in transcript_all,
          "the prompt inherits a hidden cursor, like a dead ssh session")

    check("the-client-was-started-with-sigtstp-ignored",
          "CONTAINER-TSTP-IGNORED" in transcript_all,
          "it would be stopped by the one signal it cannot survive")
finally:
    try:
        os.killpg(os.getpgid(pid), 9)
    except Exception:
        pass

sys.exit(1 if failures else 0)
