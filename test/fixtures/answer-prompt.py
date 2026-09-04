#!/usr/bin/env python3
"""Runs a command on a real pty and answers its prompts.

The credential scan only asks when stdin is a terminal, which is the whole
point - an unattended launch must not block on a question nobody will see. So
a test that drives the interactive path needs a pty rather than a pipe, or it
exercises the non-interactive branch while claiming to test the other one.

Usage: answer-prompt.py [--marker TEXT] <answer-per-prompt>... -- <command> [args...]

Each answer is sent when the child writes a line ending in the prompt marker.
Everything the child wrote is printed on exit, and the child's exit status is
this program's.
"""

import os
import pty
import signal
import re
import select
import sys
import time

# The default is the credential scan's prompt. --marker takes another, so a
# test for a different prompt does not need a second copy of this.
MARKER = "[s/a/o/r]"

# dejima pauses before the image build when it printed a notice worth reading.
# That is not the prompt any test here is about - it is ambient, and every
# launch fixture that sets [core] ssh_key raises it - so it is answered
# automatically rather than costing every caller an extra argument.
AMBIENT = "Press Enter to continue"
# An IDLE timeout: how long to wait with no output before giving up. Generous
# because the thing it guards against is a command that never finishes, and
# any finite bound catches that - while a tight one just times the machine.
# Sixty seconds was enough on an idle box and not enough under the full gate,
# where every suite runs at once (#295).
TIMEOUT = 240.0


def main():
    if "--" not in sys.argv:
        print("usage: answer-prompt.py <answer>... -- <command>...", file=sys.stderr)
        return 2
    split = sys.argv.index("--")
    args = list(sys.argv[1:split])
    global MARKER
    if "--marker" in args:
        i = args.index("--marker")
        MARKER = args[i + 1]
        del args[i:i + 2]
    answers = args
    command = sys.argv[split + 1:]
    if not command:
        print("no command given", file=sys.stderr)
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        # The child: a session leader with this pty as its controlling
        # terminal, which is what makes `[ -t 0 ]` true inside dejima.
        try:
            os.execvp(command[0], command)
        except OSError as e:
            print("exec failed: %s" % e, file=sys.stderr)
            os._exit(127)

    out = []
    pending = list(answers)
    deadline = TIMEOUT
    while True:
        r, _, _ = select.select([fd], [], [], deadline)
        if not r:
            out.append("\n[answer-prompt: timed out waiting for output]\n")
            break
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        text = chunk.decode("utf-8", "replace")
        out.append(text)
        # Answer only when the prompt is the most recent thing written, so a
        # marker appearing inside prose does not consume an answer.
        if pending and MARKER in text:
            os.write(fd, (pending.pop(0) + "\n").encode())
        elif AMBIENT in text and AMBIENT != MARKER:
            os.write(fd, b"\n")

    # The read loop ends when the child stops WRITING, which is not when it
    # stops running: dejima does its exit audit and stops its shipper after
    # the last thing it prints. So give it a grace period to finish before
    # concluding anything - killing it there reported a child that was merely
    # busy as a hang, and left it taking SIGPIPE on a pty nobody was reading.
    #
    # Only then kill, because an unanswered prompt is the other way this ends
    # and waiting on that turns a failing test into a hung suite. The caller
    # is told which it was.
    stuck = False
    status = 0
    grace = time.time() + 60.0
    try:
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done != 0:
                break
            if time.time() >= grace:
                stuck = True
                os.kill(pid, signal.SIGKILL)
                _, status = os.waitpid(pid, 0)
                break
            time.sleep(0.1)
    except OSError:
        status = 0
    sys.stdout.write("".join(out))
    if pending:
        sys.stdout.write("\n[answer-prompt: %d answer(s) never used]\n" % len(pending))
    if stuck:
        sys.stdout.write("\n[answer-prompt: the command never exited - killed. "
                         "It was probably waiting at a prompt nothing answered.]\n")
    return os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") \
        else (status >> 8)


if __name__ == "__main__":
    sys.exit(main())
