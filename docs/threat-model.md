# Threat model

[← dejima README](../README.md)

**And none of it has been reviewed by anyone else.** This is early
development: the reasoning here is one person's, the tests assert what that
person thought to check, and no outside audit or adversarial testing has
happened. Read what follows as claims awaiting scrutiny rather than claims
that have survived it. See [SECURITY.md](../SECURITY.md).

What dejima defends, what it does not, and where its boundary passes out of
its hands. [security.md](security.md) is the control-by-control account; this
is the shape of the thing those controls are arranged against.

## What this tool assumes

**The agent is hostile, or will be.** Not badly behaved: captured, mid-session,
without announcing it. Every control here is placed as though the thing inside
the container is already working against the operator, because a control that
only holds while the agent cooperates is not a control.

**Nobody is watching.** Unsupervised operation is the design point rather than
a degraded mode. A protection that depends on an operator reading output as it
scrolls past does not count, which is why the exit-time audit is a report that
survives to the next launch and not a warning printed once.

**The project is one you already trust.** dejima bounds what a compromised
session reaches. It does not make it safe to point an agent at arbitrary
adversarial input, and pointing it at a repository you would not run on your
own machine is outside what this reasoning covers.

**The container is the boundary.** The hooks are not, the briefing is not, and
`.dejima.md` is not. Those three shape what a cooperating agent does; the
container is what holds when one stops cooperating.

## The adversary

Two of them, and conflating them is how a control ends up in the wrong place.

**An agent doing what it was asked, too literally.** No attacker anywhere in
this. It force-pushes, it rewrites history to make a test pass, it merges its
own pull request because that was the obvious next step. Common, costly, and
the only adversary here that responds to being told not to.

**A prompt injection or a poisoned dependency.** Text in a web page, an issue
body, a README or a dependency's own documentation, or code that runs during
an ordinary build: an npm `postinstall`, a transitive update from yesterday.
Neither was written for this machine. The injection waits for whichever agent
reads it; the package targets whoever installs it. This one does not respond
to instructions, because it arrives as instructions.

## Ranked by what is actually likely

1. **An agent destroying something nobody meant it to.** Needs no attacker,
   happens during ordinary use, and is the one every operator meets first.
2. **A session reaching something it should not on the network.** It runs
   dependencies, build scripts and fetched content. None of that needs an
   exploit to attempt a connection.
3. **Push access becoming code execution elsewhere.** A session opens a pull
   request, CI fires, and the runner executes that commit before anyone reads
   it. No operator action anywhere in the chain. See [ci.md](ci.md).
4. **Cross-project context poisoning.** A session writes another project's
   agent memory or transcripts, and a later session there reads planted text
   as established background.
5. **Container escape.** Real, and it recurs, but it needs an unpatched host
   or a working zero-day, and the two rows it moves between are both already
   in the table below.

The ordering is the point. Nothing above the last item requires an exploit.

## Blast radius by layer

Read the last two columns together: the middle one is what the layer reaches
if nothing is arranged against it, the last is what remains once something is.

| Layer | Reached by | Radius without | Bounded by | Radius with |
| --- | --- | --- | --- | --- |
| Agent, not yet hostile | ordinary operation | the workspace, its history, every mounted path, and the forge, at full speed | the session briefing and `.dejima.md`; the `PreToolUse` hooks | obvious destruction and out-of-remote pushes fail fast, and merging stays a human decision |
| Container | ordinary operation | the operator's home directory, every credential in it, and the open internet | dejima | the workspace, allowlisted domains, and the forge token's scope |
| Devbox VM, unprivileged | container escape | everything the account can read, and unrestricted egress to the internet and the LAN | `dejima-devbox-hardener` | the same VM, with LAN reach cut to what is declared; internet egress stays open, deliberately |
| Devbox VM, root | escape plus local escalation, or misconfiguration | the whole VM, the same egress, and the model API credential | `dejima-devbox-hardener`, enforced outside the guest | the whole VM and no further: root cannot reach the rule set that holds the LAN boundary |
| CI, confined job | a session opening a pull request | code execution on the runner, its network position, and the token the forge injects into every job | `dejima-ci-hardener`, confined tier | the allowlist, and nothing else on the LAN |
| CI, confined job escaped | an escape from a confined job | root on the runner VM | the hypervisor firewall and a scheduled rollback | the privileged tier's position: the allowlist is gone, the LAN is not, and the loss expires |
| CI, privileged job | `runs-on:` asking for it | root on the runner VM, by design and without any exploit | the same two controls, both external to the VM | the VM and its network position, until the next rebuild |

Four things are worth reading twice.

**The first row is the only one whose control is advice.** Hooks and context
tell an agent what not to do, and an agent that has stopped cooperating
ignores them. They are there because the likeliest adversary is the one that
listens, not because they would stop the one that does not.

**Two rows are reached with no exploit at all.** The container, because that
is where every session already is, and the privileged CI job, because holding
the Docker socket is the grant that tier exists to give. Neither is a failure
state; both are ordinary operation, which is what makes the row below each of
them worth arranging.

**Escape moves a layer, it does not leave the table.** A confined job that
escapes arrives where a privileged job sits by design, and the two controls
holding that position hold it identically however it was reached.

**The last three rows are bounded in time as well as in reach**, because the
runner VM is rebuilt from a snapshot on a schedule. That is a property no
in-guest control can offer, since root in the guest can flush any rule set it
can see.

## Where dejima's boundary ends

dejima runs inside the machine it is protecting the rest of, which is the
whole reason there are two other repositories. It cannot bound its own host's
network position, and it cannot bound a runner it never touches.

**[dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener)**
covers the two VM rows: what an escape spreads to, rather than whether it can
talk. Its
[threat model](https://gitbox.branderson.io/dejima/dejima-devbox-hardener/src/branch/main/docs/threat-model.md#blast-radius-by-layer)
is explicit that it does not narrow internet egress back down, and says why.

**[dejima-ci-hardener](https://gitbox.branderson.io/dejima/dejima-ci-hardener)**
covers the three CI rows, on the premise that CI executes attacker-controlled
code on every pull request deliberately, because that is what CI is for.
Nothing there tries to stop the code running. Its
[threat model](https://gitbox.branderson.io/dejima/dejima-ci-hardener/src/branch/main/docs/threat-model.md#blast-radius-by-layer)
has the two tiers and where each one's boundary sits.

Neither is required to run dejima, and the container row holds without them.
What they change is what the row below it costs.

## What this repository does not claim

- **That escape is impossible.** It is a row in the table with controls of its
  own, not an outcome that has been designed away.
- **That the hooks stop a hostile agent.** They stop an unlucky one.
- **That a finding from the exit-time audit was caused by the session.** It
  reports that a surface changed while the session ran. A concurrent session
  or the operator's own editing lands in the same diff.
- **That the allowlist bounds exfiltration once a session has push access.**
  A commit is an outbound channel to a host that is on the list by definition.
  See [ci.md](ci.md).
- **That any of this has been reviewed.** Stated at the top, repeated here
  because it is the claim that qualifies all the others.
