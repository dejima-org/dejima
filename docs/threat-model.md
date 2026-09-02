# Threat model

[← dejima README](../README.md)

What dejima defends, what it does not, and where its boundary passes out of
its hands. [security.md](security.md) is the control-by-control account; this
is the shape of the thing those controls are arranged against.

**And none of it has been reviewed by anyone else.** This is early
development: the reasoning here is one person's, the tests assert what that
person thought to check, and no outside audit or adversarial testing has
happened. Read what follows as claims awaiting scrutiny rather than claims
that have survived it. See [SECURITY.md](../SECURITY.md).

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
5. **The operator running something the session asked them to run.** dejima
   tells agents to hand host-side work over rather than attempt it - a domain
   to allow, a dependency to approve, a command only the host can run. That is
   a designed, legitimate, frequent workflow, which is exactly what makes it a
   delivery mechanism: a script that does what it says and one thing more is
   indistinguishable at the moment of running it. Nothing here inspects what
   crosses that boundary, and nothing can - the whole point of the handoff is
   that a person decides.
6. **Container escape.** Real, and it recurs, but it needs an unpatched host
   or a working zero-day, and the two rows it moves between are both already
   in the table below.

The ordering is the point. Nothing above the last item requires an exploit.

Item 5 is not an argument for making the handoff harder; a session that cannot
ask is a session that works around you instead. It is an argument for being
able to answer, afterwards, what that actually did to the machine - which is
the layer below this repository's, and the reason `dejima-guard` exists and
looks at detection rather than at more enforcement.

**The handoff directories are item 5 with the person taken out.** `[core]
share_dir` and everything in `[mounts] read_write` exist so that session
output survives the container, so every byte and every filename in them is
session-authored by design. On the box that is bounded by how rarely anyone
looks. Mount one on a workstation - over sshfs, or by any sync that runs on
its own - and the directory is simply present, at which point a desktop opens
what appears in it without being asked: an indexer parsing documents and
archives to extract text, a thumbnailer decoding images, a previewer, an
editor honouring project configuration it finds beside the files. Each is a
parser running as the operator, outside the container, reached with no
decision per file. Item 5's last sentence is that a person decides; here
nobody does.

It stays item 5 rather than becoming a row of its own, because the shape is
the same: the session initiates none of it. It cannot see the mount, cannot
cause one, and the ssh credential involved already gave that operator a shell
on the box. What changes is where session-authored bytes get opened, and the
machine they get opened on is not a row in the table below.
[remote-access.md](remote-access.md#what-mounting-it-costs-you) has the
specifics and what shrinks them.

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
whole reason there are three other repositories. It cannot bound its own host's
network position, it cannot bound a runner it never touches, and it cannot tell
anyone that something changed after the session ended.

### The stack, and what each piece buys

**Only the first row is required.** Everything under it is what the layer
below the container costs, and every one of them can be substituted or left
out - the last two are categories rather than products.

| Piece | Runs on | What it buys | Without it |
| --- | --- | --- | --- |
| **dejima** | the devbox | The container boundary: what a session reaches on disk, and deny-by-default egress. | An agent with your home directory and the open internet. |
| **dejima-devbox-hardener** | the same devbox, enforced from outside the guest | Bounds where an escape *spreads*: LAN reach cut to what is declared, and root in the VM cannot flush the rule set. | An escape reaches the LAN, and the row below the container is unbounded. |
| **dejima-guard** | a different machine | Notices the devbox changed: file hashes, enabled units and listening ports, diffed against a baseline held off the box. Detection, not enforcement. | Anything a session leaves behind survives unremarked, because nobody is looking at the devbox between sessions. |
| **self-hosted CI + dejima-ci-hardener** | a runner VM | A runner that executes a session's pull request without that being LAN access, and a rollback that expires what an escape gained. | CI runs attacker-controlled code with the network position of whatever host it sits on. |
| **or third-party hosted CI** | someone else's machine | The same isolation, bought rather than run - and on their network rather than yours. | - |
| **ntfy, or any push service** | anywhere both can reach | The channel dejima's "session needs input" and the guard's alerts both arrive on. | A session that stopped to ask, and an alert that fired, both wait for someone to think to look. |
| **Uptime Kuma, or any uptime monitor** | off the devbox | The dead man's switch: it is what notices the *guard* has stopped reporting. | Silence is indistinguishable from health, which is the failure mode every watcher has. |

The last row is the one most easily skipped and the one that decides whether
the rest is real. A watcher that has died looks exactly like a watcher with
nothing to report.

### Each project's own boundary

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

**[dejima-guard](https://gitbox.branderson.io/dejima/dejima-guard)** watches a
devbox from a machine that is not the devbox and alerts on what changed. It
enforces nothing: everything it reports has already happened. It collects over
SSH, diffs against a baseline held on the watching machine, and alerts from
there. That placement is the point, since a baseline stored on the box being
watched is a baseline the thing you are watching for can edit, and it
complements devbox-hardener rather than overlapping it - one bounds where a
compromise spreads, the other notices that one happened.

**It is the only piece here that adds a machine holding credentials rather than
taking capability away.** Every other row removes something: what a session
reaches, where an escape spreads, what a runner can talk to. This one
introduces a host holding an SSH key to the devbox and a token for the alert
channel, and its exposure is bounded by the hardening of a machine this stack
does not describe or require anything of. That is the thing to weigh before
running it.

**Its detection ceiling is root on the watched box.** The collector runs on the
devbox, so root there can return whatever it likes, including the baseline
unchanged. What the guard catches is accidents, non-root compromise, and
payloads that did not think to look, which is most of them. The heartbeat
proves the guard ran, not that it saw the truth.
[Its own `SECURITY.md`](https://gitbox.branderson.io/dejima/dejima-guard/src/branch/main/SECURITY.md)
has the rest, including the ways it is deliberately narrower than dejima.

None of the three is required to run dejima, and the container row holds
without them. What they change is what the row below it costs, and whether
anyone finds out.

**A survey of comparable projects found none with rows below the container at
all** - their boundary is between the agent and the host, and what is under
the host is outside their threat models. The same survey found nothing
treating a forge or a CI runner as part of an agent's blast radius, which is
what dejima-ci-hardener exists for: a session that can open a pull
request can execute code on a machine dejima never touches.

Recorded as an observation from one day of secondary sources rather than as a
claim to have surveyed the field exhaustively. The reason it is here at all is
that it changes what to defend: if the layers below and beside the container
are ones nobody else is examining, they are also ones where nobody else's
mistakes are available to learn from.

## Which deployment this describes

The table above describes dejima **as deployed on a devbox VM with the two
sister projects arranged around it**. Say that plainly, because the README
also invites running dejima on a laptop, and there the table is shorter than
it looks: the container row holds exactly as described, and the row below it
is the operator's own machine with nothing arranged against it.

That matters more than it used to. The field's own ordering for isolating an
agent whose contents are assumed hostile puts a hardened container below
gVisor and below a per-workload VM kernel, on the grounds that a container
shares the host kernel and that container *runtime* vulnerabilities bypass
syscall filtering rather than being caught by it. dejima's answer to that
ordering is not to dispute it. It is that escape moves a layer instead of
ending the argument - which is a better answer where the next layer exists,
and no answer at all where it does not.

So `dejima-devbox-hardener` is load-bearing rather than optional-and-nice.
On a laptop, dejima is a hardened container and the honest description of what
is under it is "your home directory, and dejima has nothing to say about it".

**Load-bearing for what, exactly**, because the field's tiering invites a
reading that project does not accept and has never claimed. A per-workload VM
kernel is reached for elsewhere as a *containment* boundary. That is not what
the row below the container buys here. `dejima-devbox-hardener`'s own threat
model states in three places that its firewall bounds where a compromise can
**spread**, not whether it can phone home: an escape reopens internet egress,
deliberately, because deny-by-default earns its keep where the protected set
is enumerable and the internet is not.

Read the row as written, then: it cuts LAN reach to what is declared, and it
is enforced from outside the guest so root in the VM cannot flush it. It does
not restore the egress control the container layer provides. Anyone writing
this sentence more confidently than that is making a promise on another
repository's behalf.

**What this repository can do about that is say so**, which is the whole of
this section. Nothing in dejima can bound its own host.

## Why a container, and not a microVM

The most frequent question about this project, and the section above answers
only half of it.

**The field's ordering is not in dispute.** gVisor's syscall interposition and
a per-workload VM kernel are both stronger boundaries than a namespaced
container. Firecracker is what AWS runs Lambda on, for the reason that applies
here too: untrusted code, multi-tenant, on shared hardware. Nothing below
argues that a container is the better isolation primitive. The question is
where marginal effort goes, and that comes from the ranked list above rather
than from a preference about primitives.

### It addresses the last item on the list

Container escape is sixth of six, and the only one of the six that needs an
exploit at all. A stronger runtime does nothing for the five above it, and two
of those five get *harder* under a VM:

- **Cross-project poisoning is bounded by how `~/.claude` is mounted**, not by
  the container. Each path crossing the boundary is named individually, the
  workspace's own project slugs and nothing else, with `file-history` scoped by
  session id. Under a VM those become virtiofs shares with a daemon apiece, and
  the control that closed #104 turns into the hardest part of the port.
- **The agent socket is a live host socket.** `${SSH_AUTH_SOCK}:/ssh-agent` has
  no VM equivalent. It becomes a vsock forwarder written for this, which is a
  new component on the credential path and a new thing to argue about.

One gets easier, and it should be said: **egress enforcement.** A tap device
puts the rules on the host where the guest holds no capability to touch them.
That is a real gain, and it is available without changing the runtime at all -
see #305, which moves the packet filter to a per-launch bridge and drops
`NET_ADMIN` and `NET_RAW` from the container.

### Escape moves a layer, and here the layer exists

A stronger runtime makes it rarer to reach the row below the container. It does
not change what that row costs, which the section above has already bounded in
one dimension and left open in the other. Worth something, and less than it
first looks.

**And there is already a VM in the stack.** The comparison is usually put as
container versus microVM, as though the alternative were a container with
nothing under it. On the deployment this document describes, dejima runs inside
a devbox VM whose rule set is enforced from the hypervisor. So the choice is
not one boundary against two. It is an outer VM boundary enforced from outside
the guest, against that plus an inner one managed by software running on the
box it is protecting - by something inside the blast radius of the row it is
meant to bound. A boundary enforced from outside is worth more than one
enforced by the thing inside it, and that asymmetry is most of why the effort
went below the container rather than into it.

### What Docker is doing here, concretely

"Swap the runtime" understates the work, because several controls are
implemented *in* Docker rather than merely hosted by it:

- **The dependency approval is `docker build`.** An approved `.dejima/`
  declaration becomes a derived image `FROM` the base. Building a microVM
  rootfs in practice means `docker build`, then export, then a filesystem
  image. Docker does not leave; it demotes from runtime to build tool, and the
  "one fewer dependency" argument mostly evaporates.
- **`dejima-allow --container` reaches a running session over `docker exec`.**
  There is no exec into a microVM. It becomes an agent in the guest listening
  on vsock, which is a new privileged surface *inside* the sandbox - the
  direction this repository spends its effort removing.
- **`dejima-attach` finds live sessions by container label.** That becomes a
  registry dejima maintains, with its own staleness and its own failure mode.
- **The capability floor is an argument about Docker's model.** `cap_drop: ALL`
  and a short list added back, each with its reason recorded. Under a VM that
  argument does not transfer; an equivalent one has to be made from scratch.

None of these is a reason by itself. Together they are why this is a rewrite of
the parts that *are* the security argument, in a project whose threat model
opens by saying none of it has been reviewed by anyone else. Doubling the
number of boundaries to argue for, while halving the attention available for
each, is not obviously a gain.

### What would change the answer

Stated so the answer can be shown to be wrong rather than defended:

- **Kata Containers is the cheap path, and a per-launch switch rather than a
  fork.** It is an OCI runtime, so the compose file, the individually named
  mounts, `docker exec` and label discovery all survive, and it can use
  Firecracker underneath. What needs proving is whether the firewall still
  comes up inside a Kata guest, and what the mount count costs at boot. If the
  escape-surface argument wins, this is the version to try.
- **gVisor is cheaper still and likelier to break.** `runsc` is a smaller
  grant, and the image carries a browser, which is where syscall-compatibility
  gaps show first. Worth a spike, not worth a plan.
- **Dropping the assumption that the project is one you already trust.** If
  dejima were pointed at repositories chosen by someone else, the ranked list
  reorders and this section should be rewritten rather than argued.
- **A container escape in the wild that clears this configuration's floor.**
  Non-root session user, `no-new-privileges`, `cap_drop: ALL` and a short list
  back. The class recurs; whether a live one clears that floor is the question,
  and [research-review.md](research-review.md#the-standing-questions) is where
  it gets asked rather than assumed either way.

### What is done instead

Depth below the container rather than a harder container, which is
[the stack](#the-stack-and-what-each-piece-buys). Two of the three layers under
dejima are enforced where the guest cannot reach them: the devbox rule set from
the hypervisor, and the guard from a different machine. The third, the
scheduled rebuild, bounds a compromise in time rather than in reach, which no
in-guest control can do.

That is the difference from the field's usual answer, and it is a difference
rather than a rebuttal: a sandbox reaching for a microVM and stopping there has
nothing underneath it, so an escape from the VM ends its argument. Here it is a
row with controls of its own. Neither arrangement dominates. This one was
chosen because the layers below are where the remaining risk actually sits, and
because they keep working on the day the isolation primitive turns out to have
a bug.

## What this repository does not claim

- **That the egress allowlist bounds what reaches the model.** It bounds what
  the container can connect to. A harness tool executed outside the container
  - Claude Code's `WebSearch` is the one confirmed by observation - puts text
  from any site into the session without the allowlist seeing the name, and
  sends a session-controlled query out to a third party. It rides the model
  API connection, so it crosses dejima's own credential proxy rather than
  going somewhere unseen, but nothing inspects it. Which of a harness's tools
  fetch from the container and which do not is a per-harness question, and
  belongs in that harness's assessment.
  [security.md](security.md#the-firewall-bounds-the-container-not-the-harness)
  has the evidence.
- **That a session cannot use the model API as you while it runs.** It can.
  The credential proxy keeps the credential on the host, so nothing durable
  leaves and the misuse stops when the session does - but a session that has
  been turned can spend your quota and read whatever it asks for, through the
  proxy, without ever holding the credential. That is inherent to the sandbox
  working at all. [security.md](security.md#four-arrangements-and-what-a-session-can-take-from-each)
  has the four arrangements and what each one puts in the container, including
  the one that puts the credential itself there.
- **That escape is impossible.** It is a row in the table with controls of its
  own, not an outcome that has been designed away.
- **That the hooks stop a hostile agent.** They stop an unlucky one.
- **That a finding from the exit-time audit was caused by the session.** It
  reports that a surface changed while the session ran. A concurrent session
  or the operator's own editing lands in the same diff.
- **That what a session leaves in a handoff directory is safe for another
  machine to open.** `share_dir` and `[mounts] read_write` carry
  session-authored bytes and session-chosen filenames out of the container on
  purpose. Sanitising happens where dejima does the printing, and stops there.
- **That the allowlist bounds exfiltration once a session has push access.**
  A commit is an outbound channel to a host that is on the list by definition.
  See [ci.md](ci.md).
- **That any of this has been reviewed.** Stated at the top, repeated here
  because it is the claim that qualifies all the others.
