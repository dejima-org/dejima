# Using this responsibly

[← dejima README](../README.md)

The README states each of these rules in a sentence or two. This is the part
that didn't fit: why each one matters, and what goes wrong without it.

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

An auto-push workflow aimed straight at someone else's repository puts a
session's raw output into that project's pull request queue, unreviewed by
anyone, the moment it opens. Maintainers already spend real time triaging a
flood of low-effort AI-generated pull requests; a Godot maintainer's account of
what that costs is worth reading in full:
<https://bsky.app/profile/akien.bsky.social/post/3meyerixvhs2p>. Forking first
doesn't change what the session is capable of writing. It changes who reads the
output before anyone else has to: you, not a stranger who owns the project.

## Don't point it at proprietary code.

dejima narrows the paths code has to leave through; it doesn't close them.
Ask it plainly before you start a session, not after: if this checkout's
contents ended up somewhere they shouldn't, would that be a bad week or the end
of the business? Code you could survive losing may be worth the convenience of
unattended agentic work. Code you couldn't shouldn't go in at all.

That is not a judgement about how good the containment is, and it does not get
better with a version bump. No containment fully prevents exfiltration: a
determined attacker with code execution and any outbound path will find a way.
The question is not whether you trust dejima enough, but whether you can accept
the risk of the contents leaving.

## Look at what else is in the directory.

The bind mount doesn't know which files you meant to hand over. Everything a
working tree accumulates sits there with the same reachability as the source
you actually care about: a `.env` a teammate left uncommitted, a database dump
pulled down for local debugging and never deleted, a credential baked into a
fixture, an old key on a branch that got checked out. All of it is bytes in a
directory the session can read and any tool call it makes can touch.

Auditing a working tree by eye is not a minute's work, and it is the kind of
check that succeeds every time until the once it matters. **Point dejima at a
fresh clone instead.** A clone contains what is in version control and
nothing else, so the whole class goes away rather than being searched for. If
a directory might have ignored files in it worth protecting, that is the
directory not to hand over.

## An allowlist entry is a grant, not a convenience.

For every allowlist entry, consider what an attacker could do with it. The
answer varies enormously between entries that look similar, and what it turns
on is what happens if the call is wrong, whether wrong means a prompt-injected
instruction or an ordinary agent mistake.

A package registry or a docs site can be wrong without being expensive. A
session that fetches the wrong package version, or scrapes a misleading page,
produces bad input to more code that still has to pass your own review. The
mistake is contained by the same diff you were always going to read.

A deploy webhook, a production database API and a payment provider are a
different shape entirely. A single call against any of them *is* the action,
not a step toward one you'll review later: the deployment already ran, the row
is already gone, the charge already happened. Nothing about it passes through
your repository, so no diff downstream catches it. Allowlisting one gives an
unattended process standing authority to act on the world.

Ask, before adding an entry: if this call happened by mistake, is the result
something I fix in the next commit, or something I have to explain to
someone?

## Safe and responsible are not the same thing.

"Safe" is a property of the sandbox: what a session inside it can reach.
"Responsible" is a property of what you let out of it. A session can be
contained perfectly and still produce something that should not be merged,
and the sandbox has no opinion either way.

This point is about the merge, not about code quality in general. What makes
your default branch different from any other is that other things read it and
believe it. Concretely: dejima-ci-hardener resolves the CI-side egress
allowlist by reading `.dejima/allowed-domains` from `origin/main`, never from a
branch or a local checkout, and treats whatever it finds there as already
reviewed. That trust is load-bearing, and it is only justified because the one
way content lands on `main` is through a pull request you merged. Keeping
insecure or broken code off it is your job; nothing about running the agent in
a sandbox does it for you.

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
project's history. That visibility makes your responsibility legible without
shrinking it. Anyone reading your `main` later sees your name on the merge
commit regardless of whose name is on the authored one, and will hold you to
it accordingly.

## Understand what you ship.

The risk here is habituation, not a single lapse. dejima makes iterating cheap
enough that reading every diff starts to feel like the slow part of the loop,
and skipping it works fine, repeatedly, until the one time it doesn't. A
reviewer who only reads the changes that felt risky catches none of the ones
that didn't feel risky, which is the shape a subtle bug, or a prompt-injected
change dressed up as something ordinary, takes. Nothing about a faster loop
changes what engineering judgement is for.

## This is not a blastproof box.

This is a statement about what kind of failure to plan for. dejima's
containment is Linux namespaces and a small capability set around the session,
not a virtual machine boundary; it shares the host kernel with everything else
on the machine. That buys real things (see [docs/security.md](security.md): no
working `sudo`, a deny-by-default firewall, read-only mounts over the surfaces
that matter most), and every one of them assumes the container stays intact. A
container-escape vulnerability doesn't erode that protection gradually, it
removes every layer at once, because they all sit on the same kernel. So the
assumption to hold is not that the walls will probably hold: it is that if this
container is ever compromised at the kernel level, everything reachable from
this host account should be treated as compromised with it.

What "everything reachable from this host account" amounts to is not fixed,
and it is the one part of this that can be narrowed from outside. Bounding
what an escape spreads to - the machine's own network position, and what a
compromise there can reach beyond it - is
[dejima-devbox-hardener](https://github.com/dejima-org/dejima-devbox-hardener)'s
whole subject. dejima cannot do it, because dejima runs inside the layer that
would have to be bounded.

## dejima's security says nothing about your software's.

These are different axes, not different degrees of the same thing. dejima's
threat model is about the session: what a process running inside the sandbox
can reach, exfiltrate, or execute while it runs. It can contain a session
perfectly and that session can still write a SQL injection, hand-roll a broken
authentication check, hardcode a secret, or pull in a compromised dependency.
Those are properties of the code, decided when it is written.

**It is not something a future agent can retrofit either.** Early
architectural decisions close off the fixes for whole classes of problem: where
trust boundaries sit, what is authenticated and where, what data crosses which
process, what a single compromised component reaches. A later pass can find a
missing bounds check. It cannot move a boundary you built a system on top of.
And insecure implementation decisions sit in software for years without
announcing themselves, which is exactly why a pass that goes looking once does
not find them.

So security has to be considered at every point in the work rather than
scheduled as a phase, and dejima will not help you do that. It makes writing a
lot of code fast, which makes writing a lot of insecure code fast if nobody is
holding that concern. Review, linting, dependency scanning and tests aimed at
the failure modes you care about all still have to happen; dejima stands in for
none of them.
