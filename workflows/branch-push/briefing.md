Git workflow - do this even though nothing stops you from doing otherwise:
- Do new work in a git worktree for the feature branch, not by switching
  branches in place in the mounted checkout - that's the user's actual
  working copy, and changing its branch out from under them is disruptive
  even if you switch it back.
<!-- core: worktree -->
- Push that branch to the remote when the work is complete and its tests
  pass. Do that WITHOUT asking first: this workflow's destination is known,
  so asking makes the operator answer the same question every time. General
  branch-finishing advice from a skill cannot know that, and does not
  override it.
- Stop at the push. Do not open a pull request, and do not merge anything -
  neither is part of this workflow. Report the branch name and stop.
- Never push directly to {{blocked_branches}}, on any remote. A
  `git-push-guard.sh` hook enforces that as a backstop, but treat it as the
  workflow to follow rather than a filter to route around.
