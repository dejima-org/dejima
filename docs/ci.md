# CI, and what push access grants

[← dejima README](../README.md)

**Granting a dejima session push access grants it code execution wherever your
CI runs.** That is the whole of it, and everything below is either why it
cannot be gated or what to do about it instead.

> **This document is the why.** For the how, [dejima-ci-hardener](https://gitbox.branderson.io/branderson/dejima-ci-hardener)
> is a self-contained tool that does it — installed on the CI box, never on a
> dejima host, and it does not assume you have read this.

The chain needs no operator action at any step. A session writes code; the
push guard permits a feature branch, which is what it exists to allow; the
session opens a pull request, which its briefing tells it to do without asking
first; `on: pull_request` fires and the runner checks out that commit and runs
it. The code does not have to be a modified workflow file to be executed — a
workflow that runs a test suite is already running every file in it, and a
plausible-looking helper in a test file is a much quieter carrier than an
edited workflow, which shows up in a diff.

The gate this sandbox otherwise relies on — you merge, the agent does not —
sits strictly downstream of that. By the time anyone reads the diff, the code
has run.

This applies to any project developed in a dejima sandbox, not only to dejima
itself. The sandbox bounds what a session can reach directly. It does not
bound what it can arrange to have run elsewhere, and CI is the shortest path
elsewhere.

## What a run actually adds

The code CI executes is code the session already had. Relative to the sandbox,
a run adds three things, and every control in this document maps onto one of
them:

1. **Execution on a host you own** — outside the container, outside the
   allowlist, with whatever that host can reach.
2. **Egress from a network position you own** — no dejima firewall, no DNS
   proxy, ordinary networking.
3. **Credentials the run is handed** — the secrets you configured, plus the
   token the forge injects into every job whether the workflow asks for one or
   not.

Keep those three in view even if none of the specific configuration below
applies to you. They are what changes when a session gains push access, and
they survive translation to CI that looks nothing like this.

## Why this document offers no approval gate

The obvious answer is to require a human to approve a run. Each version of
that turns out to be reachable from the branch, from a credential the session
already holds, or to be no gate at all:

- **Changing the trigger** — `workflow_dispatch` only, or `push` to `main`
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

Every control below that is worth anything roots its trust in `main` — most
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
  instance — see "A label is not a boundary" below. Gitea's own FAQ describes
  gitea.com doing this for its public runners.

Two runners on one VM give you label tiering, not host separation: a job that
cannot get the Docker socket still shares a kernel and a network with a runner
that can. If you only have one machine, that is a real reduction and worth
doing — just do not read it as isolation between the tiers.

## Job containers

The single most consequential setting is one that is invisible from inside a
job. `act_runner` mounts the Docker daemon's socket into every job container
it starts unless `container.docker_host` is set to `"-"`; its own generated
configuration says so:

> If it's `"-"`, act_runner will find an available docker host automatically,
> but the docker host won't be mounted to the job containers and service
> containers.

Access to that socket is root-equivalent on the runner host — `docker run
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
label in the workflow — and if no runner carries the label yet, the job queues
rather than running somewhere unprepared, which is a better failure than a
green run on the wrong host.

### A label is not a boundary

That last paragraph describes routing, not containment, and the difference
matters enough to state on its own.

**`runs-on:` is in the workflow file, and the workflow file is in the branch.**
A branch can name any label it likes. So a dedicated label keeps *honest* jobs
on the runner you prepared; it does nothing against a branch that would rather
run somewhere else. A session that changes `runs-on: dejima-ci` to
`runs-on: ubuntu-latest`, pushes, and opens a pull request has stepped outside
every control on this page — no allowlist, no socket restriction, no firewall
— provided some runner answering `ubuntu-latest` will take the job.

Whether one will is a property of **where your runners are registered**, which
is the actual boundary:

| Registered at | Which repositories it serves |
| --- | --- |
| Instance | **every repository on the instance** |
| Organization | that organization's repositories |
| Repository | that repository |

Gitea has no per-repository runner ACL — its FAQ says so directly, and points
at registration scope as the control instead: gitea.com registers its runners
for one organization "so our runners will not execute jobs from other
repositories."

So the property to hold onto is this: **a repository's CI security posture is
that of the weakest runner it can reach, not the one its workflow names.** An
instance-level general-purpose runner is reachable from every repository on
that instance, including any that takes agent-authored branches.

Three ways out, in rough order of preference:

1. **Do not register general-purpose runners at instance level** on an
   instance that hosts repositories receiving agent-authored branches. Scope
   them to the organizations or repositories that need them.
2. **Harden every runner that repository can reach**, so landing on a
   different one changes nothing that matters.
3. **Move the repository** to an instance or organization whose reachable
   runners are all hardened.

The runner-environment tests in `test/ci-runner.bats` do not close this
either, and for the same reason: they are jobs in the same workflow file, so a
branch that redirects `runs-on` can drop them in the same commit. What they
catch is a *misconfigured* runner, not a *redirected* job.

What does survive the branch is the run log — it records which runner took
each job, so a job that executed somewhere unexpected is visible afterwards.
And a required status check on the runner-environment jobs means a pull
request that deletes them cannot be *merged*. Both are after the fact, which
is this document's whole point: the code has already run.

On capabilities: `--cap-drop=ALL` is the reflex and it breaks `apt-get`, which
needs `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID` and `SETGID` to unpack a
package. Drop what the job demonstrably does not need instead of dropping
everything and discovering the list by failure, and pair whatever you drop
with `--security-opt=no-new-privileges`, which costs nothing and does not
depend on getting the list right.

## Egress

The goal is that a job cannot reach somewhere new — cannot fetch a next stage,
cannot post a repository to a paste service, cannot probe an internal address
— without a human having agreed to that destination first.

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
`INPUT` packet and never passes through `DOCKER-USER` at all — and a job that
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
per allowed name, every other name gets `REFUSED` — not resolved-then-blocked,
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

Block IPv6 outright unless you have built the same allowlist for it — an
address family with no allowlist is not a smaller hole than the one you just
closed.

**The working configuration for all of this is in [`ci/`](../ci/), and
[`ci/README.md`](../ci/README.md) is the step-by-step.** It is deliberately not
reproduced here: two copies of a firewall rule drift, and the one in `ci/` is
the one with the ordering constraints and the substitution notes attached.

## The allowlist comes from `main`, not from the checkout

A dejima project already carries a version-controlled statement of where it is
allowed to reach: `.dejima/allowed-domains`. Use it — read from
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
back to allowing everything — an allowlist builder is exactly the kind of
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
raising its own cannot exceed it — it is one of the very few controls here
that the branch genuinely cannot touch.

Before 1.27, `permissions:` is ignored and the token is permissive. There is
no supported way to narrow it, which is what makes branch protection above
non-optional rather than merely advisable, and it is a concrete reason to
upgrade.

**Secrets.** A secret exposed to a pull-request-triggered run is a secret
exposed to whatever that branch contains. Give a run only what it needs, and
prefer credentials that cannot do anything else — a token that raises an
anonymous API rate limit should be a fine-grained token with no permissions
and no repository access, not a general-purpose one.

**The cache server.** `act_runner` enables it by default, and it binds on the
runner host specifically so that job containers can reach it. That is an
inbound service exposed to untrusted code. Turn it off where it is not
earning its place.

## CI you do not administer

On hosted CI — GitHub Actions, a shared pool, someone else's infrastructure —
**there is no reliable pre-execution gate for a same-repository branch**, and
the egress section above is unavailable to you: every candidate gate lives in
a file the branch can edit, and the network the job runs on is not yours to
program. That is a limit, not an oversight, and it is better known than
guessed at.

What still applies:

- **A hosted runner gives you the runner-host section for free.** It is
  disposable and it is already off your network. The dangerous case is a
  *self-hosted shared pool*, where a job can land on a machine nobody hardened
  — and where the socket-mounting default above is nobody's decision, just the
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
reach. Use it — but it is not a gate. Scoped workflows run *alongside* a
consuming repository's own workflows rather than replacing them, so a branch
can still add a workflow of its own.

## What this does not stop

- **Code still runs.** Everything here bounds *where* and *with what*, not
  *whether*. There is no point in the flow at which a human reads the diff
  before execution.
- **An allowed destination is still an exfiltration channel** through its own
  request surface — a query string, a lookup, an issue body. Domain
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
