# Optional tools

A tool is a program dejima can put in a session's image that is not the
harness and not a project dependency: something an agent uses to work, that
dejima has looked at first.

None is enabled by default.

```ini
# ~/.config/dejima/config - on this machine, always
[core]
tools = rtk
```

```
# .dejima/tools in the project - shared, and approved before it takes effect
rtk
```

```sh
dejima --include rtk        # or -i rtk, repeatable, for one launch
```

The three are a union rather than a precedence chain: they answer different
questions - what this machine always wants, what this project needs, what this
run is for - and none is a correction of another. The project's half is a
declaration like every other file in `.dejima/`: it grants nothing until
`dejima-project approve` records it in a store outside the container's reach.

## What "optional tool" does not mean

**It does not mean a bare install.** This is the part worth stating first,
because it is the whole difference between this and adding a line to
`.dejima/dependencies`.

A dependency is something a project says it needs and an operator agrees to.
Nobody claims to have read it. A tool is something **dejima ships**, and the
bar for adding one is that dejima has hardened it. That bar applies to every
tool added this way, not only the first:

- **Pinned and checksummed.** A published artifact at a fixed version with a
  `sha256` in the manifest, verified before it is unpacked. Never the
  project's own `curl | sh` installer, which fetches whatever its default
  branch points at today - an image build that produces a different binary on
  different days is one nothing has reviewed.
- **Its network behaviour established, not assumed.** Read the source for
  outbound calls, then check the artifact you are actually shipping, because
  the two can differ. Anything it wants to reach is off unless the firewall
  allowlists it, and a tool that needs a domain allowlisted to function is one
  to argue about rather than to add.
- **Telemetry off at the tool's own switch as well as at the firewall.** Two
  independent offs, because either one can be wrong.
- **Wired up by dejima, not by the tool's installer.** Most of these ship an
  `init` that patches a harness's config file, and what it patches is often
  the same hook surface dejima's guards live on. dejima renders the wiring
  itself so the ordering, and what the file ends up containing, stay dejima's.
- **The guards still hold with it enabled**, and a test says so.

If a tool cannot clear that, it is not an optional tool. It might still be a
dependency a project declares and an operator approves, where the claim being
made is much smaller.

## What a tool may declare

Deliberately little. A tool's manifest names what it is, what installs it,
what its environment needs, and what the session should be told about it.
There is no key for a hook, a mount, a domain or a guard - a tool that needed
one of those would be a change to the boundary rather than a program on PATH,
and would have to be argued for rather than declared.

See `docs/providers.md` for the key-by-key table.

## rtk

[rtk](https://github.com/rtk-ai/rtk) (Apache-2.0) compresses command output
before it reaches the model: `rtk git status` runs git and prints a shorter
form of the result. It makes no model calls of its own - it is a deterministic
filter, so nothing about it sends your code anywhere.

What was checked, since the list above is only worth as much as its worst
entry:

- **Pinned** to the published `x86_64-unknown-linux-musl` release by digest,
  taken from the artifact and confirmed against a second download.
- **Telemetry exists and the project's README does not mention it.** An HTTPS
  ping is compiled into the release binary - visible in the shipped artifact's
  strings, not only in the source - gated on a consent flag that defaults to
  unset. It is off three ways here: consent unset, `RTK_TELEMETRY_DISABLED=1`
  in the image environment, and the endpoint is not allowlisted, so the
  request cannot leave the container even if the first two were wrong.
- **It resolves wrapped commands through PATH.** Measured: `rtk git status`
  with a stub `git` earlier on PATH runs the stub. So dejima's PATH shadows -
  the git guard and the forge guard - still apply to a command run through it,
  which is the property that matters most here.
- **Its Claude Code integration installs a `PreToolUse` hook that rewrites
  commands**, in the same slot dejima's guards occupy. dejima does not install
  that hook. See below.

### Why the hook is not installed

`rtk init` registers a hook that rewrites a Bash command before it runs -
`git push origin main` becomes `rtk git push origin main`. That is the same
`PreToolUse`/`Bash` slot as `deny-dangerous-bash.sh`, `git-push-guard.sh` and
`merge-guard.sh`, and the ordering between a third-party rewrite and dejima's
guards is not something dejima would control once the tool's installer had
written it.

So dejima tells the session the tool exists instead, which is exactly what
rtk's own Cline integration does. That is weaker: the agent chooses when to
use it rather than getting it automatically. It is also the conservative first
position for the first tool of this kind, and the thing that would change it
is a measurement - establishing how Claude Code merges hooks across settings
layers, and whether a guard sees the original command or the rewritten one -
rather than a preference.

Note what is not being claimed: a session can run `rtk git push` itself
whether or not dejima installs the hook. The guards hold because they hold at
the PATH and hook layers, not because the tool is absent.

### Limitation

x86_64 only. The tarball spec names one architecture (issue #97), so an arm64
host cannot use this entry.
