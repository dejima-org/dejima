# Contributing

[← dejima README](README.md)

dejima is under active, rapid development, and it is developed on a private
forge. That forge does not allow account registration, and it does not accept
anonymous issues or pull requests. So there is currently no way for you to
file either, and that is a property of where this lives rather than a comment
on the contribution.

[github.com/dejima-org/dejima](https://github.com/dejima-org/dejima) is a
read-only mirror of `main`, with issues and pull requests turned off.

That will change: this project will provide a way to submit issues and pull
requests. Until it does, if you are using dejima and need it to do something
different, **fork it and make the change in your fork**. Nothing here depends
on an upstream maintainer accepting a patch. The fork is yours to run, and
running it is the point.

## Branches

Work is opened against `development`, which merges to `main` periodically.
`main` is what a reader should expect to be releasable; `development` is
where it happens first.

## Expect it to move

Significant change is coming in the near future. Config keys, interfaces, the
layout of the docs, and the boundaries between the CLIs are all still
settling. A fork taken today will diverge from upstream quickly.

If you do fork, pinning to a commit you have read is more useful here than
tracking a branch that is being rewritten under you.

## If you are running an agent against this repository

`docs/responsible-use.md` applies to dejima itself as much as to anything else
you point it at, and one rule in it is load-bearing here: what reaches `main`
becomes the baseline for everything after it. dejima-ci-hardener reads
`.dejima/allowed-domains` from `origin/main` and treats what it finds there as
reviewed, so a change to that file is a change to what a CI runner will let
through.
