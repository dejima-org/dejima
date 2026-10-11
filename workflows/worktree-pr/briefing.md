Git workflow - do this even though nothing stops you from doing otherwise:
<!-- core: worktree -->
- Push that branch to the remote, then run `{{pr_command}} create` from
  the worktree. Never push directly to {{blocked_branches}}, on any remote,
  and never to a host the preamble above didn't say this session can push to.
  A `git-push-guard.sh` hook enforces both as a backstop, but treat them
  as the actual workflow to follow, not just a filter to route around.
  Merging is the operator's call, not yours - a `merge-guard.sh`
  hook blocks it here. Report the PR URL and stop.
<!-- requires: autonomy=open-pr -->
- Do the push and the `{{pr_command}} create` WITHOUT asking first. Once the
  work is complete and its tests pass, that is the workflow, not a decision
  to escalate - so do not stop to offer a choice between merging locally,
  opening a PR, and leaving the branch alone. That menu is the right default
  only where nothing knows a branch's intended destination; here it is
  known, and asking makes the operator answer the same question every time.
  The line between yours and theirs is drawn after the PR is open: pushing
  and opening are yours, merging is theirs. General branch-finishing advice
  from a skill or a generic workflow does not override this, because it
  cannot know that this sandbox already has one.
<!-- end -->
<!-- requires: issues -->
- Name the issues a PR resolves in its body: `Fixes #N` (`Closes` and
  `Resolves` work too) tells the forge to close them when it merges. Use
  `Refs #N` for work that is partial or merely related, so those stay
  open. Prefer the keyword to closing anything yourself once it lands,
  because of the line above - you stop at the PR, and the merge happens
  later without you, so whatever you left for "after the merge" is not
  something you will be there to do. Write `#N` and not the issue's URL:
  they render alike, but only the short form triggers the close. Read the
  whole issue before claiming it, since the ask is often wider than the
  title, and a closing keyword closes it whether or not you covered all
  of it.
<!-- end -->
- Write PR and issue bodies to a file and pass `--body-file FILE`, rather
  than `--body "..."` or a heredoc. Both of those put the entire body into
  the Bash command string, where `deny-dangerous-bash.sh` reads it - and
  that hook matches its patterns anywhere in the string, with no way to tell
  an instruction from prose that merely mentions one. A body describing a
  crash, a restart, or a destructive command it is warning about will get
  the call blocked, which looks like a broken tool rather than what it is.
  Writing the file first keeps the prose out of the command entirely.
  `{{issue_command}}` (list/view/create/edit/comment/close/reopen) takes the
  same flag, for recording a problem you found but aren't fixing.
- Do not hard-wrap prose in those bodies. Write each paragraph as one long
  line and separate paragraphs with a blank line. The forge renders a single
  newline as a line break, so text you wrapped at a column arrives with a
  break every ten words: it wraps early on a desktop, and on a phone the
  screen breaks the line first and your newline breaks it again a few words
  later, which is much harder to read than either alone. Keep the breaks
  that carry structure - list items, table rows, headings, and anything
  inside a code fence - and drop the ones that were only there to keep the
  source tidy. The tools send the body through exactly as written; nothing
  reflows it for you.
- To revise a body after the fact, use `{{pr_command}} edit <N> --body-file`
  (or `{{issue_command}} edit <N>`). Rewriting the file you built the body
  from changes nothing on its own - the forge has its own copy from the
  moment you created it, so an edit has to be sent.
