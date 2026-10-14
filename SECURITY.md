# Security policy

This is the security policy for every repository in the dejima organisation.
Individual repositories state what is specific to them and link here for the
rest.

## What dejima claims

It bounds what an agent session can reach. It does not make an agent safe to
run.

A session runs in a container with no permission prompts, one bind-mounted
project directory, a deny-by-default egress allowlist covering DNS as well as
IP, and no copy of the credentials it authenticates with. That allowlist
bounds where a prompt injection or a compromised dependency can send code and
where it can fetch its next instruction. It does not prevent either one.

Nothing here holds against a container escape or a kernel bug. What an escape
then reaches is bounded by the layer below, which dejima cannot reach because
it runs inside it - that is
[dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener)'s
subject, not this project's. The in-session
hooks are fast-fail guards, not a boundary. The exit-time audit runs after the
session has ended and attributes nothing to it. And none of it speaks to
whether the code a session wrote is correct, secure, or fit to merge.

[docs/security.md](docs/security.md) states the threat model and covers each
of these in detail.

## Reporting a vulnerability

Email **dejima@branderson.io**. Please do not open a public issue for a
vulnerability; the tracker is public, and a report there is a disclosure.

Useful things to include:

1. what an attacker gets;
2. the steps to reproduce it;
3. the repository and the commit you tested.

## What you can expect in return

Nothing is promised: no reply, no acknowledgement, no triage, no fix, and no
timeline for any of them. Reports are read when there is time to read them.

Nothing is asked in return either. There is no embargo period and no
coordinated disclosure window. Disclose on whatever schedule you think is
right.

## This is not proven software

These projects are in early development. Nothing in them has been through
outside review, an external audit, or adversarial testing by anyone other
than the people who wrote them. Where a design argument is stated it is one
person's reasoning; where a test asserts something it asserts what that
person thought to check.

Treat every security property described in any of these repositories as a
claim awaiting scrutiny rather than one that has survived it, and do not
deploy them where being wrong would matter.

## There is no support

These are personal projects with one maintainer.

There is no paid version, no support contract, no service level, no sponsorship
attached to them, and no commercial relationship with anyone who uses them.
Questions may go unanswered. Issues may go unread. Nothing here is developed or
supplied in the course of a commercial activity.

Whoever deploys this is responsible for the result.

## Supported versions

The tip of `main`, and nothing else. There are no maintenance branches, no
backports and no security releases for older tags or commits.

Releases are tagged by date so you can tell what you are running -
`dejima --version` - and [CHANGELOG.md](CHANGELOG.md) says what each one
changed. A tag is a record of what shipped, not a version anyone may stay on.

## No warranty

The software is provided without warranty of any kind. See sections 15 and 16
of each repository's `LICENSE`.
