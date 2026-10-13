# Releasing: development to main

`main` is what an operator installs from, and what the CI hardener reads
`.dejima/allowed-domains` from. Work lands on `development` continuously; a
release is the deliberate act of moving it across, and this is what that act
consists of.

`test/release-pass.sh` runs the parts that can be run and prints the parts that
cannot, chosen from what the release actually changes. Start there.

## What is actually required, at this size

This project has one maintainer and few users, and a release gate nobody has
the bandwidth to complete is a gate that gets skipped rather than met. So the
bar is deliberately two things:

1. **An agentic security review of the whole diff**, against the invariants in
   section 2. This is the gate. It is cheap, it is repeatable, and it is the
   one thing that catches the class of mistake this project cannot afford.
2. **The maintainer runs the build.** Normal usage for a while, and a launch on
   the other configured harness to confirm it starts. That is the smoke test,
   and it is stated as what it is rather than dressed up as coverage.

Everything in section 4 is what a mature version of this project would verify
and this one does not. It is printed by `release-pass.sh` and kept in this
document because knowing what is unverified is worth more than pretending
otherwise - not because a release is blocked on it. When there are more users
than one person can apologise to, that changes.

## Why a pass at all

Every check below exists because something got through without it. The pattern
is always the same shape: the change was correct, the tests were green, and the
thing that broke was outside what any test could see - a container that could
not start, a body that arrived empty, a suite that passed in CI and failed on
the machine the work was done on.

A release is the last point where anyone looks at the whole diff rather than
one change at a time, which makes it the only place some of these are visible
at all.

## 1. The suites

`test/run-confined.sh` and `test/shellcheck.sh` run anywhere.

`test/runtime.bats` needs Docker, which a sandbox does not have. It is the only
thing that exercises the mounts, the firewall and the entrypoint end to end, so
a release is exactly when not running it stops being acceptable. Either run it
on the host, or **read the pull request's checks**: green means every job
finished and passed, `runtime.bats` among them. Yellow or grey means the
privileged job has not run - it is pinned to one self-hosted runner and queues
silently when that runner is down.

So the answer is the colour. Green is verified end to end; say so. Anything
else is a run that has not happened, and reporting it as passing is what this
paragraph exists to prevent.

## 2. Security review

Not a generic checklist - this project's product is an argument that a boundary
holds, so the review is about that boundary. Over the whole `main...development`
diff:

- **Does a mount widen?** A path that was read-only, a scope that was one
  project and is now the home directory.
- **Does a guard move after the thing it guards?** Order is the whole content
  of a check.
- **Does a credential cross the boundary that did not before?** Including
  indirectly: a variable that reaches the container, a file whose mask moved.
- **Does `.dejima/allowed-domains` gain a name?** That file is read from `main`
  by dejima-ci-hardener, which treats what it finds there as reviewed. Adding a
  domain widens every future CI job on that runner, from the moment it merges.
- **Did a refusal become a warning?** Or a hard failure become a fallback. Both
  are how a boundary stops holding without anyone deciding it should.
- **Did a test stop asserting what its name claims?** A test that still passes
  while the behaviour under it is gone is worse than no test.

The reviewer should be told to look for those specifically. A review briefed
only as "look for security problems" reliably returns generic advice about
input validation, because that is what a diff looks like without the context of
what this repository is defending.

## 3. Documentation review

- Every changed behaviour has its documentation changed in the same release.
- No document describes something that no longer exists.
- Nothing is claimed as working that has never been run. Where that is the
  case, say so where a reader will meet it - the forge and harness maturity
  sections in [providers.md](providers.md) are what this looks like.

## 4. Manual testing, which is mostly not done

`test/release-pass.sh` prints the list for the paths this release touches. It
is an inventory of what nothing has checked, not a checklist that must be
completed - see "What is actually required" above. The standing entries, and
why each is not a test:

| Touched | What to do, and why no test does it |
| --- | --- |
| `bin/dejima`, the entrypoint, compose | Launch a real session: mounts, proxy and exit audit only meet each other here |
| `forges/`, the forge guard | Open a pull request through each forge and read the body that arrived |
| any guard | Try the refused thing by the route an agent would take, not by the route the test takes |
| `bin/dejima-tty-suspend`, the launch | Ctrl-Z a real session and `fg` it: the tests use a stand-in for the container run |
| `web/` | Load it on a phone; nothing here can see a soft keyboard |
| `harnesses/` | Launch the harness against a real model |

## 5. The release pull request

Say what was run and what was not, in the body. At this size that will mostly
be "not", and writing it down is the whole point: an unverified path that is
named is one somebody can reach for when a bug turns up, and an unverified
path that is implied to be tested costs a day of looking in the wrong place.

Worth its own line: **whether the release can be rolled back.** A config key
added in a release makes the previous `main` refuse to start once an operator
adopts it, because an unknown key fails validation - so the rollback that
looks like the safety net is not one. Name the keys. A queued privileged job, a
manual check that was skipped, a forge that has still never been launched -
those are the things a reader of `main` is entitled to know, and the release
PR is where they are still true and still remembered.

Worth its own line too: **what an existing config stops being able to do.** A
release that tightens a boundary can refuse an arrangement that worked, with
nothing in the operator's config changed - and the ones that fail closed are
the ones to name, because failing closed is quiet. An observability path is
the worst case: a log shipper that can no longer reach its endpoint stops
shipping and nothing else happens. Name the arrangement, what it now needs,
and where the refusal shows up.

## 6. The version, and the entry in the changelog

A release is a date, and the tag of that name on `main` is the only record of
it. Two steps, both at merge time, both easy to forget because nothing fails
without them:

```sh
git tag 2026.10.12 <the merge commit on main>
git push origin 2026.10.12
```

and in the same pull request, rename `CHANGELOG.md`'s `## Unreleased` heading
to that date and open a fresh empty one above it. The date is the day it
merges, so it cannot be written before the merge is made - which is why the
heading waits rather than being guessed.

**There is nothing else to bump.** `dejima --version` reads `git describe`, so
the tag is the version: no file records it, and none can disagree with it. A
checkout pulled past a release reports `2026.10.12+37`, which is the honest
answer for a checkout on no release.

What an entry is for is one question - should I update, and what will I be
getting - so it names what an operator would notice rather than what changed.
The pull requests carry the detail and are linked from it. A tag is a record
of what shipped, not a version anyone may stay on; `CHANGELOG.md` says so at
the top, and `SECURITY.md` is where that is binding.
