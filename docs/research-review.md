# Reviewing the state of the art

[← dejima README](../README.md)

dejima reasoned from its own threat model for its whole life and did not check
it against anyone else's until August 2026. The first sweep found that a bypass
class is documented for exactly the control dejima leans on hardest, and that
the most credible comparable project makes the opposite default choice on it.
Neither changed a control. Both would have been expensive to keep not knowing.

This is the process for not letting that gap open again. It is deliberately
small: the failure mode of a research review is producing a reading list nobody
acts on.

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
   [Which deployment this describes](threat-model.md#which-deployment-this-describes).
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
The first sweep found a security firm's comparable project shipping full
outbound network by default. That reads as dejima being ahead, and working out
why they chose it was worth more than the scoreboard: their scope was the host
filesystem, and network was never what they were containing. Recording that
stops a different scope being mistaken for a weaker one.

**6. Turn every finding that changes a control into an issue.** A review that
ends in a document has not finished.

## What to record

One page per sweep, dated and sourced, in the house style. Two rules specific to
reviews, because both distinctions vanish within a week of writing:

- **Mark what was read in full and what came from a search summary.** A summary
  of a bypass is enough to write a test case from and not enough to claim
  dejima is safe from it.
- **Quote claims with their conditions.** "Containers are inadequate" is false
  without "for untrusted code, where the host kernel is the boundary". The
  honesty rules here apply to what is read as much as to what is written.

## The standing test queue

A bypass from the literature is a hypothesis about *their* implementation until
it is run against this one. dejima differs in ways that plausibly change the
answer: enforcement is `iptables` and a DNS proxy rather than an in-process
proxy, the matcher is an anchored shell regex rather than a string-suffix test,
the allowlist matches whole domains rather than suffixes, and the ipset is
populated from the answer the resolver returned rather than from a second parse
of a string.

Each entry states a prediction that can fail.

- **Hostile hostnames against `valid_domain`.** Null bytes, percent-encoding,
  trailing dots, embedded newlines, IDNA, empty labels. Prediction: all refused.
  *Run 2026-08-25: all refused except an empty label, which was accepted and
  has since been fixed.*
- **A published SOCKS-style parser differential, run end to end** rather than
  against the validator alone. Prediction: no path, because nothing in dejima
  speaks SOCKS and the decision and the dial are bound by the ipset. Not yet
  run.
- **Redirect chains to a host outside the allowlist.** Prediction: fail at the
  ipset, because dejima does not mediate HTTP and the connection is judged by
  address. Not yet run.
