`rtk` is available, and reading less of a command's output is usually free:
it runs the real command and prints a compressed form of what came back.
Prefix a command with it where the full output is not the point.

    rtk git status      rtk git diff        rtk git log -n 20
    rtk ls .            rtk find "*.py" .   rtk grep "pattern" .
    rtk cargo test      rtk pytest          rtk go test

It runs the real binary through PATH, so every guard that applies to a
command applies to it wrapped in rtk too. `rtk proxy <cmd>` runs something
unfiltered when you need the whole output, and `rtk read <file>` is a
structure-first view of a file rather than the whole body.

Use judgement rather than wrapping everything: a test run you are about to
debug line by line, or a diff you are about to apply, is output you want in
full.
