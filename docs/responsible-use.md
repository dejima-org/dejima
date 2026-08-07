# Using this responsibly

[← dejima README](../README.md)

The README states each of these ten rules in a sentence or two. This is the
part that didn't fit: why each one matters, what goes wrong without it, and
the detail behind the three the README could only gesture at.

## Check whether they want it first.

"They didn't ask for this" is a consent problem, not a quality problem. A
project that has said it doesn't accept AI-assisted contributions has said so
for reasons that have nothing to do with whether a given patch is good: review
load, licensing questions, a maintainer who simply doesn't want to referee
that argument on every pull request. A well-written, well-tested change
doesn't override a stated no, any more than good manners override a locked
door. Read CONTRIBUTING (or the equivalent policy file, or the pinned issue,
wherever a project keeps it) before you start work, because finding out after
means the work is already done and now has nowhere to go.

## Don't point it at repositories you don't own.

The concrete workflow, step by step:

1. Fork the project on its forge.
2. Point `bin/dejima` at your fork: run it from a local clone whose `origin`
   is your fork, not the upstream repository.
3. Let the session do its work there. With a pushing workflow configured, it
   opens branches, and pull requests, against your fork, not upstream.
4. Review the agent's branch yourself, the same way you'd review anyone
   else's diff before merging it.
5. Merge it to your fork's own `main`.
6. Open the upstream pull request by hand from there, once you would have
   been glad to have written it yourself.

The reason for the extra hop is what happens without it. An auto-push
workflow aimed straight at someone else's repository puts a session's raw
output directly into that project's pull request queue, unreviewed by
anyone, the moment it opens. Maintainers already spend real time triaging a
flood of low-effort AI-generated pull requests; a Godot maintainer's account
of what that actually costs is worth reading in full:
<https://bsky.app/profile/akien.bsky.social/post/3meyerixvhs2p>. Forking and
reviewing first doesn't change what the session is capable of writing. It
changes who reads the output before anyone else has to: you, not a stranger
who owns the project.

## Don't point it at proprietary code.

dejima narrows the paths code has to leave through; it doesn't close them,
and "point it only at code you could survive losing" is the practical test
for that gap. Ask it plainly before you start a session, not after: if this
checkout's contents ended up somewhere they shouldn't, would that be a bad
week or the end of the business? Code you could survive losing may be worth
the convenience of unattended agentic work. Code you couldn't shouldn't go in
at all.

That second one is not a judgement about how good the containment is, and it
does not get better with a version bump. There is no containment that fully
prevents exfiltration: a determined attacker with code execution and any
outbound path will find a way, and the allowlist narrows the paths rather
than closing them. So the question is never whether you trust dejima enough.
It is whether you can accept the risk of the contents leaving. If you cannot,
do not hand them to an agent that could send them.

## Look at what else is in the directory.

The bind mount doesn't know which files you meant to hand over. It exposes
the whole checkout, and everything a working tree accumulates over its life
sits there with the same reachability as the source files you actually care
about: a `.env` a teammate left uncommitted, a database dump pulled down for
local debugging and never deleted, a credential baked into a fixture file,
an old key still sitting in the history of a branch that got checked out.
None of that is code in any sense that matters to the agent; all of it is
just bytes in a directory the session can read and any tool call it makes
can touch.

Auditing a working tree by eye is not a minute's work, and it is the kind of
check that succeeds every time until the once it matters. **Point dejima at a
fresh clone instead.** A clone contains what is in version control and
nothing else, so the whole class goes away rather than being searched for. If
a directory might have ignored files in it worth protecting, that is the
directory not to hand over.

## An allowlist entry is a grant, not a convenience.

For every allowlist entry you give a dejima agent, consider what an attacker
could do with it. That is the whole rule. What follows is why the answer
varies so much between entries that look similar.

The variable is what happens if the call is wrong, whether wrong means a
prompt-injected instruction or an ordinary agent mistake.

A package registry or a docs site can be wrong without being expensive. A
session that fetches the wrong package version, or scrapes a stale or
misleading page, produces bad input to more code, code that still has to
pass through your own review before any of it ships. The mistake is
contained by the same diff you were always going to read.

A deploy webhook, a production database API, and a payment provider are a
different shape entirely. A single call against any of them is the action,
not a step toward one you'll review later: the deployment already ran, the
row is already written or gone, the charge already happened. There is no
diff downstream that catches it, because nothing about it passes through
your repository at all. Allowlisting one of these isn't giving the session a
faster way to fetch data; it's giving an unattended process standing
authority to act on the world, unsupervised, the same authority you'd think
twice about handing an unsupervised person.

Ask, before adding an entry: if this call happened by mistake, is the result
something I fix in the next commit, or something I have to explain to
someone?

## Safe and responsible are not the same thing.

"Safe" is a property of the sandbox: what a session inside it can reach.
"Responsible" is a property of what you let out of it. A session can be
contained perfectly and still produce something that should not be merged,
and the sandbox has no opinion either way.

This point is about the merge, not about code quality in general. What makes
`main` (or `master`, or whatever your default branch is called) different
from any other branch is that other things read it and believe it. It is
worth being precise about why, rather than saying "the released version" in
some vaguer sense. In this repository, dejima-ci-hardener resolves the
CI-side egress
allowlist by reading `.dejima/allowed-domains` from `origin/main`, never
from a branch or a local checkout, and treats whatever it finds there as
already reviewed. That trust isn't a policy statement, it's load-bearing:
the only way content lands on `main` is through a pull request you merged,
so reading from `main` is how the tool avoids asking a branch what it's
allowed to do. Merging something onto `main` doesn't just ship it to users.
It feeds a trust anchor that other tooling, this one and potentially future
ones, is entitled to rely on without re-checking. Keeping insecure or broken
code off `main` is what makes that reliance justified in the first place,
and that job is yours; nothing about running the agent in a sandbox does it
for you.

## Give it its own identity, then own what you merge.

The reason to separate identities is that forge-level controls key on who
authenticated, not on what changed. By default the sandbox authenticates as
you, so every control your forge offers that answers "who did this" (a merge
whitelist, a push whitelist, required approvals) admits the session exactly
as it admits you; a required approval becomes unusable outright, since a
forge won't let a pull request's own author approve it, and the session
opens pull requests as you. Giving the sandbox a dedicated forge account
(see [docs/security.md](security.md#to-your-forge-the-sandbox-is-you) for
how) is what turns those settings from decoration back into something that
actually holds a session to a smaller set of permissions than yours.

Once the identity is separate, every commit and pull request the session
produces is visibly labeled as the agent's own work, not yours, in your
project's history. That visibility doesn't shrink your responsibility for
it; it just makes it legible. Anyone reading your `main` later sees your
name on the merge commit regardless of whose name is on the authored one,
and will hold you to it accordingly.

## Understand what you ship.

The risk here is habituation, not a single lapse. dejima makes iterating
cheap enough that reading every diff starts to feel like the slow part of
the loop, and skipping it works fine, repeatedly, until the one time it
doesn't. A reviewer who reads every change catches most of what's wrong with
it. A reviewer who only reads the ones that felt risky catches none of the
ones that didn't feel risky, which is precisely the shape a subtle bug, or a
prompt-injected change dressed up as something ordinary, takes. Nothing
about a faster loop changes what engineering judgment is for.

## This is not a blastproof box.

The useful way to read this rule is as a statement about what kind of
failure to plan for, not as a disclaimer to skim past. dejima's containment
is Linux namespaces and a small capability set around the session, the same
kind of isolation a container gives any process, not a virtual machine
boundary; it shares the host kernel with everything else on the machine.
That buys real things (see [docs/security.md](security.md) for the specific
list: no working `sudo`, a deny-by-default firewall, read-only mounts over
the surfaces that matter most), and every one of them assumes the container
itself stays intact. A determined attacker, or a single container-escape
vulnerability, doesn't erode that protection gradually; it removes every
layer described in that document at once, because they all sit on the same
kernel. The operating assumption to hold isn't "the walls will probably
hold." It's "if this container is ever compromised at the kernel level,
treat everything reachable from this host account as compromised with it,"
which is a very different thing to plan around than an ordinary bug.

## dejima's security says nothing about your software's.

These are different axes, not different degrees of the same thing. dejima's
threat model is about the session: what a process running inside the
sandbox can reach, exfiltrate, or execute while it runs. None of that has
anything to say about the software that session writes once it's on disk.
dejima can contain a session perfectly and that session can still write a
SQL injection, hand-roll a broken authentication check, hardcode a secret,
or pull in a compromised dependency, because those are properties of the
code itself, decided at the moment it's written, not something a sandbox
sitting around the process that wrote it can retrofit afterward. If what got
built inside dejima turns out to be insecure, that isn't a containment
failure; containment was never the control that was supposed to catch it.

**It is not something a future agent can retrofit either**, and that is the
more useful half of this. "We will do a security pass later" was already a
weak plan before agents made it cheap to say. Early architectural decisions
close off the fixes for whole classes of problem: where trust boundaries sit,
what is authenticated and where, what data crosses which process, what a
single compromised component reaches. A later pass can find a missing bounds
check. It cannot move a boundary you built a system on top of. And insecure
implementation decisions sit in software for years without announcing
themselves, which is exactly why they are not found by a pass that goes
looking once.

So security has to be considered at every point in the work, not scheduled
as a phase, and dejima will not help you do that. It makes writing a lot of
code fast, which makes writing a lot of insecure code fast if nobody is
holding that concern. That responsibility is yours at every step, and it is
the one thing here no tooling in this repository is aiming at.

The same practices you'd apply to code from any other source, review,
linting, dependency scanning, tests aimed at the failure modes you care
about, still have to happen here. dejima doesn't stand in for any of them;
it operates on a different axis entirely.
