# CI, and what push access grants

[← dejima README](../README.md)

**Granting a dejima session push access grants it code execution wherever your
CI runs.** That is the whole of it, and everything below is either why it
cannot be gated or what to do about it instead.

> **This document is the why.** For the how, [dejima-ci-hardener](https://gitbox.branderson.io/dejima/dejima-ci-hardener)
> is a self-contained tool that does it, installed on the CI box, never on a
> dejima host, and it does not assume you have read this.

The chain needs no operator action at any step. A session writes code; the
push guard permits a feature branch, which is what it exists to allow; the
session opens a pull request, which its briefing tells it to do without asking
first; `on: pull_request` fires and the runner checks out that commit and runs
it. The code does not have to be a modified workflow file to be executed: a
workflow that runs a test suite is already running every file in it, and a
plausible-looking helper in a test file is a much quieter carrier than an
edited workflow, which shows up in a diff.

The gate this sandbox otherwise relies on (you merge, the agent does not)
sits strictly downstream of that. By the time anyone reads the diff, the code
has run.

This applies to any project developed in a dejima sandbox, not only to dejima
itself. The sandbox bounds what a session can reach directly. It does not
bound what it can arrange to have run elsewhere, and CI is the shortest path
elsewhere.

**And it applies to projects with no CI at all.** A branch can add the first
workflow, so what matters is not what a repository's workflows do today but
which runners its branches can reach, which is a property of the forge, not
of the project. If you read one section of this document before pointing a
sandbox at something, make it
[what a repository can reach](#closing-the-rest-what-a-repository-can-reach);
it is a question to answer per project, and for a project on hosted runners
the answer is reassuring.

## What a run actually adds

The code CI executes is code the session already had. Relative to the sandbox,
a run adds three things, and every control in this document maps onto one of
them:

1. **Execution on a host you own**: outside the container, outside the
   allowlist, with whatever that host can reach.
2. **Egress from a network position you own**: no dejima firewall, no DNS
   proxy, ordinary networking.
3. **Credentials the run is handed**: the secrets you configured, plus the
   token the forge injects into every job whether the workflow asks for one or
   not.

Keep those three in view even if none of the specific configuration below
applies to you. They are what changes when a session gains push access, and
they survive translation to CI that looks nothing like this.

## Why this document offers no approval gate

The obvious answer is to require a human to approve a run. Each version of
that turns out to be reachable from the branch, from a credential the session
already holds, or to be no gate at all:

- **Changing the trigger**: `workflow_dispatch` only, or `push` to `main`
  only. The workflow file lives in the tree the session controls, and on a
  `pull_request` run it is read from the head of the pull request.
- **Triggering by hand.** A forge token that can open a pull request generally
  also covers the dispatch endpoint. Gitea's `write:repository` does.
- **Leaving the runner stopped until you want a run.** Any shared pool has
  spare capacity, so a job that cannot land on your runner lands on someone
  else's. It also asks you to do something before every run, which is a
  recommendation that gets abandoned rather than followed.
- **The forge's own approval settings.** Gitea's approval requirement and
  read-only token apply to pull requests *from forks*. A dejima session pushes
  a branch to the same repository, which is precisely the case they do not
  cover.
- **Filtering egress from inside the workflow.** That is a step in a file the
  branch can edit.

Running unattended from a plan through to a pull request is most of what a
sandbox like this is for. A design that reinserts a manual step per run gives
that up and, in practice, gets routed around. So nothing here tries to stop
the run. Everything here bounds what the run can do.

## Before anything else: protect the branch

Every control below that is worth anything roots its trust in `main`: most
directly the egress allowlist, which is read from there. A job token with
write access to the repository can push to an unprotected branch, so without
this the untrusted party can edit the thing that is supposed to constrain it.

- Protect `main`: no direct push, pull request required.
- **Verify** the job token cannot push to it, rather than assuming branch
  protection covers a token the forge issues itself.
- Check whether a job token can *merge* a pull request on your instance. If it
  can, both the merge guard and the you-merge-not-the-agent gate are reachable
  from CI, and you should know that either way.

This costs nothing and it is the single highest-value item in this document.

**Branch protection needs a second identity to protect anything.** By default
a session authenticates as you, so a merge whitelist, a push whitelist and an
approval requirement all admit the sandbox exactly as they admit you, and
required approvals are unusable outright, since a forge will not let a pull
request's author approve it and the session opens them as you. Giving the
sandbox its own forge account is what turns those settings from decoration
into enforcement, and it is configuration rather than a missing feature:
[docs/security.md](security.md#to-your-forge-the-sandbox-is-you).

Note that it does not help with the rest of this document. A write-capable
account still pushes feature branches, which is what makes CI run code, and
the token the forge injects into a job is a third principal subject to none of
those settings.

## The runner host

Treat it as what it is: a machine that exists to run untrusted code, because
that is what it does on every pull request.

- **Nothing else on it.** No other service, no other project's data.
- **No route to the LAN or to a management network.** A runner that can reach
  your internal services is a runner that hands them to whatever it executes.
- **No credentials beyond its own registration token.** Registration tokens
  are worth rotating on a schedule; anyone holding one can register a runner
  and start receiving jobs, including their secrets.
- **Rebuilt from a snapshot on a schedule**, so that persistence on it has a
  bounded lifetime rather than an indefinite one.
- **Register runners at repository or organization scope**, not instance
  scope. This matters in both directions, and the second is the one that bites:
  an unrelated repository cannot schedule work onto a runner you hardened for
  this one, *and* this repository cannot schedule work onto a runner nobody
  hardened. An instance-level runner is reachable from every repository on the
  instance; see "A label is not a boundary" below. Gitea's own FAQ describes
  gitea.com doing this for its public runners.

Two runners on one VM give you label tiering, not host separation: a job that
cannot get the Docker socket still shares a kernel and a network with a runner
that can. If you only have one machine, that is a real reduction and worth
doing; just do not read it as isolation between the tiers.

## Job containers

The single most consequential setting is one that is invisible from inside a
job. `act_runner` mounts the Docker daemon's socket into every job container
it starts unless `container.docker_host` is set to `"-"`; its own generated
configuration says so:

> If it's `"-"`, act_runner will find an available docker host automatically,
> but the docker host won't be mounted to the job containers and service
> containers.

Access to that socket is root-equivalent on the runner host: `docker run
-v /:/host` ends the argument. Nothing in a job's log mentions the socket
being there, so this is not something a passing look at a green run will
surface. Check it directly, per runner:

```sh
grep -A12 '^container:' /path/to/act_runner/config.yaml
```

An unset `docker_host` is the default, and the default mounts.

Note also that whether a job gets the socket is a property of **the runner's**
configuration, not of the job. A job asking for nothing unusual still receives
whatever the runner grants everything it runs. So the useful question is not
"does this job need Docker" but "does every job this runner can pick up
deserve the socket".

For a runner that does not need it, the settings worth being explicit about
rather than leaving at their defaults are `docker_host: "-"`, an empty
`valid_volumes` (the default, but worth stating so an edit has to be
deliberate), `privileged: false`, a fixed `network` (below), `capacity: 1`,
`cache.enabled: false`, and a label nothing else carries.
dejima-ci-hardener ships both configs, with the reasoning inline.

**Prefer a new runner over reconfiguring an existing one.** A general-purpose
runner often exists precisely to build images, and taking its socket away
breaks it. Register a second runner with a label of its own, and name that
label in the workflow, and if no runner carries the label yet, the job queues
rather than running somewhere unprepared, which is a better failure than a
green run on the wrong host.

### A label is not a boundary

That last paragraph describes routing, not containment, and the difference
matters enough to state on its own.

**`runs-on:` is in the workflow file, and the workflow file is in the branch.**
A branch can name any label it likes. So a dedicated label keeps *honest* jobs
on the runner you prepared; it does nothing against a branch that would rather
run somewhere else. A session that changes `runs-on: dejima-confined` to
`runs-on: ubuntu-latest`, pushes, and opens a pull request has stepped outside
every control on this page (no allowlist, no socket restriction, no firewall),
provided some runner answering `ubuntu-latest` will take the job.

Whether one will is a property of **where your runners are registered**, which
is the actual boundary:

| Registered at | Which repositories it serves |
| --- | --- |
| Instance | **every repository on the instance** |
| Organization | that organization's repositories |
| Repository | that repository |

Gitea has no per-repository runner ACL; its FAQ says so directly, and points
at registration scope as the control instead: gitea.com registers its runners
for one organization "so our runners will not execute jobs from other
repositories."

So the property to hold onto is this: **a repository's CI security posture is
that of the weakest runner it can reach, not the one its workflow names.** An
instance-level general-purpose runner is reachable from every repository on
that instance, including any that takes agent-authored branches.

### Pinning the workflow with `pull_request_target`

Half of this is fixable, and worth fixing: **`runs-on` does not have to come
from the branch.**

Under `on: pull_request` the workflow is read from the head of the pull
request, so the branch decides what runs and where. Under
`on: pull_request_target` Gitea reads it from the **base branch**, and
explicitly discards any `pull_request_target` workflow found on the head
commit: a branch can neither edit the base copy nor introduce its own. What
runs, and on which runner, is whatever `main` says.

**Adopting it takes two merges, not one.** The trigger only takes effect once
it is on the base branch, because that is where it is read from, and a
`pull_request_target` workflow on a pull request's head is explicitly ignored.
So the change that introduces it cannot be tested by it: with only
`pull_request_target` on the branch and only `pull_request` on `main`, the
head's copy is skipped, the base has nothing to contribute, and **no checks
run at all**, which looks like a broken workflow rather than a bootstrap
problem.

Carry both triggers through the first merge, then remove `pull_request` in a
follow-up. The first change is tested by its own copy from the head, as
today; the follow-up is tested by the copy now on `main`. In between, pull
requests get both an untrusted run from the head and a trusted one from the
base, noisy, and for the untrusted half no worse than the status quo, so
keep the window short.

Two more consequences to handle rather than discover:

- **The checkout no longer defaults to the code under test.** The run's ref is
  the base branch, so a bare `actions/checkout` fetches `main` and the suite
  passes without ever seeing the change. Jobs that test the branch must name
  it: `ref: ${{ github.event.pull_request.head.sha }}`. Jobs that assert on
  the *runner* should keep the bare checkout, so their assertions come from
  `main` and a branch can neither weaken nor delete them.
- **The job runs with the base repository's token and secrets**, because the
  forge treats it as trusted. On a forge where a same-repo `pull_request` run
  already gets a permissive token this changes nothing, but it is why the
  pattern carries warnings elsewhere: give such a run no secret you would not
  hand the branch.

This does not make the repository safe on its own. A branch can still add a
workflow of its own with `on: pull_request`, which runs from the head with
whatever `runs-on` it likes. What it buys is that the *intended* CI is
trustworthy, and that escaping it means adding a file rather than editing
one: a much louder diff.

### Closing the rest: what a repository can reach

The rule underneath everything here:

> **Every runner reachable from a repository that receives agent-authored
> branches must be one you would accept an attacker running code on.**

Note what that does *not* say. It says nothing about what the repository's
workflows currently do, because a branch can add the first one. **A project
with no CI at all is still exposed**, on a forge where its branches can reach
a runner, and that is the case people do not expect, because there is nothing
in the repository to look at.

So before pointing a sandbox at a project, ask one question: *what runners can
this repository's branches reach?*

**If the answer is "hosted runners only"** (GitHub-hosted and nothing
self-hosted attached), this is the mildest case, and it is worth saying so
rather than alarming people. The runner is disposable and is not your machine,
so "execution on a host you own" largely evaporates: there is no LAN behind
it and nothing of yours on it. What remains is the third item, credentials:
give pull-request runs no secrets they do not need and a read-only token
(`permissions: contents: read`), and do not attach a self-hosted runner to
that repository.

**If self-hosted runners are reachable**, that is the sharp case, and there are
three ways to hold the rule, none of which require moving or renaming
anything.

**1. Turn CI off for that repository, if it does not use CI.** Disabling the
Actions unit means no workflow runs for that repository at all, so no runner is
reachable and a branch cannot add the first workflow. Changing it back needs
*admin* on the repository (Gitea's API puts repository settings behind
`reqAdmin()`), so a bot account with Write cannot undo it. For a project that
was not using CI anyway this costs nothing and closes the vector outright. It
is the first thing to reach for and the most commonly overlooked.

**2. Scope the dangerous runner down, rather than moving the repository out.**
The instinct is to move agent-developed repositories somewhere with only
hardened runners. For a public project that means breaking its name, its
links and its ownership, which nobody should be asked to do.

Invert it. A runner can belong to an **owner** (a user as well as an
organization) and then serves that owner's repositories; Gitea's runner model
names the three cases: global (`OwnerID` and `RepoID` both zero), org/user
level (`OwnerID` set), repository level (`RepoID` set). So:

- Make the *hardened* runner the owner-level default, so every repository gets
  it.
- Register the *permissive* runner (the one with the Docker socket, or with
  unrestricted egress) at **repository** scope, for only the repositories
  that genuinely need it.

Most repositories need a runner that can run tests, not one that can build
images. Scoping the dangerous capability to the few that need it is usually a
handful of registrations, and nothing moves or is renamed.

**3. Do not grant push.** `[core] forge = none` with
`[core] workflow = local-only`. The session commits locally and stops; you
review the diff and push it yourself. No branch, no workflow, no runner, and
the vector is closed completely rather than bounded. The cost is one push
after the review you were going to do anyway, and it is the only option here
that does not depend on getting a forge's configuration right.

If none of the three is available for a given project, that is worth knowing
plainly: pointing a sandbox at it means accepting that a compromised session
can run code on whatever that repository can reach.

## Egress

The goal is that a job cannot reach somewhere new (cannot fetch a next stage,
cannot post a repository to a paste service, cannot probe an internal address)
without a human having agreed to that destination first.

### Four network positions, only one of which is the job

Getting these confused produces either a broken build or a firewall that
protects nothing:

| Traffic | Whose namespace | Filtered in |
| --- | --- | --- |
| Job steps: `apt-get`, the checkout's fetch | the job container | `DOCKER-USER` (a `FORWARD` hook) |
| Job → the resolver on its bridge gateway | job container → the host itself | `INPUT` |
| Pulling the job's own image | the Docker daemon, on the host | the host's `OUTPUT` |
| `docker build` steps, where a job has a daemon | the daemon's own bridge | its own policy |

**Filtering only `DOCKER-USER` leaves the DNS allowlist decorative.** Traffic
to a resolver on the bridge gateway is addressed to the host, so it is an
`INPUT` packet and never passes through `DOCKER-USER` at all, and a job that
can reach any resolver it likes can resolve anything it likes. `INPUT` needs
its own pair of rules: accept port 53 from the bridge, drop the rest.

The upside of the split is that a job's own needs are usually small, because
image pulls and action fetches happen from the host rather than from the job.
For a suite that installs a few packages and checks out a repository, the job
needs the forge and a package mirror, and nothing else.

### A fixed network for jobs, a resolver, and both firewall chains

Point `container.network` at a network you created, with a named bridge, so
that the interface name, subnet and gateway are stable enough to write rules
against. Left empty, `act_runner` creates a network per job and there is no
stable interface to match on. Give it a **private** subnet: `stop-dns-rebind`
below rejects answers in the private ranges, so a reserved-but-not-private
bridge subnet is one that check silently does not cover.

With `runner.capacity: 1` one job occupies that network at a time. Above one,
concurrent jobs share a broadcast domain and can reach each other's service
containers, which is worth knowing before raising it.

The DNS and firewall shape is the same one dejima uses inside its own
container (`docker/dns-proxy.sh` and `docker/init-firewall.sh`), applied one
layer out: allowlist the *names* and let the answers populate the set of
allowed *addresses*.

`dnsmasq` binds the bridge gateway. With `no-resolv` and one `server=` line
per allowed name, every other name gets `REFUSED`, not resolved-then-blocked,
refused, which closes off encoding data into query names to a domain you never
allowed. `ipset=/#/ci-allow` adds every answer it serves to the firewall's
set, so a destination that rotates its edge addresses stays reachable without
a resolver cron chasing it. `rebind-domain-ok` exempts a self-hosted forge,
which legitimately resolves to a private address.

The runner pins its job containers at that resolver - per-runner rather than
daemon-wide, because a daemon-wide setting also reaches containers a
privileged job creates over the Docker socket, which have firewalls of their
own and no route to it. Then two chains filter: `DOCKER-USER` for everything
the job forwards off the bridge, and `INPUT` for the resolver itself, because
the gateway address belongs to the host.

Block IPv6 outright unless you have built the same allowlist for it: an
address family with no allowlist is not a smaller hole than the one you just
closed.

**The working configuration for all of this is in
[dejima-ci-hardener](https://gitbox.branderson.io/dejima/dejima-ci-hardener),
with the ordering constraints and substitution notes attached.** It is
deliberately not reproduced here: two copies of a firewall rule drift, and
dejima-ci-hardener is the one that stays runnable.

## The allowlist comes from `main`, not from the checkout

A dejima project already carries a version-controlled statement of where it is
allowed to reach: `.dejima/allowed-domains`. Use it: read from
**`origin/main`**, over the forge's API, by the runner host.

Never from the checkout. The checkout is the branch's, and a branch that can
write its own allowlist has no allowlist. `main` is yours: it got there
through a pull request you merged.

```sh
curl -fsS -H "Authorization: token $FORGE_TOKEN" \
  "https://gitea.example.com/api/v1/repos/$OWNER/$REPO/raw/.dejima/allowed-domains?ref=main"
```

The consequence is the point of the whole arrangement: **widening what CI can
reach is a diff on `main`.** It is reviewed, it is attributable, it is
revertible, and it happens in the same file and by the same act that widens
what a session can reach. A prompt injection that needs one more destination
has to get that destination past you in a pull request first.

Refresh on a timer, render the `server=` lines, reload `dnsmasq`. Fail closed:
a fetch that errors should leave the previous allowlist in place, never fall
back to allowing everything: an allowlist builder is exactly the kind of
script whose failure mode is easy to get backwards, because the broken version
looks like a working one right up until it matters.
dejima-ci-hardener's `dejima-ci-allowlist` is that, including the distinction
that costs you here: a repository with no declaration is a 404 and ordinary,
while a 401 or a 500 means this run does not know what the allowlist is and
must not render one.

Two things to be deliberate about:

- **The base set should be narrower than dejima's built-ins, not equal to
  them.** A domain judged reasonable for a sandbox was judged as reachable
  from inside a firewalled container. On a runner the same name is reachable
  from a host on your network. `api.anthropic.com`, for one, has no business
  resolving on a runner.
- **One file now grants in two places.** Merging a domain into
  `.dejima/allowed-domains` grants it to sessions *and* to CI. That is the
  price of a single reviewable grant instead of two lists that drift apart,
  and it is worth saying out loud when you review one.

You can shrink what the host itself needs, too: `runner.github_mirror` and
Gitea's `DEFAULT_ACTIONS_URL` both redirect `uses:` action fetches away from
github.com.

## Credentials a run is handed

**The job token.** Every job gets one, asked for or not. On Gitea 1.27 and
later you can set the repository's default to restricted mode (Repository →
Settings → Actions → General): read-only on `code`, `releases` and
`packages`, nothing else. The property that makes it worth having is that
workflow-level `permissions:` is *clamped* by that maximum, so a branch
raising its own cannot exceed it: it is one of the very few controls here
that the branch genuinely cannot touch.

Before 1.27, `permissions:` is ignored and the token is permissive. There is
no supported way to narrow it, which is what makes branch protection above
non-optional rather than merely advisable, and it is a concrete reason to
upgrade.

**Secrets.** A secret exposed to a pull-request-triggered run is a secret
exposed to whatever that branch contains. Give a run only what it needs, and
prefer credentials that cannot do anything else: a token that raises an
anonymous API rate limit should be a fine-grained token with no permissions
and no repository access, not a general-purpose one.

**The cache server.** `act_runner` enables it by default, and it binds on the
runner host specifically so that job containers can reach it. That is an
inbound service exposed to untrusted code. Turn it off where it is not
earning its place.

## CI you do not administer

On hosted CI (GitHub Actions, a shared pool, someone else's infrastructure),
**there is no reliable pre-execution gate for a same-repository branch**, and
the egress section above is unavailable to you: every candidate gate lives in
a file the branch can edit, and the network the job runs on is not yours to
program. That is a limit, not an oversight, and it is better known than
guessed at.

What still applies:

- **A hosted runner gives you the runner-host section for free.** It is
  disposable and it is already off your network. The dangerous case is a
  *self-hosted shared pool*, where a job can land on a machine nobody hardened,
  and where the socket-mounting default above is nobody's decision, just the
  default.
- **The credentials section applies everywhere.** `permissions: contents:
  read` where it is honoured, no secrets on pull-request runs, and no tunnel
  or credential that lets a runner reach your own infrastructure.
- **Branch protection applies everywhere** and costs nothing.
- **So does declining the grant.** If you cannot bound what CI does with push
  access, do not give push access: `[core] forge = none` with
  `[core] workflow = local-only` is a supported configuration in which the
  session commits locally and stops. The push grant *is* the CI
  code-execution grant; declining the first declines the second.

Gitea 1.27's **scoped workflows** are worth knowing about here: a workflow
maintained in a central repository the sandbox cannot push to, registerable
instance-wide, so the workflow file itself sits outside any agent branch's
reach. Use it, but it is not a gate. Scoped workflows run *alongside* a
consuming repository's own workflows rather than replacing them, so a branch
can still add a workflow of its own.

## What this does not stop

- **Code still runs.** Everything here bounds *where* and *with what*, not
  *whether*. There is no point in the flow at which a human reads the diff
  before execution.
- **A repository with no workflows is not therefore safe.** A branch can add
  one, so the exposure follows from which runners the repository can reach,
  not from what it currently runs. Disabling the Actions unit is what makes
  "this project has no CI" into a property rather than a coincidence.
- **An allowed destination is still an exfiltration channel** through its own
  request surface: a query string, a lookup, an issue body. Domain
  allowlisting closes off reaching somewhere *new*; it cannot inspect what is
  sent somewhere already trusted. That is a structural property of
  allowlist-only filtering, and it is the same caveat
  [docs/security.md](security.md) states for the sandbox itself.
- **The repository is not protected by any of this**, and does not need to be.
  A session that can push already has the code; CI does not newly expose it.
- **A job on a runner that legitimately needs the Docker socket owns that
  host** for as long as it takes to rebuild it. Where a job genuinely needs a
  daemon, the answer is a host you are willing to lose, not a smaller grant.
- **Before Gitea 1.27, the job token stays permissive.** Branch protection
  bounds where it can write; it does not take the token away.
- **None of this is checked by anything.** The rest of dejima's security
  properties have tests behind them. A runner's configuration lives on a
  machine this repository has no access to, so it is on you to re-check it
  after upgrades and rebuilds.
