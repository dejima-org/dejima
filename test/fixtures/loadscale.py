"""How much longer a bounded wait should be given on a loaded machine.

The suites here wait on things that take as long as the machine makes them take
- a pty reaching raw mode, a shipper polling, a prompt being answered - and
each wait has a deadline. A deadline that is right on an idle box is wrong
under the gate, which runs every suite at once, and lengthening it until both
work means guessing a number that is generous in one place and useless in the
other (#295).

So the runner says how much concurrency it asked for, and the deadline is
multiplied by how oversubscribed that makes the machine. Nothing gets shorter
than it is today: the multiplier floors at 1, so an idle run and a run with no
variable set behave exactly as before.

Capped, because this is a multiplier on a timeout: a variable set wrongly, or a
machine reporting one core, would otherwise turn a test that should fail in
seconds into one that hangs for the length of the CI job.

DEJIMA_TEST_CONCURRENCY is how many tests the runner intends to have in flight
at once. test/run-confined.sh sets it to the budget it divided among the
suites; the CI workflow sets it to what it passes bats. Neither is a guess
about load - it is what that runner asked the machine for.
"""
import os

MAX_SCALE = 4.0


def scale():
    """The multiplier, >= 1.0 and <= MAX_SCALE."""
    try:
        want = int(os.environ.get("DEJIMA_TEST_CONCURRENCY", "0"))
    except ValueError:
        return 1.0
    if want <= 0:
        return 1.0
    cores = os.cpu_count() or 1
    return max(1.0, min(MAX_SCALE, want / float(cores)))


def deadline(seconds):
    """A bounded wait, lengthened for the concurrency this run asked for."""
    return seconds * scale()
