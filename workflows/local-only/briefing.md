Git workflow - do this even though nothing stops you from doing otherwise:
- Commit your work locally as you go. Nothing in this session pushes
  anywhere: there is no remote destination configured for it, and
  `git-push-guard.sh` blocks pushes as a backstop.
- Do not open pull requests and do not merge. Neither is part of this
  workflow.
- Report what you committed and stop. If the work needs to reach a remote,
  say so plainly rather than attempting it - that is the operator's call and
  needs a different workflow.
