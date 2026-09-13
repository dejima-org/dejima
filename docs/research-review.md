# Reviewing the state of the art

[← dejima README](../README.md)

dejima's first month, from late July 2026, was spent reasoning from its own
threat model without checking it against anyone else's. The first sweep, in
August, turned up two things worth having found sooner than that:

- **A parser-differential bypass class against egress allowlists**, disclosed
  against another vendor's agent network sandbox: a null byte in a SOCKS5
  hostname, so the policy check read `attacker-host\x00.google.com` and matched
  a `.google.com` suffix while the resolver read `attacker-host`. dejima's
  matcher refused that shape and every neighbouring one, for structural reasons
  now recorded beside it - it matches whole domains rather than suffixes, and
  the decision and the dial are bound by the address set being filled from the
  answer the resolver returned. One laxity turned up and was fixed.
- **The closest comparable project ships the opposite default.** Trail of Bits'
  Claude Code devcontainer lists network under "not sandboxed" and has full
  outbound access unless an operator opts in. Working out why was worth more
  than the comparison: their scope is the host filesystem for an auditor
  watching a session, and network was never the thing they were containing.

Neither changed a control, which is the point. A month is not long to have gone
unchecked, and finding out was cheap - which is the argument for doing it on a
schedule rather than when something goes wrong.

This is the process. It is deliberately small: the failure mode of a research
review is producing a reading list nobody acts on.

## When to run one

**Before locking a control.** This repository's rule is to measure the premise
before designing on it. Extended one step: ask what measurement would falsify
the control, *and* whether someone has already run it - or already bypassed it.

- Before adding or changing a boundary: a mount, an egress path, a guard, a
  credential that crosses.
- When a control is being justified by reasoning rather than by a test. That is
  the moment to find out whether the reasoning is known to be wrong.
- When a bypass is published for anything in the same class. Another project's
  egress allowlist bypass is a test case for this one.
- Quarterly as a standing sweep, whether or not anything is pending. A threat
  model written eighteen months ago describes a different attacker.

That last one is the reason the schedule exists at all. Reported model
capability on offensive security tasks has moved fast enough that a sandbox
designed against a 2024 agent is not obviously adequate against a 2026 one, and
nothing else here re-examines that assumption on any schedule.

## The standing questions

The agenda. Each entry is a live claim dejima rests on, phrased so the field can
contradict it. Keep it current: a question nobody would answer "no" to is not
doing any work.

1. **Is a hardened container an adequate boundary for an agent assumed
   hostile?** The field says no for untrusted code, and tiers gVisor and
   per-workload VM kernels above it. dejima's answer is that escape moves a
   layer - true where the layer exists. See
   [Which deployment this describes](threat-model.md#which-deployment-this-describes)
   and [Why a container, and not a microVM](threat-model.md#why-a-container-and-not-a-microvm),
   which is where the reasoning is written down so a sweep can contradict it.
   The live half of this question is question 5: whether a current escape
   clears this configuration's floor.
2. **Does a name-based egress allowlist hold?** It holds against an agent that
   must resolve a name. It does not hold against exfiltration through an
   allowed domain or against DNS query-name channels, both of which are listed
   in [What dejima does not sandbox](security.md#what-dejima-does-not-sandbox).
   The open part is parser differentials between the matcher and the resolver.
3. **Where must egress enforcement sit?** Below the harness: a subprocess with
   its own HTTP client bypasses anything the harness mediates. dejima enforces
   at the container's network layer, which satisfies this. Settled unless the
   architecture changes.
4. **Is "the operator merges" the right shape for human-in-the-loop?** The
   field's phrasing is "human approval on irreversible actions", which is what
   the merge and push guards implement. Corroborated; stop re-deriving it.
5. **What is the current bypass literature for agent sandboxes?** The most
   valuable question and the one that ages fastest.
6. **Does anyone else treat the previous session's output as hostile input to
   the next one?** The positioning question, and as of the first sweep the
   answer is no.
7. **What does the field consider baseline that dejima does not do?** The
   cheapest question to ask. It found the absence of timeouts, which is now a
   [stated non-goal](security.md#why-there-are-no-timeouts) rather than a gap.
8. **Is a control argued in one layer honoured in the others?** The three
   projects are three repositories with three vocabularies, and nothing checks
   that a claim made in one reaches the next. The first sweep produced the
   worked example: dejima blocks IPv6 outright and says why, `dejima-ci-hardener`
   makes the same argument for its job network - and both sibling projects'
   node-side firewalls were IPv4-only, written later, by people who had already
   made that argument twice. Each project's tests pass, because each tests its
   own layer against its own template. This question is the only thing looking
   at the seams.

## How to run one

**1. Sweep, do not read.** Search broadly and read only summaries. This pass
produces a shortlist, not understanding. Search the standing questions, not
dejima's vocabulary - our terms are ours, and "guarded store" finds nothing.

**2. Read in full only what could change a control.** A source that agrees
changes nothing and can stay a citation. Read the ones describing a bypass of a
control that exists here, quantifying something asserted here, or occupying
ground assumed empty.

**3. Get the mechanism, not the headline.** "Egress allowlists are bypassable"
is not actionable. "The policy check saw one hostname and the resolver saw
another" is a test to write.

**4. Sort every finding into a bucket.**

| bucket | what it means | what to do |
| --- | --- | --- |
| **Prior art** | Someone built this | Read it properly, and start from where they ended. |
| **Corroboration** | They hold the same premise | Cite it, stop re-deriving it, and stop treating it as a differentiator. |
| **Their control** | They defend something dejima does not | Take the *distinction* if it is real. Do not take the *control* without asking what threat model produced it. |
| **Contradiction** | Their default is the opposite | The most valuable bucket. Work out whether the threat models differ before conceding or dismissing. |
| **Open ground** | Nobody does this | Say so, and say *why*. Usually a constraint others do not have; occasionally it means everyone else knows something. |

**5. Write down the contradiction even when it resolves in dejima's favour.**
The default-network difference above is the worked example: it reads as dejima
being ahead, and the reason turned out to be scope rather than rigour.
Recording the reason is what stops a different scope being mistaken for a
weaker one - by us, in six months, reading our own note.

**6. Turn every finding that changes a control into an issue.** A review that
ends in a document has not finished.

## What to record, and where it does not go

**A sweep is not committed here.** It is written to the shared mount on the
operator's machine, alongside the specs, plans and design notes that live
there for the same reason: a review is ephemeral, and what belongs in this
repository is the *action* it produced, not the reasoning that produced it.

What lands here is the outcome - an issue, a pull request, a paragraph in the
documentation section the finding actually bears on. This page is itself an
example: the August 2026 sweep produced a matcher fix, a
[not-sandboxed list](security.md#what-dejima-does-not-sandbox), a
[statement of which deployment the threat model describes](threat-model.md#which-deployment-this-describes),
and a stated non-goal on timeouts. The sweep that produced them stayed on the
operator's machine.

The sweep itself is one page, dated and sourced, in the house style, written
where the other ephemeral documents go. Two rules specific to reviews, because
both distinctions vanish within a week of writing:

- **Mark what was read in full and what came from a search summary.** A summary
  of a bypass is enough to write a test case from and not enough to claim
  dejima is safe from it.
- **Quote claims with their conditions.** "Containers are inadequate" is false
  without "for untrusted code, where the host kernel is the boundary". The
  honesty rules here apply to what is read as much as to what is written.

## The standing test queue

A bypass from the literature is a hypothesis about *their* implementation until
it is run against this one. dejima differs in ways that plausibly change the
answer: enforcement is a packet filter and a restricting resolver rather than an
in-process proxy, the matcher is an anchored shell regex rather than a
string-suffix test, the allowlist matches whole domains rather than suffixes,
and the address sets are populated from the answer the resolver returned rather
than from a second parse of a string.

Each entry states a prediction that can fail.

- **Hostile hostnames against `valid_domain`.** Null bytes, percent-encoding,
  trailing dots, embedded newlines, IDNA, empty labels. Prediction: all refused.
  *Run 2026-08-25: all refused except an empty label, which was accepted and
  has since been fixed.*
- **A published SOCKS-style parser differential, run end to end** rather than
  against the validator alone. Prediction: no path, because nothing in dejima
  speaks SOCKS and the decision and the dial are bound by the address set. Not yet
  run.
- **Redirect chains to a host outside the allowlist.** Prediction: fail at the
  packet filter, because dejima does not mediate HTTP and the connection is
  judged by address. Not yet run.
