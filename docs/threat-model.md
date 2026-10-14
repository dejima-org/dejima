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
| Agent, not yet hostile | ordinary operation | the workspace, its history, every mounted path, and the forge, at full speed | the session briefing and `.dejima.md`; the command guards | obvious destruction and out-of-remote pushes fail fast, and merging stays a human decision |
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
[Using dejima on its own](#using-dejima-on-its-own) is what that leaves you
with, and what to do about it.

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

## Using dejima on its own

Most installs are this: dejima on a laptop or a workstation, and none of the
sister projects. Everything above about the rows below the container is true,
and it is about one threat, the least likely one on the list.

### What holds

The container row, in full. Nothing in it depends on another project.

- **Disk:** the workspace, the mounts you declare, and this project's own slice
  of harness state. Not your home directory, not `~/.ssh`, not your other
  projects ([security.md](security.md#one-projects-session-cannot-reach-anothers)).
- **Network:** deny-by-default egress. No port on the host is open unless you
  named one, and a permitted name that answers with a private address is
  refused unless it is a destination you configured, so the LAN is out of
  reach unless you put it there
  ([security.md](security.md#network-egress-firewall)).
- **The model credential** stays on the host behind the credential proxy
  ([security.md](security.md#the-model-api-credential-never-enters-the-container)).
- **The forge:** whatever the token and key you hand the session can reach.
- **Afterwards:** the exit-time audit reports changes to the host-side files a
  session could use to run code later, before your next `git` in that repo
  ([security.md](security.md#the-exit-time-audit)).

Against [the ranked list](#ranked-by-what-is-actually-likely): items 1, 2 and 4
are the container row's, and are handled the same with or without the stack.
Item 3 depends on where your CI runs, not on your machine. Item 5 is a person
deciding, with or without the stack. Item 6, escape, is the one the
devbox-side projects exist for.

### What does not

- **An escape lands on your machine, as you.** Your home directory, your
  network position, your credentials. Nothing here bounds that.
- **Pushing is code execution wherever your CI runs**, if the project has CI
  ([security.md](security.md#ci-push-access-is-code-execution-elsewhere)).
- **Nothing watches the machine between sessions.** The audit covers the
  surfaces it lists, for the window the session ran.

### Measured caution

None of these needs another project.

1. **Keep the kernel and the container runtime patched.** An escape needs an
   unpatched host or a working zero-day, and the first is the one you control.
2. **Point repos at dejima that you would run yourself.** That is
   [an assumption](#what-this-tool-assumes) the rest rests on.
3. **Give the sandbox its own identity**, with tokens scoped to the
   repositories it works on, so the forge's reach is what you granted rather
   than all of yours ([security.md](security.md#give-the-sandbox-its-own-identity)).
4. **Decide about CI before granting push.** Hosted CI, a runner you are
   willing to lose, or no push at all (`[core] forge = none` with
   `[core] workflow = local-only`). Not a self-hosted runner with your LAN
   behind it ([ci.md](ci.md)).
5. **Treat what a session hands you as its writing:** a command it asks you to
   run, a domain or dependency it asks you to approve, and every file in
   `share_dir` or a read-write mount. See
   [what mounting it costs you](remote-access.md#what-mounting-it-costs-you)
   before syncing those anywhere a desktop will open them.
6. **Read the audit before your next `git` in that repo.** `[audit] strict`
   refuses a headless launch while CRITICAL findings are unacknowledged.
7. **Leave the credential proxy on.** `proxy = off` is the one arrangement that
   puts the real model credential in the container.

### When the rest is worth adding

- **dejima-devbox-hardener**, when your machine sits on a network with things
  you would mind an escape reaching. It enforces from outside a VM, so the
  first step is moving dejima into one.
- **dejima-ci-hardener, or hosted CI**, as soon as sessions push to a project
  whose CI you run yourself.
- **dejima-guard**, when sessions run unattended long enough that "would I
  notice?" matters, and you have a second machine to run it from.

## Why a container, and not a microVM

The most frequent question about this project.

The short answer is that a microVM is the stronger boundary and nothing here
disputes it. Container escape is the least likely of the six threats above and
the only one that needs an exploit at all, and the layer it lands on is already
bounded by a control enforced from outside the guest. The effort went there
rather than into a harder container.

**There is already a VM here**, which is what the usual framing misses. It is
put as container versus microVM, as though the alternative were a container
with nothing underneath. On the deployment this document describes, dejima runs
inside a devbox VM whose rule set is enforced from the hypervisor. So the choice
is not one boundary against two. It is an outer VM enforced from outside the
guest, against that plus an inner one managed by software running on the box it
is protecting - inside the blast radius of the row it is meant to bound. A
boundary enforced from outside is worth more than one enforced by the thing
inside it, and that is most of the answer.

**The field's ordering is not in dispute.** gVisor's syscall interposition and
a per-workload VM kernel are both stronger than a namespaced container.
Firecracker is what AWS runs Lambda on, for the reason that applies here too:
untrusted code, multi-tenant, on shared hardware. The disagreement is about
where marginal effort goes, not about which primitive is stronger.

### What a stronger runtime would and would not change

It would not touch the five threats ranked above escape. Two of them would get
*harder*, because both are enforced by how the container is configured rather
than by what isolates it:

- **One project's session cannot reach another's**, because each path crossing
  the boundary is named individually rather than mounting a tree
  ([#104](https://gitbox.branderson.io/dejima/dejima/issues/104)). Under a VM
  each becomes a filesystem daemon.
- **The container sees an agent socket, never your key.** That is a live host
  socket, and a VM has no equivalent to hand it one.

One would get easier: egress rules on a tap device sit where the guest holds no
capability to touch them. That is available without changing the runtime, which
is what [#305](https://gitbox.branderson.io/dejima/dejima/issues/305) does.

**And "swap the runtime" understates the work**, because several controls are
implemented *in* Docker rather than merely hosted by it. The dependency
approval is a derived image build; the tooling reaches live sessions through
it; the capability floor is an argument about Docker's model. Porting them is a
rewrite of the parts that *are* the security argument, in a project that says
at the top that none of it has been reviewed by anyone else.

### What would change the answer

The decision is a judgement about effort, not a door held shut, and these are
the things that would reopen it:

- **Kata Containers is the cheap path if this reasoning is wrong.** It is an
  OCI runtime, so the compose file, the mounts and the tooling survive, and it
  can use Firecracker underneath. A per-launch switch rather than a fork.
- **Pointing dejima at projects chosen by someone else.** That contradicts an
  assumption stated at the top of this document, and reorders the ranked list.
- **A container escape in the wild that clears this configuration's floor**:
  non-root session user, `no-new-privileges`, `cap_drop: ALL` and a short list
  added back. The class recurs, and whether a live one clears that floor is
  asked on a schedule in
  [research-review.md](research-review.md#the-standing-questions) rather than
  assumed either way.

What is done instead is depth below the container, which is
[the stack](#the-stack-and-what-each-piece-buys): two of the three layers under
dejima are enforced where the guest cannot reach them, and the third bounds a
compromise in time. A sandbox that reaches for a microVM and stops there has
nothing underneath it, so an escape from the VM ends its argument. Here it is a
row with controls of its own.

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
