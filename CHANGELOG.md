# Changelog

[← dejima README](README.md)

What each release changed, newest first, for one question: **should I update,
and what will I be getting.** `dejima --version` says which release the
checkout you are running is on.

A release is a date - `2026.10.12` - and the git tag of that name on `main` is
where it lives. A date rather than a version number because the useful fact
about a release is how old it is, and because `MAJOR.MINOR` would be a promise
about compatibility and patch lines that this project does not make.

**No release here is supported.** The tip of `main` is the only supported
version, and that is not a formality: there are no maintenance branches, no
backports and no security releases for older tags. A tag is a record of what
shipped so you can tell what you are missing - not a version to stay on. See
[SECURITY.md](SECURITY.md).

Entries name what an operator would notice. The full detail is in the pull
requests, which are linked.

## Unreleased

Nothing yet. The release pull request that merges `development` into `main`
replaces this heading with the date it merges, and tags `main` with the same
date.

## 2026.10.12

The first release with a version number. Everything before it is `unreleased`,
and a checkout from before this tag reports itself that way.

119 commits, PRs #360-#391 and #399.

### New

- **`dejima --isolated`** runs a session with nothing before it and nothing
  after it: no project mounted, no memory or transcript across either
  boundary, no forge credential unless the same command names a forge, and a
  `~/shared` made fresh for that session alone. For a disposable experiment,
  or anything that should not be able to read what an earlier session did.
  Supported on every shipped harness.
  ([#390](https://gitbox.branderson.io/dejima/dejima/pulls/390),
  [docs](docs/configuration.md#isolated-sessions))
- **`dejima-allow` takes up to twenty domains at once**, printed back one per
  line and confirmed before any is added. One domain is unchanged.
  ([#383](https://gitbox.branderson.io/dejima/dejima/pulls/383))
- **`dejima --version`**, a version on the startup banner, and an update
  notice that names the release you would be getting rather than only a commit
  count.

### Tightened

Each of these refuses or withholds something a previous release allowed.

- **The host entry is clamped to the ports it was told to open**, and the
  clamp is now matched *before* the wider rules. Configuring one host-resident
  service opened every port the host publishes, including sshd and the
  remote-access front door.
  ([#371](https://gitbox.branderson.io/dejima/dejima/pulls/371),
  [#399](https://gitbox.branderson.io/dejima/dejima/pulls/399))
- **The staged `~/.claude.json` carries the launching project's entry and no
  other.** A session was handed the name of every project on the host, a
  sample of each one's filenames, and what each had cost.
  ([#381](https://gitbox.branderson.io/dejima/dejima/pulls/381))
- **The real model credential is mounted only when it is this backend's own
  credential and the proxy is off for it.** A backend needing no credential at
  all - a model you serve yourself - was handed the real subscription login.
  ([#399](https://gitbox.branderson.io/dejima/dejima/pulls/399))
- **The push and merge guards are one policy, read out of argv**, closing
  several spellings that walked past them.
  ([#372](https://gitbox.branderson.io/dejima/dejima/pulls/372),
  [#374](https://gitbox.branderson.io/dejima/dejima/pulls/374))
- **Every store dejima keeps out of a session's reach is warned about** when
  it sits inside the mounted project, not three of the six.
  ([#399](https://gitbox.branderson.io/dejima/dejima/pulls/399))

### What an existing config stops being able to do

Read this part before updating. All of these fail closed, and the first fails
quietly.

- **A host-resident Loki or self-served model configured by NAME needs
  `EGRESS_HOST_PORTS` set to its port.** The clamp is matched before the open
  class now, so an address permitted by name no longer reaches the host on
  every port. A literal address with an explicit port is handled for you. The
  model fails loudly - the session cannot reach it - but **the log shipper
  fails silently**: network logging simply stops. The policy's own summary
  line, `host <addr> on ports none`, is where that shows up.
- **A configured `ssh_key` now withdraws your forwarded ssh-agent from the
  container entirely.** Choosing a dedicated key has to mean your personal
  identities are not in there, rather than merely not the default. If a
  session used the key for the forge and the agent for anything else - a
  second remote, a private submodule - the second half stops working.
  ([#375](https://gitbox.branderson.io/dejima/dejima/pulls/375))
- **An empty `ssh_key` file now counts as no key at all.** A pushing workflow
  with an empty key file and no agent is refused where it used to start and
  fail at the push.
  ([#375](https://gitbox.branderson.io/dejima/dejima/pulls/375))
- **Under the github forge, `gh api` is held to this repository.** A call
  naming no endpoint under `repos/<this repo>/` is refused - `gh api user`,
  `rate_limit`, an org endpoint - as are graphql mutations and reading a body
  from a file (`-F x=@file`, `--input`). An agent that used `gh api` for
  anything outside the repository will notice.
  ([#372](https://gitbox.branderson.io/dejima/dejima/pulls/372),
  [#373](https://gitbox.branderson.io/dejima/dejima/pulls/373))

### Known limitations

Not changes - things this release does not do, worth knowing before relying
on the ones above.

- **The host clamp covers the bridge gateway only.** The host's other
  addresses - its `docker0` address when the run network is a different
  bridge, and its LAN address - are not in it, so a service configured at the
  host's LAN IP is still permitted on every port by the open class.
  ([#401](https://gitbox.branderson.io/dejima/dejima/issues/401))

### Fixed

- The egress policy's resolver checks had no name to check when the forge
  ranges came from a cache file rather than fetched, which is how CI supplies
  them - so every container in a CI run failed to come up. An ordinary
  launch, whose ranges URL always has a host, was unaffected.
  ([#386](https://gitbox.branderson.io/dejima/dejima/pulls/386))
- GitHub's `/meta` ranges are fetched once per CI run rather than once per
  container, and a rate limit is waited out instead of failing the run.
  ([#378](https://gitbox.branderson.io/dejima/dejima/pulls/378))
- Test-suite reliability: a self-check retry that could not see its own
  failure, deadlines that scale with what a run asked of the machine, and a
  teardown race that failed CI intermittently.
  ([#379](https://gitbox.branderson.io/dejima/dejima/pulls/379),
  [#385](https://gitbox.branderson.io/dejima/dejima/pulls/385))
- A harness's per-run configuration is seeded from a staging directory that
  goes away with the launch, rather than written onto the host where it will
  live. For cline that is what lets `--isolated` work at all; for an ordinary
  launch the end state is unchanged.
  ([#393](https://gitbox.branderson.io/dejima/dejima/issues/393))

### Documentation

Two review passes over the whole tree corrected documents that stated the
opposite of the code - including what Ctrl-Z does, what the sandbox tells a
session about a hung connection, and what dejima gives you on its own, without
any of the sister projects around it.
([#370](https://gitbox.branderson.io/dejima/dejima/pulls/370),
[#377](https://gitbox.branderson.io/dejima/dejima/pulls/377),
[#391](https://gitbox.branderson.io/dejima/dejima/pulls/391))

### Rollback

This release adds no config key, so the previous `main` accepts any config
this one accepts. Rolling back restores the behaviour the "stops being able
to" section describes, including the host entry being reachable on every port.
