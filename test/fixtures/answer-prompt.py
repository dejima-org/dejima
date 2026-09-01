#!/usr/bin/env python3
"""Runs a command on a real pty and answers its prompts.

The credential scan only asks when stdin is a terminal, which is the whole
point - an unattended launch must not block on a question nobody will see. So
a test that drives the interactive path needs a pty rather than a pipe, or it
exercises the non-interactive branch while claiming to test the other one.

Usage: answer-prompt.py <answer-per-prompt>... -- <command> [args...]

Each answer is sent when the child writes a line ending in the prompt marker.
Everything the child wrote is printed on exit, and the child's exit status is
this program's.
"""

import os
import pty
import re
import select
import sys

MARKER = "[s/a/o/r]"
TIMEOUT = 60.0


def main():
    if "--" not in sys.argv:
        print("usage: answer-prompt.py <answer>... -- <command>...", file=sys.stderr)
        return 2
    split = sys.argv.index("--")
    answers = list(sys.argv[1:split])
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

    _, status = os.waitpid(pid, 0)
    sys.stdout.write("".join(out))
    if pending:
        sys.stdout.write("\n[answer-prompt: %d answer(s) never used]\n" % len(pending))
    return os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") \
        else (status >> 8)


if __name__ == "__main__":
    sys.exit(main())
